# linkstr

Last updated: March 13, 2026

`linkstr` is an iOS app for private link sharing on nostr. You create private sessions, share links with people you trust, react with emojis, and open supported video inside the app when a provider allows it.

This repo contains the app plus the small Go push service used for APNs routing.

## Documentation map

- Product support and user-facing behavior: [docs/SUPPORT.md](docs/SUPPORT.md)
- Privacy details: [docs/PRIVACY.md](docs/PRIVACY.md)
- App Store Connect checklist: [docs/APP_STORE_CONNECT.md](docs/APP_STORE_CONNECT.md)
- Push-service setup, operations, and request auth: [push-service/README.md](push-service/README.md)
- Future proposals that are not shipped yet: [docs/future/](docs/future/)

## How linkstr syncs

linkstr is built around private sessions, not one-off direct messages. A session has a creator, a name, a current member list, and a feed of link posts. Reactions and deletes hang off those root posts.

The important rule is that membership changes are snapshot-based. When the session creator adds or removes people, linkstr sends the full member list for that moment, not just a delta. That makes the latest valid snapshot the source of truth for who should be able to see future posts and reactions.

Adding someone later does not retroactively share older posts with them. Removing someone stops future delivery, but it cannot claw back content they already received while they were a valid member.

Relays do not guarantee delivery order. A post can arrive before the session snapshot that makes it valid, and a reaction can arrive before the root post it belongs to. linkstr handles that by staging valid-but-early events in memory, retrying them when the missing session or root shows up, and asking relays for history again after reconnect if something is still waiting.

Deletes are intentionally stricter. A delete notice does not become authoritative until linkstr can match it to the original root post and verify that the delete sender is the same account that sent that root. That prevents bad delete notices from silently wiping out posts or reactions just because they arrived first.

Duplicate relay delivery is normal, especially across reconnects and backfill. linkstr deduplicates by event ID, and when the same root is seen through multiple gift-wrap transport events it merges those wrapper IDs into the same stored post instead of creating duplicates. That keeps the UI clean while still preserving the transport IDs needed for relay-side delete requests later.

linkstr still does not have a durable offline outbox. If a send cannot get relay acceptance, the app leaves the composer open and shows an error instead of pretending the post was sent.

## Product behavior reference

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
- App data is transported as private nostr gift-wrap DMs using app payload kind `44001`.

### Startup and boot

- On launch, the app enters a blocking boot flow with visible status text.
- Boot status labels are user-visible and progress through:
  - `loading account…`
  - `preparing local data…`
  - `connecting relays…`
  - `starting session…`
- Boot loads identity from keychain and registers for remote notifications when allowed.
- Boot briefly retries identity load before falling back to onboarding, to tolerate transient keychain/protected-data unavailability on launch.
- Boot ensures default relays exist if the local relay list is empty.
- Boot starts relay runtime when identity is available.
- Foreground re-entry and protected-data availability events retry identity load when no account is currently active in memory.
- If persistent local storage cannot be opened, the app shows a recovery screen instead of crashing.
- Storage recovery allows retrying startup or continuing in a temporary in-memory mode for that launch only.
- If no identity exists, onboarding is shown.
- If identity exists, the main app shell is shown.
- The app uses a tokyo night color scheme across all surfaces.
- Main app shell uses native ios tab/navigation bars with visible frosted chrome over the tokyo night app background.
- Primary screens use inset-grouped surfaces, full-width list rows, and messenger-style spacing inspired by telegram while preserving tokyo night colors.
- Text sizing is controlled by centralized theme tokens with a slightly larger baseline for chat readability.

### Identity and account lifecycle

