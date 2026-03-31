import EmojiKit
import SwiftData
import SwiftUI
import UIKit

struct ReactionSummary: Identifiable, Hashable {
  let emoji: String
  let count: Int
  let includesCurrentUser: Bool

  var id: String { emoji }

  var badgeText: String {
    count > 10 ? "10+" : "\(count)"
  }

  var readOnlyBadgeText: String? {
    guard count > 1 else { return nil }
    return badgeText
  }

  static func summaries(from reactions: [SessionReactionEntity], myPubkey: String?)
    -> [ReactionSummary]
  {
    guard !reactions.isEmpty else { return [] }

    return
      Dictionary(grouping: reactions, by: \.emoji)
      .map { emoji, groupedReactions -> ReactionSummary in
        ReactionSummary(
          emoji: emoji,
          count: groupedReactions.count,
          includesCurrentUser: groupedReactions.contains { reaction in
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
}

struct ReactionParticipantBreakdown: Identifiable, Hashable {
  let displayName: String
  let emojis: [String]

  var id: String { displayName }
}

struct LinkstrReactionRow: View {
  enum Mode {
    case interactive
    case readOnly
  }

  let summaries: [ReactionSummary]
  var mode: Mode = .interactive
  let onToggleEmoji: ((String) -> Void)?
  let onAddReaction: (() -> Void)?

  private let quickEmojis = ["👍", "👎", "👀"]
  private let readOnlyMaxEmojiCount = 10

  private var quickSummariesByEmoji: [String: ReactionSummary] {
    Dictionary(
      uniqueKeysWithValues:
        summaries
        .filter { quickEmojis.contains($0.emoji) }
        .map { ($0.emoji, $0) }
    )
  }

  private var extraSummaries: [ReactionSummary] {
    summaries.filter { !quickEmojis.contains($0.emoji) }
  }

  private var readOnlyVisibleSummaries: [ReactionSummary] {
    Array(summaries.prefix(readOnlyMaxEmojiCount))
  }

  private var hasReadOnlyOverflow: Bool {
    summaries.count > readOnlyMaxEmojiCount
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .center, spacing: mode == .readOnly ? 6 : 8) {
        if mode == .readOnly {
          ForEach(readOnlyVisibleSummaries) { summary in
            readOnlySummaryText(summary)
          }

          if hasReadOnlyOverflow {
            Text("...")
              .font(LinkstrTheme.body(12))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        } else {
          ForEach(extraSummaries) { summary in
            summaryChip(summary)
          }

          ForEach(quickEmojis, id: \.self) { emoji in
            quickEmojiButton(emoji)
          }

          if let onAddReaction {
            Button(action: onAddReaction) {
              Text("...")
                .font(LinkstrTheme.body(13))
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
          }
        }
      }
      .frame(minHeight: mode == .readOnly ? 18 : nil, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func readOnlySummaryText(_ summary: ReactionSummary) -> some View {
    ZStack(alignment: .bottomTrailing) {
      Text(summary.emoji)
        .font(LinkstrTheme.system(17))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))

      if let badgeText = summary.readOnlyBadgeText {
        Text(badgeText)
          .font(LinkstrTheme.body(9))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(
            Capsule()
              .fill(LinkstrTheme.panel)
          )
          .overlay(
            Capsule()
              .stroke(LinkstrTheme.textSecondary.opacity(0.22), lineWidth: 1)
          )
          .offset(x: 7, y: 5)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.vertical, 4)
    .padding(.trailing, 8)
    .accessibilityLabel(
      "\(summary.count) \(summary.emoji) reaction\(summary.count == 1 ? "" : "s")")
  }

  private func summaryChip(_ summary: ReactionSummary) -> some View {
    Group {
      if let onToggleEmoji, mode == .interactive {
        Button {
          onToggleEmoji(summary.emoji)
        } label: {
          summaryChipLabel(summary)
        }
        .buttonStyle(.plain)
      } else {
        summaryChipLabel(summary)
      }
    }
  }

  private func summaryChipLabel(_ summary: ReactionSummary) -> some View {
    HStack(spacing: 6) {
      Text(summary.emoji)
        .font(LinkstrTheme.system(15))
      Text(summary.badgeText)
        .font(LinkstrTheme.body(12))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(summary.includesCurrentUser ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary.includesCurrentUser
            ? LinkstrTheme.accent.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
          lineWidth: 1
        )
    )
  }

  private func quickEmojiButton(_ emoji: String) -> some View {
    let summary = quickSummariesByEmoji[emoji]
    return Group {
      if let onToggleEmoji, mode == .interactive {
        Button {
          onToggleEmoji(emoji)
        } label: {
          quickEmojiButtonLabel(emoji: emoji, summary: summary)
        }
        .buttonStyle(.plain)
      } else {
        quickEmojiButtonLabel(emoji: emoji, summary: summary)
      }
    }
  }

  private func quickEmojiButtonLabel(
    emoji: String,
    summary: ReactionSummary?
  ) -> some View {
    HStack(spacing: 6) {
      Text(emoji)
        .font(LinkstrTheme.system(15))

      if let count = summary?.count, count > 0 {
        Text(summary?.badgeText ?? "\(count)")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(
          summary?.includesCurrentUser == true ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary?.includesCurrentUser == true
            ? LinkstrTheme.accent.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
          lineWidth: 1
        )
    )
  }

}

struct LinkstrEmojiPickerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let onPick: (String) -> Void

  @State private var query = ""
  @State private var category: EmojiCategory?
  @State private var selection: Emoji.GridSelection?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        VStack(spacing: 0) {
          LinkstrScreenTitle(title: "add reaction")
            .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
            .padding(.top, LinkstrTheme.screenTopPadding)
          EmojiGridScrollView(
            axis: .vertical,
            category: $category,
            selection: $selection,
            query: query,
            action: { emoji in
              onPick(emoji.char)
              dismiss()
            },
            sectionTitle: { $0.view },
            gridItem: { $0.view }
          )
          .emojiGridStyle(.medium)
          .padding(.horizontal, 8)
          .padding(.vertical, 8)
        }
      }
      .linkstrBarChrome()
      .searchable(text: $query, prompt: "search emoji")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("close emoji picker")
          .tint(LinkstrTheme.textSecondary)
        }
      }
    }
  }
}

struct PostDetailView: View {
  @EnvironmentObject private var session: AppSession
  @Environment(\.modelContext) private var modelContext
  @Environment(\.openURL) private var openURL

