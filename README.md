# linkstr

`linkstr` is a private link feed for people you trust: share videos and other media in focused sessions - like a tiny private subreddit for you and the people you talk to.

## Product Behavior Spec (Current)

### Product model

- The app is session-first, not DM-first.
- A session is a private container with:
  - A name.
  - A member set.
  - A feed of root posts.
- A post is a link item inside a session with:
  - Required URL.
  - Optional note.
  - Optional metadata hydration (title/thumbnail).
  - Emoji reactions.
- Text replies are not part of the current product.
- App data is transported as private Nostr gift-wrap DMs using app payload kind `44001`.

### Startup and boot

- On launch, the app enters a blocking boot flow with visible status text.
- Boot status labels are user-visible and progress through:
  - `Loading account…`
  - `Preparing local data…`
  - `Connecting relays…`
  - `Starting session…`
- Boot loads identity from keychain and configures local notifications.
- Boot ensures default relays exist if the local relay list is empty.
- Boot starts relay runtime when identity is available.
- If no identity exists, onboarding is shown.
- If identity exists, the main app shell is shown.

### Identity and account lifecycle

- Users can create a new account (new keypair) or import an existing `nsec`.
- The active identity is keychain-backed.
- Settings and Share expose current `npub`.
- `nsec` is hidden by default and only revealed on explicit action.
- `Log Out (Keep Local Data)` clears active identity only.
- `Log Out and Clear Local Data` clears identity and deletes account-scoped local data:
  - Contacts.
  - Sessions.
  - Session members.
  - Session posts.
  - Reactions.
  - Cached media references.
  - Local encryption key material for that owner scope.

### Sessions

- Session list is the top-level surface.
- Sessions are local account-scoped entities with:
  - `sessionID`.
  - Name.
  - Creator pubkey.
  - Updated timestamp.
  - Archive flag.
- Users create sessions from the Sessions tab `+` flow.
- Session creation requires a non-empty name.
- `Create Session` stays disabled (with disabled styling) until name is non-empty.
- Member selection at creation is optional.
- Session creation can be solo (creator only).
- After successful session creation, the app navigates directly into that session.
- Transport always includes creator in the effective member set.
- Member updates are snapshot-based (`session_members`):
  - The active member set becomes exactly the snapshot.
  - Missing previous members become inactive.
- Sessions can be archived/unarchived from session-row archive controls.
- Session list supports `Active`, `Archived`, and `All` filters.
- Archive is non-destructive.

### Session members UX

- Session member management is available inside a session.
- Members can be added only from existing contacts.
- Members can be removed from active membership.
- If a member no longer matches a local contact, UI falls back to `npub` (or truncated hex).
- Current user is preserved in effective membership.

### Posts (root links)

- Posting is session-scoped.
- Compose fields are:
  - Session context (read-only).
  - Link (required).
  - Note (optional).
- Link field supports `Paste` and `Clear` helpers.
- Entering the link field pre-fills `https://` when the field is empty.
- Paste replaces the entire link field value.
- URL input is normalized and must be valid `http`/`https`.
- Unsupported schemes are rejected.
- Note text is trimmed and persisted only when non-empty.
- In post detail, the raw link text is tappable and opens in the browser.
- Send behavior is reconnect-and-timeout:
  - Composer remains on-screen while waiting to send.
  - Send waits for a usable relay path (default timeout 12 seconds).
  - On success, post persists locally and composer dismisses.
  - On failure/timeout, composer stays open and error is shown.
- Posting is blocked when no active members are available for the session.

### Reactions

- Reactions are emoji-only toggles tied to a post.
- UX includes:
  - Session post list shows read-only reaction summary chips.
  - Post detail uses interactive Slack-style reaction summary chips.
  - Inline quick toggles for `👍`, `👎`, `👀`.
  - `...` button that opens the full emoji picker sheet.
  - Post detail shows a per-emoji participant breakdown (who reacted with each emoji).
- Default quick options include `👍`, `👎`, `👀`.
- Reaction state is keyed by:
  - Session ID.
  - Post/root ID.
  - Emoji.
  - Sender pubkey.
- Transport carries reaction active/inactive state.

### Read/unread semantics

- Session rows show unread indicators when any inbound root post in that session is unread.
- Post cards inside a session show unread indicators when that root post is unread inbound.
- Opening a session does not auto-mark all posts as read.
- Opening post detail marks that inbound root post as read.
- Reactions do not affect unread counters.

