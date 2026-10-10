package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"math/rand/v2"
	"time"
)

const pushDeliveryTTL = 15 * time.Minute

type queuedPush struct {
	ID              int64
	RecipientPubkey string
	Device          registeredDevice
	Payload         []byte
	Attempts        int
}

func (s *store) enqueuePush(ctx context.Context, senderPubkey string, push outboundPush) (int, int, error) {
	recipients := push.RecipientPubkeys
	push.RecipientPubkeys = nil
	now := time.Now()
	push.ExpiresAt = now.Add(pushDeliveryTTL)
	payload, err := json.Marshal(push)
	if err != nil {
		return 0, 0, err
	}
	recipientCount, deviceCount := 0, 0
	err = s.write(ctx, func(ctx context.Context, tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, `DELETE FROM push_dedupe WHERE created_at < ?`, now.Add(-pushDedupeTTL).Unix()); err != nil {
			return err
		}
		for _, recipient := range recipients {
			if recipient == senderPubkey {
				continue
			}
			result, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO push_dedupe
				(event_id, notification_type, recipient_pubkey, created_at)
				SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE pubkey = ?)
				AND NOT EXISTS (SELECT 1 FROM archived_conversations WHERE pubkey = ? AND conversation_id = ?)`,
				push.EventID, push.NotificationType, recipient, now.Unix(), recipient, recipient, push.ConversationID)
			if err != nil {
				return err
			}
			inserted, err := result.RowsAffected()
			if err != nil {
				return err
			}
			if inserted == 0 {
				continue
			}
			result, err = tx.ExecContext(ctx, `INSERT INTO push_jobs
				(recipient_pubkey, device_token, conversation_id, payload, expires_at, next_attempt_at)
				SELECT pubkey, device_token, ?, ?, ?, ? FROM devices WHERE pubkey = ?`,
				push.ConversationID, payload, push.ExpiresAt.Unix(), now.Unix(), recipient)
			if err != nil {
				return err
			}
			queued, err := result.RowsAffected()
			if err != nil {
				return err
			}
			recipientCount++
			deviceCount += int(queued)
		}
		return nil
	})
	return recipientCount, deviceCount, err
}

func (s *store) nextPush(ctx context.Context, now time.Time) (*queuedPush, error) {
	ctx, cancel := withTimeout(ctx)
	defer cancel()
	if _, err := s.db.ExecContext(ctx, `DELETE FROM push_jobs WHERE expires_at <= ?`, now.Unix()); err != nil {
		return nil, err
	}
	var job queuedPush
	err := s.db.QueryRowContext(ctx, `SELECT j.id, j.recipient_pubkey, j.device_token,
		d.apns_environment, j.payload, j.attempts FROM push_jobs j
		JOIN devices d ON d.pubkey = j.recipient_pubkey AND d.device_token = j.device_token
		WHERE j.next_attempt_at <= ? ORDER BY j.next_attempt_at, j.id LIMIT 1`, now.Unix()).Scan(
		&job.ID, &job.RecipientPubkey, &job.Device.DeviceToken, &job.Device.APNSEnvironment,
		&job.Payload, &job.Attempts)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return &job, err
}

func (s *store) finishPush(ctx context.Context, id int64) error {
	ctx, cancel := withTimeout(ctx)
	defer cancel()
	_, err := s.db.ExecContext(ctx, `DELETE FROM push_jobs WHERE id = ?`, id)
	return err
}

func (s *store) retryPush(ctx context.Context, job *queuedPush, now time.Time) error {
	ctx, cancel := withTimeout(ctx)
	defer cancel()
	delay := min(time.Second<<min(job.Attempts+1, 6), time.Minute)
	delay += time.Duration(rand.Int64N(int64(delay / 4)))
	_, err := s.db.ExecContext(ctx, `UPDATE push_jobs SET attempts = attempts + 1,
		next_attempt_at = ? WHERE id = ?`, now.Add(delay).Unix(), job.ID)
	return err
}

func (s *apiServer) deliverNextPush(ctx context.Context, now time.Time) (bool, error) {
	job, err := s.store.nextPush(ctx, now)
	if err != nil || job == nil {
		return false, err
	}
	var push outboundPush
	if err := json.Unmarshal(job.Payload, &push); err != nil {
		log.Printf("discarding invalid queued push %d: %v", job.ID, err)
		return true, s.store.finishPush(ctx, job.ID)
	}
	deadline := time.Now().Add(10 * time.Second)
	if push.ExpiresAt.Before(deadline) {
		deadline = push.ExpiresAt
	}
	sendContext, cancel := context.WithDeadline(ctx, deadline)
	err = s.sender.send(sendContext, job.Device, push)
	cancel()
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	if err == nil {
		return true, s.store.finishPush(ctx, job.ID)
	}
	var permanentErr permanentDeviceError
	if errors.As(err, &permanentErr) {
		return true, s.store.deleteDevice(ctx, job.RecipientPubkey, job.Device.DeviceToken)
	}
	log.Printf("push delivery deferred event=%s recipient=%s attempt=%d err=%v",
		push.EventID, job.RecipientPubkey, job.Attempts+1, err)
	if completed := time.Now(); completed.After(now) {
		now = completed
	}
	return true, s.store.retryPush(ctx, job, now)
}

func (s *apiServer) runPushWorker(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		for ctx.Err() == nil {
			delivered, err := s.deliverNextPush(ctx, time.Now())
			if err != nil {
				if ctx.Err() == nil {
					log.Printf("push worker failed: %v", err)
				}
				break
			}
			if !delivered {
				break
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-s.wake:
		case <-ticker.C:
		}
	}
}
