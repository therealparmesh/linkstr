package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func TestEnqueuePushPrunesExpiredDedupeRows(t *testing.T) {
	store, db := newTestStore(t)
	insertExpiredDedupe(t, db)

	if err := store.upsertDevice(context.Background(), "recipient", "token", "production"); err != nil {
		t.Fatal(err)
	}
	recipients, _, err := store.enqueuePush(context.Background(), "sender", outboundPush{
		EventID: "current-event", NotificationType: notificationTypeNewPost,
		ConversationID: "conversation", RecipientPubkeys: []string{"recipient"},
	})
	if err != nil {
		t.Fatalf("insert current dedupe row: %v", err)
	}
	if recipients != 1 {
		t.Fatal("expected current dedupe row to be inserted")
	}

	var expiredCount int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM push_dedupe WHERE event_id = ?;`,
		"expired-event",
	).Scan(&expiredCount); err != nil {
		t.Fatalf("count expired dedupe rows: %v", err)
	}
	if expiredCount != 0 {
		t.Fatalf("expected expired dedupe row to be pruned, got %d", expiredCount)
	}
}

func TestStoreStartupPrunesExpiredAndOrphanedRows(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "push-service.db")
	db, err := openDatabase(dbPath)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if _, err := newStore(db); err != nil {
		t.Fatalf("new store: %v", err)
	}
	insertExpiredDedupe(t, db)
	if _, err := db.Exec(
		`INSERT INTO archived_conversations (pubkey, conversation_id, updated_at) VALUES (?, ?, ?)`,
		"orphan", "conversation", time.Now().Unix(),
	); err != nil {
		t.Fatalf("insert orphaned archive row: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close database: %v", err)
	}

	db, err = openDatabase(dbPath)
	if err != nil {
		t.Fatalf("reopen database: %v", err)
	}
	defer db.Close()
	if _, err := newStore(db); err != nil {
		t.Fatalf("restart store: %v", err)
	}

	var expiredCount int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM push_dedupe WHERE event_id = ?;`,
		"expired-event",
	).Scan(&expiredCount); err != nil {
		t.Fatalf("count expired dedupe rows: %v", err)
	}
	if expiredCount != 0 {
		t.Fatalf("expected startup to prune expired dedupe row, got %d", expiredCount)
	}
	assertArchivedConversationCount(t, db, "orphan", 0)
}

func TestArchiveStateRequiresDeviceAndIsRemovedWithLastDevice(t *testing.T) {
	store, db := newTestStore(t)
	ctx := context.Background()

	if err := store.replaceArchivedConversations(ctx, "pubkey", []string{"conversation"}, nil); err != nil {
		t.Fatalf("sync archives without device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 0)

	if err := store.upsertDevice(ctx, "pubkey", "device-token", "production"); err != nil {
		t.Fatalf("register device: %v", err)
	}
	if err := store.upsertDevice(ctx, "pubkey", "second-device-token", "sandbox"); err != nil {
		t.Fatalf("register second device: %v", err)
	}
	if err := store.replaceArchivedConversations(ctx, "pubkey", []string{"conversation"}, nil); err != nil {
		t.Fatalf("sync archives with device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 1)

	if err := store.deleteDevice(ctx, "pubkey", "device-token"); err != nil {
		t.Fatalf("delete device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 1)

	if err := store.deleteDevice(ctx, "pubkey", "second-device-token"); err != nil {
		t.Fatalf("delete last device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 0)
}

func TestDeviceTokenMovesToCurrentPubkey(t *testing.T) {
	store, db := newTestStore(t)
	ctx := context.Background()
	if err := store.upsertDevice(ctx, "old-pubkey", "device-token", "production"); err != nil {
		t.Fatalf("register old pubkey: %v", err)
	}
	if err := store.replaceArchivedConversations(ctx, "old-pubkey", []string{"conversation"}, nil); err != nil {
		t.Fatalf("archive old pubkey conversation: %v", err)
	}
	if err := store.upsertDevice(ctx, "current-pubkey", "device-token", "production"); err != nil {
		t.Fatalf("register current pubkey: %v", err)
	}

	var owner string
	if err := db.QueryRow(`SELECT pubkey FROM devices WHERE device_token = ?`, "device-token").Scan(&owner); err != nil {
		t.Fatal(err)
	}
	if owner != "current-pubkey" {
		t.Fatalf("token belongs to %s", owner)
	}
	assertArchivedConversationCount(t, db, "old-pubkey", 0)
}

func newTestStore(t *testing.T) (*store, *sql.DB) {
	t.Helper()
	db, err := openDatabase(filepath.Join(t.TempDir(), "push-service.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := newStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store, db
}

func insertExpiredDedupe(t *testing.T, db *sql.DB) {
	t.Helper()
	_, err := db.Exec(
		`INSERT INTO push_dedupe (
			event_id, notification_type, recipient_pubkey, created_at
		) VALUES (?, ?, ?, ?)`,
		"expired-event",
		notificationTypeNewPost,
		"recipient",
		time.Now().Add(-pushDedupeTTL-time.Hour).Unix(),
	)
	if err != nil {
		t.Fatalf("insert expired dedupe row: %v", err)
	}
}

func assertArchivedConversationCount(t *testing.T, db *sql.DB, pubkey string, expected int) {
	t.Helper()
	var count int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM archived_conversations WHERE pubkey = ?;`,
		pubkey,
	).Scan(&count); err != nil {
		t.Fatalf("count archived conversations: %v", err)
	}
	if count != expected {
		t.Fatalf("expected %d archived conversations, got %d", expected, count)
	}
}