- Users can create a new account or import an existing secret key (`nsec`).
- Onboarding presents sign-in and account-creation as separate grouped sections rather than a single stacked neon form.
- New account creation pauses on a backup step that reveals the generated secret key (`nsec`), offers copy, and explains that it works like the account password for future sign-in.
- New account creation can optionally set a profile name that others can see before leaving onboarding.
- The active identity is keychain-backed.
- The you tab exposes a profile card, qr code, current public key (`npub`), and editing for the account's published nostr profile name.
- Settings uses always-visible grouped sections for relays, storage, and identity.
- Secret key (`nsec`) is hidden by default and only revealed on explicit action.
- Revealed secret key (`nsec`) is cleared again when the settings identity view disappears or the app moves inactive/background.
- Settings includes `delete account` inside identity with a two-step destructive confirmation flow.
- `log out (keep local data)` clears active identity only.
- `log out and clear local data` clears identity and deletes account-scoped local data:
  - contacts.
  - sessions.
  - session members.
  - session membership intervals.
  - session posts.
  - reactions.
  - cached media references.
  - local encryption key material for that owner scope.
- `delete account` clears identity and the same account-scoped local data as `log out and clear local data`.
- When relays are available, `delete account` also:
  - Publishes an empty follow list (`kind:3`) before local deletion.
  - Publishes a nostr `request to vanish` (`kind:62`) to enabled relays.
- `delete account` does not invalidate the secret key (`nsec`); keeping that key still allows sign-in again later.
- `delete account` is send-gated like other relay-backed mutations and does not proceed while relay confirmation is unavailable.

### Sessions

- Session list is the top-level surface.
- Sessions are local account-scoped entities with:
  - `sessionID`.
  - Name.
  - Creator pubkey.
  - Updated timestamp.
  - Archive flag.
- Users create sessions from the sessions tab compose action in the top-right corner.
- Session list includes inline search and uses full-width chat-list rows with solid-color avatars, timestamps, and unread markers.
- Session creation uses grouped sections for session details and member selection, plus a persistent bottom action footer.
- Session creation requires a non-empty name.
- `create session` stays disabled (with disabled styling) until name is non-empty.
- Member selection at creation is optional.
- Session creation can be solo (creator only).
- After successful session creation, the app navigates directly into that session.
- Transport always includes creator in the effective member set.
- Member updates are snapshot-based (`session_members`):
  - The active member set becomes exactly the snapshot.
  - Missing previous members become inactive.
  - Newly added members are eligible only for content sent while they are active.
  - Removed members stop receiving future content, but they may still retain anything they already received earlier.
  - Update fanout targets both prior-active and next-active members so removed members receive the removal snapshot.
  - Outbound snapshots authored by this client include the session name so newly added members can materialize the session from the snapshot alone.
  - Snapshot application is monotonic by `created_at`; older snapshots are ignored.
  - Equal-timestamp snapshot conflicts resolve by lexicographic event-ID tie-break.
- Sessions can be archived/unarchived from a session-row long-press menu.
- Session list shows active sessions by default.
- When archived sessions exist, a header archive toggle icon appears to the left of the compose action in the sessions tab.
- Tapping the archive icon switches between active and archived list mode.
- Archive mode is visually indicated via the highlighted/filled archive icon state.
- Switching away from sessions resets the list mode back to active.
- Archive is non-destructive.

### Session members UX

- Session member management is available inside a session.
- Session detail uses chat-like link cards with grouped consecutive posts and a pinned session summary card at the top.
- Members can be added only from existing contacts.
- Members can be removed from active membership.
- Only the session creator can add or remove members.
- Non-creator membership mutations are ignored on ingest.
- Session detail inserts centered `in:` / `out:` separators for membership changes observed after the first local membership snapshot for that session.
- Member identity resolves as local alias, then remote nostr profile name, then public key (`npub`).
- Outbound membership snapshots authored by this client always include the local sender key.

### Posts (root links)

- Posting is session-scoped.
- Post composer uses grouped sections for session, link, and note, with a bottom action footer.
- Compose fields are:
  - session name (read-only).
  - link (required).
  - note (optional).
