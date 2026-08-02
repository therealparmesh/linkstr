package main

import (
	"context"
	"database/sql"
	"time"

	_ "modernc.org/sqlite"
)

const (
	pushDedupeTTL = 30 * 24 * time.Hour
	schema        = `
		CREATE TABLE IF NOT EXISTS devices (
			pubkey TEXT NOT NULL,
			device_token TEXT NOT NULL,
			apns_environment TEXT NOT NULL,
			updated_at INTEGER NOT NULL,
			PRIMARY KEY (pubkey, device_token)
		);
		CREATE INDEX IF NOT EXISTS devices_device_token_idx ON devices (device_token);

		CREATE TABLE IF NOT EXISTS archived_conversations (
			pubkey TEXT NOT NULL,
			conversation_id TEXT NOT NULL,
			updated_at INTEGER NOT NULL,
			PRIMARY KEY (pubkey, conversation_id)
		);
		DELETE FROM archived_conversations
		WHERE NOT EXISTS (
			SELECT 1 FROM devices WHERE devices.pubkey = archived_conversations.pubkey
		);
		CREATE TRIGGER IF NOT EXISTS delete_orphaned_archives
		AFTER DELETE ON devices
		WHEN NOT EXISTS (SELECT 1 FROM devices WHERE pubkey = OLD.pubkey)
		BEGIN
			DELETE FROM archived_conversations WHERE pubkey = OLD.pubkey;
		END;

		CREATE TABLE IF NOT EXISTS push_dedupe (
			event_id TEXT NOT NULL,
			notification_type TEXT NOT NULL,
			recipient_pubkey TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			PRIMARY KEY (event_id, notification_type, recipient_pubkey)
		);
		CREATE INDEX IF NOT EXISTS push_dedupe_created_at_idx ON push_dedupe (created_at);

		CREATE TABLE IF NOT EXISTS auth_nonces (
			pubkey TEXT NOT NULL,
			nonce TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			PRIMARY KEY (pubkey, nonce)
		);
		CREATE INDEX IF NOT EXISTS auth_nonces_created_at_idx ON auth_nonces (created_at);
	`
)

type store struct {
	db *sql.DB
}

type registeredDevice struct {
	DeviceToken     string
	APNSEnvironment string
}

func newStore(db *sql.DB) (*store, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	if _, err := db.Exec(
		`DELETE FROM push_dedupe WHERE created_at < ?`,
		time.Now().Add(-pushDedupeTTL).Unix(),
	); err != nil {
		return nil, err
	}
	return &store{db: db}, nil
}

func (s *store) upsertDevice(ctx context.Context, pubkey, deviceToken, apnsEnvironment string) error {
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		if _, err := tx.ExecContext(
			ctx,
			`DELETE FROM devices WHERE device_token = ? AND pubkey <> ?`,
			deviceToken,
			pubkey,
		); err != nil {
			return err
		}
		_, err := tx.ExecContext(
			ctx,
			`INSERT INTO devices (pubkey, device_token, apns_environment, updated_at)
			 VALUES (?, ?, ?, ?)
			 ON CONFLICT(pubkey, device_token) DO UPDATE SET
			   apns_environment = excluded.apns_environment,
			   updated_at = excluded.updated_at`,
			pubkey,
			deviceToken,
			apnsEnvironment,
			time.Now().Unix(),
		)
		return err
	})
}

func (s *store) deleteDevice(ctx context.Context, pubkey, deviceToken string) error {
	ctx, cancel := withTimeout(ctx)
	defer cancel()
	_, err := s.db.ExecContext(
		ctx,
		`DELETE FROM devices WHERE pubkey = ? AND device_token = ?`,
		pubkey,
		deviceToken,
	)
	return err
}

func (s *store) replaceArchivedConversations(ctx context.Context, pubkey string, conversationIDs []string) error {
	return s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, `DELETE FROM archived_conversations WHERE pubkey = ?`, pubkey); err != nil {
			return err
		}

		var hasDevice bool
		if err := tx.QueryRowContext(
			ctx,
			`SELECT EXISTS(SELECT 1 FROM devices WHERE pubkey = ?)`,
			pubkey,
		).Scan(&hasDevice); err != nil {
			return err
		}
		if !hasDevice {
			return nil
		}

		now := time.Now().Unix()
		for _, conversationID := range conversationIDs {
			if _, err := tx.ExecContext(
				ctx,
				`INSERT INTO archived_conversations (pubkey, conversation_id, updated_at) VALUES (?, ?, ?)`,
				pubkey,
				conversationID,
				now,
			); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *store) isConversationArchived(ctx context.Context, pubkey, conversationID string) (bool, error) {
	ctx, cancel := withTimeout(ctx)
	defer cancel()

	var exists bool
	err := s.db.QueryRowContext(
		ctx,
		`SELECT EXISTS(
			SELECT 1 FROM archived_conversations WHERE pubkey = ? AND conversation_id = ?
		)`,
		pubkey,
		conversationID,
	).Scan(&exists)
	return exists, err
}

func (s *store) listDevices(ctx context.Context, pubkey string) ([]registeredDevice, error) {
	ctx, cancel := withTimeout(ctx)
	defer cancel()

	rows, err := s.db.QueryContext(
		ctx,
		`SELECT device_token, apns_environment FROM devices WHERE pubkey = ?`,
		pubkey,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []registeredDevice
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
	var inserted bool
	err := s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		if _, err := tx.ExecContext(
			ctx,
			`DELETE FROM push_dedupe WHERE created_at < ?`,
			time.Now().Add(-pushDedupeTTL).Unix(),
		); err != nil {
			return err
		}

		result, err := tx.ExecContext(
			ctx,
			`INSERT OR IGNORE INTO push_dedupe (
				event_id, notification_type, recipient_pubkey, created_at
			) VALUES (?, ?, ?, ?)`,
			eventID,
			notificationType,
			recipientPubkey,
			time.Now().Unix(),
		)
		if err != nil {
			return err
		}
		rowsAffected, err := result.RowsAffected()
		inserted = rowsAffected == 1
		return err
	})
	return inserted, err
}

func (s *store) claimAuthNonce(ctx context.Context, pubkey, nonce string, now time.Time) (bool, error) {
	var inserted bool
	err := s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		if _, err := tx.ExecContext(
			ctx,
			`DELETE FROM auth_nonces WHERE created_at < ?`,
			now.Add(-authTTL).Unix(),
		); err != nil {
			return err
		}

		result, err := tx.ExecContext(
			ctx,
			`INSERT OR IGNORE INTO auth_nonces (pubkey, nonce, created_at) VALUES (?, ?, ?)`,
			pubkey,
			nonce,
			now.Unix(),
		)
		if err != nil {
			return err
		}
		rowsAffected, err := result.RowsAffected()
		inserted = rowsAffected == 1
		return err
	})
	return inserted, err
}

func (s *store) write(ctx context.Context, fn func(context.Context, *sql.Tx) error) error {
	ctx, cancel := withTimeout(ctx)
	defer cancel()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fn(ctx, tx); err != nil {
		return err
	}
	return tx.Commit()
}

func withTimeout(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, 15*time.Second)
}
