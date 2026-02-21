# linkstr

`linkstr` is a private link feed for people you trust: share videos and other media, then discuss it in a focused thread - like a tiny private subreddit for you and the people you talk to.

## Product Behavior Spec (Current)

### Product shape

- The app is session-first, not DM-first.
- A session is a private container of members and posts.
- A post is a root link item inside a session.
- A post can have threaded text replies.
- A post can have emoji reactions.
- Everything is private relay-delivered Nostr DM payloads carried inside gift wrap events.

### App startup and boot

- On app launch, the app enters a boot phase and shows a loading screen with a status line.
- Boot stages are user-visible (`Loading account…`, `Preparing local data…`, `Connecting relays…`, `Starting session…`).
- If no account exists after boot, onboarding is shown.
- If an account exists, the main app is shown.
- Relay startup is attempted automatically when identity is available.

### Identity and account lifecycle

- Users can either:
  - Create a new account (new keypair).
  - Import an existing `Secret Key (nsec)`.
- Active identity is loaded from keychain.
- `Contact Key (npub)` is exposed in Share and Settings.
- `Secret Key (nsec)` is hidden by default and only revealed on explicit action in Settings.
- `Log Out (Keep Local Data)` removes active identity but keeps account-scoped local data.
- `Log Out and Clear Local Data` removes identity and deletes local data for that account scope:
  - Contacts.
  - Sessions/posts/replies/reactions.
  - Cached media references.
  - Local encryption key for that account.

### Sessions

- Session list is the top-level inbox.
- Sessions are account-scoped local entities with:
  - `sessionID`.
  - Name.
  - Created-by pubkey.
  - Updated timestamp.
  - Archive state.
- Sessions can be created from `Sessions` tab `+`.
- New session flow:
  - Requires a non-empty session name.
  - Member selection is optional.
  - Members can only be chosen from contacts in the creation UI.
  - Session creation works even with no selected contacts (solo session).
- At send/transport level, the creator is always included as a member.
- Session member updates are snapshot-based (`session_members` event):
  - Active set becomes exactly the new snapshot.
  - Missing previous members become inactive.
- Session list is split into active and archived sections.
- Archive/unarchive is non-destructive and is done via swipe action.

### Session members UX

- Session member management is available inside a session.
- Members can be removed from the current active member set.
- Contacts can be added to the active member set.
- If a member is not present in local contacts, member identity falls back to `npub` (or truncated hex fallback).
- Current user is not removable from UI and is retained in effective member set.

### Posts (root links)

- New post flow is session-scoped (no recipient picker in composer).
- Composer fields:
  - Session (read-only context).
  - Link (required).
  - Note (optional).
- Link field supports `Paste` and `Clear` assist actions.
- Link must normalize to valid `http(s)` URL.
- Invalid or unsupported URL schemes are rejected.
- Note is trimmed and persisted only when non-empty.
- Send behavior is wait-and-timeout:
  - Composer stays on screen while sending.
  - Send waits for relay connectivity/reconnect (default timeout 12s).
  - On success, root post persists locally and composer dismisses.
  - On failure/timeout, composer stays open and toast is shown.
- If no members are active for the session, send is blocked.

### Replies

- Replies are text-only payloads tied to a root post.
- Empty/whitespace-only replies are blocked.
- Reply send uses the same wait-and-timeout relay gating as root post send.
- During reply send:
  - Input/send is disabled.
  - On success, input clears and thread scrolls to bottom.
  - On failure, text remains for retry.

### Reactions

- Reactions are emoji-only toggles on a root post.
- Reaction UX uses:
  - A quick per-post summary row (Slack-like chips).
  - A dedicated emoji picker sheet for additional choices.
- Tapping an existing emoji chip toggles current user reaction for that emoji.
- Reactions are modeled as active/inactive state by key:
  - Session.
  - Post/root ID.
  - Emoji.
  - Sender pubkey.
- Default quick/common emojis include `👍`, `👎`, and `👀`.

### Read/unread semantics

- Session row shows unread dot when any of these is true:
  - Unread inbound root post exists in that session.
  - Unread inbound reply exists under any root in that session.
- Session post cards show unread dot when:
  - The root post itself is unread inbound.
  - Or that root has unread inbound replies.
- Opening a session does not auto-mark all roots as read.
- Opening a thread marks:
  - The inbound root post for that thread as read.
  - Inbound replies for that root as read.

### Relay settings and status

- Relay management is in Settings.
- Users can:
  - Add relay (`ws://` or `wss://` only, valid host required).
  - Enable/disable relay.
  - Remove relay.
  - Reset defaults.
- Relay header badge shows `connected_or_readonly_count / total_relays`.
- Relay row shows live status dot (`connected`, `reconnecting`, `read-only`, `failed`, `disabled`).
- Relay error text area reserves height even when empty to prevent row jitter.

