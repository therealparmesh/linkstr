# linkstr

`linkstr` is a private link feed for people you trust. Share videos and other media, then discuss it in a focused thread - like a tiny private subreddit for you and the people you talk to.

## Product Behavior Specification

This document is the behavioral contract for the current app. It is intentionally detailed.

### Identity and Account Lifecycle

- A user can either create a fresh keypair or import an existing `Secret Key (nsec)`.
- Once authenticated, the app treats that keypair as the active account context for all scoped data.
- `Contact Key (npub)` is visible in the app where identity sharing/inspection is expected (Share and Settings).
- `Secret Key (nsec)` is never shown by default; it is reveal/copy only from Settings.
- If no identity exists at boot, onboarding is shown.
- On boot with identity present, relay startup is attempted automatically.
- `Log Out (Keep Local Data)` clears active identity from keychain/session state but preserves that account's local contacts/messages for future re-login.
- `Log Out and Clear Local Data` removes identity session and deletes that account's local contacts/messages/cached local media references/local-data encryption key.

### Contacts and Recipient Selection

- Contacts are local-only records; no social/contact/follow event is published to relays.
- Contacts are account-scoped; contacts from one account are not visible under another account.
- Add/edit/delete contact actions are supported locally.
- A contact requires a valid `Contact Key (npub)` and non-empty display name.
- Contact duplicate prevention is applied per account after normalization.
- Recipient picker supports both saved contacts and manual `Contact Key (npub)` entry.
- Recipient picker provides `Paste` / `Scan` / `Clear` assist actions.
- Add-contact flow provides the same `Paste` / `Scan` / `Clear` assist actions.
- In new-post composer, the `Post Link` field provides `Paste` / `Clear` assist actions.
- `Use Contact Key` appears only when typed/pasted/scanned input resolves to a valid `npub` that is not already in saved contacts.
- When entering composer from a known-contact conversation, recipient is preselected.
- When entering composer from an unknown-peer conversation, recipient is locked to that peer.

### Creating a Post (Root Message)

- A post requires a valid web URL and a selected/locked recipient `npub`.
- URL input is normalized and validated; unsupported/malformed values are rejected.
- Optional note is trimmed and persisted only when non-empty.
- Transport uses NIP-59 gift-wrap via `NostrSDK`.
- Linkstr payload is embedded in inner rumor kind `44001`.
- Composer send action waits in-place for relay reconnect rather than dismissing immediately on transient outage.
- Wait behavior defaults to timeout at 12 seconds with periodic polling.
- While awaiting send, composer remains onscreen in sending state.
- On success, post is persisted locally and composer dismisses.
- On failure/timeout, composer stays open and user receives error toast.

### Replying in a Thread

- Reply content is text-only.
- Empty/whitespace-only replies are not sent.
- Reply send uses the same relay-reconnect wait + timeout flow as root post send.
- During reply send attempt, reply input and send action are disabled to prevent duplicate taps.
- If send succeeds, reply input clears, focus is dismissed, and thread scrolls to bottom.
- If send fails or times out, reply text remains in input for retry/edit.

### Sessions, Threads, and Unread Semantics

- Unknown peers can appear directly in Sessions with no invite flow.
- Each root post has an associated reply thread.
- Sessions support swipe archive/unarchive actions.
- Archive state is applied at the root-post level; replies are not independently archived.
- Archive is non-destructive and only changes list placement (`Active` vs `Archived`).
- Opening a session marks inbound root posts in that session as read.
- Opening a thread marks inbound replies for that root post as read.
- Unread indication is dot-only (no numeric badge).
- Session unread logic is per-root-post and does not double-count replies.

### Relay Configuration in Settings

- Users can add, remove, and enable/disable relays.
- Relay URL add validation accepts only `ws://` or `wss://` URLs with valid host.
- Relay list is shown sorted alphabetically.
- Users can reset relay list to app defaults.
- Current default relay set is:
  - `wss://relay.damus.io`
  - `wss://relay.primal.net`
  - `wss://nos.lol`
  - `wss://nostr.satoshisfrens.win`
  - `wss://relay.snort.social`
- Relay row displays health indicator and optional status/error detail.
- Relay inline error slot reserves layout space to prevent row jitter when messages appear/disappear.

### Relay Runtime Lifecycle and Send Gating

- Relay runtime is started when identity is available and app is active.
- On foreground re-entry, relay session is force-restarted to avoid stale-socket assumptions.
- Relay status writes are foreground-only to avoid high-churn persistence while backgrounded.
- Reconnect scheduling uses a single in-flight retry timer (no overlapping reconnect loop tasks).
- Live send requires at least one writable connected relay socket.
- Read-only connected relays are surfaced as read-only and are excluded from send eligibility.
- Relay state classification includes: no enabled relays, online, read-only, reconnecting, offline.
- Blocking send errors are explicit and user-facing for no-enabled, read-only, reconnecting, and offline states.
- Await-send path blocks hard only for no-enabled/read-only and otherwise waits for reconnection until timeout.
- Toast chatter is suppressed during reconnect flapping to avoid repeated noise.
- Offline toast is shown once per outage window when no viable relay is available.
- No offline outbox queue is implemented.
- Failed sends are not auto-retried after future reconnect.

