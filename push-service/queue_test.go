package main

import (
	"context"
	"errors"
	"net/http"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestQueuedPushSurvivesRestartAndRetriesOnlyFailedDevice(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "queue.db")
	db, err := openDatabase(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err := newStore(db)
	if err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{"healthy", "unavailable"} {
		if err := store.upsertDevice(ctx, "recipient", token, "production"); err != nil {
			t.Fatal(err)
		}
	}
	push := outboundPush{NotificationType: notificationTypeNewEmojiReaction, EventID: "reaction",
		ConversationID: "session", RecipientPubkeys: []string{"recipient"}, Emoji: "🔥", PostID: "post"}
	var requests sync.WaitGroup
	for range 8 {
		requests.Go(func() {
			if _, _, err := store.enqueuePush(ctx, "sender", push); err != nil {
				t.Error(err)
			}
		})
	}
	requests.Wait()
	sender := &capturingSender{sendErr: errors.New("temporary APNs failure"), failDevice: "unavailable"}
	server := &apiServer{store: store, sender: sender}
	drainTestPushes(t, server, time.Now())
	if len(sender.sent) != 2 {
		t.Fatalf("concurrent duplicate requests produced %d sends", len(sender.sent))
	}
	expires := sender.sent[0].push.ExpiresAt
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = openDatabase(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	store, err = newStore(db)
	if err != nil {
		t.Fatal(err)
	}
	sender = &capturingSender{}
	drainTestPushes(t, &apiServer{store: store, sender: sender}, time.Now().Add(time.Minute))
	if len(sender.sent) != 1 || sender.sent[0].device.DeviceToken != "unavailable" {
		t.Fatalf("restart did not retry just the failed device: %#v", sender.sent)
	}
	retried := sender.sent[0].push
	if !retried.ExpiresAt.Equal(expires) || retried.EventID != push.EventID ||
		retried.PostID != push.PostID || retried.Emoji != push.Emoji {
		t.Fatalf("retry changed expiry or reaction navigation: %#v", retried)
	}
	assertPendingPushes(t, store, 0)
}

func TestPendingPushesRespectArchiveDeviceChangesAndExpiry(t *testing.T) {
	for _, change := range []string{"archive", "unregister", "change account", "expire"} {
		t.Run(change, func(t *testing.T) {
			ctx := context.Background()
			store, db := newTestStore(t)
			for _, owner := range []string{"affected", "control"} {
				if err := store.upsertDevice(ctx, owner, owner+"-token", "production"); err != nil {
					t.Fatal(err)
				}
			}
			if _, _, err := store.enqueuePush(ctx, "sender", outboundPush{
				NotificationType: notificationTypeNewPost, EventID: "post", ConversationID: "session",
				RecipientPubkeys: []string{"affected", "control"},
			}); err != nil {
				t.Fatal(err)
			}
			assertPendingPushes(t, store, 2)
			var err error
			switch change {
			case "archive":
				err = store.replaceArchivedConversations(ctx, "affected", []string{"session"}, []string{"session"})
			case "unregister":
				err = store.deleteDevice(ctx, "affected", "affected-token")
			case "change account":
				err = store.upsertDevice(ctx, "new-owner", "affected-token", "production")
			case "expire":
				_, err = db.Exec(`UPDATE push_jobs SET expires_at = ? WHERE recipient_pubkey = ?`, time.Now().Add(-time.Second).Unix(), "affected")
			}
			if err != nil {
				t.Fatal(err)
			}
			sender := &capturingSender{}
			drainTestPushes(t, &apiServer{store: store, sender: sender}, time.Now())
			if len(sender.sent) != 1 || sender.sent[0].device.DeviceToken != "control-token" {
				t.Fatalf("cancelled notification was sent or control was lost: %#v", sender.sent)
			}
			assertPendingPushes(t, store, 0)
		})
	}
}

func TestQueueFailureRollsBackAllDevicesAndDedupe(t *testing.T) {
	store, db := newTestStore(t)
	server := &apiServer{store: store, sender: &capturingSender{}}
	handler := newHTTPHandler(server)
	senderSecret, _ := testIdentity(t)
	recipientSecret, recipient := testIdentity(t)
	for _, token := range []string{"first", "second"} {
		registerTestDevice(t, handler, recipientSecret, token, "production")
	}
	if _, err := db.Exec(`CREATE TRIGGER simulate_disk_failure BEFORE INSERT ON push_jobs
		WHEN NEW.device_token = 'second' BEGIN SELECT RAISE(ABORT, 'disk failure'); END;`); err != nil {
		t.Fatal(err)
	}
	request := pushRequest{NotificationType: notificationTypeNewPost, EventID: "post",
		ConversationID: "session", RecipientPubkeys: []string{recipient}}
	performSignedJSONRequest(t, handler, "POST", "/v1/push", request, senderSecret, http.StatusInternalServerError)
	assertPendingPushes(t, store, 0)
	if _, err := db.Exec(`DROP TRIGGER simulate_disk_failure`); err != nil {
		t.Fatal(err)
	}
	performSignedJSONRequest(t, handler, "POST", "/v1/push", request, senderSecret, http.StatusAccepted)
	assertPendingPushes(t, store, 2)
}

type interruptedSender struct {
	started chan struct{}
}

func (s interruptedSender) send(ctx context.Context, _ registeredDevice, _ outboundPush) error {
	close(s.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestWorkerStartsWithSavedJobsAndPreservesInterruptedDelivery(t *testing.T) {
	store, _ := newTestStore(t)
	if err := store.upsertDevice(context.Background(), "recipient", "token", "production"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.enqueuePush(context.Background(), "sender", outboundPush{
		NotificationType: notificationTypeNewPost, EventID: "post", ConversationID: "session",
		RecipientPubkeys: []string{"recipient"},
	}); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	server := &apiServer{store: store, sender: interruptedSender{started}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { defer close(done); server.runPushWorker(ctx) }()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("saved notification did not resume without a new HTTP request")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("worker did not stop on shutdown")
	}
	assertPendingPushes(t, store, 1)
	sender := &capturingSender{}
	drainTestPushes(t, &apiServer{store: store, sender: sender}, time.Now())
	if len(sender.sent) != 1 {
		t.Fatal("interrupted notification was lost")
	}
}

func drainTestPushes(t *testing.T, server *apiServer, now time.Time) {
	t.Helper()
	for {
		delivered, err := server.deliverNextPush(context.Background(), now)
		if err != nil {
			t.Fatal(err)
		}
		if !delivered {
			return
		}
	}
}

func assertPendingPushes(t *testing.T, store *store, expected int) {
	t.Helper()
	var count int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM push_jobs`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != expected {
		t.Fatalf("expected %d pending deliveries, got %d", expected, count)
	}
}
