import SwiftData
import SwiftUI
import UIKit

// MARK: - PostDetailView Sections

extension PostDetailView {
  var post: SessionMessageEntity? {
    loadedPost
  }

  var reactions: [SessionReactionEntity] {
    loadedReactions
  }

  var members: [SessionMemberEntity] {
    loadedMembers
  }

  var loadRequestID: String {
    "\(ownerPubkey)|\(sessionID)|\(postID)"
  }

  var reactionSummaries: [ReactionSummary] {
    ReactionSummary.summaries(
      from: reactions,
      myPubkey: session.identityService.pubkeyHex
    )
  }

  var reactionBreakdown: [ReactionParticipantBreakdown] {
    guard !reactions.isEmpty else { return [] }

    let myPubkeyHash = session.identityService.pubkeyHex.map {
      LocalDataCrypto.shared.digestHex($0)
    }
    let grouped = Dictionary(grouping: reactions) { reaction -> String in
      if let myPubkeyHash, reaction.senderMatchesHash(myPubkeyHash) {
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

  var profileLookupPubkeys: [String] {
    NostrValueNormalizer.dedupedNormalizedPubkeyHexes(reactions.map(\.senderPubkey))
  }

  var canReactToPost: Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    let myPubkeyHash = LocalDataCrypto.shared.digestHex(myPubkey)
    return members.contains { member in
      member.memberMatchesHash(myPubkeyHash)
    }
  }

  var shareDeepLinkURL: URL? {
    guard let post else { return nil }
    return LinkstrDeepLinkCodec.makeAppDeepLink(url: post.url)
  }
  func postCardContent(_ post: SessionMessageEntity) -> some View {
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

      postCardNoteBlock
      mediaBlock(post)
      postCardReadOnlyNotice
      postCardReactionRow
      postCardReactionBreakdown
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  var postCardNoteBlock: some View {
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
  }

  @ViewBuilder
  var postCardReadOnlyNotice: some View {
    if !canReactToPost {
      Text("you're no longer a member of this session. reactions are read-only.")
        .font(LinkstrTheme.body(12))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  var postCardReactionRow: some View {
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
  }

  @ViewBuilder
  var postCardReactionBreakdown: some View {
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

  @ViewBuilder
  func mediaBlock(_ post: SessionMessageEntity) -> some View {
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

  func toggleReaction(_ emoji: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task { @MainActor in
      guard let post else { return }
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
      await loadContent()
    }
  }

  func refreshPostMetadata(_ post: SessionMessageEntity) {
    guard !isRefreshingMetadata else { return }
    isRefreshingMetadata = true
    Task { @MainActor in
      _ = await session.refreshPostMetadata(post)
      await loadContent()
      isRefreshingMetadata = false
    }
  }

  func metadataRefreshButton(for post: SessionMessageEntity) -> some View {
    Button {
      refreshPostMetadata(post)
    } label: {
      Group {
        if isRefreshingMetadata {
          ProgressView()
            .controlSize(.small)
            .frame(width: 18, height: 18)
        } else {
          Image(systemName: "arrow.clockwise")
            .linkstrToolbarIconLabel()
        }
      }
    }
    .accessibilityLabel("refresh post metadata")
    .disabled(isRefreshingMetadata)
    .tint(LinkstrTheme.accent)
  }

  func shareDeepLinkButton(for url: URL) -> some View {
    ShareLink(item: url) {
      Image(systemName: "square.and.arrow.up")
        .linkstrToolbarIconLabel()
    }
    .accessibilityLabel("share deep link")
    .tint(LinkstrTheme.accent)
  }

  var noteText: String? {
    guard let post else { return nil }
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var remotePostTextRequestID: String? {
    guard let post else { return nil }
    guard let urlString = post.url else { return nil }
    return shouldLoadRemotePostText(for: urlString) ? urlString : nil
  }

  func shouldLoadRemotePostText(for urlString: String) -> Bool {
    guard let url = URL(string: urlString) else { return false }
    return SocialPostResolutionService.supportsRemotePostText(for: url)
  }

  func resolvedRemotePostText() async -> String? {
    guard let post else { return nil }
    guard let urlString = post.url, shouldLoadRemotePostText(for: urlString) else { return nil }
    guard let url = URL(string: urlString) else { return nil }
    return await SocialPostResolutionService.resolveRemotePostText(for: url)
  }

  func accentTextBlock(label: String, text: String) -> some View {
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

  func clearPersistedLocalMedia(for post: SessionMessageEntity) {
    if let localURL = ManagedLocalFileScope.shared.managedFileURL(fromPath: post.cachedMediaPath) {
      try? FileManager.default.removeItem(at: localURL)
    }
    post.cachedMediaPath = nil
    post.cachedMediaSourceURL = nil
    try? modelContext.save()
  }

  @MainActor
  func loadContent() async {
    loadedPost = try? fetchPost()
    loadedReactions = (try? fetchReactions()) ?? []
    loadedMembers = (try? fetchMembers()) ?? []
    loadedContacts = (try? fetchContacts(senderPubkeys: Set(reactions.map(\.senderPubkey)))) ?? []
  }

  func fetchPost() throws -> SessionMessageEntity? {
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

  func fetchContacts(senderPubkeys: Set<String>) throws -> [ContactEntity] {
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

  func fetchReactions() throws -> [SessionReactionEntity] {
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

  func fetchMembers() throws -> [SessionMemberEntity] {
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
