package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreMigrationRemovesLegacyDisabledDevices(t *testing.T) {
	db, err := openDatabase(filepath.Join(t.TempDir(), "push-service.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer db.Close()

	_, err = db.Exec(`CREATE TABLE devices (
		pubkey TEXT NOT NULL,
		device_token TEXT NOT NULL,
		apns_environment TEXT NOT NULL,
		updated_at INTEGER NOT NULL,
		disabled_at INTEGER,
		last_error TEXT,
		PRIMARY KEY (pubkey, device_token)
	);`)
	if err != nil {
		t.Fatalf("create legacy devices table: %v", err)
	}
	_, err = db.Exec(`INSERT INTO devices (
		pubkey, device_token, apns_environment, updated_at, disabled_at, last_error
	) VALUES
		('active', 'active-token', 'production', 1, NULL, NULL),
		('disabled', 'disabled-token', 'production', 1, 2, 'Unregistered');`)
	if err != nil {
		t.Fatalf("insert legacy devices: %v", err)
	}

	store, err := newStore(db)
	if err != nil {
		t.Fatalf("migrate store: %v", err)
	}

	activeDevices, err := store.listDevices(context.Background(), "active")
	if err != nil {
		t.Fatalf("list active devices: %v", err)
	}
	if len(activeDevices) != 1 || activeDevices[0].DeviceToken != "active-token" {
		t.Fatalf("unexpected active devices: %#v", activeDevices)
	}
	disabledDevices, err := store.listDevices(context.Background(), "disabled")
	if err != nil {
		t.Fatalf("list disabled devices: %v", err)
	}
	if len(disabledDevices) != 0 {
		t.Fatalf("expected disabled devices to be removed, got %#v", disabledDevices)
	}

	rows, err := db.Query(`PRAGMA table_info(devices);`)
	if err != nil {
		t.Fatalf("inspect migrated devices table: %v", err)
	}
	defer rows.Close()
	for rows.Next() {
		var columnID, notNull, primaryKey int
		var name, columnType string
		var defaultValue any
		if err := rows.Scan(&columnID, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			t.Fatalf("scan device column: %v", err)
		}
		if name == "disabled_at" || name == "last_error" {
			t.Fatalf("legacy column still exists: %s", name)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("inspect device columns: %v", err)
	}
}

func TestInsertPushDedupePrunesExpiredRows(t *testing.T) {
	db, err := openDatabase(filepath.Join(t.TempDir(), "push-service.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer db.Close()

	store, err := newStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	expiredAt := time.Now().Add(-pushDedupeTTL - time.Hour).Unix()
	_, err = db.Exec(`INSERT INTO push_dedupe (
		event_id, notification_type, recipient_pubkey, created_at
	) VALUES (?, ?, ?, ?);`, "expired-event", notificationTypeNewPost, "recipient", expiredAt)
	if err != nil {
		t.Fatalf("insert expired dedupe row: %v", err)
	}

	inserted, err := store.insertPushDedupe(
		context.Background(),
		"current-event",
		notificationTypeNewPost,
		"recipient",
	)
	if err != nil {
		t.Fatalf("insert current dedupe row: %v", err)
	}
	if !inserted {
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

func TestStoreStartupPrunesExpiredPushDedupeRows(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "push-service.db")
	db, err := openDatabase(dbPath)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if _, err := newStore(db); err != nil {
		t.Fatalf("new store: %v", err)
	}
	expiredAt := time.Now().Add(-pushDedupeTTL - time.Hour).Unix()
	_, err = db.Exec(`INSERT INTO push_dedupe (
		event_id, notification_type, recipient_pubkey, created_at
	) VALUES (?, ?, ?, ?);`, "expired-event", notificationTypeNewPost, "recipient", expiredAt)
	if err != nil {
		t.Fatalf("insert expired dedupe row: %v", err)
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
}

func TestArchiveStateRequiresDeviceAndIsRemovedWithLastDevice(t *testing.T) {
	db, err := openDatabase(filepath.Join(t.TempDir(), "push-service.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer db.Close()

	store, err := newStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	ctx := context.Background()

	if err := store.replaceArchivedConversations(ctx, "pubkey", []string{"conversation"}); err != nil {
		t.Fatalf("replace archive state without device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 0)

	if err := store.upsertDevice(ctx, "pubkey", "device-token", "production"); err != nil {
		t.Fatalf("register device: %v", err)
	}
	if err := store.replaceArchivedConversations(ctx, "pubkey", []string{"conversation"}); err != nil {
		t.Fatalf("replace archive state with device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 1)

	if err := store.deleteDevice(ctx, "pubkey", "device-token"); err != nil {
		t.Fatalf("delete device: %v", err)
	}
	assertArchivedConversationCount(t, db, "pubkey", 0)
}

func TestDeviceTokenMovesToCurrentPubkey(t *testing.T) {
	db, err := openDatabase(filepath.Join(t.TempDir(), "push-service.db"))
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer db.Close()

	store, err := newStore(db)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	ctx := context.Background()
	if err := store.upsertDevice(ctx, "old-pubkey", "device-token", "production"); err != nil {
		t.Fatalf("register old pubkey: %v", err)
	}
	if err := store.replaceArchivedConversations(ctx, "old-pubkey", []string{"conversation"}); err != nil {
		t.Fatalf("archive old pubkey conversation: %v", err)
	}
	if err := store.upsertDevice(ctx, "current-pubkey", "device-token", "production"); err != nil {
		t.Fatalf("register current pubkey: %v", err)
	}

	oldDevices, err := store.listDevices(ctx, "old-pubkey")
	if err != nil {
		t.Fatalf("list old pubkey devices: %v", err)
	}
	if len(oldDevices) != 0 {
		t.Fatalf("expected token to leave old pubkey, got %#v", oldDevices)
	}
	currentDevices, err := store.listDevices(ctx, "current-pubkey")
	if err != nil {
		t.Fatalf("list current pubkey devices: %v", err)
	}
	if len(currentDevices) != 1 || currentDevices[0].DeviceToken != "device-token" {
		t.Fatalf("unexpected current pubkey devices: %#v", currentDevices)
	}
	assertArchivedConversationCount(t, db, "old-pubkey", 0)
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