### Relay settings and runtime

- Relay management is in Settings.
- Users can:
  - Add relay URL (`ws://` or `wss://`, valid host required).
  - Enable/disable relay.
  - Remove relay.
  - Reset default relays.
- Relay header shows `connected_or_readonly / total`.
- Relay rows show a live status dot (`connected`, `read-only`, `failed`, `disabled`) and optional inline error text.
- Relay error rows reserve layout height to avoid jitter when status text appears/disappears.

### Relay send gating

- Relay runtime starts when identity exists and app is active.
- Foreground re-entry force-restarts runtime to avoid stale sockets.
- Send gating behavior:
  - Immediate block when no enabled relays.
  - Immediate block when only read-only relays are available.
  - Otherwise wait for connection until timeout.
- No offline outbox exists.
- Failed sends are not queued for automatic retry.

### Nostr transport and ingest

- Payloads are JSON-encoded and published through `NostrSDK` gift wraps.
- Outgoing publish awaits relay `OK` acceptance with timeout.
- Accepted incoming payload kinds are:
  - `session_create`
  - `session_members`
  - `root`
  - `reaction`
- Ingest processing rules:
  - Ignore undecodable/unvalidated payloads.
  - Deduplicate by event ID.
  - Upsert sessions/member snapshots from session events.
  - Persist root posts under account scope.
  - Upsert reaction state by composite reaction key.

### Notifications (best effort)

- Notifications are local notifications based on incoming relay events.
- APNs remote push is not implemented.
- Current notification type is inbound root post only.
- Reaction events do not trigger notifications.
- Self-echoed events do not trigger notifications.
- Foreground presentation remains enabled (`banner`, `list`, `sound`).

### Media and link behavior

- URL classification drives playback mode (extract/embed/link fallback).
- Canonicalization handles mobile host variants (for example `m.facebook.com`).
- For extraction-capable providers, local playback is attempted first with explicit controls to switch to embed mode.
- If extraction fails, embed mode remains available and offers retry-local plus Safari open actions.
- Media actions are normalized:
  - One action button uses full width.
  - Two action buttons split width evenly with spacing.
- Metadata hydration fetches title/thumbnail asynchronously for root posts.
- On boot, existing root posts are re-queued for metadata hydration when stale/missing.
- Missing local thumbnail files are treated as stale and re-fetched.

### Contacts

- Contacts are local account-scoped records.
- Contacts are not published as social graph events.
- Contact management supports add/edit/delete.
- Add-contact input supports manual entry, paste, and QR scan.
- Duplicate contacts are blocked per account scope.

### Share tab

- Share tab exposes current account `npub`.
- Share tab provides:
  - QR code.
  - Raw key text.
  - Copy action.

### Deep links

- Deep link format is `linkstr://open?p=...`.
- Valid deep links open a full-screen playback surface.
- Dismissing deep link playback clears pending deep-link state.

### Local data and security

- Local entities are owner-scoped by pubkey.
- Sensitive stored fields are encrypted at rest with per-owner local keys.
- Identity keys remain in keychain.
- Keychain accessibility uses `WhenUnlocked` and prefers synchronizable items when available.
- Simulator fallback key storage is used when simulator keychain is unavailable.

### Backup and migration expectations

- Identity continuity across devices depends on keychain/iCloud keychain backup conditions.
- SwiftData participates in iOS backup/restore according to device backup mode.
- If encrypted local data restores without matching key material, encrypted fields are unreadable.
- Reliable long-term portability still depends on preserving `nsec`.

### Known non-goals

- No offline guaranteed delivery queue.
- No automatic resend of previously failed posts.
- No APNs remote push.
- No public discovery feed/social graph product surface.
- No text-based post replies.

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

- Use this prompt when behavior changes and README must stay aligned with shipped code:

```text
Rewrite README.md as a cohesive, human-readable product behavior spec for the current app state.

Constraints:
- Keep the top project title and one-line product description intact unless explicitly asked to change them.
- Use bullet points, not numbered checklist formatting.
- Cover: product model, boot, identity lifecycle, sessions, members, posts, reactions, unread semantics, relay management/runtime/send gating, transport+ingest, notifications, media/link behavior, contacts, share tab, deep links, local security/storage, migration expectations, and non-goals.
- Reflect current implementation only; do not document aspirational behavior.
- Keep precise engineering language without commit-log or Jira-task tone.
- Keep development commands at the end.
```