- Link field supports `paste` and `clear` helpers.
- Link helper controls render directly below the field in a compact, consistent control row.
- Entering the link field pre-fills `https://` when the field is empty.
- `paste` replaces the entire link field value.
- URL input is normalized and must be valid `http`/`https`.
- Unsupported schemes are rejected.
- Note text is trimmed and persisted only when non-empty.
- In post detail, the raw link text supports the standard ios copy menu via text selection.
- In post detail, the top-right share action exports a `linkstr://open?p=...` deep link for the current post URL.
- Browser handoff uses the `open in browser` action.
- In post detail, note text is rendered as an accented note callout for visual separation and media/metadata sit inside grouped detail surfaces.
- Send behavior is reconnect-and-timeout:
  - Composer remains on-screen while waiting to send.
  - Send waits for a usable relay path (default timeout 12 seconds).
  - On success, post persists locally and composer dismisses.
  - On failure/timeout, composer stays open and error is shown.
- Posting is blocked when the sender is not an active member of the target session.
- Posting recipient resolution uses only active session members.
- Root post identity is the nostr event ID.
- Inbound root payloads with a non-empty `root_id` that does not match the event ID are ignored.
- Outgoing root posts persist the relay-visible gift-wrap event IDs that carried that root payload.
- Session post lists show sender headers above post cards and collapse repeated headers for consecutive posts from the same sender.
- Session post lists expose delete for posts sent by the signed-in user via a long-press menu on the post row, matching the session-row archive interaction pattern.
- Post delete publishes a nostr deletion request (`kind:5`) against the stored gift-wrap event IDs when available, and also sends a linkstr delete notice to known current and former session members so encrypted session feeds converge on the removal.
- Older locally stored root posts without recorded gift-wrap IDs skip relay-side `kind:5` publication and still use the linkstr delete notice plus local tombstoning.
- Validated post delete persists a local deletion watermark so historical backfill cannot resurrect a previously deleted root post.

### Reactions

- Reactions are emoji-only toggles tied to a post.
- Reaction send is blocked when the sender is not an active member of the target session.
- UX includes:
  - Session post list shows compact read-only reaction summaries (no interactive controls); single reactions show emoji-only and higher counts use bottom-right badges.
  - Post detail uses interactive reaction chips with the current user's selections highlighted.
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
- Reactions received before their root post are staged in memory and retried once the root arrives.
- Reactions targeting a root that is already tombstoned by a validated delete watermark are discarded.
- A validated matching root delete also clears any staged reactions that were still waiting on that root.
- Mismatched or still-unvalidated delete notices do not clear staged reactions.
- Equal-timestamp reaction conflicts resolve by lexicographic event-ID tie-break.
- Reactions tied to a deleted post are removed with that post.

### Read/unread semantics

- Session rows show unread indicators when any inbound root post in that session is unread.
- Post cards inside a session show unread indicators when that root post is unread inbound.
- Initial relay history restore into an empty local store treats replayed inbound posts as already read.
- Opening a session marks visible inbound root posts as read.
- Opening post detail also marks that inbound root post as read.
- Reactions do not affect unread counters.

### Relay settings and runtime

- Relay management is in settings.
- Users can:
  - Add relay URL (`ws://` or `wss://`, valid host required).
  - Enable/disable relay.
  - Remove relay.
  - Reset default relays.
- Relay header shows `connected_or_readonly / total`.
- Relay, storage, and identity controls remain visible without disclosure-group expansion.
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

### Relay delivery and ingest

- linkstr payloads are JSON-encoded and delivered through nostr gift-wrap direct messages.
- Outgoing publish waits for relay `OK` acceptance with timeout, and fanout only counts as successful once every published gift-wrap has at least one accepted relay path.
- Accepted incoming payload kinds are:
  - `session_create`
  - `session_members`
  - `root`
  - `root_delete`
  - `reaction`
- Ingest processing rules:
  - Ignore anything that cannot be decoded or validated.
  - Deduplicate by event ID.
  - If your own root comes back through more than one gift-wrap, merge the extra transport IDs into the same stored or staged root instead of creating duplicate posts.
  - `session_create` requires both sender and receiver to appear in the snapshot member set.
  - `session_create` for an existing session is accepted only from the stored creator pubkey.
  - `session_members` is accepted only from the stored creator pubkey.
  - `session_members` can bootstrap a missing session when the snapshot includes sender, receiver, and a non-empty session name.
  - `session_members` snapshots must include the creator pubkey.
  - Accepted session events update the stored session row and membership snapshot.
  - Live relay subscriptions use `since` filters so live ingest stays focused on new events.
