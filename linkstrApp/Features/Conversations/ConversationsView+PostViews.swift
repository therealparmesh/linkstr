import SwiftUI
import UIKit

// MARK: - SessionPostsView Helpers

extension SessionPostsView {
  func timelineView(for sessionEntity: SessionEntity) -> some View {
    let contentState = contentState
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          LinkstrScreenTitle(title: sessionEntity.name)

          if contentState.postCount > 0 {
            Text(contentState.postCountLabel)
              .font(LinkstrTheme.font(.caption, weight: .medium))
              .foregroundStyle(LinkstrTheme.textTertiary)
          }

          if !contentState.canCreatePosts {
            LinkstrReadOnlyBanner()
          }

          if contentState.timelineRows.isEmpty {
            LinkstrCenteredEmptyStateView(
              title: "no posts yet",
              systemImage: "link.badge.plus",
              description: contentState.canCreatePosts
                ? "send a link to this session." : "you're no longer a member of this session.",
              actionTitle: contentState.canCreatePosts ? "share a link" : nil,
              actionSystemImage: "plus",
              action: contentState.canCreatePosts ? { isPresentingNewPost = true } : nil
            )
            .frame(maxWidth: .infinity, minHeight: 260)
          } else {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(contentState.timelineRows) { row in
                timelineRow(row)
                  .id(row.id)
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .onChange(of: pendingScrollPostID.map { target in rootPosts.contains { $0.rootID == target } } == true,
                initial: true) { _, isAvailable in
        guard isAvailable, let postID = pendingScrollPostID else { return }
        proxy.scrollTo(postID, anchor: .center)
        pendingScrollPostID = nil
      }
      .onScrollPhaseChange { _, phase in
        if phase == .tracking || phase == .interacting { pendingScrollPostID = nil }
      }
    }
  }

  private var contentState: SessionPostsContentState {
    let myPubkey = session.identityService.pubkeyHex
    let contactIndex = contactsByPubkey
    let reactionSummariesByPostID = makeReactionSummariesByPostID(
      reactions: reactions,
      myPubkey: myPubkey
    )
    let membershipRows = SessionMembershipTimelineBuilder.changes(
      from: memberIntervals.map {
        SessionMembershipTimelineInterval(
          memberPubkey: $0.memberPubkey,
          startAt: $0.startAt,
          endAt: $0.endAt
        )
      }
    ).map { change in
      let resolvedDisplayName: String
      if change.memberPubkey == myPubkey {
        resolvedDisplayName = "you"
      } else {
        resolvedDisplayName = displayName(
          for: change.memberPubkey,
          contactsByPubkey: contactIndex
        )
      }
      return SessionMembershipChangeRow(change: change, displayName: resolvedDisplayName)
    }
    let entries =
      rootPosts.map(SessionTimelineEntry.post)
      + membershipRows.map(SessionTimelineEntry.membershipChange)
    let sortedEntries = entries.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp > rhs.timestamp
      }
      return lhs.sortPriority < rhs.sortPriority
    }
    let timelineRows: [SessionTimelineRow] = sortedEntries.enumerated().map { index, entry in
      switch entry {
      case .membershipChange(let change):
        return .membershipChange(change)
      case .post(let post):
        let previousPost = index > 0 ? sortedEntries[index - 1].post : nil
        let nextPost = index < sortedEntries.count - 1 ? sortedEntries[index + 1].post : nil
        return .post(
          PostListRow(
            post: post,
            senderLabel: senderLabel(
              for: post,
              myPubkey: myPubkey,
              contactsByPubkey: contactIndex
            ),
            isOutgoing: isOutgoing(post, myPubkey: myPubkey),
            showsSenderHeader: previousPost?.senderPubkey != post.senderPubkey,
            isFollowedBySameSender: nextPost?.senderPubkey == post.senderPubkey,
            hasUnreadPost: hasUnreadIncomingRootPost(post, myPubkey: myPubkey),
            reactionSummaries: reactionSummariesByPostID[post.rootID] ?? []
          )
        )
      }
    }

