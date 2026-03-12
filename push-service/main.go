package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	nostr "github.com/nbd-wtf/go-nostr"
)

const (
	notificationTypeNewPost          = "new_post"
	notificationTypeNewEmojiReaction = "new_emoji_reaction"
	maxRequestBodyBytes              = 64 << 10
	authHeaderPrefix                 = "Nostr "
	authTTL                          = 5 * time.Minute
)

type config struct {
	listenAddr   string
	databasePath string
	apnsTopic    string
	apnsKeyID    string
	apnsTeamID   string
	apnsKeyP8    string
	apnsDisable  bool
}

type apiServer struct {
	store  *store
	sender pushSender
}

type registerDeviceRequest struct {
	DeviceToken     string `json:"device_token"`
	APNSEnvironment string `json:"apns_environment"`
}

type unregisterDeviceRequest struct {
	DeviceToken string `json:"device_token"`
}

type archiveStateRequest struct {
	ArchivedConversationIDs []string `json:"archived_conversation_ids"`
}

type pushRequest struct {
	NotificationType string   `json:"notification_type"`
	EventID          string   `json:"event_id"`
	ConversationID   string   `json:"conversation_id"`
	RecipientPubkeys []string `json:"recipient_pubkeys"`
	Emoji            string   `json:"emoji,omitempty"`
}

func main() {
	cfg := loadConfig()

	db, err := openDatabase(cfg.databasePath)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer db.Close()

	store, err := newStore(db)
	if err != nil {
		log.Fatalf("initialize store: %v", err)
	}

	sender, err := newPushSender(cfg)
	if err != nil {
		log.Fatalf("initialize APNs sender: %v", err)
	}

	server := &apiServer{
		store:  store,
		sender: sender,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", server.handleHealthz)
	mux.HandleFunc("POST /v1/devices/register", server.handleRegisterDevice)
	mux.HandleFunc("POST /v1/devices/unregister", server.handleUnregisterDevice)
	mux.HandleFunc("PUT /v1/conversations/archive-state", server.handleArchiveState)
	mux.HandleFunc("POST /v1/push", server.handlePush)

	log.Printf("push service listening on %s", cfg.listenAddr)
	if err := http.ListenAndServe(cfg.listenAddr, mux); err != nil {
		log.Fatalf("listen: %v", err)
	}
}

func loadConfig() config {
	return config{
		listenAddr:   envOrDefault("LISTEN_ADDR", ":8787"),
		databasePath: envOrDefault("DATABASE_PATH", "push-service.db"),
		apnsTopic:    strings.TrimSpace(os.Getenv("APNS_TOPIC")),
		apnsKeyID:    strings.TrimSpace(os.Getenv("APNS_KEY_ID")),
		apnsTeamID:   strings.TrimSpace(os.Getenv("APNS_TEAM_ID")),
		apnsKeyP8:    os.Getenv("APNS_KEY_P8"),
		apnsDisable:  os.Getenv("APNS_DISABLE") == "1",
	}
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func (s *apiServer) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *apiServer) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	pubkey, body, ok := authenticateRequest(w, r)
	if !ok {
		return
	}

	var req registerDeviceRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}

	deviceToken := strings.TrimSpace(req.DeviceToken)
	apnsEnvironment := normalizeAPNSEnvironment(req.APNSEnvironment)
	if deviceToken == "" || apnsEnvironment == "" {
		writeError(w, http.StatusBadRequest, "device_token and apns_environment are required")
		return
	}

	if err := s.store.upsertDevice(r.Context(), pubkey, deviceToken, apnsEnvironment); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save device")
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]string{"status": "registered"})
}

func (s *apiServer) handleUnregisterDevice(w http.ResponseWriter, r *http.Request) {
	pubkey, body, ok := authenticateRequest(w, r)
	if !ok {
		return
	}

	var req unregisterDeviceRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}

	deviceToken := strings.TrimSpace(req.DeviceToken)
	if deviceToken == "" {
		writeError(w, http.StatusBadRequest, "device_token is required")
		return
	}

	if err := s.store.deleteDevice(r.Context(), pubkey, deviceToken); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to remove device")
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]string{"status": "unregistered"})
}

func (s *apiServer) handleArchiveState(w http.ResponseWriter, r *http.Request) {
	pubkey, body, ok := authenticateRequest(w, r)
	if !ok {
		return
	}

	var req archiveStateRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}

	archivedConversationIDs := dedupeNonEmpty(req.ArchivedConversationIDs)
	if err := s.store.replaceArchivedConversations(r.Context(), pubkey, archivedConversationIDs); err != nil {
		writeError(w, http.StatusInternalServerError, "failed to save archive state")
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]string{"status": "synced"})
}

