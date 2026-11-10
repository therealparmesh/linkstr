import SwiftData
import SwiftUI
import UIKit
struct SessionPostsView: View {
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var session: AppSession

  let ownerPubkey: String
  let sessionID: String
  let onWatchPositionChange: (String) -> Void

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
  @State var pendingScrollPostID: String?

  @State var showsWatch: Bool
  @State var returnsToTimelineFromWatch = false
  @State var watchPostID: String?
  @State var activeWatchPostID: String?
  @State var isPaging = false

  init(
    ownerPubkey: String, sessionID: String, scrollToPostID: String? = nil,
    startingWatchPostID: String? = nil, opensInWatch: Bool = false,
    onWatchPositionChange: @escaping (String) -> Void
  ) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.onWatchPositionChange = onWatchPositionChange
    _pendingScrollPostID = State(initialValue: scrollToPostID)
    _showsWatch = State(initialValue: opensInWatch)
    _watchPostID = State(initialValue: startingWatchPostID)

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
      sort: [SortDescriptor(\.timestamp, order: .reverse), SortDescriptor(\.rootID, order: .reverse)]
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

  var canManageSession: Bool {
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

  var canShareLinks: Bool {
    let ownerHash = LocalDataCrypto.shared.digestHex(ownerPubkey)
    return members.contains { $0.memberMatchesHash(ownerHash) }
  }

  var hasUnreadLinks: Bool {
    let ownerHash = LocalDataCrypto.shared.digestHex(ownerPubkey)
    return rootPosts.contains { $0.readAt == nil && !$0.senderMatchesHash(ownerHash) }
  }

  func browsePosts() {
    pendingScrollPostID = watchPostID
    showsWatch = false
  }

  func showPost(_ postID: String) {
    pendingScrollPostID = nil
    watchPostID = postID
    returnsToTimelineFromWatch = true
    showsWatch = true
  }

  var body: some View {
    let sessionEntity = sessionEntity
    Group {
      if let sessionEntity, showsWatch, !rootPosts.isEmpty {
        watchView(for: sessionEntity)
      } else if let sessionEntity {
        timelineView(for: sessionEntity)
      } else {
        ContentUnavailableView(
          "session unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("this session is no longer available.")
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(LinkstrBackgroundView())

    .linkstrBarChrome()
    .toolbarVisibility(showsWatch && !rootPosts.isEmpty ? .hidden : .visible, for: .navigationBar)
    .toolbarVisibility(.hidden, for: .tabBar)
    .toolbar {
      if sessionEntity != nil, !showsWatch || rootPosts.isEmpty {
        ToolbarItemGroup(placement: .topBarTrailing) {
          if !rootPosts.isEmpty {
            Button {
              if let postID = watchPostID ?? rootPosts.first?.rootID { showPost(postID) }
            } label: {
              Image(systemName: "play.rectangle")
                .linkstrToolbarIconLabel()
            }
            .accessibilityLabel("watch posts")
            .tint(LinkstrTheme.accent)
          }
          if hasUnreadLinks {
            Button {
              session.markSessionRead(sessionID: sessionID, ownerPubkey: ownerPubkey)
            } label: {
              Image(systemName: "checkmark.circle")
                .linkstrToolbarIconLabel()
            }
            .accessibilityLabel("mark all as read")
            .tint(LinkstrTheme.accent)
          }
          Button {
            isPresentingMembers = true
          } label: {
            Image(systemName: "person.2")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel(canManageSession ? "manage session" : "members")
          .tint(LinkstrTheme.accent)

          if canShareLinks {
            Button {
              isPresentingNewPost = true
            } label: {
              Image(systemName: "plus")
                .linkstrToolbarIconLabel()
            }
            .accessibilityLabel("share a link")
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
    .task(id: profileLookupPubkeys.stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
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
