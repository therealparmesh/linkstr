# push-service

_Last updated: March 12, 2026_

Minimal linkstr push backend for iOS APNs delivery.

## What it does

- Stores APNs device tokens per Nostr pubkey.
- Stores archived conversation IDs per Nostr pubkey.
- Accepts signed push enqueue requests from the app.
- Sends generic APNs alerts for:
  - `new_post`
  - `new_emoji_reaction`

It does not decrypt linkstr content, watch relays directly, or keep a notification inbox.

## Request auth

Every mutating request is authorized with a signed Nostr HTTP auth event.

- The signature covers the HTTP method, request path, request body hash, and a random nonce.
- The service stores recently used nonces for the current auth window and rejects reuse.

That keeps a captured request from being replayed over and over during the normal auth TTL.

## What you need to do manually

To make this real, you need to do four things:

1. Create an APNs auth key in Apple Developer.
2. Enable push in the iOS app target.
3. Deploy this service somewhere public.
4. Point the app build at that public URL and test on a real iPhone.

The sections below are the exact steps.

## Apple Developer steps

1. Sign in to Apple Developer.
2. Go to `Certificates, Identifiers & Profiles`.
3. Open `Keys`.
4. Create a key with `Apple Push Notifications service (APNs)` enabled, or reuse an existing APNs auth key.
5. Download the `.p8` file and store it somewhere safe. Apple only lets you download it once.
6. Record:
   - `Key ID`
   - `Team ID`
   - The app bundle id, which should be `com.parmscript.linkstr` unless you changed it.

You will use those values as:

- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_TOPIC`

## Xcode steps

1. Open the project in Xcode.
2. Select the `linkstr` app target.
3. Open `Signing & Capabilities`.
4. Confirm `Push Notifications` is present.
5. Confirm the correct Apple team is selected for signing.
6. In the run scheme, add `LINKSTR_PUSH_SERVICE_BASE_URL` once you have a backend URL.
7. Build to a real iPhone for end-to-end validation. The simulator is useful for app wiring, but real APNs delivery requires a physical device.

The codebase already includes:

- The entitlements change.
- APNs registration callbacks.
- Foreground presentation.
- Backend registration and enqueue calls.

You do not need to add more app capabilities for this v1 path.

## Local development

From this directory:

```bash
go test ./...
APNS_DISABLE=1 go run .
```

Defaults:

- `LISTEN_ADDR=:8787`
- `DATABASE_PATH=push-service.db`

With `APNS_DISABLE=1`, the service accepts signed requests and logs attempted sends instead of talking to Apple.
Without `APNS_DISABLE=1`, the service expects a complete APNs configuration and exits on startup if any required APNs setting is missing.

### App setup for local development

1. Open the `linkstr` run scheme in Xcode.
2. Add `LINKSTR_PUSH_SERVICE_BASE_URL=http://127.0.0.1:8787` if you are using the simulator.
3. If you are running the app on a physical iPhone against your laptop, use your machine's LAN IP instead, for example `http://192.168.1.50:8787`.
4. Launch the app.
5. Grant notification permission.
6. Confirm the service receives:
   - `POST /v1/devices/register`
   - `POST /v1/devices/unregister`
   - `PUT /v1/conversations/archive-state`
   - `POST /v1/push`
7. Create a post and an active emoji reaction from another account and confirm the no-op backend logs both attempted sends.

This local flow validates:

- App-to-backend auth signing.
- Token registration.
- Archive sync.
- Enqueue behavior.

It does not validate real closed-app/background push delivery. That must go through Apple on a real device.

## Required env vars for real APNs

- `APNS_TOPIC`
- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_KEY_P8`

Optional:

- `LISTEN_ADDR`
- `DATABASE_PATH`
- `APNS_DISABLE=1`

## Exact Fly deploy

These commands assume:

- You are in the `push-service` directory in this repo.
- You have `flyctl` installed and authenticated.
- You have the APNs `.p8` file from Apple Developer.

Set these once in your shell:

```bash
cd push-service

export APP_NAME="linkstr-push-service"
export VOLUME_NAME="linkstr_push_service_data"
export FLY_REGION="dfw"
export APNS_TOPIC="com.parmscript.linkstr"
export APNS_KEY_ID="YOUR_KEY_ID"
export APNS_TEAM_ID="YOUR_TEAM_ID"
export APNS_KEY_P8_FILE="$HOME/Downloads/AuthKey_YOUR_KEY_ID.p8"
```

Create the Fly app and persistent volume:

```bash
fly apps create "$APP_NAME"
fly volumes create "$VOLUME_NAME" --app "$APP_NAME" --region "$FLY_REGION" --size 1
sed -i '' \
  -e "s/^app = \".*\"$/app = \"$APP_NAME\"/" \
  -e "s/^  source = \".*\"$/  source = \"$VOLUME_NAME\"/" \
  fly.toml
```

Set the APNs secrets:

```bash
fly secrets set --app "$APP_NAME" \
  APNS_TOPIC="$APNS_TOPIC" \
  APNS_KEY_ID="$APNS_KEY_ID" \
  APNS_TEAM_ID="$APNS_TEAM_ID" \
  APNS_KEY_P8="$(cat "$APNS_KEY_P8_FILE")"
```

Deploy and verify:

```bash
fly deploy --config fly.toml
fly status --app "$APP_NAME"
fly logs --app "$APP_NAME"
curl -fsS "https://$APP_NAME.fly.dev/healthz"
```

The health endpoint should answer:

```json
{ "status": "ok" }
```

## Point the app at Fly

Set the app's push backend URL to:

```text
https://linkstr-push-service.fly.dev
```

Or the hostname for your chosen `APP_NAME`.

For local Xcode runs, set the scheme environment variable:

```text
LINKSTR_PUSH_SERVICE_BASE_URL=https://linkstr-push-service.fly.dev
```

If you want a fixed value in the built app instead, set `LinkstrPushServiceBaseURL` in the app's `Info.plist` or through the build setting that feeds it.

## Real-device validation steps

Do this after Fly is up and the app points at the Fly URL.

1. Install the app on a physical iPhone.
2. Launch the app and allow notifications.
3. Confirm the service logs a `POST /v1/devices/register`.
4. Sign into a second account on another device or simulator.
5. Make sure both accounts share a session.
6. From the sender account, create a post.
7. Confirm the recipient phone receives a `new_post` alert.
8. From the sender account, add an active emoji reaction.
9. Confirm the recipient phone receives a `new_emoji_reaction` alert.
10. Archive the conversation on the recipient account.
11. Repeat the post and reaction checks.
12. Confirm the archived conversation stays silent.
13. Test all three recipient app states:
    - foreground
    - background
    - fully closed

For this v1, the expected alert text is generic. The app fetches the actual encrypted content separately.

## Test coverage

Backend:

- `go test ./...`
- Auth rejection.
- Device registration.
- Archive suppression.
- Push dedupe.
- Self-send suppression.
- Device unregistration.

App (run from the repo root):

- `./scripts/test.sh`
- Post enqueue coverage.
- Reaction enqueue coverage.
- Archive sync coverage.

The remaining gap is real APNs delivery on physical hardware, which no local test can replace.
