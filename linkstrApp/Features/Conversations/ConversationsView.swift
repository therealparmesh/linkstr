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

@MainActor
struct SessionMemberAvatar: Identifiable {
  let id: String
  let name: String

  static func grouped(
    _ members: [SessionMemberEntity], sessionIDs: Set<String>, ownerHash: String,
    contacts: [String: ContactEntity], appSession: AppSession
  ) -> [String: [Self]] {
    var result: [String: [Self]] = [:]
    for member in members where sessionIDs.contains(member.sessionID) {
      guard result[member.sessionID, default: []].count < 3, !member.memberMatchesHash(ownerHash) else { continue }
      let name = displayName(member.memberPubkey, contacts: contacts, appSession: appSession)
      result[member.sessionID, default: []].append(.init(id: member.memberPubkeyHash, name: name))
    }
    return result
  }

  static func displayName(_ pubkey: String, contacts: [String: ContactEntity], appSession: AppSession) -> String {
    guard !pubkey.isEmpty else { return "member" }
    let identity = contacts[pubkey].map { appSession.resolvedIdentity(for: $0) }
      ?? appSession.resolvedIdentity(for: pubkey, contacts: [])
    return identity.showsNPubLine ? identity.displayName : "member"
  }
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
    let visibleSessions = sessions.filter { $0.isArchived == isShowingArchivedSessions }
    guard !visibleSessions.isEmpty else { return [] }
    let visibleSessionIDs = Set(visibleSessions.map(\.sessionID))
    var latestPosts: [String: SessionMessageEntity] = [:]
    var unreadCounts: [String: Int] = [:]
    for post in rootMessages where visibleSessionIDs.contains(post.conversationID) {
      if latestPosts[post.conversationID] == nil {
        latestPosts[post.conversationID] = post
      }
      if post.readAt == nil && !post.senderMatchesHash(ownerPubkeyHash) {
        unreadCounts[post.conversationID, default: 0] += 1
      }
    }

    let contactIndex = Dictionary(contacts.map { ($0.targetPubkey, $0) }, uniquingKeysWith: { first, _ in first })
    let avatars = SessionMemberAvatar.grouped(
      members, sessionIDs: visibleSessionIDs, ownerHash: ownerPubkeyHash, contacts: contactIndex, appSession: appSession
    )
    return visibleSessions
      .map { group in
        let post = latestPosts[group.sessionID]
        let source = post.flatMap { LinkstrPostPreview.source(for: $0.url) }
        return SessionSummary(
          id: group.sessionID,
          session: group,
          latestTimestamp: post?.timestamp ?? group.updatedAt,
          latestPost: post,
          preview: previewText(post, contacts: contactIndex),
          source: source,
          memberAvatars: avatars[group.sessionID, default: []],
          unreadCount: unreadCounts[group.sessionID, default: 0]
        )
      }
      .sorted {
        $0.latestTimestamp == $1.latestTimestamp ? $0.id < $1.id : $0.latestTimestamp > $1.latestTimestamp
      }
  }

  private func previewText(_ post: SessionMessageEntity?, contacts: [String: ContactEntity]) -> String {
    guard let post else { return "no posts yet" }
    let sender = post.senderMatchesHash(ownerPubkeyHash)
      ? "you" : SessionMemberAvatar.displayName(post.senderPubkey, contacts: contacts, appSession: appSession)
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
    !summaries.isEmpty && !normalizedQuery.isEmpty
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
    return isShowingArchivedSessions ? nil : { isShowingArchivedSessions = true }
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .scrollContentBackground(.hidden)
    .onChange(of: isShowingArchivedSessions) { _, _ in query = "" }
  }

  private var heading: some View {
    LinkstrPageHeader(title: isShowingArchivedSessions ? "archived" : "sessions") {
      if hasArchivedSessions {
        LinkstrHeaderButton(
          title: isShowingArchivedSessions ? "view active sessions" : "view archived sessions",
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
      VStack(spacing: LinkstrTheme.listBlockSpacing) {
        heading
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.pageHeaderTopPadding)
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
                : isShowingArchivedSessions ? nil : "view archived sessions",
              actionSystemImage: isSearching ? "xmark.circle" : "archivebox",
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
        .padding(.top, LinkstrTheme.pageHeaderTopPadding)
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
    HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: LinkstrTheme.rowSpacing) {
      SessionAvatarCluster(members: summary.memberAvatars)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        if dynamicTypeSize.isAccessibilitySize {
          sessionName
          HStack(spacing: LinkstrTheme.compactSpacing) { sessionMetadata }
        } else {
          HStack(alignment: .firstTextBaseline, spacing: LinkstrTheme.compactSpacing) {
            sessionName
            sessionMetadata
          }
        }

        HStack(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing) {
          VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
            Text(summary.preview)
              .font(LinkstrTheme.font(.subheadline))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let source = summary.source {
              Text(source)
                .font(LinkstrTheme.font(.caption, weight: .medium))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if let post = summary.latestPost, !dynamicTypeSize.isAccessibilitySize {
            LinkstrPostThumbnail(post: post, width: 47, height: 47, size: .listRow)
          }
        }
      }
    }
    .padding(.vertical, LinkstrTheme.listBlockSpacing)
    .frame(minHeight: 86)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) { LinkstrListRowDivider(leadingInset: 62) }
    .accessibilityElement(children: .combine)
  }

  private var sessionName: some View {
    Text(summary.session.name)
      .font(LinkstrTheme.font(.headline, weight: .semibold))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var sessionMetadata: some View {
    Text(summary.latestTimestamp.linkstrActivityTimestampLabel)
      .font(LinkstrTheme.font(.caption))
      .foregroundStyle(LinkstrTheme.textSecondary)
      .lineLimit(1)
      .fixedSize()
    if summary.unreadCount > 0 {
      Text(summary.unreadCount > 99 ? "99+" : String(summary.unreadCount))
        .font(LinkstrTheme.font(.caption2, weight: .bold).monospacedDigit())
        .foregroundStyle(LinkstrTheme.background)
        .padding(.horizontal, LinkstrTheme.tightSpacing)
        .padding(.vertical, LinkstrTheme.metaSpacing)
        .background(LinkstrTheme.accent, in: Capsule())
        .accessibilityLabel("\(summary.unreadCount) unread")
    }
  }
}

struct SessionAvatarCluster: View {
  let members: [SessionMemberAvatar]

  var body: some View {
    ZStack {
      switch members.count {
      case 0:
        Image(systemName: "bookmark")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(LinkstrTheme.accent)
          .frame(width: 42, height: 42)
          .background(LinkstrTheme.panelElevated, in: Circle())
      case 1:
        avatar(members[0], size: 42)
      default:
        ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
          avatar(member, size: 29)
            .overlay { Circle().strokeBorder(LinkstrTheme.background, lineWidth: 1.5) }
            .offset(
              x: index == 0 ? -9 : index == 1 ? 9 : 3,
              y: members.count == 2 ? 0 : index == 2 ? 9 : -8
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
