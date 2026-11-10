import SwiftData
import SwiftUI
import UIKit

// MARK: - PostDetailView Sections

extension PostDetailView {
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
    let grouped = Dictionary(grouping: reactions, by: \.senderPubkeyHash)

    return
      grouped.compactMap { senderPubkeyHash, reactions in
        guard let firstReaction = reactions.first else { return nil }
        let isCurrentUser = myPubkeyHash.map(firstReaction.senderMatchesHash) ?? false
        let displayName = isCurrentUser
          ? "you" : session.displayName(for: firstReaction.senderPubkey, contacts: contacts)
        let emojis = Array(Set(reactions.map(\.emoji))).sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return ReactionParticipantBreakdown(
          id: senderPubkeyHash,
          displayName: displayName,
          emojis: emojis
        )
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
  @ViewBuilder
  var postCardNoteBlock: some View {
    if noteText != nil || remotePostText != nil {
      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        if let noteText {
          accentTextBlock(label: "note", text: noteText)
        }

        if let remotePostText {
          Text(remotePostText)
            .font(LinkstrTheme.font(.footnote))
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
        .font(LinkstrTheme.font(.caption))
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
  func mediaBlock(_ post: SessionMessageEntity, isCovered: Bool) -> some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      AdaptiveMediaView(
        sourceURL: url,
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
        },
        reloadID: mediaReloadID,
        immersive: true,
        isCovered: isCovered,
        watchInsets: watchInsets,
        linkContent: { WatchLinkPreview(post: post) },
        overlayContent: { saveAction, hasNativePlayer in
          watchPostOverlay(post, saveAction: saveAction, hasNativePlayer: hasNativePlayer)
        }
      )
    } else {
      missingLinkPost(post)
    }
  }
  private func missingLinkPost(_ post: SessionMessageEntity) -> some View {
    VStack(spacing: 0) {
      ContentUnavailableView(
        "link unavailable", systemImage: "link",
        description: Text("the original link is missing. you can still view the note and reactions.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      watchPostOverlay(post, saveAction: nil, hasNativePlayer: false)
    }
    .padding(.top, watchInsets.top + 64)
  }

  func toggleReaction(_ emoji: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task { @MainActor in
      guard let post else { return }
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
    }
  }
  func refreshPostMetadata(_ post: SessionMessageEntity) {
    guard !isRefreshingMetadata else { return }
    isRefreshingMetadata = true
    Task { @MainActor in
      defer { isRefreshingMetadata = false }
      if let urlString = post.url, let url = URL(string: urlString) {
        await session.invalidateTransientMediaCaches(for: url)
      }
      clearPersistedLocalMedia(for: post)
      mediaReloadID += 1
      _ = await session.refreshPostMetadata(post)
    }
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
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(LinkstrTheme.accent)

        Text(text)
          .font(LinkstrTheme.font(.footnote))
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

  func fetchContacts(senderPubkeys: Set<String>) throws -> [ContactEntity] {
    guard !senderPubkeys.isEmpty else { return [] }

    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(
      Array(senderPubkeys)
    )
    guard !normalizedPubkeys.isEmpty else { return [] }

    let targetPubkeys = Set(normalizedPubkeys)
    let descriptor = FetchDescriptor<ContactEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey && targetPubkeys.contains($0.targetPubkey) },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    return try modelContext.fetch(descriptor)
  }

  func watchPost(_ post: SessionMessageEntity) -> some View {
    mediaBlock(post, isCovered: isCovered || activeSheet != nil)
      .background(LinkstrTheme.background)
      .clipped()
  }

  private func watchPostOverlay(
    _ post: SessionMessageEntity, saveAction: (() -> Void)?, hasNativePlayer: Bool
  ) -> some View {
    HStack(alignment: .bottom, spacing: 14) {
      watchCaption(post)
      watchActions(post, saveAction: saveAction)
    }
    .padding(.horizontal, 16)
    .background(alignment: .bottom) {
      if hasNativePlayer {
        LinearGradient(
          stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.76), location: 0.76),
                  .init(color: .clear, location: 1)],
          startPoint: .top, endPoint: .bottom
        )
        .padding(.top, -32)
        .padding(.bottom, -12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .padding(.bottom, (hasNativePlayer ? 65 : 20) + watchInsets.bottom)
    .foregroundStyle(LinkstrTheme.textPrimary)
    .buttonStyle(.plain)
    .zIndex(1)
  }

  private func watchCaption(_ post: SessionMessageEntity) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        LinkstrContactAvatar(name: sender, size: 29, seed: post.senderPubkeyHash)
        Text(sender)
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
          .lineLimit(1)
        Text(post.timestamp.linkstrActivityTimestampLabel)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .lineLimit(1)
      }
      if let caption = noteText ?? LinkstrPostPreview.title(for: post) {
        Button {
          activeSheet = .details
        } label: {
          Text(caption)
            .font(LinkstrTheme.font(.subheadline))
            .multilineTextAlignment(.leading)
            .lineLimit(3)
        }
        .accessibilityHint("open post details")
      }
      if let source = LinkstrPostPreview.source(for: post.url) {
        Text(source)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .lineLimit(1)
      }
      if !reactionSummaries.isEmpty {
        Button {
          activeSheet = .reactions
        } label: {
          HStack(spacing: 9) {
            ForEach(reactionSummaries.prefix(3)) { reaction in
              Text("\(reaction.emoji) \(reaction.count)")
            }
          }
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("view reactions")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func watchActions(_ post: SessionMessageEntity, saveAction: (() -> Void)?) -> some View {
    VStack(spacing: 9) {
      Button {
        activeSheet = .reactions
      } label: {
        WatchActionLabel(title: canReactToPost ? "react" : "reactions", icon: "face.smiling")
      }
      if let url = post.url.flatMap(URL.init(string:)) {
        Button {
          openURL(url)
        } label: {
          WatchActionLabel(title: "open", icon: "arrow.up.right.square")
        }
        .accessibilityLabel("open in browser")
      }
      Menu {
        Button("post details", systemImage: "info.circle") { activeSheet = .details }
        if canDelete && canReactToPost {
          Button(noteText == nil ? "add a note" : "edit note", systemImage: "pencil") {
            activeSheet = .editNote
          }
        }
        Button("refresh preview", systemImage: "arrow.clockwise") { refreshPostMetadata(post) }
          .disabled(isRefreshingMetadata)
        if shareDeepLinkURL != nil {
          Button("share link", systemImage: "square.and.arrow.up") { activeSheet = .share }
        }
        if let saveAction {
          Button("save video", systemImage: "square.and.arrow.down", action: saveAction)
        }
        if canDelete {
          Button("delete post", systemImage: "trash", role: .destructive, action: delete)
        }
      } label: {
        WatchActionLabel(title: "more", icon: "ellipsis")
      }
      .accessibilityLabel("more post actions")
    }
  }
}
