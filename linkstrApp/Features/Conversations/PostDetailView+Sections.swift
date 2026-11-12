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
        let lhsIsCurrentUser = $0.id == myPubkeyHash
        let rhsIsCurrentUser = $1.id == myPubkeyHash
        if lhsIsCurrentUser != rhsIsCurrentUser { return lhsIsCurrentUser }
        let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
        return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
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
        if let remotePostText {
          Text(remotePostText)
            .font(LinkstrTheme.font(.subheadline))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        if let noteText {
          accentTextBlock(label: "note", text: noteText)
        }
      }
    }
  }

  @ViewBuilder
  func mediaBlock(_ post: SessionMessageEntity, isCovered: Bool) -> some View {
    if let url = LinkstrPostPreview.webURL(for: post.url) {
      AdaptiveMediaView(
        sourceURL: url,
        openSourceAction: { openURL(url) },
        reloadID: mediaReloadID,
        cachedCanonicalSourceURL: LinkstrPostPreview.webURL(for: post.cachedMediaSourceURL),
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
        immersive: true, isCovered: isCovered,
        watchInsets: watchInsets,
        postControlsSummary: controlsSummary(for: post),
        linkContent: {
          WatchLinkPreview(post: post, postText: remotePostText)
        },
        overlayContent: { saveAction in
          watchPostOverlay(post, saveAction: saveAction)
        }
      )
    } else {
      missingLinkPost(post)
    }
  }
  private func controlsSummary(for post: SessionMessageEntity) -> WatchPostSummary {
    WatchPostSummary(
      author: sender,
      timestamp: post.timestamp.linkstrMessageTimestampLabel,
      caption: remotePostText ?? LinkstrPostPreview.title(for: post) ?? noteText,
      note: noteText,
      reactions: reactionSummaries,
      toggleReaction: canReactToPost ? toggleReaction : nil,
      pickReaction: canReactToPost ? { activeSheet = .emojiPicker } : nil,
      openReactions: { emoji in
        selectedReactionEmoji = emoji
        activeSheet = .reactions
      },
      shareLink: shareDeepLinkURL == nil ? nil : { activeSheet = .share }
    )
  }

  private func missingLinkPost(_ post: SessionMessageEntity) -> some View {
    ZStack {
      ViewThatFits(in: .vertical) {
        missingLinkNotice(icon: "link")
          .padding(.vertical, LinkstrTheme.panelPadding)
          .fixedSize(horizontal: false, vertical: true)
        missingLinkNotice(icon: nil)
          .fixedSize(horizontal: false, vertical: true)
        ScrollView { missingLinkNotice(icon: nil) }
          .scrollBounceBehavior(.basedOnSize)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.top, watchInsets.top + 10)
      .padding(.bottom, watchInsets.bottom + missingLinkControlsHeight)
      WatchPostControls(
        summary: controlsSummary(for: post),
        topInset: watchInsets.top, bottomInset: watchInsets.bottom, playbackControlsHeight: 0,
        onReservedHeightChange: { missingLinkControlsHeight = $0 },
        content: { watchPostOverlay(post, saveAction: nil) }
      )
    }
  }

  private func missingLinkNotice(icon: String?) -> some View {
    LinkstrCenteredEmptyStateView(
      title: "link unavailable", systemImage: icon,
      description: noteText == nil
        ? "you can still view reactions for this post."
        : "you can still read the note and view reactions."
    )
  }

  func toggleReaction(_ emoji: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    Task { @MainActor in
      guard let post else { return }
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
    }
  }
  func refreshPostMetadata() async {
    guard let request = metadataRefreshRequest, let post else { return }
    defer {
      if metadataRefreshRequest == request { metadataRefreshRequest = nil }
    }
    let result = await session.refreshPostMetadata(post)
    guard !Task.isCancelled, metadataRefreshRequest == request, result != .interrupted else { return }
    guard clearPersistedLocalMedia(for: post) else { return }
    mediaReloadID += 1
    previewRefreshID += 1
    switch result {
    case .updated, .unchanged: LinkstrToast.showSuccess("post refreshed")
    case .unavailable: session.composeError = "retrying playback, but the preview couldn’t be refreshed."
    case .interrupted: break
    }
  }
  var noteText: String? {
    guard let post else { return nil }
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  struct PostTextRequest: Equatable {
    let url: URL
    let revision: Int
  }

  var remotePostText: String? {
    guard let loadedPostText, loadedPostText.request.url == remotePostTextRequest?.url else { return nil }
    return loadedPostText.body
  }

  var remotePostTextRequest: PostTextRequest? {
    guard let url = LinkstrPostPreview.webURL(for: post?.url),
      SocialPostResolutionService.supportsRemotePostText(for: url) else { return nil }
    return PostTextRequest(url: url, revision: previewRefreshID)
  }

  func loadRemotePostText() async {
    guard let request = remotePostTextRequest, loadedPostText?.request != request else { return }
    let sourceURL = await URLCanonicalizationService.shared.canonicalPlaybackURL(for: request.url)
    guard !Task.isCancelled, request == remotePostTextRequest else { return }
    let result = await SocialPostResolutionService.resolveRemotePostText(for: sourceURL)
    guard !Task.isCancelled, request == remotePostTextRequest,
      let body = LinkstrPostPreview.text(result) else { return }
    loadedPostText = (request, body)
  }

  func accentTextBlock(label: String, text: String) -> some View {
    HStack(alignment: .top, spacing: LinkstrTheme.rowSpacing) {
      Capsule(style: .continuous)
        .fill(LinkstrTheme.accent)
        .frame(width: 4)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(label)
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(LinkstrTheme.accent)

        Text(text)
          .font(LinkstrTheme.font(.subheadline))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 2)
  }

  @discardableResult
  func clearPersistedLocalMedia(for post: SessionMessageEntity) -> Bool {
    do {
      try session.messageStore.clearCachedMedia(messages: [post])
      return true
    } catch {
      session.report(error: error)
      return false
    }
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
    _ post: SessionMessageEntity, saveAction: (() -> Void)?
  ) -> some View {
    HStack(alignment: .top, spacing: LinkstrTheme.compactSpacing) {
      watchDetails(post)
      let canRefresh = LinkstrPostPreview.webURL(for: post.url) != nil
      if canRefresh || canDelete || saveAction != nil {
        Menu {
          if canRefresh {
            Button(isRefreshingMetadata ? "refreshing post…" : "refresh post", systemImage: "arrow.clockwise") {
              metadataRefreshRequest = UUID()
            }
            .disabled(isRefreshingMetadata)
            .accessibilityHint("reloads the preview and retries playback")
          }
          if canDelete && canReactToPost {
            Button(noteText == nil ? "add a note" : "edit note", systemImage: "pencil") {
              activeSheet = .editNote
            }
          }
          if let saveAction {
            Button("save video", systemImage: "square.and.arrow.down", action: saveAction)
          }
          if canDelete {
            Button("delete post", systemImage: "trash", role: .destructive, action: delete)
          }
        } label: {
          Group {
            if isRefreshingMetadata {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "ellipsis")
            }
          }
          .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("more post actions")
      }
    }
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .foregroundStyle(LinkstrTheme.textPrimary)
    .buttonStyle(.plain)
  }
}
