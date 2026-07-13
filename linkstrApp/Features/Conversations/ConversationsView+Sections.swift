import SwiftData
import SwiftUI
import UIKit

struct SessionPostsView: View {
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var session: AppSession

  let ownerPubkey: String
  let sessionID: String

  @Query var sessionEntities: [SessionEntity]
  @Query var rootPosts: [SessionMessageEntity]
  @Query var contacts: [ContactEntity]
  @Query var members: [SessionMemberEntity]
  @Query var memberIntervals: [SessionMemberIntervalEntity]
  @Query var reactions: [SessionReactionEntity]

  @State var isPresentingNewPost = false
  @State var isPresentingMembers = false
  @State var postPendingDelete: SessionMessageEntity?
  @State var isPresentingDeleteConfirmation = false
  @State var isDeletingPost = false
  @State var hadResolvedSession = false

  init(ownerPubkey: String, sessionID: String) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID

    let rootKindRaw = SessionMessageKind.root.rawValue
    _sessionEntities = Query(
      filter: #Predicate<SessionEntity> { session in
        session.ownerPubkey == ownerPubkey && session.sessionID == sessionID
      },
      sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)]
    )
    _rootPosts = Query(
      filter: #Predicate<SessionMessageEntity> { message in
        message.ownerPubkey == ownerPubkey
          && message.conversationID == sessionID
          && message.kindRaw == rootKindRaw
      },
      sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)]
    )
    _contacts = Query(
      filter: #Predicate<ContactEntity> { contact in
        contact.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\ContactEntity.createdAt)]
    )
    _members = Query(
      filter: #Predicate<SessionMemberEntity> { member in
        member.ownerPubkey == ownerPubkey
          && member.sessionID == sessionID
          && member.isActive == true
      },
      sort: [SortDescriptor(\SessionMemberEntity.createdAt)]
    )
    _memberIntervals = Query(
      filter: #Predicate<SessionMemberIntervalEntity> { interval in
        interval.ownerPubkey == ownerPubkey && interval.sessionID == sessionID
      },
      sort: [SortDescriptor(\SessionMemberIntervalEntity.startAt)]
    )
    _reactions = Query(
      filter: #Predicate<SessionReactionEntity> { reaction in
        reaction.ownerPubkey == ownerPubkey
          && reaction.sessionID == sessionID
          && reaction.isActive == true
      },
      sort: [SortDescriptor(\SessionReactionEntity.updatedAt, order: .reverse)]
    )
  }

  var sessionEntity: SessionEntity? {
    sessionEntities.first
  }

  private var canManageSession: Bool {
    guard let sessionEntity else { return false }
    return session.canManageSession(for: sessionEntity)
  }

  var contactsByPubkey: [String: ContactEntity] {
    var contactsByPubkey: [String: ContactEntity] = [:]
    contactsByPubkey.reserveCapacity(contacts.count)

    for contact in contacts {
      contactsByPubkey[contact.targetPubkey] = contact
    }

    return contactsByPubkey
  }

  var body: some View {
    let sessionEntity = sessionEntity
    let contentState = contentState

    Group {
      if let sessionEntity {
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
            LinkstrScreenTitle(title: sessionEntity.name)

            if contentState.postCount > 0 {
              Text(contentState.postCountLabel)
                .font(LinkstrTheme.body(11, weight: .medium))
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
                  ? "send a link to this session."
                  : "you're no longer a member of this session."
              )
              .frame(maxWidth: .infinity, minHeight: 260)
            } else {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(contentState.timelineRows) { row in
                  timelineRow(row, sessionName: sessionEntity.name)
                }
              }
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
        }
      } else {
        ContentUnavailableView(
          "session unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("this session is no longer available.")
        )
      }
    }
    .linkstrTabBarContentInset()
    .scrollContentBackground(.hidden)
    .background(LinkstrBackgroundView())

    .linkstrBarChrome()
    .toolbar {
      if sessionEntity != nil {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            isPresentingMembers = true
          } label: {
            Image(systemName: "person.2")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel(canManageSession ? "manage session" : "members")
          .tint(LinkstrTheme.accent)

          if contentState.canCreatePosts {
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
    }
    .sheet(isPresented: $isPresentingNewPost) {
      if let sessionEntity {
        NewPostSheet(sessionEntity: sessionEntity)
      }
    }
    .sheet(isPresented: $isPresentingMembers) {
      if let sessionEntity {
        SessionManagementSheet(sessionEntity: sessionEntity)
      }
    }
    .alert("delete post", isPresented: $isPresentingDeleteConfirmation) {
      Button("delete post", role: .destructive) {
        guard let postPendingDelete, !isDeletingPost else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
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
    .task(id: contentState.profileLookupPubkeys.stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: contentState.profileLookupPubkeys)
    }
    .onAppear {
      dismissIfSessionWasDeleted()
    }
    .onChange(of: sessionEntities.map(\.storageID).stableTaskID) { _, _ in
      dismissIfSessionWasDeleted()
    }
    .onDisappear {
      session.cancelPendingMetadataRefreshesForHiddenSession()
    }
  }
}

// MARK: - Supporting Types
struct SessionPostsContentState {
  let canCreatePosts: Bool
  let postCount: Int
  let timelineRows: [SessionTimelineRow]
  let profileLookupPubkeys: [String]

  var postCountLabel: String {
    postCount == 1 ? "1 post" : "\(postCount) posts"
  }
}

struct PostListRow: Identifiable {
  let post: SessionMessageEntity
  let senderLabel: String
  let isOutgoing: Bool
  let showsSenderHeader: Bool
  let isFollowedBySameSender: Bool
  let hasUnreadPost: Bool
  let reactionSummaries: [ReactionSummary]

  var id: String { post.rootID }
}

struct SessionMembershipChangeRow: Identifiable {
  let change: SessionMembershipTimelineChange
  let displayName: String

  var id: String { change.id }
}

enum SessionTimelineEntry {
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

enum SessionTimelineRow: Identifiable {
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

struct SessionMembershipChangeRowView: View {
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
