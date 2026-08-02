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
	s.sent = append(s.sent, sentPush{device: device, push: push})
	return s.sendErr
}

func TestRegisterDeviceAndPushSendsToNonArchivedRecipient(t *testing.T) {
	handler, sender := newTestMux(t)
	senderSecret, senderPubkey := testIdentity(t)
	recipientSecret, recipientPubkey := testIdentity(t)
	registerTestDevice(t, handler, recipientSecret, "device-token-1", "sandbox")

	recorder := performSignedJSONRequest(
		t,
		handler,
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
	)
	var response struct {
		Status           string `json:"status"`
		RecipientCount   int    `json:"recipient_count"`
		CandidateDevices int    `json:"candidate_devices"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response body: %v", err)
	}

	if response.Status != "accepted" || response.RecipientCount != 1 || response.CandidateDevices != 1 {
		t.Fatalf("unexpected push response: %#v", response)
	}
	if len(sender.sent) != 1 || sender.sent[0].device.DeviceToken != "device-token-1" {
		t.Fatalf("unexpected sends: %#v", sender.sent)
	}
	if sender.sent[0].push.NotificationType != notificationTypeNewPost {
		t.Fatalf("unexpected push: %#v", sender.sent[0].push)
	}
}

func TestPushSkipsArchivedConversation(t *testing.T) {
	handler, sender := newTestMux(t)
	senderSecret, _ := testIdentity(t)
	recipientSecret, recipientPubkey := testIdentity(t)
	registerTestDevice(t, handler, recipientSecret, "device-token-1", "sandbox")
	performSignedJSONRequest(
		t,
		handler,
		"PUT",
		"/v1/conversations/archive-state",
		archiveStateRequest{ArchivedConversationIDs: []string{"conversation-1"}},
		recipientSecret,
		http.StatusAccepted,
	)
	sendTestPush(t, handler, senderSecret, recipientPubkey, "event-1")

	if len(sender.sent) != 0 {
		t.Fatalf("expected archived conversation to suppress push, got %d sends", len(sender.sent))
	}
}

func TestPushDedupeSuppressesRepeatDelivery(t *testing.T) {
	handler, sender := newTestMux(t)
	senderSecret, _ := testIdentity(t)
	recipientSecret, recipientPubkey := testIdentity(t)
	registerTestDevice(t, handler, recipientSecret, "device-token-1", "sandbox")

	request := pushRequest{
		NotificationType: notificationTypeNewEmojiReaction,
		EventID:          "event-1",
		ConversationID:   "conversation-1",
		RecipientPubkeys: []string{recipientPubkey},
		Emoji:            "🔥",
	}
	for range 2 {
		performSignedJSONRequest(t, handler, "POST", "/v1/push", request, senderSecret, http.StatusAccepted)
	}

	if len(sender.sent) != 1 {
		t.Fatalf("expected dedupe to keep a single send, got %d", len(sender.sent))
	}
}

func TestPermanentAPNSErrorRemovesDevice(t *testing.T) {
	handler, sender := newTestMux(t)
	sender.sendErr = permanentDeviceError("apns rejection: Unregistered")
	senderSecret, _ := testIdentity(t)
	recipientSecret, recipientPubkey := testIdentity(t)
	registerTestDevice(t, handler, recipientSecret, "invalid-device-token", "production")

	for _, eventID := range []string{"event-1", "event-2"} {
		sendTestPush(t, handler, senderSecret, recipientPubkey, eventID)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("expected invalid token to be removed after one send, got %d attempts", len(sender.sent))
	}
}

func TestUnregisterDeviceRemovesPushTarget(t *testing.T) {
	handler, sender := newTestMux(t)
	senderSecret, _ := testIdentity(t)
	recipientSecret, recipientPubkey := testIdentity(t)
	registerTestDevice(t, handler, recipientSecret, "device-token-1", "sandbox")
	performSignedJSONRequest(
		t,
		handler,
		"POST",
		"/v1/devices/unregister",
		unregisterDeviceRequest{DeviceToken: "device-token-1"},
		recipientSecret,
		http.StatusAccepted,
	)
	sendTestPush(t, handler, senderSecret, recipientPubkey, "event-1")

	if len(sender.sent) != 0 {
		t.Fatalf("expected no sends after unregister, got %d", len(sender.sent))
	}
}

func TestPushSkipsSelfSendRecipients(t *testing.T) {
	handler, sender := newTestMux(t)
	senderSecret, senderPubkey := testIdentity(t)
	sendTestPush(t, handler, senderSecret, senderPubkey, "event-1")
	if len(sender.sent) != 0 {
		t.Fatalf("expected self-send recipients to be skipped, got %d sends", len(sender.sent))
	}
}

func TestMissingAuthorizationIsRejected(t *testing.T) {
	handler, _ := newTestMux(t)
	body, err := json.Marshal(registerDeviceRequest{
		DeviceToken:     "device-token-1",
		APNSEnvironment: "sandbox",
	})
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest("POST", "/v1/devices/register", bytes.NewReader(body)))
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestAuthorizationNonceReplayIsRejected(t *testing.T) {
	handler, _ := newTestMux(t)
	secret, _ := testIdentity(t)
	body, err := json.Marshal(registerDeviceRequest{
		DeviceToken:     "device-token-1",
		APNSEnvironment: "sandbox",
	})
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	firstRequest, err := signedJSONRequest("POST", "/v1/devices/register", body, secret)
	if err != nil {
		t.Fatalf("build signed request: %v", err)
	}
	firstRecorder := httptest.NewRecorder()
	handler.ServeHTTP(firstRecorder, firstRequest)
	if firstRecorder.Code != http.StatusAccepted {
		t.Fatalf("expected first request to succeed, got %d body=%s", firstRecorder.Code, firstRecorder.Body.String())
	}

	secondRequest := httptest.NewRequest("POST", "/v1/devices/register", bytes.NewReader(body))
	secondRequest.Header.Set("Authorization", firstRequest.Header.Get("Authorization"))
	secondRecorder := httptest.NewRecorder()
	handler.ServeHTTP(secondRecorder, secondRequest)
	if secondRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected replay to be rejected, got %d body=%s", secondRecorder.Code, secondRecorder.Body.String())
	}
}

func TestOversizedRequestIsRejected(t *testing.T) {
	handler, _ := newTestMux(t)
	secret, _ := testIdentity(t)
	body := bytes.Repeat([]byte("x"), maxRequestBodyBytes+1)
	request, err := signedJSONRequest("POST", "/v1/devices/register", body, secret)
	if err != nil {
		t.Fatalf("build signed request: %v", err)
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected oversized request to be rejected, got %d", recorder.Code)
	}
}

func TestNewPushSenderRequiresAPNSConfigWhenNotDisabled(t *testing.T) {
	if _, err := newPushSender(config{}); err == nil {
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
	store, _ := newTestStore(t)
	sender := &capturingSender{}
	return newHTTPHandler(&apiServer{store: store, sender: sender}), sender
}

func testIdentity(t *testing.T) (string, string) {
	t.Helper()
	secret := nostr.GeneratePrivateKey()
	pubkey, err := nostr.GetPublicKey(secret)
	if err != nil {
		t.Fatalf("get public key: %v", err)
	}
	return secret, pubkey
}

func registerTestDevice(t *testing.T, handler http.Handler, secret, deviceToken, environment string) {
	t.Helper()
	performSignedJSONRequest(
		t,
		handler,
		"POST",
		"/v1/devices/register",
		registerDeviceRequest{DeviceToken: deviceToken, APNSEnvironment: environment},
		secret,
		http.StatusAccepted,
	)
}

func sendTestPush(t *testing.T, handler http.Handler, secret, recipientPubkey, eventID string) {
	t.Helper()
	performSignedJSONRequest(
		t,
		handler,
		"POST",
		"/v1/push",
		pushRequest{
			NotificationType: notificationTypeNewPost,
			EventID:          eventID,
			ConversationID:   "conversation-1",
			RecipientPubkeys: []string{recipientPubkey},
		},
		secret,
		http.StatusAccepted,
	)
}

func performSignedJSONRequest(
	t *testing.T,
	handler http.Handler,
	method, path string,
	body any,
	secret string,
	expectedStatus int,
) *httptest.ResponseRecorder {
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
	return recorder
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
	request.Header.Set("Authorization", "Nostr "+base64.StdEncoding.EncodeToString(authPayload))
	return request, nil
}
