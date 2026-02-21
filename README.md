# linkstr

`linkstr` is a private link feed for people you trust: share videos and other media, then discuss it in a focused thread - like a tiny private subreddit for you and the people you talk to.

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
- iMessage extension
  - Includes an iMessage app extension (`LinkstrMessagesExtension`) for sharing supported video URLs in Messages.
  - Uses the same runtime URL support matrix as the main app (`URLClassifier` in `SharedKit`).
  - Encodes bubble payloads in `MSMessage.url` as HTTPS (`https://linkstr.app/messages/open?p=...`).
  - On send, the extension waits for LinkPresentation metadata for up to 10 seconds.
  - If metadata fetch times out or fails, send is blocked and the composer shows an error so the user can retry.
  - If message send itself fails, the extension stays open and shows an error instead of silently dismissing.
  - After successful send, the extension dismisses and Messages shows the native pending/sent bubble flow.
  - Selecting a Linkstr bubble auto-attempts opening `linkstr://open?p=...`; if that fails/cancels, `Open in Linkstr` remains available in the extension UI.
  - iOS controls cross-app launch confirmation from Messages extensions; a system open-app confirmation may appear before Linkstr opens.
  - Main app handles that deep link and opens an isolated playback-first screen with `Done` to dismiss.
  - Deep-link flow is intentionally independent of Nostr messaging routes and does not use app-group payload persistence.
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
  - Share extension pre-fills the shared URL and uses the same `To` search pattern, but only existing contacts can be selected (no manual custom `Contact Key` target).
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
  - Relay health/status persistence is foreground-only (no relay-status DB churn while app is backgrounded).
  - No app-side background cutoff is enforced for relay connections; they continue until iOS suspends/terminates the app.
  - Foreground resume/send gating prefers live connected relay sockets.
  - Green relay status means read/write connected; read-only relays are shown separately and cannot send.
  - Relay disconnect/reconnect chatter is suppressed in toasts.
  - Offline toast appears only when zero enabled relays are connected, zero are read-only, and none are reconnecting.
  - Sending is blocked when no relay connectivity is available (live socket or persisted writable status).
  - Pending shares stay queued until a live relay socket is connected.
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

## iMessage manual QA

1. Install and run `Linkstr` on simulator/device.
2. Open Messages and launch `linkstr` from the app drawer.
3. Paste a supported video URL and send.
4. Select the sent Linkstr bubble in the transcript.
5. Verify Linkstr auto-opens (or use fallback `Open in Linkstr` if iOS canceled/blocked launch).
6. Verify Linkstr opens to the deep-link player surface (not into Sessions/threads).
7. Tap `Done` and verify dismissal back to the app root.
8. Repeat with an unsupported URL and verify send is blocked in the extension.
