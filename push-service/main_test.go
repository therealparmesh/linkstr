package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	nostr "github.com/nbd-wtf/go-nostr"
)

type sentPush struct {
	device registeredDevice
	push   outboundPush
}

type capturingSender struct {
	sent    []sentPush
	sendErr error
}

func (s *capturingSender) send(_ context.Context, device registeredDevice, push outboundPush) error {
	s.sent = append(s.sent, sentPush{
		device: device,
		push:   push,
	})
	return s.sendErr
}

func TestRegisterDeviceAndPushSendsToNonArchivedRecipient(t *testing.T) {
	mux, sender := newTestMux(t)

	senderSecret := nostr.GeneratePrivateKey()
	senderPubkey, err := nostr.GetPublicKey(senderSecret)
	if err != nil {
		t.Fatalf("get sender pubkey: %v", err)
	}

	recipientSecret := nostr.GeneratePrivateKey()
	recipientPubkey, err := nostr.GetPublicKey(recipientSecret)
	if err != nil {
		t.Fatalf("get recipient pubkey: %v", err)
	}

	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/devices/register",
		registerDeviceRequest{
			DeviceToken:     "device-token-1",
			APNSEnvironment: "sandbox",
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)

	var response struct {
		Status           string `json:"status"`
		RecipientCount   int    `json:"recipient_count"`
		CandidateDevices int    `json:"candidate_devices"`
	}
	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/push",
		pushRequest{
			NotificationType: notificationTypeNewPost,
			EventID:          "event-1",
			ConversationID:   "conversation-1",
			RecipientPubkeys: []string{senderPubkey, recipientPubkey},
		},
		senderSecret,
		http.StatusAccepted,
		&response,
	)

	if response.Status != "accepted" {
		t.Fatalf("expected accepted status, got %#v", response)
	}
	if response.RecipientCount != 1 || response.CandidateDevices != 1 {
		t.Fatalf("unexpected push counts: %#v", response)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("expected 1 delivered push, got %d", len(sender.sent))
	}
	if sender.sent[0].device.DeviceToken != "device-token-1" {
		t.Fatalf("unexpected device token: %#v", sender.sent[0].device)
	}
	if sender.sent[0].push.NotificationType != notificationTypeNewPost {
		t.Fatalf("unexpected notification type: %#v", sender.sent[0].push)
	}
}

func TestPushSkipsArchivedConversation(t *testing.T) {
	mux, sender := newTestMux(t)

	senderSecret := nostr.GeneratePrivateKey()
	recipientSecret := nostr.GeneratePrivateKey()
	recipientPubkey, err := nostr.GetPublicKey(recipientSecret)
	if err != nil {
		t.Fatalf("get recipient pubkey: %v", err)
	}

	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/devices/register",
		registerDeviceRequest{
			DeviceToken:     "device-token-1",
			APNSEnvironment: "sandbox",
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)
	performSignedJSONRequest(
		t,
		mux,
		"PUT",
		"/v1/conversations/archive-state",
		archiveStateRequest{
			ArchivedConversationIDs: []string{"conversation-1"},
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)
	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/push",
		pushRequest{
			NotificationType: notificationTypeNewPost,
			EventID:          "event-1",
			ConversationID:   "conversation-1",
			RecipientPubkeys: []string{recipientPubkey},
		},
		senderSecret,
		http.StatusAccepted,
		nil,
	)

	if len(sender.sent) != 0 {
		t.Fatalf("expected archived conversation to suppress push, got %d sends", len(sender.sent))
	}
}

func TestPushDedupeSuppressesRepeatDelivery(t *testing.T) {
	mux, sender := newTestMux(t)

	senderSecret := nostr.GeneratePrivateKey()
	recipientSecret := nostr.GeneratePrivateKey()
	recipientPubkey, err := nostr.GetPublicKey(recipientSecret)
	if err != nil {
		t.Fatalf("get recipient pubkey: %v", err)
	}

	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/devices/register",
		registerDeviceRequest{
			DeviceToken:     "device-token-1",
			APNSEnvironment: "sandbox",
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)

	requestBody := pushRequest{
		NotificationType: notificationTypeNewEmojiReaction,
		EventID:          "event-1",
		ConversationID:   "conversation-1",
		RecipientPubkeys: []string{recipientPubkey},
		Emoji:            "🔥",
	}
	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/push",
		requestBody,
		senderSecret,
		http.StatusAccepted,
		nil,
	)
	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/push",
		requestBody,
		senderSecret,
		http.StatusAccepted,
		nil,
	)

	if len(sender.sent) != 1 {
		t.Fatalf("expected dedupe to keep a single send, got %d", len(sender.sent))
	}
}

