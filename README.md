# linkstr

`linkstr` is for sharing videos and links privately with people who don’t use social media.

## Product behavior specification

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
  - `loading account…`
  - `preparing local data…`
  - `connecting relays…`
  - `starting session…`
- Boot loads identity from keychain and configures local notifications.
- Boot ensures default relays exist if the local relay list is empty.
- Boot starts relay runtime when identity is available.
- If no identity exists, onboarding is shown.
- If identity exists, the main app shell is shown.
- The app uses a Tokyo Night color scheme across all surfaces.
- Main app shell uses native iOS tab/navigation bars with transparent chrome over the Tokyo Night app background.
- Text sizing is controlled by centralized theme tokens with a slightly larger baseline for chat readability.

### Identity and account lifecycle

- Users can create a new account (new keypair) or import an existing `nsec`.
- The active identity is keychain-backed.
- Settings and Share expose current `npub`.
- Settings sections are collapsed by default and expand on demand.
- `nsec` is hidden by default and only revealed on explicit action.
- Revealed `nsec` is cleared again when the Settings identity view disappears or the app moves inactive/background.
- Settings includes `Delete Account` inside Identity with a two-step destructive confirmation flow.
- `Log Out (Keep Local Data)` clears active identity only.
- `Log Out and Clear Local Data` clears identity and deletes account-scoped local data:
  - Contacts.
  - Sessions.
  - Session members.
  - Session membership intervals.
  - Session posts.
  - Reactions.
  - Cached media references.
  - Local encryption key material for that owner scope.
- `Delete Account` clears identity and the same account-scoped local data as `Log Out and Clear Local Data`.
- When relays are available, `Delete Account` also:
  - Publishes an empty follow list (`kind:3`) before local deletion.
  - Publishes a Nostr `Request to Vanish` (`kind:62`) to enabled relays.
- `Delete Account` is send-gated like other relay-backed mutations and does not proceed while relay confirmation is unavailable.

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
  - Update fanout targets both prior-active and next-active members so removed members receive the removal snapshot.
  - Snapshot application is monotonic by `created_at`; older snapshots are ignored.
  - Equal-timestamp snapshot conflicts resolve by lexicographic event-ID tie-break.
- Sessions can be archived/unarchived from a session-row long-press menu.
- Session list shows active sessions by default.
- When archived sessions exist, a header archive toggle icon appears to the left of `+` in the sessions tab.
- Tapping the archive icon switches between active and archived list mode.
- Archive mode is visually indicated via the highlighted/filled archive icon state.
- Switching away from sessions resets the list mode back to active.
- Archive is non-destructive.

### Session members UX

- Session member management is available inside a session.
- Members can be added only from existing contacts.
- Members can be removed from active membership.
- Only the session creator can add or remove members.
- Non-creator membership mutations are ignored on ingest.
- If a member no longer matches a local contact, UI falls back to `npub` (or truncated hex).
- Outbound membership snapshots authored by this client always include the local sender key.

### Posts (root links)

- Posting is session-scoped.
- Compose fields are:
  - Session context (read-only).
  - Link (required).
  - Note (optional).
- Link field supports `Paste` and `Clear` helpers.
- Link helper controls render directly below the field in a compact, consistent control row.
- Entering the link field pre-fills `https://` when the field is empty.
- Paste replaces the entire link field value.
- URL input is normalized and must be valid `http`/`https`.
- Unsupported schemes are rejected.
- Note text is trimmed and persisted only when non-empty.
- In post detail, the raw link text is tappable and opens in the browser.
- In post detail, note text is rendered in its own bubble for visual separation.
- Send behavior is reconnect-and-timeout:
  - Composer remains on-screen while waiting to send.
  - Send waits for a usable relay path (default timeout 12 seconds).
  - On success, post persists locally and composer dismisses.
  - On failure/timeout, composer stays open and error is shown.
- Posting is blocked when the sender is not an active member of the target session.
- Posting recipient resolution uses only active session members.
- Root post identity is the Nostr event ID.
- Inbound root payloads with a non-empty `root_id` that does not match the event ID are ignored.
- Outgoing root posts persist the relay-visible gift-wrap event IDs that carried that root payload.
- Post detail exposes delete only for posts sent by the signed-in user.
- Post delete publishes a Nostr deletion request (`kind:5`) against the stored gift-wrap event IDs when available, and also sends a Linkstr delete notice to known current and former session members so encrypted session feeds converge on the removal.
- Older locally stored root posts without recorded gift-wrap IDs skip relay-side `kind:5` publication and still use the Linkstr delete notice plus local tombstoning.
- Post delete persists a local deletion watermark so historical backfill cannot resurrect a previously deleted root post.