- Persist root posts only when sender and receiver are active at the event timestamp.
- Live root ingest additionally requires sender and receiver to be active in the latest local membership snapshot.
- Out-of-order root posts are staged in memory until a valid session snapshot arrives.
- Out-of-order root deletes are staged in memory until the target root exists locally and the delete sender matches that root.
- If staged dependencies remain across relay reconnects, the app restarts the relay runtime to request a fresh historical replay.
- linkstr delete notices remove matching stored root posts only when the delete sender matches the original post sender, and they do not persist speculative tombstones before that validation exists.
- Upsert reaction state only when sender and receiver are active at the event timestamp and the root post exists locally.
- Out-of-order reactions are staged in memory until the root post arrives, then retried against the same membership rules.
- Live reaction ingest additionally requires sender and receiver to be active in the latest local membership snapshot.

### Notifications

- Notifications are APNs remote notifications backed by a linkstr-operated push service.
- Current notification types are:
  - Inbound root posts.
  - Inbound active emoji reactions.
- Archived conversations do not notify.
- Reaction deactivations do not trigger notifications.
- Self-echoed events do not trigger notifications.
- Historical relay restore/backfill does not trigger catch-up notifications.
- Foreground presentation remains enabled (`banner`, `list`, `sound`).
- Push alerts use generic text; encrypted session content is still fetched and decrypted on-device.

### Media and link behavior

- URL classification drives playback mode (extraction/embed/link fallback).
- Canonicalization handles mobile host variants (for example `m.facebook.com`).

#### Extraction vs. embed

- Extraction downloads the video file locally for native playback.
  - Local playback uses the system video player with full controls.
  - Extracted media can be saved to photos or files.
  - Works offline once cached.
  - Downloaded video cache auto-trims with a least-recently-used policy once device-local video cache exceeds about 1 GB.
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
- Media playback surfaces temporarily acquire an `AVAudioSession` playback category while onscreen, so audio still plays when the iphone silent switch is enabled.
- In local playback mode with a locally cached media file, users can export via `save...`:
  - `save to photos` (requests photos add-only permission).
  - `save to files` (document export flow, no broad media permission).
- If extraction fails, embed mode remains available and offers retry-local plus Safari open actions.
- Canonical TikTok post URLs prefer exact `aweme_id` API playback candidates and avoid page-sniff fallback when exact extraction fails, to reduce accidental related-video matches.
- Twitter/X status handling is resolved at runtime:
  - Video statuses use extraction-preferred playback.
  - Non-video statuses use the official X widgets render path, gated by `publish.twitter.com/oembed` availability.
  - Embedded tweet taps that navigate away from the widget open externally instead of silently dying inside `WKWebView`.
  - If official tweet embed resolution fails, the fallback is a regular browser link.

#### Embed URL patterns

- Embed URLs prefer provider-native patterns where available:
  - TikTok `embed/v2`.
  - Instagram `/embed`.
  - Facebook plugin `/plugins/video.php`.
  - YouTube `/embed`.
  - Rumble oEmbed iframe URL.
- Twitter/X embeds use the official X widget factory (`widgets.js` / `createTweet`) instead of rendering the raw oEmbed fragment directly.
- Facebook videos/reels use Facebook plugin embed URLs (`/plugins/video.php`) with canonicalized `href` targets.
- Rumble embeds are resolved from provider oEmbed iframe URLs when available.
- Embedded web playback allows provider element fullscreen when supported by the provider and iframe context.

#### Media actions and metadata

- Media actions are normalized:
  - One action button uses full width.
  - Two action buttons split width evenly with spacing.
- Metadata hydration fetches title/thumbnail asynchronously for root posts.
- X/Twitter status previews prefer the Twitter-specific status metadata path for author/title and media thumbnails before falling back to generic `LinkPresentation` metadata.
- Opening a session lazily retries missing metadata for posts as they scroll into view, and opening post detail retries that post directly when titles are missing, local thumbnail files are missing, or expected provider thumbnails are absent.
- Missing local thumbnail files are treated as stale and re-fetched.
- Settings > Storage can clear hydrated previews and cached media for the current account without deleting posts.
- Settings > Storage shows an estimate of how much local storage the signed-in account can clear.

