package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	apns2 "github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

type outboundPush struct {
	NotificationType string
	EventID          string
	ConversationID   string
	RecipientPubkeys []string
	Emoji            string
}

type pushSender interface {
	send(ctx context.Context, device registeredDevice, push outboundPush) error
}

type noOpSender struct{}

type permanentDeviceError string

type apnsSender struct {
	topic      string
	sandbox    *apns2.Client
	production *apns2.Client
}

func (e permanentDeviceError) Error() string {
	return string(e)
}

func newPushSender(cfg config) (pushSender, error) {
	if cfg.apnsDisable {
		log.Printf("APNs disabled, using no-op sender")
		return noOpSender{}, nil
	}
	if err := validateAPNSConfig(cfg); err != nil {
		return nil, err
	}

	authKey, err := token.AuthKeyFromBytes([]byte(cfg.apnsKeyP8))
	if err != nil {
		return nil, err
	}

	providerToken := &token.Token{
		AuthKey: authKey,
		KeyID:   cfg.apnsKeyID,
		TeamID:  cfg.apnsTeamID,
	}

	return &apnsSender{
		topic:      cfg.apnsTopic,
		sandbox:    apns2.NewTokenClient(providerToken).Development(),
		production: apns2.NewTokenClient(providerToken).Production(),
	}, nil
}

func (noOpSender) send(_ context.Context, device registeredDevice, push outboundPush) error {
	log.Printf(
		"noop push send type=%s event=%s conversation=%s env=%s token=%s",
		push.NotificationType,
		push.EventID,
		push.ConversationID,
		device.APNSEnvironment,
		device.DeviceToken,
	)
	return nil
}

func (s *apnsSender) send(ctx context.Context, device registeredDevice, push outboundPush) error {
	client := s.production
	if device.APNSEnvironment == "sandbox" {
		client = s.sandbox
	}

	notification := &apns2.Notification{
		DeviceToken: device.DeviceToken,
		Topic:       s.topic,
		CollapseID:  push.EventID,
		Expiration:  time.Now().Add(15 * time.Minute),
		Priority:    apns2.PriorityHigh,
		PushType:    apns2.PushTypeAlert,
		Payload:     buildPayload(push),
	}

	response, err := client.PushWithContext(ctx, notification)
	if err != nil {
		return err
	}

	if response.StatusCode == apns2.StatusSent {
		return nil
	}

	if isPermanentTokenReason(response.Reason) {
		return permanentDeviceError("apns rejection: " + response.Reason)
	}

	return fmt.Errorf("apns rejection: status=%d reason=%s", response.StatusCode, response.Reason)
}

func buildPayload(push outboundPush) *payload.Payload {
	title := "New post in linkstr"
	if push.NotificationType == notificationTypeNewEmojiReaction {
		title = "New reaction " + push.Emoji + " in linkstr"
	}
	builder := payload.NewPayload().
		AlertTitle(title).
		AlertBody("Open linkstr to view").
		Sound("default").
		ThreadID(push.ConversationID).
		Custom("type", push.NotificationType).
		Custom("event_id", push.EventID).
		Custom("conversation_id", push.ConversationID)

	if push.Emoji != "" {
		builder.Custom("emoji", push.Emoji)
	}

	return builder
}

func validateAPNSConfig(cfg config) error {
	missing := make([]string, 0, 4)
	if cfg.apnsTopic == "" {
		missing = append(missing, "APNS_TOPIC")
	}
	if cfg.apnsKeyID == "" {
		missing = append(missing, "APNS_KEY_ID")
	}
	if cfg.apnsTeamID == "" {
		missing = append(missing, "APNS_TEAM_ID")
	}
	if strings.TrimSpace(cfg.apnsKeyP8) == "" {
		missing = append(missing, "APNS_KEY_P8")
	}
	if len(missing) == 0 {
		return nil
	}
	return errors.New("missing APNs configuration: " + strings.Join(missing, ", "))
}

func isPermanentTokenReason(reason string) bool {
	return reason == apns2.ReasonBadDeviceToken ||
		reason == apns2.ReasonDeviceTokenNotForTopic ||
		reason == apns2.ReasonUnregistered
}
