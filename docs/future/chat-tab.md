# Future Proposal: Chat Tab

Status: Proposal only. Not implemented.

## Summary

A dedicated "chat" tab providing a typical 1:1 Nostr direct messaging experience alongside the existing link-sharing sessions. Sessions are curated, feed-style, link-first. Chat is ephemeral, conversational, text-first.

---

## Goals

- 1:1 free-text messaging between contacts.
- Familiar chat UX (bubble layout, composer bar, conversation list).
- NIP-17 compliant for interoperability with other Nostr clients.
- Reactions, replies, and link previews as first-class features.
- Reuse existing relay, encryption, identity, and push infrastructure.

## Non-goals

- Group chat (defer to sessions for multi-party communication).
- Voice/video calling.
- Replacing sessions — chat and sessions coexist as distinct tabs.

---

## Tab placement

Add `chat` between `sessions` and `contacts` in `MainTabView.AppTab`:

```
sessions | chat | contacts | you | settings
```

Icon: `bubble.left.and.text.bubble.right.fill`

---

## Protocol layer

### Transport

Reuse the existing NIP-59 gift-wrap pipeline (`NostrDMService`). Chat messages travel inside gift wraps identically to linkstr payloads today.

### Rumor kind

Use **standard NIP-17 kind 14** for the inner rumor (not linkstr's custom kind 44001). This enables interoperability — messages sent from linkstr will appear in Damus, Amethyst, Primal, etc.

```
Gift Wrap (kind 1059)
  └─ Seal (kind 13)
       └─ Rumor (kind 14)  ← NIP-17 direct message
            content: "hey, check this relay"
            tags: [["p", <recipient_pubkey>]]
```

### Dual-subscription model

`NostrDMService.handleIncomingEvent` currently filters for `linkstrRumorKind` (44001). Extend this to branch:

```swift
guard let rumor = try? wrapped.unsealedRumor(using: keypair.privateKey) else { return }

switch rumor.kind {
case linkstrRumorKind:
    // existing linkstr payload path
    handleLinkstrPayload(rumor, wrapped: wrapped, subscriptionId: subscriptionId)
case .directMessage:  // kind 14
    // new chat path
    onChatMessage?(parseChatMessage(rumor, wrapped: wrapped, subscriptionId: subscriptionId))
default:
    return
}
```

No new relay subscriptions needed — kind-14 rumors arrive inside the same kind-1059 gift wraps we already subscribe to.

---

## Data model

### `ChatMessageEntity`

```swift
@Model
final class ChatMessageEntity {
    @Attribute(.unique) var storageID: String
    #Index<ChatMessageEntity>(
        [\.ownerPubkey, \.counterpartyPubkeyHash, \.timestamp],
        [\.ownerPubkey, \.conversationKey, \.timestamp]
    )

    var eventID: String
    var ownerPubkey: String
    var conversationKey: String           // deterministic: sorted(myPubkey, theirPubkey) hash
    var counterpartyPubkeyHash: String
    var encryptedCounterpartyPubkey: String
    var encryptedContent: String
    var timestamp: Date
    var isOutgoing: Bool
    var readAt: Date?
    var deliveryStateRaw: String          // "pending" | "sent" | "failed"
    var replyToEventID: String?           // if this is a reply
    var encryptedReplyPreview: String?    // cached snippet of the replied-to message
    var publishedTransportEventIDsStorage: String?
}
```

### `ChatConversationEntity`

```swift
@Model
final class ChatConversationEntity {
    @Attribute(.unique) var storageID: String
    #Index<ChatConversationEntity>([\.ownerPubkey, \.lastMessageTimestamp])

    var ownerPubkey: String
    var conversationKey: String
    var counterpartyPubkeyHash: String
    var encryptedCounterpartyPubkey: String
    var lastMessageTimestamp: Date
    var unreadCount: Int
    var isPinned: Bool
    var isMuted: Bool
}
```

### `ChatReactionEntity`

```swift
@Model
final class ChatReactionEntity {
    @Attribute(.unique) var storageID: String

    var ownerPubkey: String
    var targetEventID: String             // the message being reacted to
    var senderPubkeyHash: String
    var encryptedSenderPubkey: String
    var emoji: String
    var timestamp: Date
}
```

### Conversation key derivation

Deterministic, direction-agnostic:

```swift
static func conversationKey(pubkeyA: String, pubkeyB: String) -> String {
    let sorted = [pubkeyA, pubkeyB].sorted()
    return LocalDataCrypto.shared.digestHex(sorted.joined())
}
```

---

## Service layer

### `ChatMessageStore`

Analogous to `SessionMessageStore`. Responsibilities:

- Insert/upsert incoming and outgoing `ChatMessageEntity`.
- Maintain `ChatConversationEntity` (update lastMessageTimestamp, unreadCount).
- Paginated fetch for message history (oldest-first for scroll-to-bottom).
- Mark conversation read.
- Reaction insert/toggle.

### `AppSession+Chat` extension

- `sendChatMessage(content:to:replyTo:)` — builds kind-14 rumor, gift-wraps, publishes.
- `sendChatReaction(emoji:to:)` — sends reaction payload inside gift wrap.
- `markChatConversationRead(_:)` — zeroes unread count, sets `readAt` on messages.
- `deleteChatMessage(_:)` — local deletion + optional NIP-09 relay deletion request.

### Publishing a chat message

```swift
func sendChatMessage(content: String, to recipientPubkey: String, replyTo: String? = nil) async throws -> String {
    guard let keypair = identityService.keypair else { throw NostrServiceError.missingIdentity }
    guard nostrDMService.relayPool != nil else { throw NostrServiceError.relayUnavailable }

    // Build kind-14 rumor
    let rumor = try buildKind14Rumor(
        content: content,
        recipientPubkey: recipientPubkey,
        replyToEventID: replyTo,
        signedBy: keypair
    )

    // Gift wrap to recipient + self-copy
    let wraps = try buildGiftWraps(rumor: rumor, recipients: [recipientPubkey, keypair.publicKey.hex])
    let publishedIDs = try await nostrDMService.publishEventsAwaitingRelayAcceptance(wraps)

    // Persist locally
    try chatMessageStore.insertOutgoing(
        eventID: rumor.id,
        content: content,
        recipientPubkey: recipientPubkey,
        replyToEventID: replyTo,
        publishedTransportEventIDs: publishedIDs
    )

    return rumor.id
}
```

---

## UI architecture

### File structure

```
Features/
  Chat/
    ChatListView.swift              — conversation list (tab content)
    ChatDetailView.swift            — message thread
    ChatComposerBar.swift           — text input + send
    ChatBubbleView.swift            — single message bubble
    ChatMessageRow.swift            — bubble + metadata + reactions
    ChatConversationRow.swift       — row in ChatListView
    ChatDateSeparator.swift         — "Today", "Yesterday", etc.
    ChatReactionOverlay.swift       — long-press reaction picker
    NewChatSheet.swift              — recipient picker
```

### ChatListView (conversation list)

```
┌─────────────────────────────────────────┐
│  chat                             ✏️    │  screen title + new chat button
├─────────────────────────────────────────┤
│  🔍 search chats                        │
├─────────────────────────────────────────┤
│  ┌──┐  alice                      2m   │
│  │  │  hey did you see that ar...       │  latest message preview
│  └──┘                              ●    │  unread dot
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│  ┌──┐  bob                        1h   │
│  │  │  sounds good 👍                   │
│  └──┘                                   │
├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤
│  ┌──┐  carol                      3d   │
│  │  │  You: check this relay ou...      │  "You:" prefix for outgoing
│  └──┘                                   │
└─────────────────────────────────────────┘
```

- Mirrors `ConversationsView` layout conventions (avatar, title, timestamp, preview, unread indicator).
- Swipe leading: pin. Swipe trailing: mute, delete.
- Search filters by contact display name and message content.
- Empty state: "no chats yet — message a contact to start."

### ChatDetailView (message thread)

```
┌─────────────────────────────────────────┐
│  ←  alice                          ⓘ   │  nav bar (back, name, info)
├─────────────────────────────────────────┤
│                                         │
│         ┌───────────────────┐           │
│         │ hey! what relay   │   10:02   │  incoming (left, panel bg)
│         │ do you use?       │           │
│         └───────────────────┘           │
│          😂                             │  reaction below bubble
│                                         │
│    ┌────────────────────────┐           │
│    │ wss://relay.damus.io   │   10:03 ✓ │  outgoing (right, accent bg)
│    │ mostly                 │           │
│    └────────────────────────┘           │
│                                         │
│          ── Today ──                    │  date separator
│                                         │
│         ┌───────────────────┐           │
│         │ nice, thx!        │   14:20   │
│         └───────────────────┘           │
│                                         │
│  ┌─ reply preview ─────────────────┐    │
│  │  ↩ "what relay do you use?"     │    │
│  ├─────────────────────────────────┤    │
│  │ [ message...          ]  [▲]    │    │  composer bar
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

**Bubble design:**

- Outgoing: `LinkstrTheme.accent` background, white text, right-aligned.
- Incoming: `LinkstrTheme.panel` background, `textPrimary`, left-aligned.
- Corner radius: 16pt, with tail on sender side.
- Timestamps: shown for messages with > 5 min gap from prior message.

**Scroll behavior:**

- `ScrollViewReader` anchored to newest message on open.
- Pull up to load older messages (paginated from `ChatMessageStore`).
- "Jump to bottom" FAB when scrolled up and new messages arrive.

**Delivery indicators:**

- `✓` = at least one relay ACK'd the gift wrap.
- No indicator = still pending (shows subtle spinner).
- `✕` = failed (tap to retry).
- No double-check / read receipts in v1 (no NIP standard).

### ChatComposerBar

```swift
struct ChatComposerBar: View {
    @State private var text = ""
    @FocusState private var isFocused: Bool
    let replyingTo: ChatMessageEntity?
    let onSend: (String) -> Void
    let onCancelReply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                replyPreviewStrip(replyingTo)
            }
            HStack(spacing: 10) {
                TextField("message...", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .font(LinkstrTheme.body(15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(LinkstrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($isFocused)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? LinkstrTheme.accent : LinkstrTheme.textTertiary)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(LinkstrTheme.chrome)
    }
}
```

### NewChatSheet (recipient picker)

Reuse `RecipientSearchLogic` and the contacts list. Flow:

1. Present sheet with contacts list + npub search field.
2. User selects contact or pastes npub.
3. Dismiss sheet → navigate to `ChatDetailView` for that counterparty.
4. If conversation already exists, open existing; otherwise create on first send.

---

## Features & interactions

### Emoji reactions

Reuse the existing `ReactionSummary` pattern. Implementation:

- **Trigger**: Long-press a message bubble → show emoji picker overlay.
- **Protocol**: Send a kind-14 rumor with content = the emoji, `e` tag referencing the target message event ID, `p` tag for recipient. Wrapped in gift wrap.
- **Storage**: `ChatReactionEntity` linked by `targetEventID`.
- **Display**: Compact emoji pills below the bubble (same as `LinkstrReactionRow`).
- **Toggle**: Tap own reaction to remove (send same payload with removal semantics or NIP-09 delete).

```
┌───────────────────┐
│ nice, thx!        │
└───────────────────┘
 😂 ❤️ 2
```

### Reply / quote

- **Trigger**: Swipe right on a message, or long-press → "Reply".
- **Protocol**: Kind-14 rumor with an `e` tag (reply marker) pointing to original event ID. Content is the reply text.
- **Display**: Quoted snippet above the reply bubble (truncated to ~60 chars).
- **Storage**: `replyToEventID` + `encryptedReplyPreview` on `ChatMessageEntity`.

### Link previews

- Detect URLs in message content via `LinkstrURLValidator`.
- Fetch metadata with existing `URLMetadataService`.
- Display inline card below the message bubble (title + domain + optional thumbnail).
- "Share to session" action available on messages containing links.

### Message deletion

- Swipe trailing → "Delete" (local only by default).
- Option to "delete for relay" which sends a NIP-09 deletion event for the transport event IDs.
- Tombstone display: "this message was deleted" in italic if counterparty deletes.

### Search within conversation

- Toolbar button in `ChatDetailView` nav bar.
- Filters messages by content substring.
- Highlight matches and allow jumping between results.

---

## Typing indicators

### Feasibility assessment

Nostr has no standardized NIP for typing indicators. Options:

| Approach                     | Delivery                     | Privacy                            | Cost                                              |
| ---------------------------- | ---------------------------- | ---------------------------------- | ------------------------------------------------- |
| Ephemeral event (kind 10003) | Unreliable (relays may drop) | Leaks "A is messaging B" to relays | Cheap                                             |
| Gift-wrapped indicator       | Reliable                     | Private                            | Expensive (full NIP-59 cycle per keystroke batch) |
| Skip entirely                | N/A                          | Maximum                            | Zero                                              |

### Recommended approach (optional, off by default)

If implemented:

- Send a lightweight **ephemeral kind 10003** event (not gift-wrapped) with a `p` tag for the recipient.
- Debounce: send at most once per 3 seconds while user is actively typing.
- Expire: recipient hides indicator after 5 seconds with no new event.
- **Privacy setting**: off by default. User can enable in Settings → Chat → "Show typing status".
- Display: animated "..." below the last incoming bubble, with counterparty's name on the conversation list row.

### Privacy implications

Ephemeral events are not encrypted. Relays can observe who is typing to whom. This is an explicit opt-in tradeoff. Document clearly in settings.

If privacy is paramount, skip typing indicators entirely. The UX loss is minimal.

---

## Read receipts

### Protocol

No Nostr NIP for read receipts. Custom approach (linkstr-to-linkstr only):

- When user opens a conversation and messages become visible, send a gift-wrapped kind-14 rumor with a special tag: `["read", "<latest_read_event_id>"]`.
- Recipient's linkstr client interprets this and updates delivery state to "read" for messages up to that event ID.

### Privacy & UX

- Off by default. Enable in Settings → Chat → "Send read receipts".
- Only works between two linkstr users (other Nostr clients will ignore the tag).
- Show double-check `✓✓` on outgoing messages confirmed read.

### Deferral recommendation

Skip for v1. Adds complexity, privacy concerns, and only works in the linkstr ecosystem. Revisit if a NIP emerges.

---

## Push notifications

Extend `PushNotificationService` with a `chat` category:

```swift
// Notification payload from push-service
{
    "aps": { "alert": { "title": "alice", "body": "hey did you see that article?" } },
    "category": "chat",
    "conversation_id": "<conversation_key>"    // for navigation on tap
}
```

- Tap notification → navigate to `ChatDetailView` for that conversation.
- Routing: use `category` field to disambiguate chat vs session. Add a dedicated `pendingChatConversationKey` on `PushNotificationService` (separate from the existing `pendingConversationID` used for session navigation, since session IDs and chat conversation keys are different identifier types).
- Muted conversations suppress both push and badge increment.

---

## Coexistence with sessions and contacts

### Mental model

| Tab          | Metaphor                | Content type              | Orientation                    |
| ------------ | ----------------------- | ------------------------- | ------------------------------ |
| **Sessions** | Shared bookmarks folder | Links with notes, curated | Group, persistent, link-first  |
| **Chat**     | iMessage                | Free-text conversation    | 1:1, ephemeral, text-first     |
| **Contacts** | Address book            | Identity registry         | Passive, the "who" behind both |

Sessions = **what** you're sharing. Chat = **what** you're saying. Contacts = **who** you know.

### Why they don't collapse

- **Sessions are multi-party and persistent.** They have names, membership management, archiving. They're a shared artifact. Chat is lightweight and disposable.
- **Contacts exist without conversation.** You can have a contact you've never messaged and never shared a session with. The rolodex is standalone.
- **Chat is 1:1 and real-time.** It has different UX expectations (bubbles, typing, read state) than a link feed.

### Contacts as the shared spine

Both sessions and chat reference contacts for display names, avatars, and identity resolution. Contacts doesn't own conversations — it's the rolodex that feeds both social surfaces.

### Tab order rationale

```
sessions | chat | contacts | you | settings
```

Sessions is the hero feature (the app's differentiator). Chat sits next to it as the conversational complement. Contacts is the utility layer between social features and personal settings.

### Unread badge strategy

- Sessions tab: dot if any session has unread posts (existing behavior).
- Chat tab: dot if any conversation has unread messages.
- Contacts tab: never has a badge — it's passive.
- App icon badge count: sum of unread session posts + unread chat messages (excluding muted).

### The "which do I use?" user question

"I want to send alice a link — sessions or chat?"

Both are valid, for different intent:

- Drop a link in chat = "hey check this out" (ephemeral, conversational).
- Post a link in a session = "this belongs in our curated collection" (persistent, organized).

The "Share to session" action on chat links bridges the gap — discover something in conversation, then promote it to the permanent feed.

---

## Integration points

### Contacts tab

- Add "Message" action button on each contact row.
- Tapping opens/creates chat conversation with that contact.

### Sessions tab

- "Share to session" context action on chat messages containing URLs.
- Flow: long-press chat message → "Share to Session" → session picker → auto-creates root post with the URL.
- Session member avatar tap → option to "Open chat" with that person.

### Deep links

- `nostr:npub1...` links anywhere in the app offer "Open chat" option.
- Push notification taps route through `DeepLinkHandler` to the correct tab based on `category` (session vs chat).

### Profile / identity

- Chat uses `resolvedIdentity(for:)` for display names (local alias → chosen name → npub).
- Profile pictures from kind-0 metadata shown as avatars in conversation list and chat header.

---

## Migration & rollout considerations

### Backfill

On first launch with chat enabled, backfill existing kind-14 DMs from relays. The existing `NostrDMService.BackfillState` pattern handles this — add a parallel backfill subscription filtered to kind-14 gift wraps.

### Existing NIP-04 messages

NIP-04 (legacy encrypted DMs, kind 4) is deprecated but still common. Decision: **do not support NIP-04** in linkstr chat. Only NIP-17 (kind 14 inside gift wraps). This keeps the implementation clean and privacy-forward. Users with legacy DMs can use other clients.

### Storage impact

Chat messages are typically smaller than session posts (no URL metadata, thumbnails, etc.) but more numerous. Consider:

- Aggressive pagination (load 50 messages at a time, not all).
- Optional auto-prune for conversations older than N days (setting).
- SwiftData index on `[ownerPubkey, conversationKey, timestamp]` for efficient range queries.

---

## Open questions

1. **Media messages**: Should v1 support image/file attachments (upload to Blossom/NIP-96 server, send URL)? Or text-only for simplicity?
2. **Blocking**: Should there be a block action that suppresses all messages from a pubkey? Requires local blocklist and optional relay-level filtering.
3. **Message retention**: Should messages be stored forever locally, or offer a disappearing messages option?

---

## Implementation phases

### Phase 1: Core chat (MVP)

- Data models (`ChatMessageEntity`, `ChatConversationEntity`).
- `ChatMessageStore` with insert, fetch, mark-read.
- Kind-14 rumor building and parsing in `NostrDMService`.
- `ChatListView` and `ChatDetailView` with bubble UI.
- `ChatComposerBar` (text only).
- New tab in `MainTabView`.
- Push notification routing for chat messages.

### Phase 2: Interactions

- Emoji reactions on messages.
- Reply/quote with swipe gesture.
- Link detection + inline preview cards.
- "Share to session" action on link messages.
- Message deletion (local + relay).

### Phase 3: Polish

- Typing indicators (opt-in).
- Read receipts (opt-in, linkstr-to-linkstr).
- Search within conversation.
- Pin/mute conversations.
- Profile pictures in chat header and conversation list.

### Phase 4: Extended

- Voice messages (audio upload + inline player).
- Image/media sharing via Blossom/NIP-96.
- Message forwarding.
- Disappearing messages (optional TTL).
