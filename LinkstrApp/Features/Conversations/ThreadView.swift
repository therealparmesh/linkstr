import SwiftData
import SwiftUI

struct ReactionSummary: Identifiable, Hashable {
  let emoji: String
  let count: Int
  let includesCurrentUser: Bool

  var id: String { emoji }
}

struct LinkstrReactionRow: View {
  let summaries: [ReactionSummary]
  let onToggleEmoji: (String) -> Void
  let onAddReaction: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(summaries) { summary in
        Button {
          onToggleEmoji(summary.emoji)
        } label: {
          HStack(spacing: 6) {
            Text(summary.emoji)
              .font(.system(size: 15))
            Text("\(summary.count)")
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
              .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            Capsule()
              .fill(summary.includesCurrentUser ? LinkstrTheme.panelSoft : LinkstrTheme.panel)
          )
          .overlay(
            Capsule()
              .stroke(
                summary.includesCurrentUser
                  ? LinkstrTheme.neonCyan.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
                lineWidth: 1
              )
          )
        }
        .buttonStyle(.plain)
      }

      Button(action: onAddReaction) {
        HStack(spacing: 6) {
          Image(systemName: "face.smiling")
            .font(.system(size: 13, weight: .semibold))
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          Capsule()
            .fill(LinkstrTheme.panel)
        )
        .overlay(
          Capsule()
            .stroke(LinkstrTheme.textSecondary.opacity(0.2), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      Spacer(minLength: 0)
    }
  }
}

struct LinkstrEmojiPickerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let onPick: (String) -> Void

  @State private var query = ""

  private let quickEmojis = ["👍", "👎", "👀"]

  private let categories: [(title: String, emojis: [String])] = [
    (
      "People",
      [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "🙂", "😉", "😍", "😘", "😋",
        "😎", "🤓", "🤔", "😐", "😶", "🙄", "😏", "😬", "😮", "😢", "😭", "😤", "😡", "🤯",
        "🥳", "😴", "🤗", "🤝", "🙏", "👏", "🙌", "👋", "🤌", "👌", "✌️", "🤞", "🤟", "🫡",
      ]
    ),
    (
      "Reactions",
      [
        "👍", "👎", "👊", "✊", "👏", "🙌", "👌", "🤝", "🙏", "💪", "🔥", "💯", "✅", "❌", "⚡️",
        "❤️", "💙", "💚", "🧡", "💜", "🤍", "💔", "💥", "⭐️", "✨", "🎯", "🚀", "👀", "👎", "👍",
      ]
    ),
    (
      "Objects",
      [
        "📌", "📎", "📷", "🎥", "📺", "🎧", "📱", "💻", "⌚️", "🧠", "📝", "📚", "🔗", "🔒", "🔓",
        "🛠️", "⚙️", "🧪", "💡", "🧯", "🎬", "🎮", "🧩", "🗂️", "🧾", "📦", "🧭", "🛰️", "🧱", "🧲",
      ]
    ),
    (
      "Nature & Food",
      [
        "🌞", "🌙", "⭐️", "☀️", "🌧️", "⚡️", "❄️", "🌊", "🌱", "🌴", "🌸", "🍀", "🍎", "🍕", "🍔",
        "🍟", "🌮", "🍣", "🍜", "☕️", "🍺", "🍷", "🍿", "🍪", "🍫", "🍓", "🍉", "🥑", "🥐", "🍩",
      ]
    ),
  ]

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            TextField("Search emoji", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )

            LinkstrSectionHeader(title: "Quick")
            emojiGrid(quickEmojis)

            ForEach(filteredCategories, id: \.title) { category in
              LinkstrSectionHeader(title: category.title)
              emojiGrid(category.emojis)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      .navigationTitle("Add Reaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }

  @ViewBuilder
  private func emojiGrid(_ emojis: [String]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 40)), count: 7), spacing: 8) {
      ForEach(emojis, id: \.self) { emoji in
        Button {
          onPick(emoji)
          dismiss()
        } label: {
          Text(emoji)
            .font(.system(size: 28))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var filteredCategories: [(title: String, emojis: [String])] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return categories
    }

    return categories.map { category in
      let filteredEmojis = category.emojis.filter { emoji in
        emoji.contains(trimmed)
      }
      return (category.title, filteredEmojis)
    }
    .filter { !$0.emojis.isEmpty }
  }
}