func TestPermanentAPNSErrorRemovesDevice(t *testing.T) {
	mux, sender := newTestMux(t)
	sender.sendErr = permanentDeviceError{reason: "apns rejection: Unregistered"}

	senderSecret := nostr.GeneratePrivateKey()
	recipientSecret := nostr.GeneratePrivateKey()
	recipientPubkey, err := nostr.GetPublicKey(recipientSecret)
	if err != nil {
		t.Fatalf("get recipient pubkey: %v", err)
	}

	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/devices/register",
		registerDeviceRequest{
			DeviceToken:     "invalid-device-token",
			APNSEnvironment: "production",
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)

	for _, eventID := range []string{"event-1", "event-2"} {
		performSignedJSONRequest(
			t,
			mux,
			"POST",
			"/v1/push",
			pushRequest{
				NotificationType: notificationTypeNewPost,
				EventID:          eventID,
				ConversationID:   "conversation-1",
				RecipientPubkeys: []string{recipientPubkey},
			},
			senderSecret,
			http.StatusAccepted,
			nil,
		)
	}

	if len(sender.sent) != 1 {
		t.Fatalf("expected invalid token to be removed after one send, got %d attempts", len(sender.sent))
	}
}

func TestUnregisterDeviceRemovesPushTarget(t *testing.T) {
	mux, sender := newTestMux(t)

	senderSecret := nostr.GeneratePrivateKey()
	recipientSecret := nostr.GeneratePrivateKey()
	recipientPubkey, err := nostr.GetPublicKey(recipientSecret)
	if err != nil {
		t.Fatalf("get recipient pubkey: %v", err)
	}

	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/devices/register",
		registerDeviceRequest{
			DeviceToken:     "device-token-1",
			APNSEnvironment: "sandbox",
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)
	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/devices/unregister",
		unregisterDeviceRequest{
			DeviceToken: "device-token-1",
		},
		recipientSecret,
		http.StatusAccepted,
		nil,
	)
	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/push",
		pushRequest{
			NotificationType: notificationTypeNewPost,
			EventID:          "event-1",
			ConversationID:   "conversation-1",
			RecipientPubkeys: []string{recipientPubkey},
		},
		senderSecret,
		http.StatusAccepted,
		nil,
	)

	if len(sender.sent) != 0 {
		t.Fatalf("expected no sends after unregister, got %d", len(sender.sent))
	}
}

func TestPushSkipsSelfSendRecipients(t *testing.T) {
	mux, sender := newTestMux(t)

	senderSecret := nostr.GeneratePrivateKey()
	senderPubkey, err := nostr.GetPublicKey(senderSecret)
	if err != nil {
		t.Fatalf("get sender pubkey: %v", err)
	}

	performSignedJSONRequest(
		t,
		mux,
		"POST",
		"/v1/push",
		pushRequest{
			NotificationType: notificationTypeNewPost,
			EventID:          "event-1",
			ConversationID:   "conversation-1",
			RecipientPubkeys: []string{senderPubkey},
		},
		senderSecret,
		http.StatusAccepted,
		nil,
	)

	if len(sender.sent) != 0 {
		t.Fatalf("expected self-send recipients to be skipped, got %d sends", len(sender.sent))
	}
}

