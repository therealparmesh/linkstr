import SwiftData
import SwiftUI

private struct SessionSummary: Identifiable {
  let id: String
  let session: SessionEntity
  let latestTimestamp: Date
  let latestPost: SessionMessageEntity?
  let preview: String
  let source: String?
  let memberAvatars: [SessionMemberAvatar]
  let unreadCount: Int
}

private struct SessionMemberAvatar: Identifiable {
  let id: String
  let name: String
}

struct ConversationsView: View {
  @EnvironmentObject private var appSession: AppSession
  @Binding var isShowingArchivedSessions: Bool
  let createSession: () -> Void
  let openSession: (String) -> Void
  private let ownerPubkeyHash: String

  @Query private var sessions: [SessionEntity]

  @Query private var rootMessages: [SessionMessageEntity]
  @Query private var members: [SessionMemberEntity]
  @Query private var contacts: [ContactEntity]

  init(
    ownerPubkey: String,
    isShowingArchivedSessions: Binding<Bool>,
    createSession: @escaping () -> Void,
    openSession: @escaping (String) -> Void
  ) {
    self._isShowingArchivedSessions = isShowingArchivedSessions
    self.createSession = createSession
    self.openSession = openSession
    self.ownerPubkeyHash = LocalDataCrypto.shared.digestHex(ownerPubkey)

    let rootKindRaw = SessionMessageKind.root.rawValue
    _sessions = Query(
      filter: #Predicate<SessionEntity> { session in
        session.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)]
    )
    _rootMessages = Query(
      filter: #Predicate<SessionMessageEntity> { message in
        message.ownerPubkey == ownerPubkey && message.kindRaw == rootKindRaw
      },
      sort: [
        SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse),
        SortDescriptor(\SessionMessageEntity.rootID, order: .reverse)
      ]
    )
    _members = Query(
      filter: #Predicate<SessionMemberEntity> { member in
        member.ownerPubkey == ownerPubkey && member.isActive
      },
      sort: [SortDescriptor(\SessionMemberEntity.createdAt), SortDescriptor(\SessionMemberEntity.storageID)]
    )
    _contacts = Query(filter: #Predicate<ContactEntity> { $0.ownerPubkey == ownerPubkey })
  }

  var body: some View {
    ConversationsContentView(
      hasSessions: !sessions.isEmpty,
      summaries: makeSummaries(),
      isShowingArchivedSessions: $isShowingArchivedSessions,
      hasArchivedSessions: sessions.contains(where: \.isArchived),
      createSession: createSession,
      openSession: openSession
    )
  }

  private func makeSummaries() -> [SessionSummary] {
    var latestPosts: [String: SessionMessageEntity] = [:]
    var unreadCounts: [String: Int] = [:]
    for post in rootMessages {
      if latestPosts[post.conversationID] == nil {
        latestPosts[post.conversationID] = post
      }
      if post.readAt == nil && !post.senderMatchesHash(ownerPubkeyHash) {
        unreadCounts[post.conversationID, default: 0] += 1
      }
    }

    let groupedMembers = Dictionary(
      grouping: members.filter { !$0.memberMatchesHash(ownerPubkeyHash) },
      by: \.sessionID
    )
    let contactIndex = Dictionary(contacts.map { ($0.targetPubkey, $0) }, uniquingKeysWith: { first, _ in first })
    return sessions.filter { $0.isArchived == isShowingArchivedSessions }
      .map { group in
        let post = latestPosts[group.sessionID]
        let source = post.flatMap { LinkstrPostPreview.source(for: $0.url) }
        let avatars = groupedMembers[group.sessionID, default: []].prefix(3).map { member in
          SessionMemberAvatar(id: member.memberPubkeyHash, name: displayName(member.memberPubkey, in: contactIndex))
        }
        return SessionSummary(
          id: group.sessionID,
          session: group,
          latestTimestamp: post?.timestamp ?? group.updatedAt,
          latestPost: post,
          preview: previewText(post, contacts: contactIndex),
          source: source,
          memberAvatars: avatars,
          unreadCount: unreadCounts[group.sessionID, default: 0]
        )
      }
      .sorted {
        $0.latestTimestamp == $1.latestTimestamp ? $0.id < $1.id : $0.latestTimestamp > $1.latestTimestamp
      }
  }

  private func displayName(_ pubkey: String, in index: [String: ContactEntity]) -> String {
    guard !pubkey.isEmpty else { return "member" }
    let identity = index[pubkey].map { appSession.resolvedIdentity(for: $0) }
      ?? appSession.resolvedIdentity(for: pubkey, contacts: [])
    return identity.showsNPubLine ? identity.displayName : "member"
  }

  private func previewText(_ post: SessionMessageEntity?, contacts: [String: ContactEntity]) -> String {
    guard let post else { return "no links yet" }
    let sender = post.senderMatchesHash(ownerPubkeyHash) ? "you" : displayName(post.senderPubkey, in: contacts)
    if let text = LinkstrPostPreview.text(post.note) ?? LinkstrPostPreview.title(for: post) {
      return "\(sender): \(text)"
    }
    let kind = LinkstrPostPreview.kind(for: post.url) ?? "link"
    return "\(sender) shared a \(kind)"
  }
}