    return SessionPostsContentState(
      canCreatePosts: canShareLinks,
      postCount: rootPosts.count,
      timelineRows: timelineRows
    )
  }

  var profileLookupPubkeys: [String] {
    NostrValueNormalizer.dedupedNormalizedPubkeyHexes(
      members.map(\.memberPubkey) + memberIntervals.map(\.memberPubkey)
        + rootPosts.map(\.senderPubkey) + reactions.map(\.senderPubkey)
    )
  }

  @ViewBuilder
  func timelineRow(_ row: SessionTimelineRow) -> some View {
    switch row {
    case .post(let postListRow):
      postRow(postListRow)
    case .membershipChange(let changeRow):
      SessionMembershipChangeRowView(row: changeRow)
    }
  }

  @ViewBuilder
  func postRow(_ row: PostListRow) -> some View {
    let postLink = Button {
      showPost(row.post.rootID)
    } label: {
      PostListRowView(
        post: row.post,
        senderLabel: row.senderLabel,
        isOutgoing: row.isOutgoing,
        showsSenderHeader: row.showsSenderHeader,
        isFollowedBySameSender: row.isFollowedBySameSender,
        hasUnreadPost: row.hasUnreadPost,
        reactionSummaries: row.reactionSummaries
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onAppear {
      session.refreshMetadataForVisiblePostIfNeeded(row.post)
    }

    if row.isOutgoing {
      postLink
        .contextMenu {
          Button(role: .destructive) {
            guard !isDeletingPost else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            postPendingDelete = row.post
            isPresentingDeleteConfirmation = true
          } label: {
            Label("delete post", systemImage: "trash")
          }
        }
        .accessibilityHint("long press for post actions.")
        .accessibilityAction(named: "delete post") {
          guard !isDeletingPost else { return }
          postPendingDelete = row.post
          isPresentingDeleteConfirmation = true
        }
    } else {
      postLink
    }
  }

  func makeReactionSummariesByPostID(
    reactions: [SessionReactionEntity],
    myPubkey: String?
  ) -> [String: [ReactionSummary]] {
    let reactionsByPostID = Dictionary(grouping: reactions, by: \.postID)
    var summariesByPostID: [String: [ReactionSummary]] = [:]
    summariesByPostID.reserveCapacity(reactionsByPostID.count)

    for (postID, reactionsForPost) in reactionsByPostID {
      summariesByPostID[postID] = ReactionSummary.summaries(
        from: reactionsForPost,
        myPubkey: myPubkey
      )
    }

    return summariesByPostID
  }

  func isOutgoing(_ message: SessionMessageEntity, myPubkey: String?) -> Bool {
    guard let myPubkey else { return false }
    return message.senderPubkey == myPubkey
  }

  func senderLabel(
    for message: SessionMessageEntity,
    myPubkey: String?,
    contactsByPubkey: [String: ContactEntity]
  ) -> String {
    if isOutgoing(message, myPubkey: myPubkey) {
      return "you"
    }
    return displayName(for: message.senderPubkey, contactsByPubkey: contactsByPubkey)
  }

  func displayName(
    for pubkeyHex: String,
    contactsByPubkey: [String: ContactEntity]
  ) -> String {
    let normalizedPubkey = NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
    if let contact = contactsByPubkey[normalizedPubkey] {
      return session.resolvedIdentity(for: contact).displayName
    }
    return LinkstrResolvedIdentity(
      localAlias: nil,
      chosenName: session.remoteProfilesByPubkey[normalizedPubkey]?.chosenName,
      pubkeyHex: normalizedPubkey
    ).displayName
  }

  func hasUnreadIncomingRootPost(
    _ post: SessionMessageEntity, myPubkey: String?
  ) -> Bool {
    guard !isOutgoing(post, myPubkey: myPubkey) else { return false }
    return post.readAt == nil
  }

  func dismissIfSessionWasDeleted() {
    if sessionEntity != nil {
      hadResolvedSession = true
      return
    }
    guard hadResolvedSession else { return }
    isPresentingNewPost = false
    isPresentingMembers = false
    postPendingDelete = nil
    isPresentingDeleteConfirmation = false
    dismiss()
  }
}

// MARK: - Post Card Views

struct PostListRowView: View {
  let post: SessionMessageEntity
  let senderLabel: String
  let isOutgoing: Bool
  let showsSenderHeader: Bool
  let isFollowedBySameSender: Bool
  let hasUnreadPost: Bool
  let reactionSummaries: [ReactionSummary]

  private var bottomSpacing: CGFloat {
    isFollowedBySameSender ? 6 : 14
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showsSenderHeader {
        Text(senderLabel)
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(
            isOutgoing
              ? LinkstrTheme.accent
              : LinkstrAvatarStyleResolver.sessionColor(for: post.senderPubkey)
          )
          .lineLimit(1)
          .padding(.horizontal, LinkstrTheme.rowSpacing)
      }

      PostCardView(
        post: post,
        isOutgoing: isOutgoing,
        hasUnreadPost: hasUnreadPost,
        reactionSummaries: reactionSummaries
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, bottomSpacing)
    .accessibilityCustomContent(LocalizedStringKey("sender"), senderLabel)
  }
}

struct PostCardView: View {
  let post: SessionMessageEntity
  let isOutgoing: Bool
  let hasUnreadPost: Bool
  let reactionSummaries: [ReactionSummary]

  var body: some View {
    HStack(alignment: .top, spacing: LinkstrTheme.rowSpacing) {
      LinkstrPostThumbnail(post: post, width: 58, height: 58)

      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        Text(primaryText)
          .font(LinkstrTheme.font(.headline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(2)

        if let noteText {
          Text(noteText)
            .font(LinkstrTheme.font(.footnote))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(3)
        }

        HStack(alignment: .center, spacing: 6) {
          if hasUnreadPost {
            Circle()
              .fill(LinkstrTheme.accent)
              .frame(width: 7, height: 7)
              .accessibilityLabel("unread")
          }

          Text(post.timestamp.linkstrListTimestampLabel)
            .font(LinkstrTheme.font(.caption, weight: .medium))
            .foregroundStyle(LinkstrTheme.textTertiary)
            .lineLimit(1)
        }

        if !reactionSummaries.isEmpty {
          LinkstrReactionRow(
            summaries: reactionSummaries,
            mode: .readOnly,
            onToggleEmoji: nil,
            onAddReaction: nil
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(isOutgoing ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(
          isOutgoing ? LinkstrTheme.accent.opacity(0.22) : LinkstrTheme.separator, lineWidth: 1)
    }
  }

  private var primaryText: String {
    if let title = post.metadataTitle, !title.isEmpty {
      return title
    }
    if let url = post.url, !url.isEmpty {
      return url
    }
    return "untitled post"
  }

  private var noteText: String? {
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