func (s *apiServer) handlePush(w http.ResponseWriter, r *http.Request) {
	senderPubkey, body, ok := authenticateRequest(w, r)
	if !ok {
		return
	}

	var req pushRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}

	push := outboundPush{
		NotificationType: strings.TrimSpace(req.NotificationType),
		EventID:          strings.TrimSpace(req.EventID),
		ConversationID:   strings.TrimSpace(req.ConversationID),
		SenderPubkey:     senderPubkey,
		RecipientPubkeys: dedupeNonEmpty(req.RecipientPubkeys),
		Emoji:            strings.TrimSpace(req.Emoji),
	}
	if err := validatePush(push); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	recipientCount := 0
	deviceCount := 0
	for _, recipientPubkey := range push.RecipientPubkeys {
		if recipientPubkey == senderPubkey {
			continue
		}

		archived, err := s.store.isConversationArchived(r.Context(), recipientPubkey, push.ConversationID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to inspect archive state")
			return
		}
		if archived {
			continue
		}

		devices, err := s.store.listDevices(r.Context(), recipientPubkey)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to load devices")
			return
		}
		if len(devices) == 0 {
			continue
		}

		inserted, err := s.store.insertPushDedupe(
			r.Context(),
			push.EventID,
			push.NotificationType,
			recipientPubkey,
		)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to apply push dedupe")
			return
		}
		if !inserted {
			continue
		}

		recipientCount++
		deviceCount += len(devices)

		for _, device := range devices {
			if err := s.sender.send(r.Context(), device, push); err != nil {
				var permanentErr permanentDeviceError
				if errors.As(err, &permanentErr) {
					if disableErr := s.store.disableDevice(
						r.Context(),
						recipientPubkey,
						device.DeviceToken,
						permanentErr.Error(),
					); disableErr != nil {
						log.Printf("disable device failed for %s: %v", recipientPubkey, disableErr)
					}
					continue
				}
				log.Printf(
					"push send failed type=%s event=%s recipient=%s token=%s err=%v",
					push.NotificationType,
					push.EventID,
					recipientPubkey,
					device.DeviceToken,
					err,
				)
			}
		}
	}

	writeJSON(
		w,
		http.StatusAccepted,
		map[string]any{
			"status":            "accepted",
			"recipient_count":   recipientCount,
			"candidate_devices": deviceCount,
		},
	)
}

func validatePush(push outboundPush) error {
	if push.NotificationType != notificationTypeNewPost && push.NotificationType != notificationTypeNewEmojiReaction {
		return errors.New("unsupported notification_type")
	}
	if push.EventID == "" {
		return errors.New("event_id is required")
	}
	if push.ConversationID == "" {
		return errors.New("conversation_id is required")
	}
	if len(push.RecipientPubkeys) == 0 {
		return errors.New("recipient_pubkeys is required")
	}
	if push.NotificationType == notificationTypeNewEmojiReaction && push.Emoji == "" {
		return errors.New("emoji is required for new_emoji_reaction")
	}
	return nil
}

func authenticateRequest(w http.ResponseWriter, r *http.Request) (string, []byte, bool) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBodyBytes))
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to read request body")
		return "", nil, false
	}

	pubkey, err := verifyAuthorizationHeader(r, body)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return "", nil, false
	}

	return pubkey, body, true
}

func verifyAuthorizationHeader(r *http.Request, body []byte) (string, error) {
	headerValue := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(headerValue, authHeaderPrefix) {
		return "", errors.New("missing Authorization header")
	}

	encoded := strings.TrimSpace(strings.TrimPrefix(headerValue, authHeaderPrefix))
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", errors.New("invalid Authorization header encoding")
	}

	var event nostr.Event
	if err := json.Unmarshal(decoded, &event); err != nil {
		return "", errors.New("invalid Authorization header payload")
	}

	if event.Kind != nostr.KindHTTPAuth {
		return "", errors.New("invalid auth event kind")
	}

	ok, err := event.CheckSignature()
	if err != nil || !ok {
		return "", errors.New("invalid auth event signature")
	}

	now := time.Now()
	if event.CreatedAt.Time().Before(now.Add(-authTTL)) || event.CreatedAt.Time().After(now.Add(authTTL)) {
		return "", errors.New("stale auth event")
	}

	if tagValue(event.Tags, "method") != r.Method {
		return "", errors.New("auth event method mismatch")
	}
	if tagValue(event.Tags, "path") != r.URL.Path {
		return "", errors.New("auth event path mismatch")
	}

	bodyHash := sha256.Sum256(body)
	if tagValue(event.Tags, "payload_sha256") != hex.EncodeToString(bodyHash[:]) {
		return "", errors.New("auth event body hash mismatch")
	}

	if strings.TrimSpace(event.PubKey) == "" {
		return "", errors.New("auth event pubkey missing")
	}

	return event.PubKey, nil
}

func tagValue(tags nostr.Tags, key string) string {
	for _, tag := range tags {
		if len(tag) >= 2 && tag[0] == key {
			return tag[1]
		}
	}
	return ""
}

func dedupeNonEmpty(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		if _, exists := seen[trimmed]; exists {
			continue
		}
		seen[trimmed] = struct{}{}
		result = append(result, trimmed)
	}
	return result
}

func normalizeAPNSEnvironment(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "sandbox":
		return "sandbox"
	case "production":
		return "production"
	default:
		return ""
	}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{
		"error": message,
	})
}

func openDatabase(databasePath string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		return nil, err
	}

	pragmas := []string{
		"PRAGMA journal_mode = WAL;",
		"PRAGMA synchronous = NORMAL;",
		"PRAGMA foreign_keys = ON;",
	}
	for _, pragma := range pragmas {
		if _, err := db.Exec(pragma); err != nil {
			_ = db.Close()
			return nil, err
		}
	}

	return db, nil
}

func withTimeoutContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, 15*time.Second)
}
