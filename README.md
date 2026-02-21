# linkstr

`linkstr` is a private link feed for people you trust: share videos and other media, then discuss it in a focused thread - like a tiny private subreddit for you and the people you talk to.

## Product Behavior Specification

This document is the behavioral contract for the current app. It is intentionally detailed.

### 1) Identity and Account Lifecycle

**Acceptance criteria**

1. A user can either create a fresh keypair or import an existing `Secret Key (nsec)`.
2. Once authenticated, the app treats that keypair as the active account context for all scoped data.
3. `Contact Key (npub)` is visible in the app where identity sharing/inspection is expected (Share and Settings).
4. `Secret Key (nsec)` is never shown by default; it is reveal/copy only from Settings.
5. If no identity exists at boot, onboarding is shown.
6. On boot with identity present, relay startup is attempted automatically.
7. `Log Out (Keep Local Data)` clears active identity from keychain/session state but preserves that account's local contacts/messages for future re-login.
8. `Log Out and Clear Local Data` removes identity session and deletes that account's local contacts/messages/cached local media references/local-data encryption key.

### 2) Contacts and Recipient Selection

**Acceptance criteria**

1. Contacts are local-only records; no social/contact/follow event is published to relays.
2. Contacts are account-scoped; contacts from one account are not visible under another account.
3. Add/edit/delete contact actions are supported locally.
4. A contact requires a valid `Contact Key (npub)` and non-empty display name.
5. Contact duplicate prevention is applied per account after normalization.
6. Recipient picker supports both saved contacts and manual `Contact Key (npub)` entry.
7. Recipient picker provides `Paste` / `Scan` / `Clear` assist actions.
8. Add-contact flow provides the same `Paste` / `Scan` / `Clear` assist actions.
9. In new-post composer, the `Post Link` field provides `Paste` / `Clear` assist actions.
10. `Use Contact Key` appears only when typed/pasted/scanned input resolves to a valid `npub` that is not already in saved contacts.
11. When entering composer from a known-contact conversation, recipient is preselected.
12. When entering composer from an unknown-peer conversation, recipient is locked to that peer.

### 3) Creating a Post (Root Message)

**Acceptance criteria**

1. A post requires a valid web URL and a selected/locked recipient `npub`.
2. URL input is normalized and validated; unsupported/malformed values are rejected.
3. Optional note is trimmed and persisted only when non-empty.
4. Transport uses NIP-59 gift-wrap via `NostrSDK`.
5. Linkstr payload is embedded in inner rumor kind `44001`.
6. Composer send action waits in-place for relay reconnect rather than dismissing immediately on transient outage.
7. Wait behavior defaults to timeout at 12 seconds with periodic polling.
8. While awaiting send, composer remains onscreen in sending state.
9. On success, post is persisted locally and composer dismisses.
10. On failure/timeout, composer stays open and user receives error toast.

### 4) Replying in a Thread

**Acceptance criteria**

1. Reply content is text-only.
2. Empty/whitespace-only replies are not sent.
3. Reply send uses the same relay-reconnect wait + timeout flow as root post send.
4. During reply send attempt, reply input and send action are disabled to prevent duplicate taps.
5. If send succeeds, reply input clears, focus is dismissed, and thread scrolls to bottom.
6. If send fails or times out, reply text remains in input for retry/edit.

### 5) Sessions, Threads, and Unread Semantics

**Acceptance criteria**

1. Unknown peers can appear directly in Sessions with no invite flow.
2. Each root post has an associated reply thread.
3. Opening a session marks inbound root posts in that session as read.
4. Opening a thread marks inbound replies for that root post as read.
5. Unread indication is dot-only (no numeric badge).
6. Session unread logic is per-root-post and does not double-count replies.

### 6) Relay Configuration in Settings

**Acceptance criteria**

1. Users can add, remove, and enable/disable relays.
2. Relay URL add validation accepts only `ws://` or `wss://` URLs with valid host.
3. Relay list is shown sorted alphabetically.
4. Users can reset relay list to app defaults.
5. Current default relay set is:
   - `wss://relay.damus.io`
   - `wss://relay.primal.net`
   - `wss://nos.lol`
   - `wss://nostr.satoshisfrens.win`
   - `wss://relay.snort.social`
6. Relay row displays health indicator and optional status/error detail.
7. Relay inline error slot reserves layout space to prevent row jitter when messages appear/disappear.

### 7) Relay Runtime Lifecycle and Send Gating

**Acceptance criteria**