  let ownerPubkey: String
  let sessionID: String
  let postID: String
  let sessionName: String

  @State private var isPresentingEmojiPicker = false
  @State private var loadedPost: SessionMessageEntity?
  @State private var loadedContacts: [ContactEntity] = []
  @State private var loadedReactions: [SessionReactionEntity] = []
  @State private var loadedMembers: [SessionMemberEntity] = []
  @State private var remotePostText: String?
  @State private var isRefreshingMetadata = false

  init(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    sessionName: String
  ) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.postID = postID
    self.sessionName = sessionName
  }

  private var post: SessionMessageEntity? {
    loadedPost
  }

  private var contacts: [ContactEntity] {
    loadedContacts
  }

  private var reactions: [SessionReactionEntity] {
    loadedReactions
  }

  private var members: [SessionMemberEntity] {
    loadedMembers
  }

  private var loadRequestID: String {
    "\(ownerPubkey)|\(sessionID)|\(postID)"
  }

  private var reactionSummaries: [ReactionSummary] {
    ReactionSummary.summaries(
      from: reactions,
      myPubkey: session.identityService.pubkeyHex
    )
  }

  private var reactionBreakdown: [ReactionParticipantBreakdown] {
    guard !reactions.isEmpty else { return [] }

    let grouped = Dictionary(grouping: reactions) { reaction -> String in
      let myPubkey = session.identityService.pubkeyHex
      if let myPubkey, reaction.senderMatches(myPubkey) {
        return "you"
      }
      return session.displayName(for: reaction.senderPubkey, contacts: contacts)
    }

    return
      grouped.map { displayName, reactions in
        let emojis = Array(Set(reactions.map(\.emoji))).sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return ReactionParticipantBreakdown(displayName: displayName, emojis: emojis)
      }
      .sorted {
        if $0.displayName == "you" { return true }
        if $1.displayName == "you" { return false }
        return
          $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
          == .orderedAscending
      }
  }

  private var profileLookupPubkeys: [String] {
    NostrValueNormalizer.dedupedNormalizedPubkeyHexes(reactions.map(\.senderPubkey))
  }

