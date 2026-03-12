package main

import (
	"context"
	"database/sql"
	"time"

	_ "modernc.org/sqlite"
)

type store struct {
	db *sql.DB
}

type registeredDevice struct {
	DeviceToken     string
	APNSEnvironment string
}

func newStore(db *sql.DB) (*store, error) {
	s := &store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *store) migrate(ctx context.Context) error {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS devices (
			pubkey TEXT NOT NULL,
			device_token TEXT NOT NULL,
			apns_environment TEXT NOT NULL,
			updated_at INTEGER NOT NULL,
			disabled_at INTEGER,
			last_error TEXT,
			PRIMARY KEY (pubkey, device_token)
		);`,
		`CREATE TABLE IF NOT EXISTS archived_conversations (
			pubkey TEXT NOT NULL,
			conversation_id TEXT NOT NULL,
			updated_at INTEGER NOT NULL,
			PRIMARY KEY (pubkey, conversation_id)
		);`,
		`CREATE TABLE IF NOT EXISTS push_dedupe (
			event_id TEXT NOT NULL,
			notification_type TEXT NOT NULL,
			recipient_pubkey TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			PRIMARY KEY (event_id, notification_type, recipient_pubkey)
		);`,
	}

	for _, statement := range statements {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return err
		}
	}

	return nil
}

func (s *store) upsertDevice(ctx context.Context, pubkey, deviceToken, apnsEnvironment string) error {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	_, err := s.db.ExecContext(
		ctx,
		`INSERT INTO devices (pubkey, device_token, apns_environment, updated_at, disabled_at, last_error)
		 VALUES (?, ?, ?, ?, NULL, NULL)
		 ON CONFLICT(pubkey, device_token) DO UPDATE SET
		   apns_environment = excluded.apns_environment,
		   updated_at = excluded.updated_at,
		   disabled_at = NULL,
		   last_error = NULL;`,
		pubkey,
		deviceToken,
		apnsEnvironment,
		time.Now().Unix(),
	)
	return err
}

func (s *store) deleteDevice(ctx context.Context, pubkey, deviceToken string) error {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	_, err := s.db.ExecContext(
		ctx,
		`DELETE FROM devices WHERE pubkey = ? AND device_token = ?;`,
		pubkey,
		deviceToken,
	)
	return err
}

func (s *store) disableDevice(ctx context.Context, pubkey, deviceToken, lastError string) error {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	_, err := s.db.ExecContext(
		ctx,
		`UPDATE devices
		   SET disabled_at = ?, last_error = ?
		 WHERE pubkey = ? AND device_token = ?;`,
		time.Now().Unix(),
		lastError,
		pubkey,
		deviceToken,
	)
	return err
}

func (s *store) replaceArchivedConversations(ctx context.Context, pubkey string, conversationIDs []string) error {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `DELETE FROM archived_conversations WHERE pubkey = ?;`, pubkey); err != nil {
		return err
	}

	now := time.Now().Unix()
	for _, conversationID := range conversationIDs {
		if _, err := tx.ExecContext(
			ctx,
			`INSERT INTO archived_conversations (pubkey, conversation_id, updated_at)
			 VALUES (?, ?, ?);`,
			pubkey,
			conversationID,
			now,
		); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (s *store) isConversationArchived(ctx context.Context, pubkey, conversationID string) (bool, error) {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	var archived int
	err := s.db.QueryRowContext(
		ctx,
		`SELECT 1
		   FROM archived_conversations
		  WHERE pubkey = ? AND conversation_id = ?
		  LIMIT 1;`,
		pubkey,
		conversationID,
	).Scan(&archived)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (s *store) listDevices(ctx context.Context, pubkey string) ([]registeredDevice, error) {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	rows, err := s.db.QueryContext(
		ctx,
		`SELECT device_token, apns_environment
		   FROM devices
		  WHERE pubkey = ? AND disabled_at IS NULL;`,
		pubkey,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	devices := make([]registeredDevice, 0)
	for rows.Next() {
		var device registeredDevice
		if err := rows.Scan(&device.DeviceToken, &device.APNSEnvironment); err != nil {
			return nil, err
		}
		devices = append(devices, device)
	}

	return devices, rows.Err()
}

func (s *store) insertPushDedupe(ctx context.Context, eventID, notificationType, recipientPubkey string) (bool, error) {
	ctx, cancel := withTimeoutContext(ctx)
	defer cancel()

	result, err := s.db.ExecContext(
		ctx,
		`INSERT OR IGNORE INTO push_dedupe (
			event_id,
			notification_type,
			recipient_pubkey,
			created_at
		) VALUES (?, ?, ?, ?);`,
		eventID,
		notificationType,
		recipientPubkey,
		time.Now().Unix(),
	)
	if err != nil {
		return false, err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rowsAffected == 1, nil
}
