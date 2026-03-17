import NostrSDK
import SwiftData
import SwiftUI
import UIKit

private struct SessionSummary: Identifiable {
  let id: String
  let session: SessionEntity
  let latestTimestamp: Date
  let latestPreview: String
  let latestNote: String?
  let hasUnread: Bool
}

struct ConversationsView: View {
  @EnvironmentObject private var session: AppSession
  @Binding var isShowingArchivedSessions: Bool
  let openSession: (String) -> Void
  @State private var query = ""

  @Query(sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)])
  private var allSessions: [SessionEntity]

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)])
  private var allMessages: [SessionMessageEntity]

  private var ownerPubkey: String? {
    session.identityService.pubkeyHex
  }

  private var ownerPubkeyHash: String? {
    guard let ownerPubkey else { return nil }
    return LocalDataCrypto.shared.digestHex(ownerPubkey)
  }

  private var scopedSessions: [SessionEntity] {
    guard let ownerPubkey else { return [] }
    return allSessions.filter { $0.ownerPubkey == ownerPubkey }
  }

  private var scopedMessages: [SessionMessageEntity] {
    guard let ownerPubkey else { return [] }
    return allMessages.filter { $0.ownerPubkey == ownerPubkey }
  }

  private var visibleSummaries: [SessionSummary] {
    let summaries = makeSummaries(
      sessions: scopedSessions,
      messages: scopedMessages,
      ownerPubkeyHash: ownerPubkeyHash
    )
    let archiveFilteredSummaries = summaries.filter { summary in
      isShowingArchivedSessions ? summary.session.isArchived : !summary.session.isArchived
    }

    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
      .localizedLowercase
    guard !normalizedQuery.isEmpty else { return archiveFilteredSummaries }

    return archiveFilteredSummaries.filter { summary in
      summary.session.name.localizedLowercase.contains(normalizedQuery)
        || summary.latestPreview.localizedLowercase.contains(normalizedQuery)
        || (summary.latestNote?.localizedLowercase.contains(normalizedQuery) ?? false)
    }
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .scrollContentBackground(.hidden)
  }

  @ViewBuilder
  private var content: some View {
    if scopedSessions.isEmpty {
      LinkstrCenteredEmptyStateView(
        title: "no sessions",
        systemImage: "rectangle.stack.badge.plus",
        description: "start a session. links you share will show up here."
      )
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          LinkstrSearchField(
            prompt: isShowingArchivedSessions ? "search archived sessions" : "search sessions",
            text: $query
          )

          if visibleSummaries.isEmpty {
            LinkstrCenteredEmptyStateView(
              title: isShowingArchivedSessions ? "no archived sessions" : "no sessions found",
              systemImage: isShowingArchivedSessions ? "archivebox" : "magnifyingglass",
              description: isShowingArchivedSessions
                ? "archive a session to move it here."
                : "try a different search or create a new session."
            )
            .frame(maxWidth: .infinity, minHeight: 220)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visibleSummaries) { summary in
                Button {
                  openSession(summary.session.sessionID)
                } label: {
                  SessionRowView(summary: summary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                  Button {
                    session.setSessionArchived(
                      sessionID: summary.session.sessionID,
                      archived: !summary.session.isArchived
                    )
                  } label: {
                    Label(
                      summary.session.isArchived ? "unarchive session" : "archive session",
                      systemImage: summary.session.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
      }
      .linkstrTabBarContentInset()
    }
  }

  private func hasUnreadIncomingRootPost(
    _ post: SessionMessageEntity,
    ownerPubkeyHash: String?
  ) -> Bool {
    guard let ownerPubkeyHash else { return false }
    return post.senderPubkeyHash != ownerPubkeyHash && post.readAt == nil
  }

  private func previewText(for post: SessionMessageEntity?) -> String {
    guard let post else { return "no posts yet" }
    if let title = post.metadataTitle, !title.isEmpty {
      return title
    }
    if let url = post.url, !url.isEmpty {
      return url
    }
    return "untitled post"
  }

  private func normalizedNote(_ note: String?) -> String? {
    guard let note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func makeSummaries(
    sessions: [SessionEntity],
    messages: [SessionMessageEntity],
    ownerPubkeyHash: String?
  ) -> [SessionSummary] {
    var aggregates:
      [String: (
        latestPost: SessionMessageEntity?,
        hasUnread: Bool
      )] = [:]
    aggregates.reserveCapacity(max(1, sessions.count))

    for message in messages where message.kind == .root {
      let key = message.conversationID
      var aggregate = aggregates[key] ?? (latestPost: nil, hasUnread: false)

      if aggregate.latestPost == nil {
        aggregate.latestPost = message
      }

      aggregate.hasUnread =
        aggregate.hasUnread
        || hasUnreadIncomingRootPost(message, ownerPubkeyHash: ownerPubkeyHash)
      aggregates[key] = aggregate
    }

    return
      sessions
      .compactMap { sessionEntity in
        let aggregate = aggregates[sessionEntity.sessionID]
        let latestPost = aggregate?.latestPost
        let latestTimestamp = latestPost?.timestamp ?? sessionEntity.updatedAt
        let latestPreview = previewText(for: latestPost)
        let latestNote = normalizedNote(latestPost?.note)
        let hasUnread = aggregate?.hasUnread ?? false

        return SessionSummary(
          id: sessionEntity.sessionID,
          session: sessionEntity,
          latestTimestamp: latestTimestamp,
          latestPreview: latestPreview,
          latestNote: latestNote,
          hasUnread: hasUnread
        )
      }
      .sorted { $0.latestTimestamp > $1.latestTimestamp }
  }
}

private struct SessionRowView: View {
  let summary: SessionSummary

  private var subtitle: String {
    if let latestNote = summary.latestNote {
      return latestNote
    }
    return summary.latestPreview
  }

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrSessionAvatar(
        seed: summary.session.sessionID,
        size: 50
      )

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        HStack(alignment: .firstTextBaseline, spacing: LinkstrTheme.buttonRowSpacing) {
          Text(summary.session.name)
            .font(LinkstrTheme.title(16, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(1)

          Spacer(minLength: 8)

          HStack(spacing: 6) {
            Text(summary.latestTimestamp.linkstrListTimestampLabel)
              .font(LinkstrTheme.body(11, weight: .medium))
              .foregroundStyle(LinkstrTheme.textTertiary)
              .lineLimit(1)
          }
        }

        HStack(alignment: .center, spacing: 8) {
          Text(subtitle)
            .font(LinkstrTheme.body(13))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(2)

          Spacer(minLength: 6)

          if summary.hasUnread {
            Circle()
              .fill(LinkstrTheme.accent)
              .frame(width: 8, height: 8)
              .accessibilityLabel("unread")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider(leadingInset: 62)
    }
  }
}

struct SessionPostsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var allContacts: [ContactEntity]

  @Query(sort: [SortDescriptor(\SessionMemberEntity.createdAt)])
  private var allMembers: [SessionMemberEntity]

  @Query(sort: [SortDescriptor(\SessionMemberIntervalEntity.startAt)])
  private var allMemberIntervals: [SessionMemberIntervalEntity]

  @Query(sort: [SortDescriptor(\SessionReactionEntity.updatedAt, order: .reverse)])
  private var allReactions: [SessionReactionEntity]

  let sessionEntity: SessionEntity

  @State private var isPresentingNewPost = false
  @State private var isPresentingMembers = false
  @State private var postPendingDelete: SessionMessageEntity?
  @State private var isPresentingDeleteConfirmation = false
  @State private var isDeletingPost = false

  private var scopedMessages: [SessionMessageEntity] {
    OwnerScopedCollections.messages(allMessages, ownerPubkey: session.identityService.pubkeyHex)
  }

  private var scopedContacts: [ContactEntity] {
    OwnerScopedCollections.contacts(allContacts, ownerPubkey: session.identityService.pubkeyHex)
      .sorted {
        session.resolvedIdentity(for: $0).displayName.localizedCaseInsensitiveCompare(
          session.resolvedIdentity(for: $1).displayName
        ) == .orderedAscending
      }
  }

  private var scopedMembers: [SessionMemberEntity] {
    OwnerScopedCollections.members(allMembers, ownerPubkey: session.identityService.pubkeyHex)
      .filter { $0.sessionID == sessionEntity.sessionID && $0.isActive }
  }

  private var scopedMemberIntervals: [SessionMemberIntervalEntity] {
    OwnerScopedCollections.memberIntervals(
      allMemberIntervals,
      ownerPubkey: session.identityService.pubkeyHex
    )
    .filter { $0.sessionID == sessionEntity.sessionID }
  }

  private var scopedReactions: [SessionReactionEntity] {
    OwnerScopedCollections.reactions(allReactions, ownerPubkey: session.identityService.pubkeyHex)
      .filter { $0.sessionID == sessionEntity.sessionID && $0.isActive }
  }

  private var canManageMembers: Bool {
    session.canManageMembers(for: sessionEntity)
  }

  private var canCreatePosts: Bool {
    session.isCurrentUserActiveMember(of: sessionEntity)
  }

  private var posts: [SessionMessageEntity] {
    scopedMessages
      .filter { $0.conversationID == sessionEntity.sessionID && $0.kind == .root }
      .sorted { $0.timestamp > $1.timestamp }
  }

  private var membershipChangeRows: [SessionMembershipChangeRow] {
    let myPubkey = session.identityService.pubkeyHex
    let intervals = scopedMemberIntervals.map {
      SessionMembershipTimelineInterval(
        memberPubkey: $0.memberPubkey,
        startAt: $0.startAt,
        endAt: $0.endAt
      )
    }
    return SessionMembershipTimelineBuilder.changes(from: intervals).map { change in
      let displayName: String
      if change.memberPubkey == myPubkey {
        displayName = "you"
      } else {
        displayName = session.displayName(for: change.memberPubkey, contacts: scopedContacts)
      }
      return SessionMembershipChangeRow(change: change, displayName: displayName)
    }
  }

  private var timelineRows: [SessionTimelineRow] {
    let entries =
      posts.map(SessionTimelineEntry.post)
      + membershipChangeRows.map(SessionTimelineEntry.membershipChange)
    let sortedEntries = entries.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp > rhs.timestamp
      }
      return lhs.sortPriority < rhs.sortPriority
    }

    return sortedEntries.enumerated().map { index, entry in
      switch entry {
      case .membershipChange(let change):
        return .membershipChange(change)
      case .post(let post):
        let previousPost = index > 0 ? sortedEntries[index - 1].post : nil
        let nextPost = index < sortedEntries.count - 1 ? sortedEntries[index + 1].post : nil
        return .post(
          PostListRow(
            post: post,
            senderLabel: senderLabel(for: post),
            isOutgoing: isOutgoing(post),
            showsSenderHeader: previousPost?.senderPubkey != post.senderPubkey,
            isFollowedBySameSender: nextPost?.senderPubkey == post.senderPubkey,
            hasUnreadPost: hasUnreadIncomingRootPost(post),
            reactionSummaries: reactionSummariesByPostID[post.rootID] ?? []
          )
        )
      }
    }
  }

  private var reactionSummariesByPostID: [String: [ReactionSummary]] {
    let reactionsByPostID = Dictionary(grouping: scopedReactions, by: \.postID)
    let myPubkey = session.identityService.pubkeyHex
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

  private var profileLookupPubkeys: [String] {
    var pubkeys = scopedContacts.map(\.targetPubkey)
    pubkeys.append(contentsOf: scopedMembers.map(\.memberPubkey))
    pubkeys.append(contentsOf: scopedMemberIntervals.map(\.memberPubkey))
    pubkeys.append(contentsOf: posts.map(\.senderPubkey))
    pubkeys.append(contentsOf: scopedReactions.map(\.senderPubkey))
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeys)
  }

  private var postCountLabel: String {
    posts.count == 1 ? "1 post" : "\(posts.count) posts"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
        if !posts.isEmpty {
          Text(postCountLabel)
            .font(LinkstrTheme.body(11, weight: .medium))
            .foregroundStyle(LinkstrTheme.textTertiary)
        }

        if !canCreatePosts {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.xmark")
              .font(LinkstrTheme.system(14, weight: .semibold))
              .foregroundStyle(LinkstrTheme.textSecondary)

            Text("you're no longer a member. this session is read-only.")
              .font(LinkstrTheme.body(12))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(
              cornerRadius: LinkstrTheme.fieldCornerRadius,
              style: .continuous
            )
            .fill(LinkstrTheme.panelMuted)
          )
          .overlay {
            RoundedRectangle(
              cornerRadius: LinkstrTheme.fieldCornerRadius,
              style: .continuous
            )
            .stroke(LinkstrTheme.separator.opacity(1.4), lineWidth: 1)
          }
        }

        if timelineRows.isEmpty {
          LinkstrCenteredEmptyStateView(
            title: "no posts yet",
            systemImage: "link.badge.plus",
            description: canCreatePosts
              ? "send a link to this session."
              : "you're no longer a member of this session."
          )
          .frame(maxWidth: .infinity, minHeight: 260)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(timelineRows) { row in
              timelineRow(row)
            }
          }
        }
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
    }
    .linkstrTabBarContentInset()
    .scrollContentBackground(.hidden)
    .background(LinkstrBackgroundView())
    .navigationTitle(sessionEntity.name)
    .navigationBarTitleDisplayMode(.inline)
    .linkstrBarChrome()
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          isPresentingMembers = true
        } label: {
          Image(systemName: "person.2")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel(canManageMembers ? "manage members" : "members")
        .tint(LinkstrTheme.accent)

        if canCreatePosts {
          Button {
            isPresentingNewPost = true
          } label: {
            Image(systemName: "square.and.pencil")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("new post")
          .tint(LinkstrTheme.accent)
        }
      }
    }
    .sheet(isPresented: $isPresentingNewPost) {
      NewPostSheet(sessionEntity: sessionEntity)
    }
    .sheet(isPresented: $isPresentingMembers) {
      SessionMembersSheet(sessionEntity: sessionEntity)
    }
    .alert("delete post", isPresented: $isPresentingDeleteConfirmation) {
      Button("delete post", role: .destructive) {
        guard let postPendingDelete, !isDeletingPost else { return }
        isDeletingPost = true
        Task {
          let didDelete = await session.deletePostAwaitingRelay(postPendingDelete)
          await MainActor.run {
            isDeletingPost = false
            if didDelete {
              self.postPendingDelete = nil
            }
          }
        }
      }
      Button("cancel", role: .cancel) {
        postPendingDelete = nil
      }
    } message: {
      Text(
        "this permanently removes the post from your session feed and sends a nostr deletion request."
      )
    }
    .task(id: profileLookupPubkeys.sorted()) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .onDisappear {
      session.cancelPendingMetadataRefreshesForHiddenSession()
    }
  }

  @ViewBuilder
  private func timelineRow(_ row: SessionTimelineRow) -> some View {
    switch row {
    case .post(let postListRow):
      postRow(postListRow)
    case .membershipChange(let changeRow):
      membershipChangeRow(changeRow)
    }
  }

  @ViewBuilder
  private func postRow(_ row: PostListRow) -> some View {
    let postLink = NavigationLink {
      PostDetailView(post: row.post, sessionName: sessionEntity.name)
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
    }
    .buttonStyle(.plain)
    .onAppear {
      session.markRootPostRead(postID: row.post.rootID)
      session.refreshMetadataForVisiblePostIfNeeded(row.post)
    }

    if row.isOutgoing {
      postLink
        .contextMenu {
          Button(role: .destructive) {
            guard !isDeletingPost else { return }
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

  private func membershipChangeRow(_ row: SessionMembershipChangeRow) -> some View {
    SessionMembershipChangeRowView(row: row)
  }

  private func isOutgoing(_ message: SessionMessageEntity) -> Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return message.senderPubkey == myPubkey
  }

  private func senderLabel(for message: SessionMessageEntity) -> String {
    if isOutgoing(message) {
      return "you"
    }
    return session.displayName(for: message.senderPubkey, contacts: scopedContacts)
  }

  private func hasUnreadIncomingRootPost(_ post: SessionMessageEntity) -> Bool {
    guard !isOutgoing(post) else { return false }
    return post.readAt == nil
  }
}

private struct PostListRow: Identifiable {
  let post: SessionMessageEntity
  let senderLabel: String
  let isOutgoing: Bool
  let showsSenderHeader: Bool
  let isFollowedBySameSender: Bool
  let hasUnreadPost: Bool
  let reactionSummaries: [ReactionSummary]

  var id: String { post.rootID }
}

private struct SessionMembershipChangeRow: Identifiable {
  let change: SessionMembershipTimelineChange
  let displayName: String

  var id: String { change.id }
}

private enum SessionTimelineEntry {
  case post(SessionMessageEntity)
  case membershipChange(SessionMembershipChangeRow)

  var timestamp: Date {
    switch self {
    case .post(let post):
      return post.timestamp
    case .membershipChange(let row):
      return row.change.timestamp
    }
  }

  var sortPriority: Int {
    switch self {
    case .membershipChange:
      return 0
    case .post:
      return 1
    }
  }

  var post: SessionMessageEntity? {
    guard case .post(let post) = self else { return nil }
    return post
  }
}

private enum SessionTimelineRow: Identifiable {
  case post(PostListRow)
  case membershipChange(SessionMembershipChangeRow)

  var id: String {
    switch self {
    case .post(let row):
      return row.id
    case .membershipChange(let row):
      return row.id
    }
  }
}

private struct PostListRowView: View {
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
          .font(LinkstrTheme.body(12, weight: .semibold))
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

private struct PostCardView: View {
  let post: SessionMessageEntity
  let isOutgoing: Bool
  let hasUnreadPost: Bool
  let reactionSummaries: [ReactionSummary]

  @State private var thumbnailImage: UIImage?

  var body: some View {
    HStack(alignment: .top, spacing: LinkstrTheme.rowSpacing) {
      thumbnailView

      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        Text(primaryText)
          .font(LinkstrTheme.title(15, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(2)

        if let noteText {
          Text(noteText)
            .font(LinkstrTheme.body(13))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(3)
        }

        HStack(alignment: .center, spacing: 6) {
          if hasUnreadPost {
            Circle()
              .fill(LinkstrTheme.accent)
              .frame(width: 7, height: 7)
          }

          Text(post.timestamp.linkstrListTimestampLabel)
            .font(LinkstrTheme.body(12, weight: .medium))
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
    .task(id: post.encryptedThumbnailURL) {
      guard
        let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: post.thumbnailURL)?.path
      else {
        thumbnailImage = nil
        return
      }
      thumbnailImage = ThumbnailImageCache.shared.loadImage(at: path)
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

  @ViewBuilder
  private var thumbnailView: some View {
    if let thumbnailImage {
      Image(uiImage: thumbnailImage)
        .resizable()
        .scaledToFill()
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else {
      thumbnailPlaceholder
    }
  }

  private var thumbnailPlaceholder: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(LinkstrTheme.panelMuted)
      .frame(width: 58, height: 58)
      .overlay {
        Image(systemName: "link")
          .font(LinkstrTheme.body(16))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
  }
}

private struct SessionMembershipChangeRowView: View {
  let row: SessionMembershipChangeRow

  private var markerLabel: String {
    switch row.change.kind {
    case .joined:
      return "in: \(row.displayName)"
    case .left:
      return "out: \(row.displayName)"
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      Rectangle()
        .fill(LinkstrTheme.separator)
        .frame(height: 1)

      Text(markerLabel)
        .font(LinkstrTheme.body(11, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)
        .lineLimit(1)

      Rectangle()
        .fill(LinkstrTheme.separator)
        .frame(height: 1)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(markerLabel)
    .accessibilityValue(row.change.timestamp.linkstrMessageTimestampLabel)
  }
}

struct SessionMembershipTimelineInterval: Equatable {
  let memberPubkey: String
  let startAt: Date
  let endAt: Date?
}

struct SessionMembershipTimelineChange: Identifiable, Equatable {
  enum Kind: String {
    case joined
    case left

    fileprivate var sortPriority: Int {
      switch self {
      case .joined:
        return 0
      case .left:
        return 1
      }
    }
  }

  let memberPubkey: String
  let timestamp: Date
  let kind: Kind

  var id: String {
    "\(memberPubkey):\(kind.rawValue):\(timestamp.timeIntervalSince1970)"
  }
}

enum SessionMembershipTimelineBuilder {
  static func changes(
    from intervals: [SessionMembershipTimelineInterval]
  ) -> [SessionMembershipTimelineChange] {
    guard let baselineTimestamp = intervals.map(\.startAt).min() else { return [] }

    var changes: [SessionMembershipTimelineChange] = []
    changes.reserveCapacity(intervals.count * 2)

    for interval in intervals {
      if interval.startAt > baselineTimestamp {
        changes.append(
          SessionMembershipTimelineChange(
            memberPubkey: interval.memberPubkey,
            timestamp: interval.startAt,
            kind: .joined
          )
        )
      }
      if let endAt = interval.endAt, endAt > baselineTimestamp {
        changes.append(
          SessionMembershipTimelineChange(
            memberPubkey: interval.memberPubkey,
            timestamp: endAt,
            kind: .left
          )
        )
      }
    }

    return changes.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp < rhs.timestamp
      }
      if lhs.kind != rhs.kind {
        return lhs.kind.sortPriority < rhs.kind.sortPriority
      }
      return lhs.memberPubkey < rhs.memberPubkey
    }
  }
}

struct NewSessionSheet: View {
  private enum Field: Hashable {
    case sessionName
    case search
  }

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession
  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var allContacts: [ContactEntity]

  @State private var sessionName = ""
  @State private var query = ""
  @State private var selectedNPubs = Set<String>()
  @State private var isCreating = false
  @State private var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState private var focusedField: Field?

  private var canCreateSession: Bool {
    !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var scopedContacts: [ContactEntity] {
    OwnerScopedCollections.contacts(allContacts, ownerPubkey: session.identityService.pubkeyHex)
  }

  private var profileLookupPubkeys: [String] {
    scopedContacts.map(\.targetPubkey)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrInsetSection(title: "session details") {
              TextField("session name", text: $sessionName)
                .font(LinkstrTheme.body(15))
                .focused($focusedField, equals: .sessionName)
                .textInputAutocapitalization(.words)
                .submitLabel(scopedContacts.isEmpty ? .done : .next)
                .onSubmit(handleSessionNameSubmit)
                .linkstrInputField()
            }

            LinkstrInsetSection(
              title: "members",
              accessory: "\(selectedNPubs.count + 1)"
            ) {
              LinkstrSearchField(
                prompt: "search contacts",
                text: $query,
                submitLabel: .done,
                onSubmit: dismissKeyboard
              )
              .focused($focusedField, equals: .search)

              if scopedContacts.isEmpty {
                Text("no contacts yet. solo still works.")
                  .font(LinkstrTheme.body(13))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              } else if filteredContacts.isEmpty {
                Text("no contacts match.")
                  .font(LinkstrTheme.body(13))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              } else {
                VStack(spacing: 0) {
                  ForEach(filteredContacts) { contact in
                    let identity = session.resolvedIdentity(for: contact)
                    Button {
                      toggle(contact.npub)
                    } label: {
                      HStack(spacing: LinkstrTheme.rowSpacing) {
                        LinkstrContactAvatar(name: identity.displayName, size: 38)
                        LinkstrContactIdentityView(
                          identity: identity,
                          primaryFont: LinkstrTheme.body(14, weight: .medium)
                        )

                        Spacer()

                        Image(
                          systemName: selectedNPubs.contains(contact.npub)
                            ? "checkmark.circle.fill" : "circle"
                        )
                        .font(LinkstrTheme.system(19, weight: .semibold))
                        .foregroundStyle(
                          selectedNPubs.contains(contact.npub)
                            ? LinkstrTheme.accent : LinkstrTheme.textTertiary
                        )
                      }
                      .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
                      .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if contact.id != filteredContacts.last?.id {
                      LinkstrListRowDivider(leadingInset: 50)
                    }
                  }
                }
              }
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .scrollDismissesKeyboard(.interactively)
        }
      }
      .navigationTitle("new session")
      .navigationBarTitleDisplayMode(.inline)
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("cancel")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isCreating)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button {
            createSession()
          } label: {
            if isCreating {
              ProgressView()
                .frame(width: 30, height: 30, alignment: .center)
            } else {
              Image(systemName: "plus.circle.fill")
                .linkstrToolbarIconLabel()
            }
          }
          .accessibilityLabel("create session")
          .tint(LinkstrTheme.accent)
          .disabled(isCreating || !canCreateSession)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let footerStatus {
          LinkstrSheetStatusFooter(
            message: footerStatus.message,
            messageColor: footerStatus.color
          )
        }
      }
      .task(id: profileLookupPubkeys.sorted()) {
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
      }
      .onChange(of: sessionName) { _, _ in
        mutationFeedback.clear()
      }
    }
  }

  private var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isCreating,
      progressMessage: "waiting for relay reconnect before creating...",
      validationMessage: canCreateSession ? nil : "session name required."
    )
  }

  private var filteredContacts: [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      scopedContacts,
      query: query,
      displayName: { session.resolvedIdentity(for: $0).displayName },
      npub: \.npub,
      additionalNames: { session.searchableNames(for: $0) }
    )
  }

  private func toggle(_ npub: String) {
    mutationFeedback.clear()
    if selectedNPubs.contains(npub) {
      selectedNPubs.remove(npub)
    } else {
      selectedNPubs.insert(npub)
    }
  }

  private func createSession() {
    guard !isCreating else { return }
    guard canCreateSession else { return }
    dismissKeyboard()
    mutationFeedback.clear()
    let selected = Array(selectedNPubs)
    isCreating = true

    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.createSessionAwaitingRelay(
          name: sessionName,
          memberNPubs: selected
        )
      }
      isCreating = false
      if result.didSucceed {
        dismiss()
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }

  private func handleSessionNameSubmit() {
    if scopedContacts.isEmpty {
      createSession()
    } else {
      focusedField = .search
    }
  }

  private func dismissKeyboard() {
    focusedField = nil
  }
}

private struct SessionMembersSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession
  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var allContacts: [ContactEntity]
  @Query(sort: [SortDescriptor(\SessionMemberEntity.createdAt)])
  private var allMembers: [SessionMemberEntity]

  let sessionEntity: SessionEntity

  @State private var includedMemberHexes = Set<String>()
  @State private var query = ""
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrInsetSection(
              title: "current members",
              accessory: "\(visibleCurrentMembers.count + 1)"
            ) {
              if visibleCurrentMembers.isEmpty {
                Text("only you are in this session.")
                  .font(LinkstrTheme.body(13))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              } else {
                VStack(spacing: 0) {
                  ForEach(visibleCurrentMembers, id: \.self) { memberHex in
                    let identity = memberIdentity(for: memberHex)
                    HStack(spacing: LinkstrTheme.rowSpacing) {
                      LinkstrContactAvatar(
                        name: identity?.displayName ?? "you",
                        size: 38
                      )

                      if let identity {
                        LinkstrContactIdentityView(
                          identity: identity,
                          primaryFont: LinkstrTheme.body(14, weight: .medium)
                        )
                      } else {
                        Text("you")
                          .font(LinkstrTheme.body(14, weight: .medium))
                          .foregroundStyle(LinkstrTheme.textPrimary)
                      }

                      Spacer()

                      if canManageMembers {
                        Button(role: .destructive) {
                          includedMemberHexes.remove(memberHex)
                        } label: {
                          Image(systemName: "minus.circle.fill")
                            .font(LinkstrTheme.system(18, weight: .semibold))
                            .foregroundStyle(LinkstrTheme.destructive)
                            .frame(width: 28, height: 28, alignment: .center)
                        }
                        .accessibilityLabel("remove \(identity?.displayName ?? "member")")
                      }
                    }
                    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)

                    if memberHex != visibleCurrentMembers.last {
                      LinkstrListRowDivider(leadingInset: 50)
                    }
                  }
                }
              }
            }

            if canManageMembers {
              LinkstrInsetSection(title: "add from contacts") {
                LinkstrSearchField(prompt: "search contacts", text: $query)

                if scopedContacts.isEmpty {
                  Text("no contacts yet.")
                    .font(LinkstrTheme.body(13))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                } else if filteredContacts.isEmpty {
                  Text("no contacts match.")
                    .font(LinkstrTheme.body(13))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                } else {
                  VStack(spacing: 0) {
                    ForEach(filteredContacts) { contact in
                      let identity = session.resolvedIdentity(for: contact)
                      let contactHex = contact.targetPubkey
                      Button {
                        if includedMemberHexes.contains(contactHex) {
                          includedMemberHexes.remove(contactHex)
                        } else {
                          includedMemberHexes.insert(contactHex)
                        }
                      } label: {
                        HStack(spacing: LinkstrTheme.rowSpacing) {
                          LinkstrContactAvatar(name: identity.displayName, size: 38)
                          LinkstrContactIdentityView(
                            identity: identity,
                            primaryFont: LinkstrTheme.body(14, weight: .medium)
                          )

                          Spacer()

                          Image(
                            systemName: includedMemberHexes.contains(contactHex)
                              ? "checkmark.circle.fill" : "circle"
                          )
                          .font(LinkstrTheme.system(19, weight: .semibold))
                          .foregroundStyle(
                            includedMemberHexes.contains(contactHex)
                              ? LinkstrTheme.accent : LinkstrTheme.textTertiary
                          )
                        }
                        .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
                        .contentShape(Rectangle())
                      }
                      .buttonStyle(.plain)

                      if contact.id != filteredContacts.last?.id {
                        LinkstrListRowDivider(leadingInset: 50)
                      }
                    }
                  }
                }
              }
            } else {
              LinkstrInsetSection(title: "member permissions") {
                Text("only the session creator can add or remove members.")
                  .font(LinkstrTheme.body(13))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              }
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
        }
      }
      .navigationTitle("session members")
      .navigationBarTitleDisplayMode(.inline)
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel(canManageMembers ? "cancel" : "close")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isSaving)
        }
        if canManageMembers {
          ToolbarItem(placement: .confirmationAction) {
            Button {
              saveMembers()
            } label: {
              Image(systemName: "checkmark")
                .linkstrToolbarIconLabel()
            }
            .accessibilityLabel(isSaving ? "saving members" : "save members")
            .disabled(isSaving)
            .tint(LinkstrTheme.accent)
          }
        }
      }
      .task(id: profileLookupPubkeys.sorted()) {
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
      }
      .onAppear(perform: syncIncludedMembersIfNeeded)
      .onChange(of: activeMembers.map(\.memberPubkey).sorted()) { _, _ in
        syncIncludedMembersIfNeeded()
      }
    }
  }

  private var scopedContacts: [ContactEntity] {
    OwnerScopedCollections.contacts(allContacts, ownerPubkey: session.identityService.pubkeyHex)
      .sorted {
        session.resolvedIdentity(for: $0).displayName.localizedCaseInsensitiveCompare(
          session.resolvedIdentity(for: $1).displayName
        ) == .orderedAscending
      }
  }

  private var activeMembers: [SessionMemberEntity] {
    OwnerScopedCollections.members(allMembers, ownerPubkey: session.identityService.pubkeyHex)
      .filter { $0.sessionID == sessionEntity.sessionID && $0.isActive }
  }

  private var canManageMembers: Bool {
    session.canManageMembers(for: sessionEntity)
  }

  private var visibleCurrentMembers: [String] {
    let myPubkey = session.identityService.pubkeyHex
    return
      includedMemberHexes
      .filter { memberHex in
        guard let myPubkey else { return true }
        return memberHex != myPubkey
      }
      .sorted {
        session.displayName(for: $0, contacts: scopedContacts).localizedCaseInsensitiveCompare(
          session.displayName(for: $1, contacts: scopedContacts)
        ) == .orderedAscending
      }
  }

  private var filteredContacts: [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      scopedContacts,
      query: query,
      displayName: { session.resolvedIdentity(for: $0).displayName },
      npub: \.npub,
      additionalNames: { session.searchableNames(for: $0) }
    )
  }

  private var profileLookupPubkeys: [String] {
    var pubkeys = scopedContacts.map(\.targetPubkey)
    pubkeys.append(contentsOf: visibleCurrentMembers)
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeys)
  }

  private func memberIdentity(for pubkeyHex: String) -> LinkstrResolvedIdentity? {
    guard pubkeyHex != session.identityService.pubkeyHex else { return nil }
    return session.resolvedIdentity(for: pubkeyHex, contacts: scopedContacts)
  }

  private func saveMembers() {
    guard canManageMembers else {
      composeCreatorOnlyError()
      return
    }
    guard !isSaving else { return }
    isSaving = true

    let memberNPubs = includedMemberHexes.compactMap { PublicKey(hex: $0)?.npub }

    Task { @MainActor in
      let didSave = await session.updateSessionMembersAwaitingRelay(
        session: sessionEntity,
        memberNPubs: memberNPubs
      )
      isSaving = false
      if didSave {
        dismiss()
      }
    }
  }

  private func composeCreatorOnlyError() {
    session.composeError = "only the session creator can manage members."
  }

  private func syncIncludedMembersIfNeeded() {
    guard includedMemberHexes.isEmpty else { return }
    includedMemberHexes = Set(activeMembers.map(\.memberPubkey))
  }
}