  private var canReactToPost: Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return members.contains { member in
      member.memberMatches(myPubkey)
    }
  }

  private var shareDeepLinkURL: URL? {
    guard let post else { return nil }
    return LinkstrDeepLinkCodec.makeAppDeepLink(url: post.url)
  }

  var body: some View {
    Group {
      if let post {
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: sessionName)
            postCardContent(post)
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
        }
      } else {
        ContentUnavailableView(
          "post unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("this post is no longer available.")
        )
      }
    }
    .linkstrTabBarContentInset()
    .task(id: loadRequestID) {
      await loadContent()
    }
    .task(id: profileLookupPubkeys.stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .background(LinkstrBackgroundView())
    .linkstrBarChrome()
    .toolbar {
      if let post {
        ToolbarItemGroup(placement: .topBarTrailing) {
          metadataRefreshButton(for: post)
          if let shareDeepLinkURL {
            shareDeepLinkButton(for: shareDeepLinkURL)
          }
        }
      } else if let shareDeepLinkURL {
        ToolbarItem(placement: .topBarTrailing) {
          shareDeepLinkButton(for: shareDeepLinkURL)
        }
      }
    }
    .task(id: post?.storageID) {
      guard let post else { return }
      session.markRootPostRead(postID: post.rootID)
      session.refreshMetadataForVisiblePostIfNeeded(post)
    }
    .task(id: remotePostTextRequestID) {
      remotePostText = await resolvedRemotePostText()
    }
    .sheet(isPresented: $isPresentingEmojiPicker) {
      LinkstrEmojiPickerSheet { emoji in
        toggleReaction(emoji)
      }
      .presentationDetents([.fraction(0.92)])
    }
  }

  private func postCardContent(_ post: SessionMessageEntity) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
      HStack(spacing: 12) {
        Spacer(minLength: 0)

        Text(post.timestamp.linkstrMessageTimestampLabel)
          .font(LinkstrTheme.body(11, weight: .medium))
          .foregroundStyle(LinkstrTheme.textTertiary)
      }

      if let title = post.metadataTitle, !title.isEmpty {
        Text(title)
          .font(LinkstrTheme.title(17, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let url = post.url {
        Text(url)
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
      }

      if noteText != nil || remotePostText != nil {
        VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
          if let noteText {
            accentTextBlock(label: "note", text: noteText)
          }

          if let remotePostText {
            Text(remotePostText)
              .font(LinkstrTheme.body(13))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
      }

      mediaBlock(post)

      if !canReactToPost {
        Text("you're no longer a member of this session. reactions are read-only.")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      LinkstrReactionRow(
        summaries: reactionSummaries,
        mode: canReactToPost ? .interactive : .readOnly,
        onToggleEmoji: canReactToPost
          ? { emoji in
            toggleReaction(emoji)
          } : nil,
        onAddReaction: canReactToPost
          ? {
            isPresentingEmojiPicker = true
          } : nil
      )

      if !reactionBreakdown.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          LinkstrListRowDivider(leadingInset: 0)
          VStack(alignment: .leading, spacing: 10) {
            ForEach(reactionBreakdown) { entry in
              HStack(alignment: .center, spacing: 8) {
                Text(entry.displayName)
                  .font(LinkstrTheme.body(13, weight: .medium))
                  .foregroundStyle(LinkstrTheme.textSecondary)

                Text(entry.emojis.joined(separator: " "))
                  .font(LinkstrTheme.system(16))
                  .foregroundStyle(LinkstrTheme.textPrimary)

                Spacer(minLength: 0)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func mediaBlock(_ post: SessionMessageEntity) -> some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      AdaptiveVideoPlaybackView(
        sourceURL: url,
        showOpenSourceButtonInEmbedMode: true,
        openSourceAction: { openURL(url) },
        resolveCachedLocalMedia: { sourceURL in
          guard
            let localURL = ManagedLocalFileScope.shared.managedFileURL(
              fromPath: post.cachedMediaPath),
            post.cachedMediaSourceURL == sourceURL.absoluteString
          else {
            return nil
          }
          guard FileManager.default.fileExists(atPath: localURL.path) else {
            clearPersistedLocalMedia(for: post)
            return nil
          }
          return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
        },
        persistLocalMedia: { sourceURL, media in
          guard media.isLocalFile else { return }
          guard
            let managedURL = ManagedLocalFileScope.shared.managedFileURL(
              fromPath: media.playbackURL.path
            )
          else {
            clearPersistedLocalMedia(for: post)
            return
          }
          post.cachedMediaPath = managedURL.path
          post.cachedMediaSourceURL = sourceURL.absoluteString
          try? modelContext.save()
        },
        clearPersistedLocalMedia: {
          clearPersistedLocalMedia(for: post)
        }
      )
    }
  }

  private func toggleReaction(_ emoji: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task { @MainActor in
      guard let post else { return }
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
      await loadContent()
    }
  }

  private func refreshPostMetadata(_ post: SessionMessageEntity) {
    guard !isRefreshingMetadata else { return }
    isRefreshingMetadata = true
    Task { @MainActor in
      await session.refreshPostMetadata(post)
      await loadContent()
      isRefreshingMetadata = false
    }
  }

  private func metadataRefreshButton(for post: SessionMessageEntity) -> some View {
    Button {
      refreshPostMetadata(post)
    } label: {
      Image(systemName: "arrow.clockwise")
        .linkstrToolbarIconLabel()
    }
    .accessibilityLabel("refresh post metadata")
    .disabled(isRefreshingMetadata)
    .tint(LinkstrTheme.accent)
  }

  private func shareDeepLinkButton(for url: URL) -> some View {
    ShareLink(item: url) {
      Image(systemName: "square.and.arrow.up")
        .linkstrToolbarIconLabel()
    }
    .accessibilityLabel("share deep link")
    .tint(LinkstrTheme.accent)
  }

  private var noteText: String? {
    guard let post else { return nil }
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var remotePostTextRequestID: String? {
    guard let post else { return nil }
    guard let urlString = post.url else { return nil }
    return shouldLoadRemotePostText(for: urlString) ? urlString : nil
  }

  private func shouldLoadRemotePostText(for urlString: String) -> Bool {
    guard let url = URL(string: urlString) else { return false }
    return SocialPostResolutionService.supportsRemotePostText(for: url)
  }

  private func resolvedRemotePostText() async -> String? {
    guard let post else { return nil }
    guard let urlString = post.url, shouldLoadRemotePostText(for: urlString) else { return nil }
    guard let url = URL(string: urlString) else { return nil }
    return await SocialPostResolutionService.resolveRemotePostText(for: url)
  }

  private func accentTextBlock(label: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Capsule(style: .continuous)
        .fill(LinkstrTheme.accent)
        .frame(width: 4)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(label)
          .font(LinkstrTheme.body(11, weight: .semibold))
          .foregroundStyle(LinkstrTheme.accent)

        Text(text)
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 2)
  }

  private func clearPersistedLocalMedia(for post: SessionMessageEntity) {
    if let localURL = ManagedLocalFileScope.shared.managedFileURL(fromPath: post.cachedMediaPath) {
      try? FileManager.default.removeItem(at: localURL)
    }
    post.cachedMediaPath = nil
    post.cachedMediaSourceURL = nil
    try? modelContext.save()
  }

  @MainActor
  private func loadContent() async {
    loadedPost = try? fetchPost()
    loadedReactions = (try? fetchReactions()) ?? []
    loadedMembers = (try? fetchMembers()) ?? []
    loadedContacts = (try? fetchContacts(senderPubkeys: Set(reactions.map(\.senderPubkey)))) ?? []
  }

  private func fetchPost() throws -> SessionMessageEntity? {
    let storageID = SessionMessageEntity.storageID(
      ownerPubkey: ownerPubkey,
      eventID: postID
    )
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    guard let post = try modelContext.fetch(descriptor).first else { return nil }
    guard post.conversationID == sessionID, post.kind == .root else { return nil }
    return post
  }

  private func fetchContacts(senderPubkeys: Set<String>) throws -> [ContactEntity] {
    guard !senderPubkeys.isEmpty else { return [] }

    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(
      Array(senderPubkeys)
    )
    guard !normalizedPubkeys.isEmpty else { return [] }

    var contacts: [ContactEntity] = []
    contacts.reserveCapacity(normalizedPubkeys.count)

    for pubkey in normalizedPubkeys {
      let descriptor = FetchDescriptor<ContactEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == ownerPubkey && $0.targetPubkey == pubkey
        },
        sortBy: [SortDescriptor(\.createdAt)]
      )
      contacts.append(contentsOf: try modelContext.fetch(descriptor))
    }

    return contacts
  }

  private func fetchReactions() throws -> [SessionReactionEntity] {
    let descriptor = FetchDescriptor<SessionReactionEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey
          && $0.sessionID == sessionID
          && $0.postID == postID
          && $0.isActive == true
      },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  private func fetchMembers() throws -> [SessionMemberEntity] {
    let descriptor = FetchDescriptor<SessionMemberEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey
          && $0.sessionID == sessionID
          && $0.isActive == true
      },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    return try modelContext.fetch(descriptor)
  }
}