### Incoming Event Ingestion and Backfill

- App subscribes to gift-wrap events for both recipient and author filters.
- On relay connect, subscriptions are (re)installed to handle socket-start races.
- Historical backfill runs in pages to recover earlier messages.
- Backfill completion waits for expected relay EOSE responses per page.
- Backfill pagination continues while a page is full; `until` cursor moves to oldest seen event time minus one.
- Only gift-wrap events that unseal to valid linkstr rumor payloads (`44001`) are accepted.
- Duplicate events are ignored by event ID deduping.
- For already-known root events, duplicate re-ingest can still trigger metadata refresh requeueing.
- Incoming accepted events are persisted locally under active account scope.

### Link Metadata and Preview Hydration

- Root posts use `LinkPresentation` metadata fetch for title/thumbnail enrichment.
- Metadata fetch runs asynchronously and never blocks compose send completion.
- Metadata provider requests use a bounded timeout (currently 6 seconds per attempt).
- On app boot, existing root posts are scanned and missing metadata is re-hydrated.
- Root messages with missing titles are re-queued for metadata fetch.
- Root messages with thumbnail paths that no longer exist on disk are re-queued for metadata fetch.
- Re-ingested duplicate root events can re-queue metadata enrichment for previously stored messages.
- Metadata updates are non-destructive: existing title/thumbnail values are preserved when fresh fetch results are partial.
- Stale thumbnail paths are cleared if no valid thumbnail file exists and no replacement thumbnail is returned.
- Thumbnail files are stored under app `Application Support` in `linkstr/thumbnails`.

### Notifications

- Notifications are local best-effort notifications driven by incoming relay events.
- APNs remote push is not implemented.
- Only inbound messages trigger notifications (self-sent echoes do not).
- Root post notification title format: `"{sender} shared a post"`.
- Reply notification title format: `"{sender} replied"`.
- Notification body prefers note text when present; otherwise uses fallback copy.
- Notifications are grouped by conversation using `threadIdentifier`.
- When app is open, notifications are still presented as banner/list/sound.

### Media and Link Playback Behavior

- Runtime URL classification determines playback strategy.
- Extraction candidates default to local playback with automatic fallback to official embed.
- URL classification accepts standard web links only (`http` / `https`).
- Local extraction candidates include:
  - TikTok video links
  - Instagram Reels (including shared reel links)
  - Facebook Reels (including shared reel links)
  - X/Twitter status video links matching `.../status/<id>/video/...`
- Embed-only providers include:
  - YouTube (including Shorts)
  - Rumble
  - Instagram non-Reel video posts (including shared post links)
  - Facebook non-Reel video posts (`videos`, `watch?v=...`, and shared video links)
  - X/Twitter non-video statuses (text/photo)
- Instagram host variants include `instagram.com` and `instagr.am`.
- Facebook host variants include `facebook.com`, `fb.com`, and `fb.watch`.
- X/Twitter embeds are rewritten to `fixupx.com` to improve embed consistency.
- Local extraction rejects non-HTTPS media URLs.
- Post cards no longer show a `Video`/`Link` kind label.

### Deep Links

- App handles deep links in the `linkstr://open?p=...` format.
- Deep-link payload opens a dedicated playback-first full-screen experience.
- User exits deep-link experience with `Done`.

### Data Storage, Isolation, and Security

- Contacts, messages, relay settings, and cached media are stored locally on device.
- Contacts/messages are account-isolated by owner pubkey.
- Account switching does not merge, leak, or expose another account's local contact/message data.
- Sensitive contact/message fields are encrypted at rest with per-account local key material.
- Decryption occurs on read for active account context.
- Identity key material is stored in keychain.
- Keychain storage uses migratory accessibility (`WhenUnlocked`, not `ThisDeviceOnly`) so encrypted backups/device migration can carry keys.
- Keychain writes prefer synchronizable storage when available to improve cross-device restore continuity.
- Keychain survival across reinstall may occur but is not guaranteed and should not be treated as backup strategy.
- Uninstall removes app-local data.
- Reliable cross-device/reinstall recovery requires user backup of `Secret Key (nsec)`.

### Known Limitations and Explicit Non-Goals (Current)

- Offline outbox/retry queue is not in scope today.
- Message deletion selection mode/bulk delete is not in scope today.
- Remote push (APNs) is not in scope today.
- Contact graph publishing/follow events are not in scope today.
- Public feed/discovery is not in scope; app is DM/session oriented.

## QR Scanner Notes

- QR scan requires camera permission.
- iOS Simulator camera scanning is often unreliable.
- If scan fails/unavailable, paste/manual entry and real-device testing are expected fallback paths.

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