1. Relay runtime is started when identity is available and app is active.
2. On foreground re-entry, relay session is force-restarted to avoid stale-socket assumptions.
3. Relay status writes are foreground-only to avoid high-churn persistence while backgrounded.
4. Reconnect scheduling uses a single in-flight retry timer (no overlapping reconnect loop tasks).
5. Live send requires at least one writable connected relay socket.
6. Read-only connected relays are surfaced as read-only and are excluded from send eligibility.
7. Relay state classification includes: no enabled relays, online, read-only, reconnecting, offline.
8. Blocking send errors are explicit and user-facing for no-enabled, read-only, reconnecting, and offline states.
9. Await-send path blocks hard only for no-enabled/read-only and otherwise waits for reconnection until timeout.
10. Toast chatter is suppressed during reconnect flapping to avoid repeated noise.
11. Offline toast is shown once per outage window when no viable relay is available.
12. No offline outbox queue is implemented.
13. Failed sends are not auto-retried after future reconnect.

### 8) Incoming Event Ingestion and Backfill

**Acceptance criteria**

1. App subscribes to gift-wrap events for both recipient and author filters.
2. On relay connect, subscriptions are (re)installed to handle socket-start races.
3. Historical backfill runs in pages to recover earlier messages.
4. Backfill completion waits for expected relay EOSE responses per page.
5. Backfill pagination continues while a page is full; `until` cursor moves to oldest seen event time minus one.
6. Only gift-wrap events that unseal to valid linkstr rumor payloads (`44001`) are accepted.
7. Duplicate events are ignored by event ID deduping.
8. Incoming accepted events are persisted locally under active account scope.

### 9) Notifications

**Acceptance criteria**

1. Notifications are local best-effort notifications driven by incoming relay events.
2. APNs remote push is not implemented.
3. Only inbound messages trigger notifications (self-sent echoes do not).
4. Root post notification title format: `"{sender} shared a post"`.
5. Reply notification title format: `"{sender} replied"`.
6. Notification body prefers note text when present; otherwise uses fallback copy.
7. Notifications are grouped by conversation using `threadIdentifier`.
8. When app is open, notifications are still presented as banner/list/sound.

### 10) Media and Link Playback Behavior

**Acceptance criteria**

1. Runtime URL classification determines playback strategy.
2. Extraction candidates default to local playback with automatic fallback to official embed.
3. Local extraction candidates include:
   - TikTok video links
   - Instagram Reels
   - Facebook Reels
   - X/Twitter status video links matching `.../status/<id>/video/...`
4. Embed-only providers include:
   - YouTube (including Shorts)
   - Rumble
   - Instagram non-Reel video posts
   - Facebook non-Reel video posts
   - X/Twitter non-video statuses (text/photo)
5. X/Twitter embeds are rewritten to `fixupx.com` to improve embed consistency.
6. Local extraction rejects non-HTTPS media URLs.
7. Post label `Video` appears only for extraction candidates; embed-only and generic links display `Link`.

### 11) Deep Links

**Acceptance criteria**

1. App handles deep links in the `linkstr://open?p=...` format.
2. Deep-link payload opens a dedicated playback-first full-screen experience.
3. User exits deep-link experience with `Done`.

### 12) Data Storage, Isolation, and Security

**Acceptance criteria**

1. Contacts, messages, relay settings, and cached media are stored locally on device.
2. Contacts/messages are account-isolated by owner pubkey.
3. Account switching does not merge, leak, or expose another account's local contact/message data.
4. Sensitive contact/message fields are encrypted at rest with per-account local key material.
5. Decryption occurs on read for active account context.
6. Identity key material is stored in keychain.
7. Keychain survival across reinstall may occur but is not guaranteed and should not be treated as backup strategy.
8. Uninstall removes app-local data.
9. Reliable cross-device/reinstall recovery requires user backup of `Secret Key (nsec)`.

### 13) Known Limitations and Explicit Non-Goals (Current)

**Acceptance criteria**

1. Offline outbox/retry queue is not in scope today.
2. Remote push (APNs) is not in scope today.
3. Contact graph publishing/follow events are not in scope today.
4. Public feed/discovery is not in scope; app is DM/session oriented.

## QR Scanner Notes

1. QR scan requires camera permission.
2. iOS Simulator camera scanning is often unreliable.
3. If scan fails/unavailable, paste/manual entry and real-device testing are expected fallback paths.

## Development

### Open in Xcode

```bash
open Linkstr.xcodeproj
```

### Run tests

```bash
xcodebuild test -project Linkstr.xcodeproj -scheme Linkstr -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

If your installed simulator name differs, replace `name=iPhone 17 Pro` with one available on your machine.
