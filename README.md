# linkstr (iOS 17+)

`linkstr` is a private, link-first Nostr app for sharing URLs and threaded replies with one session per peer.

## Product behavior

- Identity
  - Sign in with `Secret Key (nsec)` or create a new keypair.
  - `Contact key (npub)` is visible in Share and Settings.
  - `Secret Key (nsec)` is reveal/copy only in Settings.
  - Log out is available in Settings.
- Messaging
  - Uses NIP-59 gift-wrap transport through `NostrSDK`.
  - App payload is carried in custom inner rumor kind `44001`.
  - Only linkstr payloads (`44001`) are processed.
  - Posts require URL + optional note.
  - Replies are text-only.
  - Notifications are local best-effort alerts while the app is active/receiving relay events (no APNs remote push yet).
- Sessions and contacts
  - Unknown peers appear directly in Sessions (no invite flow).
  - Contacts are local-only (no follow event is published).
  - Add/edit/delete contacts locally.
  - Add contact flow supports camera QR scan to prefill `Contact key (npub)`.
  - New post composer uses contact selection by default. From inside a known-contact session, recipient is preselected; from inside an unknown-peer session, recipient is locked to that peer.
  - Share extension sends to a selected contact with URL + optional note.
- Read/unread
  - Opening a session marks inbound posts in that session as read.
  - Opening a post thread marks inbound replies for that post as read.
  - Unread status is shown as a dot indicator (no numeric badge).
  - Session unread state is per-post (no reply double-counting).
- Relays
  - Add/remove/toggle relays.
  - Relay health status shown by colored dot.
  - Relay disconnect/reconnect chatter is suppressed in toasts.
  - Offline toast appears only when zero enabled relays are connected.
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

## Local data and reinstall/switch behavior

- Contacts, messages, relay settings, and cached media are local app data.
- Uninstall removes local app data.
- Identity key is stored in keychain. Keychain entries may survive reinstall on the same device, but do not rely on that for recovery.
- For reliable recovery across devices/reinstalls, back up your `Secret Key (nsec)` and sign in again.

## Open in Xcode

```bash
open Linkstr.xcodeproj
```

## Run tests

```bash
xcodebuild test -project Linkstr.xcodeproj -scheme Linkstr -destination 'platform=iOS Simulator,name=iPhone 16'
```

If your installed simulator name differs, replace `name=iPhone 16` with one available on your machine.