### Relay runtime and send gating

- Relay runtime starts when identity is available and app is active.
- On foreground re-entry, relay runtime is force-restarted to avoid stale sockets.
- Runtime relay status is treated as foreground/live truth for send gating.
- Send gating behavior:
  - Hard block immediately for:
    - No enabled relays.
    - Only read-only relays.
  - Otherwise wait for live connection until timeout.
- No offline outbox queue is implemented.
- Failed sends are not auto-retried later.

### Nostr transport behavior

- App payloads are encoded as JSON and carried in rumor kind `44001`.
- Rumors are gift-wrapped per recipient member using `NostrSDK`.
- Outgoing publish confirmation waits for relay `OK` response with timeout.
- Incoming processing accepts only:
  - Gift wraps that can be unsealed.
  - Rumors with app kind `44001`.
  - Payloads that pass validation.
- Event IDs are deduped to avoid duplicate persistence.

### Incoming event handling

- Accepted incoming payload kinds:
  - `session_create`.
  - `session_members`.
  - `root`.
  - `reply`.
  - `reaction`.
- `session_create` upserts session and applies full member snapshot.
- `session_members` applies full member snapshot for existing/new session.
- `root`/`reply` are persisted as session messages under account scope.
- `reaction` upserts per `(session, post, emoji, sender)` state.

### Notifications (best effort)

- Notifications are local notifications triggered by incoming relay events.
- APNs remote push is not implemented.
- Notification types:
  - Incoming root post.
  - Incoming reply.
  - Incoming reaction.
- Self-sent echoes do not trigger notifications.
- Notifications are grouped per session via `threadIdentifier`.
- Foreground presentation is enabled (`banner`, `list`, `sound`).

### Media strategy and previews

- URL classification determines playback mode:
  - Extraction-preferred (local media extraction first, embed fallback).
  - Embed-only.
  - Plain link.
- Classification and host handling include mobile host variants (for example `m.facebook.com`).
- Facebook canonicalization normalizes to stable web host for embed URL generation.
- Metadata hydration:
  - Root posts fetch title/thumbnail asynchronously.
  - Existing roots are re-hydrated on boot if metadata is missing/stale.
  - Missing thumbnail file paths are treated as stale and re-fetched.

### Contacts

- Contacts are local account-scoped records.
- Contacts are not published as social graph events.
- Add/edit/delete contact is supported.
- Add contact supports:
  - Manual input.
  - Paste.
  - QR scan.
- Duplicate contacts are prevented within the same account scope.

### Share tab

- Share tab exposes current account `npub`:
  - QR code.
  - Raw key text.
  - Copy action.

### Deep links

- App deep link format: `linkstr://open?p=...`.
- Valid deep links open a dedicated full-screen playback container.
- Dismissing the deep link screen clears pending deep link state.

### Local data and security

- Local models are account-scoped by owner pubkey.
- Sensitive local fields are encrypted at rest with per-account local key material.
- Identity key material is stored in keychain.
- Keychain behavior is migration-friendly:
  - Uses `WhenUnlocked` accessibility.
  - Prefers synchronizable items when available.
- Simulator-only fallback key storage is used when simulator keychain is unavailable.

### Device restore and migration expectations

- Login continuity across device migration depends on keychain/iCloud keychain backup conditions.
- Local SwiftData content is local app data and can participate in device backup/restore depending on iOS backup mode.
- If local encrypted app data restores but keys do not, encrypted fields are not decryptable.
- Reliable long-term portability still requires preserving/exporting `nsec`.

### Known non-goals (current)

- No background guaranteed delivery queue.
- No automatic resend later for previously failed sends.
- No APNs remote push.
- No public feed/discovery social product surface.
- No bulk delete/multi-select message deletion flow yet.

## Development

### Open in Xcode

```bash
open Linkstr.xcodeproj
```

### Run tests

```bash
xcodebuild test -project Linkstr.xcodeproj -scheme Linkstr -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

- If your simulator name differs, replace `name=iPhone 17 Pro` with one available locally.

## README maintenance prompt

- Use this prompt when updating this file after behavior changes:

```text
Rewrite README.md as a cohesive, human-readable product behavior spec for the current app state.

Constraints:
- Keep the top project title and one-line product description intact unless explicitly asked to change them.
- Use bullet points, not numbered acceptance-checklist formatting.
- Be comprehensive: identity, boot, sessions, members, posting, replies, reactions, unread semantics, archive behavior, relays, send gating/timeouts, ingest/backfill, notifications, media/link behavior, deep links, local data/security, migration expectations, and known non-goals.
- Reflect what the code does today, not aspirational future behavior.
- Avoid commit-log tone and avoid Jira/task wording.
- Keep wording precise and implementation-aware, but still readable by product/engineering.
- Keep dev commands at the end.
```