func TestMissingAuthorizationIsRejected(t *testing.T) {
	mux, _ := newTestMux(t)

	requestBody, err := json.Marshal(registerDeviceRequest{
		DeviceToken:     "device-token-1",
		APNSEnvironment: "sandbox",
	})
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	request := httptest.NewRequest(
		"POST",
		"/v1/devices/register",
		bytes.NewReader(requestBody),
	)
	request.Header.Set("Content-Type", "application/json")

	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for missing auth, got %d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestAuthorizationNonceReplayIsRejected(t *testing.T) {
	mux, _ := newTestMux(t)
	secret := nostr.GeneratePrivateKey()

	requestBody, err := json.Marshal(registerDeviceRequest{
		DeviceToken:     "device-token-1",
		APNSEnvironment: "sandbox",
	})
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	firstRequest, err := signedJSONRequest("POST", "/v1/devices/register", requestBody, secret)
	if err != nil {
		t.Fatalf("build signed request: %v", err)
	}
	authHeader := firstRequest.Header.Get("Authorization")

	firstRecorder := httptest.NewRecorder()
	mux.ServeHTTP(firstRecorder, firstRequest)
	if firstRecorder.Code != http.StatusAccepted {
		t.Fatalf("expected first request to succeed, got %d body=%s", firstRecorder.Code, firstRecorder.Body.String())
	}

	secondRequest := httptest.NewRequest(
		"POST",
		"/v1/devices/register",
		bytes.NewReader(requestBody),
	)
	secondRequest.Header.Set("Content-Type", "application/json")
	secondRequest.Header.Set("Authorization", authHeader)

	secondRecorder := httptest.NewRecorder()
	mux.ServeHTTP(secondRecorder, secondRequest)
	if secondRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected replay to be rejected, got %d body=%s", secondRecorder.Code, secondRecorder.Body.String())
	}
}

func TestNewPushSenderRequiresAPNSConfigWhenNotDisabled(t *testing.T) {
	_, err := newPushSender(config{})
	if err == nil {
		t.Fatal("expected missing APNs config to fail when APNS_DISABLE is not set")
	}
}

func TestNewPushSenderAllowsNoOpWhenDisabled(t *testing.T) {
	sender, err := newPushSender(config{apnsDisable: true})
	if err != nil {
		t.Fatalf("expected APNS_DISABLE to allow no-op sender: %v", err)
	}
	if _, ok := sender.(noOpSender); !ok {
		t.Fatalf("expected noOpSender, got %T", sender)
	}
}

func newTestMux(t *testing.T) (*http.ServeMux, *capturingSender) {
	t.Helper()

	dbPath := filepath.Join(t.TempDir(), "push-service.db")
	db, err := openDatabase(dbPath)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() {
		_ = db.Close()
	})

	store, err := newStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	sender := &capturingSender{}
	server := &apiServer{
		store:  store,
		sender: sender,
	}

	return newHTTPHandler(server), sender
}

func performSignedJSONRequest(
	t *testing.T,
	handler http.Handler,
	method, path string,
	body any,
	secret string,
	expectedStatus int,
	responseBody any,
) {
	t.Helper()

	requestBody, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	request, err := signedJSONRequest(method, path, requestBody, secret)
	if err != nil {
		t.Fatalf("build signed request: %v", err)
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != expectedStatus {
		t.Fatalf("unexpected status %d body=%s", recorder.Code, recorder.Body.String())
	}

	if responseBody != nil {
		if err := json.Unmarshal(recorder.Body.Bytes(), responseBody); err != nil {
			t.Fatalf("decode response body: %v", err)
		}
	}
}

func signedJSONRequest(method, path string, body []byte, secret string) (*http.Request, error) {
	bodyHash := sha256.Sum256(body)
	event := nostr.Event{
		CreatedAt: nostr.Now(),
		Kind:      nostr.KindHTTPAuth,
		Tags: nostr.Tags{
			{"method", method},
			{"path", path},
			{"payload_sha256", hex.EncodeToString(bodyHash[:])},
			{"nonce", nostr.GeneratePrivateKey()},
		},
		Content: "",
	}
	if err := event.Sign(secret); err != nil {
		return nil, err
	}

	authPayload, err := json.Marshal(event)
	if err != nil {
		return nil, err
	}

	request := httptest.NewRequest(method, path, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(
		"Authorization",
		"Nostr "+base64.StdEncoding.EncodeToString(authPayload),
	)
	return request, nil
}
