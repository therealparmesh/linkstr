# linkstr

_Last updated: June 21, 2026_

linkstr is an iOS app for private link sharing on [Nostr](https://nostr.com). You create private sessions, share links with people you trust, react with emojis, and play supported video directly inside the app when a provider allows it.

This repo contains the iOS app and the small Go push service used for APNs routing.

## Documentation map

| Document                                               | Description                                      |
| ------------------------------------------------------ | ------------------------------------------------ |
| [docs/SUPPORT.md](docs/SUPPORT.md)                     | Product support and user-facing behavior         |
| [docs/PRIVACY.md](docs/PRIVACY.md)                     | Privacy details                                  |
| [docs/APP_STORE_CONNECT.md](docs/APP_STORE_CONNECT.md) | App Store Connect checklist                      |
| [push-service/README.md](push-service/README.md)       | Push-service setup, operations, and request auth |
| [docs/future/](docs/future/)                           | Future proposals (not yet shipped)               |

---

## How linkstr syncs

linkstr is built around private sessions, not one-off direct messages. A session has a creator, a name, a current member list, and a feed of link posts. Reactions and deletes hang off those root posts.

**Membership is snapshot-based.** When the session creator adds or removes people, linkstr publishes the full member list as it exists at that moment — not a delta. The latest valid snapshot is the source of truth for who can see future posts and reactions. Adding someone later does not retroactively share older posts with them. Removing someone stops future delivery but cannot claw back content they already received while they were a valid member.

**Ordering is not guaranteed.** Relays do not guarantee delivery order. A post can arrive before the session snapshot that makes it valid, and a reaction can arrive before its root post. linkstr handles this by staging valid-but-early events in memory, retrying them when the missing dependency shows up, and letting late relay connections widen historical backfill coverage when more history is still needed.

**Deletes are strict.** A delete notice does not become authoritative until linkstr can match it to the original root post and verify that the delete sender is the same account that authored that root. This prevents bad delete notices from silently wiping out posts or reactions just because they arrived first.

**Deduplication is automatic.** Duplicate relay delivery is normal, especially across reconnects and backfill. linkstr deduplicates by event ID, and when the same root arrives through multiple gift-wrap transport events it merges those wrapper IDs into the same stored post instead of creating duplicates. This keeps the UI clean while preserving the transport IDs needed for relay-side delete requests later.

**No offline outbox exists.** If a send cannot get relay acceptance, the app leaves the composer open and shows an error instead of pretending the post was sent.

---

## Product behavior reference

### Product model

- The app is session-first, not DM-first.
- A **session** is a private container with a name, a member set, and a feed of root posts.
- A **post** is a link item inside a session with a required URL, an optional note, optional metadata hydration (title and thumbnail), and emoji reactions.
- Text replies are not part of the current product.
- App data is transported as private Nostr gift-wrap DMs using app payload kind `44001`.

### Startup and boot

- On launch, the app enters a blocking boot flow with visible status text that progresses through:
  - `loading account…`
  - `preparing local data…`
  - `connecting relays…`
  - `starting session…`
- Boot loads identity from the keychain and registers for remote notifications when allowed.
- Boot briefly retries identity load before falling back to onboarding, to tolerate transient keychain or protected-data unavailability at launch.
- Boot uses the shipped default relay set when no relay configuration is persisted.
- Boot starts the relay runtime once identity is available.
- Foreground re-entry and protected-data availability events retry identity load when no account is currently active in memory.
- If persistent local storage cannot be opened, the app shows a recovery screen instead of crashing. Recovery allows retrying startup or continuing in a temporary in-memory mode for that launch only.
- If no identity exists, onboarding is shown. If identity exists, the main app shell is shown.

**Visual design:**

- The app uses a Tokyo Night color scheme across all surfaces.
- The main app shell uses native iOS tab and navigation bars with visible frosted chrome over the Tokyo Night background.
- Primary screens use inset-grouped surfaces, full-width list rows, and messenger-style spacing inspired by Telegram.
- Text sizing is controlled by centralized theme tokens with a slightly larger baseline for chat readability.

### Identity and account lifecycle

- Users can create a new account or import an existing secret key (`nsec`).
- Onboarding presents sign-in and account creation as separate grouped sections rather than a single stacked neon form.
- New account creation pauses on a backup step that reveals the generated `nsec`, offers copy, and explains that it functions as the account password for future sign-in.
- New account creation can optionally set a profile name visible to others before leaving onboarding.
- The active identity is keychain-backed.
- The You tab exposes a profile card, QR code, current public key (`npub`), and editing for the account's published Nostr profile name.
- Settings uses always-visible grouped sections for relays, storage, and identity.
- Settings storage controls can clear downloaded videos separately from saved link metadata and thumbnails.
- The `nsec` is hidden by default and only revealed on explicit action. The revealed value is cleared again when the settings identity view disappears or the app moves to the inactive or background state.

**Account removal:**

| Action                       | Clears identity | Clears local data | Publishes to relays |
| ---------------------------- | :-------------: | :---------------: | :-----------------: |
| Log out (keep local data)    |        ✓        |         —         |          —          |
| Log out and clear local data |        ✓        |         ✓         |          —          |
| Delete account               |        ✓        |         ✓         |          ✓          |

- "Log out and clear local data" and "Delete account" both remove account-scoped local data: contacts, sessions, session members, membership intervals, posts, session deletion tombstones, reactions, cached media references, and local encryption key material for that owner scope.
- "Delete account" includes a two-step destructive confirmation flow. When relays are available, it also publishes an empty follow list (`kind:3`) and a Nostr request-to-vanish (`kind:62`) to enabled relays.
- "Delete account" does not invalidate the `nsec`; the key remains usable for sign-in later.
- "Delete account" is send-gated like other relay-backed mutations and does not proceed while relay confirmation is unavailable.

### Sessions

- The session list is the top-level surface.
- Sessions are local, account-scoped entities with a session ID, name, creator pubkey, updated timestamp, and archive flag.
- Users create sessions from the compose action in the top-right corner of the sessions tab.
- The session list includes inline search and uses full-width chat-list rows with solid-color avatars, timestamps, and unread markers.

**Session creation:**

- Uses grouped sections for session details and member selection.
- Exposes a top-right create icon while the sheet is open; the icon stays disabled (with disabled styling) until the name is non-empty.
- The bottom footer is used only for status and validation messaging — it does not duplicate the action button.
- The keyboard return key advances from the session name into member search, or submits immediately when no contacts exist.
- A non-empty name is required. Member selection is optional — sessions can be solo (creator only).
- After successful creation, the app navigates directly into the new session.

**Membership snapshots:**

- Transport always includes the creator in the effective member set.
- The active member set becomes exactly the snapshot. Missing previous members become inactive.
- Newly added members are eligible only for content sent while they are active.
- Removed members stop receiving future content but may retain anything they already received.
- Update fanout targets both prior-active and next-active members so removed members receive the removal snapshot.
- Outbound snapshots include the session name so newly added members can materialize the session from the snapshot alone and existing members can apply renames.
- Snapshot application is monotonic by `created_at`; older snapshots are ignored. Equal-timestamp conflicts resolve by lexicographic event-ID tiebreak.

**Archive:**

- Sessions can be archived or unarchived from the session members/manage sheet.
- The session list shows active sessions by default. When archived sessions exist, a header archive toggle icon appears to the left of the compose action.
- Tapping the archive icon switches between active and archived list mode; the filled icon state indicates archive mode.
- Switching away from the sessions tab resets the list mode back to active. Archive is non-destructive.

**Delete:**

- The session creator can delete a session from the manage session sheet.
- Delete requires confirmation and dismisses back to the session list when the session disappears.
- Delete removes the session from both active and archived views on this device and prevents later relay backfill from recreating it.
- Delete sends an encrypted `session_delete` notice to known members.
- When relay-visible wrapper IDs are available, linkstr also makes a best-effort relay-side delete request. Missing relay-side deletion does not roll back the local delete.

### Session members UX

- Session member management is available inside a session.
- The session members button opens the same sheet for everyone. Creators manage the session there; non-creators see the session name read-only and can review current members.
- Session detail uses chat-like link cards with grouped consecutive posts and inline membership timeline markers.
- Members can be added only from existing contacts. Members can be removed from active membership.
- Only the session creator can rename, delete, or change session membership. Non-creator membership and delete mutations are ignored on ingest.
- Session detail inserts centered `in:` / `out:` separators for membership changes observed after the first local membership snapshot.
- If the signed-in user is removed, the session stays visible as local history but becomes read-only for new posts and reactions.
- Member identity resolves as: local alias → remote Nostr profile name → `npub`.
- Outbound membership snapshots always include the local sender key.
- Outbound membership snapshots always include the current session name so other members can apply renames.
- Inbound membership snapshots from the session creator update the local session name when the snapshot carries a newer name.

### Posts (root links)

- Posting is session-scoped.

**Composer:**

- Uses grouped sections for session, link, and note.
- Exposes a top-right send icon while the sheet is open.
- The bottom footer is used only for status and validation messaging — it does not duplicate the action button.
- The keyboard return key advances from the link field into the note field.
- Fields: session name (read-only), link (required), note (optional).
- The link field supports paste and clear helpers rendered directly below the field in a compact control row. Paste replaces the entire field value.
- Links without a scheme are normalized to `https://`. URL input must be a valid `http` or `https` URL; unsupported schemes are rejected.
- Recognized media links surface an inline hint when in-app playback is available.
- Note text is trimmed and persisted only when non-empty.

**Post detail:**

- The raw link text supports the standard iOS copy menu via text selection.
- The top-right share action exports a `linkstr://open?url=…` deep link for the current post URL.
- Note text is rendered as an accented note callout for visual separation. Media and metadata sit inside grouped detail surfaces.
- Browser handoff uses the "open in browser" action.

**Send behavior:**

- The composer remains on-screen while waiting to send.
- Send waits for a usable relay path with a default timeout of 12 seconds.
- On success, the post persists locally and the composer dismisses. On failure or timeout, the composer stays open and the error is shown.
- Posting is blocked when the sender is not an active member of the target session.
- Recipient resolution uses only active session members.

**Identity, deduplication, and deletion:**

- Root post identity is the Nostr event ID. Inbound root payloads with a non-empty `root_id` that does not match the event ID are ignored.
- Outgoing root posts persist the relay-visible gift-wrap event IDs that carried the payload.
- Session post lists show sender headers above post cards and collapse repeated headers for consecutive posts from the same sender.
- Post delete is available via long-press on posts sent by the signed-in user.
- Delete publishes a Nostr deletion request (`kind:5`) against the stored gift-wrap event IDs when available, and also sends a linkstr delete notice to known members so encrypted session feeds converge on the removal.
- Older locally stored root posts without recorded gift-wrap IDs skip relay-side `kind:5` publication and still use the linkstr delete notice plus local tombstoning.
- Validated post deletes persist a local deletion watermark so historical backfill cannot resurrect a previously deleted root post.

### Reactions

- Reactions are emoji-only toggles tied to a post.
- Reaction send is blocked when the sender is not an active member of the target session.
- Default quick options: 👍, 👎, 👀. A `…` button opens the full emoji picker sheet.
- Session post lists show compact read-only reaction summaries with no interactive controls; single reactions show emoji-only, and higher counts use bottom-right badges. Read-only count badges cap visually at `10+`.
- Post detail uses interactive reaction chips with the current user's selections highlighted and shows per-participant breakdown rows below a divider.

**State and ordering:**

- Reaction state is keyed by session ID, post/root ID, emoji, and sender pubkey.
- Transport carries reaction active/inactive state.
- Reactions received before their root post are staged in memory and retried once the root arrives.
- Reactions targeting a root already tombstoned by a validated delete watermark are discarded.
- A validated root delete also clears any staged reactions still waiting on that root. Mismatched or unvalidated delete notices do not clear staged reactions.
- Equal-timestamp reaction conflicts resolve by lexicographic event-ID tiebreak.
- Reactions tied to a deleted post are removed with that post.

### Read/unread semantics

- Session rows show unread indicators when any inbound root post in that session is unread.
- Post cards inside a session show unread indicators when that root post is unread inbound.
- Initial relay history restore into an empty local store treats replayed inbound posts as already read.
- Opening a session marks visible inbound root posts as read. Opening post detail also marks that post as read.
- Reactions do not affect unread counters.

### Relay settings and runtime

- Relay management lives in settings.
- Users can add a relay URL (`ws://` or `wss://`, valid host required), enable or disable a relay, remove a relay, or reset back to the current shipped default relays.
- The relay header shows `connected_or_readonly / total`.
- Relay, storage, and identity controls remain visible without disclosure-group expansion.
- Relay rows show a live status dot (`connecting`, `connected`, `read-only`, `failed`, `disabled`) and optional inline error text. Error rows reserve layout height to avoid jitter when status text appears or disappears.
- Offline relay toast signaling is suppressed during initial connection and only shown after a previously healthy relay drops in the same foreground lifecycle.

### Relay send gating

- Relay runtime starts when identity exists and the app is active.
- Leaving the foreground stops relay runtime so suspended sockets do not linger into the next reopen cycle.
- When relay runtime stops or restarts, enabled relays are reset to a `disconnected` baseline so the next start does not inherit stale UI state.
- Foreground re-entry rebuilds relay runtime from scratch once, like a cold reopen.
- Send gating blocks immediately when there are no enabled relays or only read-only relays are available; otherwise it waits for a connection until timeout.
- No offline outbox exists. Failed sends are not queued for automatic retry.

### Relay delivery and ingest

linkstr payloads are JSON-encoded and delivered through Nostr gift-wrap direct messages. Outgoing publish waits for relay `OK` acceptance with a timeout, and fanout only counts as successful once every published gift-wrap has at least one accepted relay path.

**Accepted payload kinds:**

- `session_create`
- `session_members`
- `session_delete`
- `root`
- `root_delete`
- `reaction`

**Ingest rules:**

- Ignore anything that cannot be decoded or validated. Deduplicate by event ID.
- Duplicate gift-wraps for the same root merge transport IDs into the existing stored post instead of creating duplicates.
- `session_create` requires both sender and receiver in the member set. For an existing session it is accepted only from the stored creator.
- `session_members` is accepted only from the stored creator. It can bootstrap a missing session when the snapshot includes sender, receiver, and a non-empty session name.
- Root posts and reactions are persisted only when sender and receiver are active at the event timestamp. Out-of-order events are staged in memory until the missing dependency arrives.
- Delete notices are applied only when the delete sender matches the original root sender.
- Late relay connections widen backfill coverage and retry staged events without tearing down the app-level relay lifecycle.
- Live relay subscriptions use `since` filters that account for the gift-wrap timestamp obfuscation window so recently published events are not filtered out.

### Notifications

- Notifications are APNs remote notifications backed by a linkstr-operated push service.
- Current notification types: inbound root posts and inbound active emoji reactions.
- Archived conversations do not notify.
- Reaction deactivations, self-echoed events, and historical relay restore/backfill do not trigger notifications.
- Foreground presentation remains enabled (banner, list, sound).
- Tapping a notification navigates to the relevant session.
- Push alerts use generic text; encrypted session content is fetched and decrypted on-device.

### Media and link behavior

URL classification drives playback mode: extraction, embed, or link fallback. Mobile host variants (e.g. `m.facebook.com`) are canonicalized automatically.

#### Playback modes

**Extraction** downloads the video file locally for native playback:

- System video player with full controls.
- Extracted media can be saved to Photos or Files.
- Works offline once cached.
- Video cache auto-trims at approximately 1 GB with least-recently-used eviction.

**Embed** loads the provider's web player in an inline web view:

- Requires network connectivity.
- Subject to provider playback restrictions.
- Fullscreen depends on provider iframe support.

#### Provider support

**Extraction-preferred** (local playback attempted first, embed fallback available):

- TikTok videos
- Instagram Reels
- Facebook Reels
- Twitter/X statuses — only when provider metadata confirms video media is present

**Embed-only** (web player only, no extraction):

- YouTube
- Rumble
- Instagram non-Reel posts (`/p/`, `/tv/`)
- Facebook non-Reel videos (`/videos/`)

Non-video provider URLs (channel pages, profiles, etc.) fall back to open-in-browser.

#### Playback behavior

- For extraction-preferred providers, local playback is attempted first with explicit controls to switch to embed mode.
- If a local playback stream fails, the next available stream is tried automatically before falling back to embed mode.
- If extraction fails, embed mode remains available with retry-local and open-in-browser actions.
- Action rows are normalized across post detail and shared-link detail surfaces.
- Audio plays even when the iPhone silent switch is enabled.
- In local playback mode with a cached file, users can export via **Save…** to Photos or Files.

**Twitter/X statuses** are resolved at runtime:

- Video statuses use extraction-preferred playback.
- Non-video statuses use official tweet embeds when available, falling back to open-in-browser.
- Embedded tweet taps that navigate away from the widget open externally.

#### Embed URLs

| Provider  | Pattern                                                   |
| --------- | --------------------------------------------------------- |
| TikTok    | Desktop website (`/@_/video/<id>`)                        |
| Instagram | Desktop website (`/reel/<shortcode>/`, `/p/<shortcode>/`) |
| Facebook  | `/plugins/video.php`                                      |
| YouTube   | `/embed`                                                  |
| Rumble    | oEmbed iframe URL                                         |
| Twitter/X | Official widget factory (`widgets.js` / `createTweet`)    |

Embedded web playback allows provider-element fullscreen when supported.

#### Metadata

- Title and thumbnail are fetched asynchronously for root posts.
- Twitter/X, Instagram, TikTok, Facebook, and Rumble use provider-specific metadata paths before falling back to generic `LinkPresentation`.
- Missing metadata is retried lazily when posts scroll into view or when post detail is opened.
- Post detail also exposes a refresh action that forces metadata to re-fetch for that post.
- Missing local thumbnail files are treated as stale and re-fetched.
- Settings → Storage can clear downloaded videos separately from hydrated metadata and thumbnails.

### Contacts

- Contacts mirror the account's Nostr follow list (`kind:3`, NIP-02).
- Add and remove actions publish a full replacement follow-list event and wait for relay acceptance.
- Incoming follow-list events from the signed-in author reconcile local contacts (newer timestamp wins; equal timestamp uses lexicographic event-ID tiebreak).
- Follow-list recency watermarks are persisted per account so an app restart does not allow stale follow-list rollback.
- Aliases are private per-account, per-device data and are never published to relays.
- Remote Nostr profile names are fetched lazily by pubkey and used only when no local alias exists. When both exist, contact UI shows the local alias as primary and the published Nostr name as secondary.

**Add-contact sheet:**

- Uses grouped sections for key entry, identity preview, and alias entry.
- Exposes a top-right add icon while the sheet is open; the icon stays disabled until the public key normalizes to a valid `npub`.
- The bottom footer is used only for status and validation messaging — it does not duplicate the action button.
- The keyboard return key advances from the public key field into alias, and submits from alias.
- Input supports manual entry, paste, and QR scan.
- A valid `npub` triggers an identity preview that lazily looks up the published Nostr name.
- Public-key helper controls render directly below the field in the same compact control row pattern used by the post composer.
- Re-adding the same contact updates the saved alias; it does not create a duplicate or republish the follow list.

**Contact management** supports add, long-press remove, and alias edit.

### You tab

- Exposes the current account `npub`.
- Lets the user publish, update, or clear an optional Nostr profile name. Submitting with the keyboard return key or the save button applies the change and dismisses the keyboard.
- Provides a QR code with the current profile name above it (when set), a short scan hint below it, raw key text, and a copy action.

### Deep links

- Shared-link detail format: `linkstr://open?url=…`
- Share composer format: `linkstr://share?url=…&note=…`
- Media download format: `linkstr://download?url=…`
- Valid deep links open a full-screen shared-link detail, share composer, or media-download surface.
- Post detail can share the current post as a deep link through the native iOS share sheet.
- The iOS share extension accepts web URLs, webpages, or text containing a web link, then offers `share link` or `download media`.
- `share link` opens a full-screen share composer with the link prefilled, any surrounding text as the optional note, and a separate searchable active-session picker.
- `download media` opens linkstr to cache downloadable media for valid links. Shares without a valid web link close without an error.
- Shared deep links carry only the normalized web URL; title, thumbnail, and provider-specific preview text are fetched when the recipient opens the link.
- Shared-link detail reuses the same adaptive local/embed controls as post detail when the URL supports in-app playback.
- Dismissing shared-link detail, the share composer, or the media-download surface clears pending deep-link state.

### Local data and security

**Persisted local data:**

- Relay configuration and enabled state when persisted.
- Contacts and private aliases.
- Sessions, member snapshots, membership intervals, session deletion tombstones, root posts, post deletion watermarks, reactions, read state, and archive state.
- Cached media references, downloaded videos, and metadata hydration state.
- Account-scoped app state (follow-list recency watermark).

**Storage and caching:**

- SwiftData persistence is local-first and survives app relaunch.
- Cached video files live under `Library/Caches` and are treated as disposable device cache with LRU eviction at approximately 1 GB.
- Settings → Storage can purge downloaded videos or clear hydrated metadata and thumbnails across all local accounts retained on the device.

**Scoping and encryption:**

- Local entities are owner-scoped by pubkey. Account scoping is enforced in storage and query paths to prevent cross-account bleed.
- "Log out (keep local data)" preserves persisted entities so the same account can log back in later.
- "Log out and clear local data" removes the signed-in account's persisted entities, managed thumbnails, cached videos, and cache references.
- If account-scoped local cleanup cannot fully complete, the app surfaces an error instead of reporting a clean success.
- Sensitive content fields are encrypted at rest with per-owner local keys (aliases, session and member identity values, URLs, notes, metadata, and creator keys).
- Operational identifiers and timestamps remain plaintext in local storage for indexing and querying.
- Identity keys remain in the keychain. Keychain accessibility uses `WhenUnlocked` and prefers synchronizable items when available.
- Simulator fallback key storage is used when the simulator keychain is unavailable.

### Backup and migration expectations

- Identity continuity across devices depends on keychain and iCloud Keychain backup conditions.
- SwiftData participates in iOS backup and restore according to the device's backup mode.
- If encrypted local data restores without matching key material, encrypted fields are unreadable.
- Reliable long-term portability depends on preserving the `nsec`.
- A Nostr vanish or delete request is relay-side only; the key itself remains usable until you discard it.

### Known non-goals

- No offline guaranteed-delivery queue.
- No automatic resend of previously failed posts.
- No public discovery feed or social graph product surface.
- No text-based post replies.

---

## Future

Future proposals are tracked as separate docs and are not part of the current shipped behavior. Proposal docs are directional and high-level and can change before implementation.

- [Leave session](docs/future/leave-session.md)

---

## Development

### Generate the Xcode project

The `.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). Run this after pulling or changing `project.yml`:

```bash
./scripts/gen.sh
```

### Open in Xcode

```bash
open linkstr.xcodeproj
```

### Run all tests

```bash
./scripts/test.sh
```

This runs both the iOS unit tests (via `xcodebuild`) and the push-service Go tests in one pass.

### Lint

```bash
./scripts/lint.sh
```

Runs [SwiftLint](https://github.com/realm/SwiftLint) across all Swift sources.

### Run iOS tests only

```bash
xcodebuild test \
  -project linkstr.xcodeproj \
  -scheme linkstr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet
```

### Run push-service tests only

```bash
cd push-service && go test -v ./...
```

---

## Copyright

Copyright © 2026 ParmScript.