struct ThreadView: View {
  @EnvironmentObject private var session: AppSession
  @Environment(\.openURL) private var openURL

  let post: SessionMessageEntity
  let sessionName: String

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @Query(sort: [SortDescriptor(\SessionReactionEntity.updatedAt, order: .reverse)])
  private var allReactions: [SessionReactionEntity]

  @State private var replyText = ""
  @State private var isSendingReply = false
  @State private var isPresentingEmojiPicker = false
  @FocusState private var isComposerFocused: Bool

  private var scopedMessages: [SessionMessageEntity] {
    session.scopedMessages(from: allMessages)
  }

  private var scopedContacts: [ContactEntity] {
    session.scopedContacts(from: contacts)
  }

  private var scopedReactions: [SessionReactionEntity] {
    session.scopedReactions(from: allReactions)
      .filter {
        $0.sessionID == post.conversationID
          && $0.postID == post.rootID
          && $0.isActive
      }
  }

  private var replies: [SessionMessageEntity] {
    scopedMessages.filter { $0.kind == .reply && $0.rootID == post.rootID }
  }

  private var postSenderLabel: String {
    if isOutgoing(post) {
      return "You"
    }
    return session.contactName(for: post.senderPubkey, contacts: scopedContacts)
  }

  private var hasUnreadIncomingReplies: Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return replies.contains { $0.senderPubkey != myPubkey && $0.readAt == nil }
  }

  private var reactionSummaries: [ReactionSummary] {
    guard !scopedReactions.isEmpty else { return [] }
    let grouped = Dictionary(grouping: scopedReactions, by: \.emoji)
    let myPubkey = session.identityService.pubkeyHex

    return
      grouped
      .map { emoji, reactions -> ReactionSummary in
        ReactionSummary(
          emoji: emoji,
          count: reactions.count,
          includesCurrentUser: reactions.contains { reaction in
            guard let myPubkey else { return false }
            return reaction.senderMatches(myPubkey)
          }
        )
      }
      .sorted {
        if $0.count == $1.count {
          return $0.emoji < $1.emoji
        }
        return $0.count > $1.count
      }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 10) {
          postCard
            .id("post-card")

          ForEach(replies) { reply in
            ReplyBubbleRow(
              text: reply.note ?? "",
              timestamp: reply.timestamp,
              isOutgoing: isOutgoing(reply)
            )
            .id(reply.eventID)
          }

          Color.clear
            .frame(height: 1)
            .id("bottom-anchor")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
      }
      .background(chatBackground)
      .safeAreaInset(edge: .bottom) {
        composerBar(proxy: proxy)
      }
      .navigationTitle(sessionName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .task {
        session.markRootPostRead(postID: post.rootID)
        session.markPostRepliesRead(postID: post.rootID)
      }
      .onChange(of: replies.count) { _, _ in
        session.markPostRepliesRead(postID: post.rootID)
        scrollToBottom(using: proxy)
      }
      .sheet(isPresented: $isPresentingEmojiPicker) {
        LinkstrEmojiPickerSheet { emoji in
          toggleReaction(emoji)
        }
        .presentationDetents([.fraction(0.92)])
      }
    }
  }

  private var postCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Sent by \(postSenderLabel)")
          .font(.caption2)
          .foregroundStyle(LinkstrTheme.textSecondary)

        Spacer()

        Text(post.timestamp.linkstrMessageTimestampLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if let title = post.metadataTitle, !title.isEmpty {
        Text(title)
          .font(.custom(LinkstrTheme.titleFont, size: 18))
          .foregroundStyle(LinkstrTheme.textPrimary)
      }

      if let url = post.url {
        Text(url)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
      }

      if let note = post.note, !note.isEmpty {
        Text(note)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.94))
      }

      mediaBlock

      LinkstrReactionRow(
        summaries: reactionSummaries,
        onToggleEmoji: { emoji in
          toggleReaction(emoji)
        },
        onAddReaction: {
          isPresentingEmojiPicker = true
        }
      )

      HStack(spacing: 8) {
        Image(systemName: "bubble.left.and.bubble.right")
          .foregroundStyle(LinkstrTheme.textSecondary)
        Text(replyCountLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)
        if hasUnreadIncomingReplies {
          Circle()
            .fill(LinkstrTheme.neonAmber)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread replies")
        }
      }
    }
    .padding(.horizontal, 2)
  }

  @ViewBuilder
  private var mediaBlock: some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      AdaptiveVideoPlaybackView(
        sourceURL: url,
        showOpenSourceButtonInEmbedMode: true,
        openSourceAction: { openURL(url) },
        resolveCachedLocalMedia: { sourceURL in
          guard let path = post.cachedMediaPath,
            post.cachedMediaSourceURL == sourceURL.absoluteString
          else {
            return nil
          }
          let localURL = URL(fileURLWithPath: path)
          guard FileManager.default.fileExists(atPath: localURL.path) else {
            post.cachedMediaPath = nil
            post.cachedMediaSourceURL = nil
            return nil
          }
          return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
        },
        persistLocalMedia: { sourceURL, media in
          guard media.isLocalFile else { return }
          post.cachedMediaPath = media.playbackURL.path
          post.cachedMediaSourceURL = sourceURL.absoluteString
        }
      )
    }
  }

  private var chatBackground: some View {
    LinkstrBackgroundView()
  }

  private func composerBar(proxy: ScrollViewProxy) -> some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Write a reply", text: $replyText, axis: .vertical)
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .focused($isComposerFocused)
        .disabled(isSendingReply)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinkstrTheme.panelSoft)
        )
        .foregroundStyle(LinkstrTheme.textPrimary)

      Button {
        sendReply(using: proxy)
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 30))
          .foregroundStyle(LinkstrTheme.neonCyan)
      }
      .disabled(isSendingReply || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(LinkstrTheme.panel.opacity(0.92))
  }

  private func sendReply(using proxy: ScrollViewProxy) {
    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard !isSendingReply else { return }

    isSendingReply = true
    Task { @MainActor in
      let didSend = await session.sendReplyAwaitingRelay(text: text, post: post)
      isSendingReply = false
      guard didSend else { return }
      replyText = ""
      isComposerFocused = false
      scrollToBottom(using: proxy)
    }
  }

  private func toggleReaction(_ emoji: String) {
    Task { @MainActor in
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
    }
  }

  private func scrollToBottom(using proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.25)) {
      proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
  }

  private func isOutgoing(_ message: SessionMessageEntity) -> Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return message.senderPubkey == myPubkey
  }

  private var replyCountLabel: String {
    replies.count == 1 ? "1 reply" : "\(replies.count) replies"
  }
}

private struct ReplyBubbleRow: View {
  let text: String
  let timestamp: Date
  let isOutgoing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(text)
        .font(.custom(LinkstrTheme.bodyFont, size: 14))
        .foregroundStyle(isOutgoing ? LinkstrTheme.bgBottom : LinkstrTheme.textPrimary)

      Text(timestamp.linkstrMessageTimestampLabel)
        .font(.caption2)
        .foregroundStyle(
          isOutgoing ? LinkstrTheme.bgBottom.opacity(0.76) : LinkstrTheme.textSecondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(isOutgoing ? LinkstrTheme.neonCyan : LinkstrTheme.panel)
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
              isOutgoing
                ? LinkstrTheme.neonCyan.opacity(0.38) : LinkstrTheme.neonPink.opacity(0.26),
              lineWidth: 1
            )
        )
        .shadow(color: LinkstrTheme.neonPink.opacity(isOutgoing ? 0.0 : 0.12), radius: 8, y: 2)
    )
    .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
  }
}
