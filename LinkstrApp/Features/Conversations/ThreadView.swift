import SwiftData
import SwiftUI

struct ThreadView: View {
  @EnvironmentObject private var session: AppSession
  @Environment(\.openURL) private var openURL

  let post: SessionMessageEntity

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @State private var replyText = ""
  @FocusState private var isComposerFocused: Bool

  private var scopedMessages: [SessionMessageEntity] {
    guard let ownerPubkey = session.identityService.pubkeyHex else { return [] }
    return allMessages.filter { $0.ownerPubkey == ownerPubkey }
  }

  private var scopedContacts: [ContactEntity] {
    guard let ownerPubkey = session.identityService.pubkeyHex else { return [] }
    return
      contacts
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  private var replies: [SessionMessageEntity] {
    scopedMessages.filter { $0.kind == .reply && $0.rootID == post.rootID }
  }

  private var threadTitle: String {
    guard let myPubkey = session.identityService.pubkeyHex else {
      return "Thread"
    }
    let other = post.senderPubkey == myPubkey ? post.receiverPubkey : post.senderPubkey
    return session.contactName(for: other, contacts: scopedContacts)
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

  private var mediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: post.url)
  }

  private var mediaAspectRatio: CGFloat {
    guard let urlString = post.url, let sourceURL = URL(string: urlString) else {
      return 16.0 / 9.0
    }
    return URLClassifier.preferredMediaAspectRatio(for: sourceURL, strategy: mediaStrategy)
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
      .navigationTitle(threadTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .task {
        session.markPostRepliesRead(postID: post.rootID)
      }
      .onChange(of: replies.count) { _, _ in
        session.markPostRepliesRead(postID: post.rootID)
        scrollToBottom(using: proxy)
      }
    }
  }

  private var postCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(contentKindLabel)
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
          Text("Sent by \(postSenderLabel)")
            .font(.caption2)
            .foregroundStyle(LinkstrTheme.textSecondary)
        }

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
        VStack(alignment: .leading, spacing: 4) {
          Text("NOTE")
            .font(.custom(LinkstrTheme.titleFont, size: 11))
            .foregroundStyle(LinkstrTheme.neonAmber)
          Text(note)
            .font(.custom(LinkstrTheme.bodyFont, size: 13))
            .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.94))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinkstrTheme.panelSoft)
        )
      }

      mediaBlock

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
    .padding(12)
    .linkstrNeonCard()
  }

  private var contentKindLabel: String {
    mediaStrategy.contentKindLabel
  }

  @ViewBuilder
  private var mediaBlock: some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      AdaptiveVideoPlaybackView(
        sourceURL: url,
        mediaStrategy: mediaStrategy,
        mediaAspectRatio: mediaAspectRatio,
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
      .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(LinkstrTheme.panel.opacity(0.92))
  }

  private func sendReply(using proxy: ScrollViewProxy) {
    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    session.sendReply(text: text, post: post)
    replyText = ""
    isComposerFocused = false
    scrollToBottom(using: proxy)
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
