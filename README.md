# linkstr (iOS 17+)

`linkstr` is a private, link-first Nostr app for sharing URLs and threaded replies with one session per peer.

## Product behavior

- Identity
  - Sign in with `Secret Key (nsec)` or create a new keypair.
  - `Contact Key (npub)` is visible in Share and Settings.
  - `Secret Key (nsec)` is reveal/copy only in Settings.
  - Log out is available in Settings.
- Messaging
  - Uses NIP-59 gift-wrap transport through `NostrSDK`.
  - Message payloads are already encrypted in transit by NIP-59 gift-wrap.
  - App payload is carried in custom inner rumor kind `44001`.
  - Only linkstr payloads (`44001`) are processed.
  - Posts require URL + optional note.
  - Replies are text-only.
  - Notifications are local best-effort alerts while the app is active/receiving relay events (no APNs remote push yet).
- Sessions and contacts
  - Unknown peers appear directly in Sessions (no invite flow).
  - Contacts are local-only (no follow event is published) and scoped per signed-in account.
  - Messages are scoped per signed-in account.
  - Contact and message sensitive fields are encrypted at rest locally with a per-account key.
  - Add/edit/delete contacts locally.
  - Add contact flow provides the same `Paste` / `Scan` / `Clear` assist row used in recipient selection.
  - New post composer uses a single recipient picker with one `To` input for contact search and manual `Contact Key (npub)` entry, with matching `Paste` / `Scan` / `Clear` shortcuts.
  - `Use Contact Key` appears only for valid `Contact Key (npub)` values that are not already saved contacts.
  - From inside a known-contact session, recipient is preselected; from inside an unknown-peer session, recipient is locked to that peer.
  - Share extension sends to a selected contact with URL + optional note.
  - Pending shares are scoped to the account that queued them.
  - Share-extension snapshots and pending shares in the app-group container are encrypted at rest.
- Read/unread
  - Opening a session marks inbound posts in that session as read.
  - Opening a post thread marks inbound replies for that post as read.
  - Unread status is shown as a dot indicator (no numeric badge).
  - Session unread state is per-post (no reply double-counting).
- Relays
  - Add/remove/toggle relays.
  - Relay health status shown by colored dot.
  - Green relay status means read/write connected; read-only relays are shown separately and cannot send.
  - Relay disconnect/reconnect chatter is suppressed in toasts.
  - Offline toast appears only when zero enabled relays are connected, zero are read-only, and none are reconnecting.
  - Sending is blocked unless at least one enabled relay is read/write connected.
  - Pending shares stay queued until a writable relay connection is available.
  - On connect/sign-in, the app subscribes live and also backfills relay history (paged) to recover prior messages.
  - Relays sorted alphabetically in Settings.
  - Reset to default relays from Settings.
- Media
  - Runtime URL classification decides playback strategy.
  - Local extraction candidates: TikTok video links, Instagram Reels, Facebook Reels, X/Twitter status video links (`.../status/<id>/video/...`).
  - Extraction candidates default to local playback and auto-fallback to official embed.
  - Embed-only: YouTube (including Shorts), Rumble, Instagram non-reel video posts, Facebook non-reel video posts, and X/Twitter non-video statuses (text/photo).
  - X/Twitter embeds use `fixupx.com` substitution (`https://fixupx.com/...`) for consistent embedded rendering.
  - Local extraction only accepts HTTPS media URLs; HTTP candidates are ignored.
  - `Video` label appears only for extraction candidates; embed-only and generic URLs show `Link`.

## QR scanner note

- QR scanning needs camera access.
- iOS Simulator often cannot provide reliable live camera scanning.
- If simulator scan is unavailable, use manual paste/entry or test scanning on a physical iPhone.

## Local data and account switching

- Contacts, messages, relay settings, and cached media are local app data.
- Contacts/messages are isolated by account (`pubkey`) on-device. Logging into another account does not merge or expose another account's contacts/messages.
- Local sensitive fields for contacts/messages are encrypted at rest; decryption happens on read for the active account.
- `Log Out (Keep Local Data)` signs out and keeps this account's local contacts/messages on-device for that same account to see after signing back in.
- `Log Out and Clear Local Data` removes this account's local contacts/messages, account-scoped queued shares, cached local video references, and this account's local-data encryption key.
- Share-extension contact snapshot is cleared on logout and repopulated from the currently signed-in account.
- Uninstall removes local app data.
- Identity key is stored in keychain. Keychain entries may survive reinstall on the same device, but do not rely on that for recovery.
- For reliable recovery across devices/reinstalls, back up your `Secret Key (nsec)` and sign in again.

## Open in Xcode

```bash
open Linkstr.xcodeproj
```

## Run tests

```bash
xcodebuild test -project Linkstr.xcodeproj -scheme Linkstr -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

If your installed simulator name differs, replace `name=iPhone 17 Pro` with one available on your machine.