private struct ConversationsContentView: View {
  let hasSessions: Bool
  let summaries: [SessionSummary]
  @Binding var isShowingArchivedSessions: Bool
  let hasArchivedSessions: Bool
  let createSession: () -> Void
  let openSession: (String) -> Void

  @State private var query = ""

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
  }

  private var isSearching: Bool {
    !normalizedQuery.isEmpty
  }

  private var visibleSummaries: [SessionSummary] {
    guard !normalizedQuery.isEmpty else { return summaries }
    return summaries.filter { summary in
      summary.session.name.localizedLowercase.contains(normalizedQuery)
        || summary.preview.localizedLowercase.contains(normalizedQuery)
        || [summary.latestPost?.metadataTitle, summary.latestPost?.url, summary.source]
          .compactMap { $0 }.contains { $0.localizedLowercase.contains(normalizedQuery) }
    }
  }

  private var emptyStateAction: (() -> Void)? {
    if isSearching {
      return { query = "" }
    }
    return isShowingArchivedSessions ? nil : createSession
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .scrollContentBackground(.hidden)
  }

  private var heading: some View {
    LinkstrTabHeader(title: isShowingArchivedSessions ? "archived" : "sessions") {
      if hasArchivedSessions {
        LinkstrHeaderButton(
          title: isShowingArchivedSessions ? "show active sessions" : "show archived sessions",
          icon: isShowingArchivedSessions ? "archivebox.fill" : "archivebox"
        ) {
          isShowingArchivedSessions.toggle()
        }
      }

      LinkstrHeaderButton(title: "new session", icon: "square.and.pencil", action: createSession)
    }
  }

  @ViewBuilder
  private var content: some View {
    if !hasSessions {
      VStack(spacing: 0) {
        heading
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
        LinkstrCenteredEmptyStateView(
          title: "no sessions",
          systemImage: "rectangle.stack.badge.plus",
          description: "create a private session to share links with your people.",
          actionTitle: "new session",
          actionSystemImage: "square.and.pencil",
          action: createSession
        )
      }
      .linkstrReadableContent()
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          heading

          if !summaries.isEmpty {
            LinkstrSearchField(
              prompt: isShowingArchivedSessions ? "search archived sessions" : "search sessions",
              text: $query
            )
          }

          if visibleSummaries.isEmpty {
            LinkstrCenteredEmptyStateView(
              title: isSearching
                ? "no sessions found"
                : isShowingArchivedSessions ? "no archived sessions" : "no active sessions",
              systemImage: isSearching
                ? "magnifyingglass"
                : isShowingArchivedSessions ? "archivebox" : "rectangle.stack.badge.plus",
              description: isSearching
                ? "try another search."
                : isShowingArchivedSessions
                  ? "archive a session to move it here."
                  : "start a new session or unarchive one.",
              actionTitle: isSearching
                ? "clear search"
                : isShowingArchivedSessions ? nil : "new session",
              actionSystemImage: isSearching ? "xmark.circle" : "square.and.pencil",
              action: emptyStateAction
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
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .linkstrKeyboardDismissal()
    }
  }
}

private struct SessionRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let summary: SessionSummary

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      avatarCluster

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(summary.session.name)
            .font(LinkstrTheme.font(.headline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)

          Text(summary.latestTimestamp.linkstrActivityTimestampLabel)
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
          if summary.unreadCount > 0 {
            Text(summary.unreadCount > 99 ? "99+" : String(summary.unreadCount))
              .font(LinkstrTheme.font(.caption2, weight: .bold).monospacedDigit())
              .foregroundStyle(LinkstrTheme.background)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(LinkstrTheme.accent, in: Capsule())
              .accessibilityLabel("\(summary.unreadCount) unread")
          }
        }

        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            Text(summary.preview)
              .font(LinkstrTheme.font(.subheadline))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let source = summary.source {
              Text(source)
                .font(LinkstrTheme.font(.caption))
                .foregroundStyle(LinkstrTheme.textSecondary.opacity(0.83))
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if let post = summary.latestPost, !dynamicTypeSize.isAccessibilitySize {
            LinkstrPostThumbnail(post: post, width: 47, height: 47)
          }
        }
      }
    }
    .padding(.vertical, 14)
    .frame(minHeight: 86)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) { LinkstrListRowDivider(leadingInset: 62) }
    .accessibilityElement(children: .combine)
  }

  private var avatarCluster: some View {
    ZStack {
      switch summary.memberAvatars.count {
      case 0:
        Image(systemName: "bookmark")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(LinkstrTheme.accent)
          .frame(width: 42, height: 42)
          .background(LinkstrTheme.panelElevated, in: Circle())
      case 1:
        avatar(summary.memberAvatars[0], size: 42)
      default:
        ForEach(Array(summary.memberAvatars.enumerated()), id: \.element.id) { index, member in
          avatar(member, size: 29)
            .overlay { Circle().strokeBorder(LinkstrTheme.background, lineWidth: 1.5) }
            .offset(
              x: index == 0 ? -9 : index == 1 ? 9 : 3,
              y: summary.memberAvatars.count == 2 ? 0 : index == 2 ? 9 : -8
            )
        }
      }
    }
    .frame(width: 50, height: 50)
    .accessibilityHidden(true)
  }

  private func avatar(_ member: SessionMemberAvatar, size: CGFloat) -> some View {
    LinkstrContactAvatar(name: member.name, size: size, seed: member.id)
  }
}