### Reactions

- Reactions are emoji-only toggles tied to a post.
- Reaction send is blocked when the sender is not an active member of the target session.
- UX includes:
  - Session post list shows compact read-only reaction summaries (no interactive controls); single reactions show emoji-only and higher counts use bottom-right badges.
  - Post detail uses interactive Slack-style reaction summary chips.
  - Inline quick toggles for `👍`, `👎`, `👀`.
  - `...` button that opens the full emoji picker sheet.
  - Post detail separates the per-participant breakdown section with a divider.
  - Post detail shows per-participant breakdown rows (`display_name: emojis_reacted_with`).
- Default quick options include `👍`, `👎`, `👀`.
- Read-only reaction count badges cap visually at `10+`.
- Reaction state is keyed by:
  - Session ID.
  - Post/root ID.
  - Emoji.
  - Sender pubkey.
- Transport carries reaction active/inactive state.
- Reactions targeting unknown root posts are ignored.
- Equal-timestamp reaction conflicts resolve by lexicographic event-ID tie-break.
- Reactions tied to a deleted post are removed with that post.

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
- Relay rows show a live status dot (`connecting`, `connected`, `read-only`, `failed`, `disabled`) and optional inline error text.
- Relay error rows reserve layout height to avoid jitter when status text appears/disappears.
- Offline relay toast signaling is suppressed during initial connection and only shown after a previously healthy relay drops in the same foreground lifecycle.

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
- Outgoing publish awaits relay `OK` acceptance with timeout, and fanout sends only succeed after each published gift-wrap has at least one accepted relay path.
- Accepted incoming payload kinds are:
  - `session_create`
  - `session_members`
  - `root`
  - `root_delete`
  - `reaction`
- Ingest processing rules:
  - Ignore undecodable/unvalidated payloads.
  - Deduplicate by event ID.
  - Self-authored duplicate root echoes merge additional gift-wrap transport IDs into the stored root post instead of creating duplicate posts.
  - `session_create` requires sender and receiver inclusion in the snapshot member set.
  - `session_create` for an existing session is accepted only from the stored creator pubkey.
  - `session_members` is accepted only from the stored creator pubkey and only when the session already exists.
  - `session_members` snapshots must include the creator pubkey.
  - Upsert sessions/member snapshots from accepted session events.
  - Live relay subscriptions use `since` filters so live ingest is new-event oriented.
  - Persist root posts only when sender and receiver are active at the event timestamp.
  - Live root ingest additionally requires sender and receiver to be active in the latest local membership snapshot.
  - Linkstr delete notices remove matching stored root posts only when the delete sender matches the original post sender.
  - Upsert reaction state only when sender and receiver are active at the event timestamp and the root post exists locally.
  - Live reaction ingest additionally requires sender and receiver to be active in the latest local membership snapshot.

### Notifications (best effort)

- Notifications are local notifications based on incoming relay events.
- APNs remote push is not implemented.
- Current notification types are:
  - Inbound root posts.
  - Inbound active emoji reactions.
- Reaction deactivations do not trigger notifications.
- Self-echoed events do not trigger notifications.
- Foreground presentation remains enabled (`banner`, `list`, `sound`).
- Background delivery is best-effort only; when the app is suspended and sockets are not active, incoming events are surfaced on next reconnect/foreground.

### Media and link behavior

- URL classification drives playback mode (extraction/embed/link fallback).
- Canonicalization handles mobile host variants (for example `m.facebook.com`).

#### Extraction vs. embed

- Extraction downloads the video file locally for native playback.
  - Local playback uses the system video player with full controls.
  - Extracted media can be saved to Photos or Files.
  - Works offline once cached.
- Embed loads the provider's web player in an inline web view.
  - Requires network connectivity.
  - Subject to provider playback restrictions and UX.
  - Fullscreen depends on provider iframe support.
- Hidden provider-sniff web views use non-persistent website data and reject non-web navigation schemes.

#### Provider support

- Extraction-preferred providers (local playback attempted first, embed fallback available):
  - TikTok videos.
  - Instagram Reels.
  - Facebook Reels.
  - Twitter/X statuses only when provider metadata confirms video media is present.
- Embed-only providers (web player only, no extraction):
  - YouTube.
  - Rumble.
  - Instagram non-reel posts (`/p/`, `/tv/`).
  - Facebook non-reel videos (`/videos/`).
- Twitter/X non-video statuses prefer official tweet embeds with deferred reveal and live height measurement, and otherwise fall back to browser open.
- Generic links fall back to open-in-browser.

#### Playback behavior