### Contacts

- Contacts mirror the account's nostr follow list (`kind:3`, NIP-02).
- Add/remove contact actions publish a full replacement follow-list event and wait for relay acceptance.
- Incoming follow-list events from the signed-in author reconcile local contacts (newer timestamp wins; equal timestamp uses lexicographic event-ID tie-break).
- Follow-list recency watermarks are persisted per account so app restart does not allow stale follow-list rollback.
- Aliases are private per-account device data and are never published to relays.
- Remote nostr profile names are fetched lazily by pubkey and are used only when no local alias exists.
- When both exist, contact UI shows the local alias as primary and the published nostr name as secondary.
- Contact management supports add, long-press remove contact, and alias edit.
- Add-contact sheet uses grouped sections for key entry, identity preview, and alias entry, plus a bottom action footer.
- Add-contact input supports manual entry, paste, and qr scan.
- Add-contact input previews the resolved identity for a valid public key (`npub`) and lazily looks up the published nostr name.
- Public-key helper controls render directly below the field in the same compact control row pattern used by post compose.
- `add contact` stays disabled until the public key normalizes to a valid `npub`.
- Re-adding the same contact updates the saved alias for that contact; it does not create a duplicate or republish the follow list.

### You tab

- The you tab exposes the current account public key (`npub`).
- The you tab lets the user publish, update, or clear an optional nostr profile name.
- Submitting the profile name with the keyboard `return` key or the save button applies the change and dismisses the keyboard.
- The you tab provides:
  - qr code.
  - current profile name above the qr code when one is set.
  - a short scan hint below the qr code.
  - raw key text.
  - copy action.

### Deep links

- Deep link format is `linkstr://open?p=...`.
- Valid deep links open a full-screen playback surface.
- Post detail can share the current post as a deep link through the native iOS share sheet.
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
- Cached video files live under `Library/Caches` and are treated as disposable device cache.
- The app enforces a least-recently-used video cache cap of about 1 GB for downloaded local playback media.
- Settings > Storage actions can purge cached media plus hydrated preview titles/thumbnails for the signed-in account and let previews rebuild lazily.
- Local entities are owner-scoped by pubkey.
- Account scoping is enforced in storage and query paths to prevent cross-account bleed.
- `log out (keep local data)` preserves persisted local entities so the same account can log back in later.
- `log out and clear local data` removes the signed-in account's persisted entities and cached media references.
- If account-scoped local cleanup cannot fully complete, the app surfaces an error instead of reporting a clean success.
- Sensitive content fields are encrypted at rest with per-owner local keys (aliases, session/member identity values, URLs/notes, metadata, and creator keys).
- Operational identifiers and timestamps remain plaintext in local storage for indexing/querying.
- Identity keys remain in keychain.
- Keychain accessibility uses `WhenUnlocked` and prefers synchronizable items when available.
- Simulator fallback key storage is used when simulator keychain is unavailable.

### Backup and migration expectations

- Identity continuity across devices depends on keychain/iCloud keychain backup conditions.
- SwiftData participates in ios backup/restore according to device backup mode.
- If encrypted local data restores without matching key material, encrypted fields are unreadable.
- Reliable long-term portability still depends on preserving the secret key (`nsec`).
- A nostr vanish/delete request is relay-side only; the key itself remains usable until you discard it.

### Known non-goals

- No offline guaranteed delivery queue.
- No automatic resend of previously failed posts.
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

### Run iOS tests

```bash
xcodebuild -project Linkstr.xcodeproj -scheme Linkstr -showdestinations
xcodebuild test -project Linkstr.xcodeproj -scheme Linkstr -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'
```

- Use `-showdestinations` first, then swap in a locally available simulator ID.

### Run push-service tests

```bash
cd push-service
go test ./...
```

## Copyright

Copyright © 2026 ParmScript.