- For extraction-capable providers, local playback is attempted first with explicit controls to switch to embed mode.
- Local/embed action rows are normalized across post detail and deep-link playback surfaces.
- Media playback surfaces temporarily acquire an `AVAudioSession` playback category while onscreen, so audio still plays when the iPhone silent switch is enabled.
- In local playback mode with a locally cached media file, users can export via `Save...`:
  - `Save to Photos` (requests Photos add-only permission).
  - `Save to Files` (document export flow, no broad media permission).
- If extraction fails, embed mode remains available and offers retry-local plus Safari open actions.
- Canonical TikTok post URLs prefer exact `aweme_id` API playback candidates and avoid page-sniff fallback when exact extraction fails, to reduce accidental related-video matches.
- Twitter/X status handling is resolved at runtime:
  - Video statuses use extraction-preferred playback.
  - Non-video statuses use official tweet oEmbed HTML when available.
  - If official tweet embed resolution fails, the fallback is a regular browser link.

#### Embed URL patterns

- Embed URLs prefer provider-native patterns where available:
  - TikTok `embed/v2`.
  - Instagram `/embed`.
  - Facebook plugin `/plugins/video.php`.
  - YouTube `/embed`.
  - Rumble oEmbed iframe URL.
- Twitter/X embeds use official `publish.twitter.com/oembed` HTML rather than assuming `x.com/i/status/...` is always embeddable.
- Facebook videos/reels use Facebook plugin embed URLs (`/plugins/video.php`) with canonicalized `href` targets.
- Rumble embeds are resolved from provider oEmbed iframe URLs when available.
- Embedded web playback allows provider element fullscreen when supported by the provider and iframe context.

#### Media actions and metadata

- Media actions are normalized:
  - One action button uses full width.
  - Two action buttons split width evenly with spacing.
- Metadata hydration fetches title/thumbnail asynchronously for root posts.
- On boot, existing root posts are re-queued for metadata hydration when stale/missing.
- Missing local thumbnail files are treated as stale and re-fetched.

### Contacts

- Contacts mirror the account's Nostr follow list (`kind:3`, NIP-02).
- Add/remove contact actions publish a full replacement follow-list event and wait for relay acceptance.
- Incoming follow-list events from the signed-in author reconcile local contacts (newer timestamp wins; equal timestamp uses lexicographic event-ID tie-break).
- Follow-list recency watermarks are persisted per account so app restart does not allow stale follow-list rollback.
- Aliases are private per-account device data and are never published to relays.
- Contact management supports add/remove and alias edit.
- Add-contact input supports manual entry, paste, and QR scan.
- Contact-key helper controls render directly below the field in the same compact control row pattern used by post compose.
- Duplicate contacts are blocked per account scope.

### Share tab

- Share tab exposes current account `npub`.
- Share tab provides:
  - QR code.
  - A centered scan helper caption below the QR code.
  - Raw key text.
  - Copy action.

### Deep links

- Deep link format is `linkstr://open?p=...`.
- Valid deep links open a full-screen playback surface.
- Deep-link playback reuses the same adaptive local/embed controls as in post detail.
- Dismissing deep link playback clears pending deep-link state.

### Local data and security

- SwiftData persistence is local-first and survives app relaunch.
- Persisted local entities include:
  - Relay configuration and enabled state.
  - Contacts and private aliases.
  - Account-scoped app state (follow-list recency watermark).
  - Sessions, member snapshots, membership intervals, root posts, post deletion watermarks, reactions, read state, and archive state.
  - Cached media references and metadata hydration state.
- Managed thumbnails and cached video files live under app-owned directories, and cleanup only removes files from those managed paths.
- Local entities are owner-scoped by pubkey.
- Account scoping is enforced in storage and query paths to prevent cross-account bleed.
- `Log Out (Keep Local Data)` preserves persisted local entities for later re-login.
- `Log Out and Clear Local Data` removes the signed-in account’s persisted entities and cached media references.
- Sensitive content fields are encrypted at rest with per-owner local keys (aliases, session/member identity values, URLs/notes, metadata, and creator keys).
- Operational identifiers and timestamps remain plaintext in local storage for indexing/querying.
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

## Future

- Future proposals are tracked as separate docs and are not part of the current shipped behavior.
- Proposal docs are directional/high-level and can change before implementation.
- Delete session: [docs/future/delete-session.md](docs/future/delete-session.md)
- Leave session: [docs/future/leave-session.md](docs/future/leave-session.md)

## Development

### Open in Xcode

```bash
open Linkstr.xcodeproj
```

### Run tests

```bash
xcodebuild test -project Linkstr.xcodeproj -scheme Linkstr -destination 'platform=iOS Simulator,name=iPhone 17'
```

- If your simulator name differs, replace `name=iPhone 17` with one available locally.
