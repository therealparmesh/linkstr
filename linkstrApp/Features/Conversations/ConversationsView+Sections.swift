import SwiftData
import SwiftUI
import UIKit
struct SessionPostsView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.verticalSizeClass) var verticalSizeClass
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
  @State var postPendingNoteEdit: SessionMessageEntity?
  @State var postPendingDelete: SessionMessageEntity?
  @State var isPresentingDeleteConfirmation = false
  @State var isDeletingPost = false
  @State var hadResolvedSession = false
  @State var pendingScrollPostID: String?

  @State var showsWatch: Bool
  @State var watchPostID: String?
  @State var activeWatchPostID: String?
  @State var reactionShortcutPostID: String?
  @State var isPaging = false
  @State var watchHeaderHeight: CGFloat = 54

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
      sort: [SortDescriptor(\SessionMemberEntity.createdAt), SortDescriptor(\SessionMemberEntity.storageID)]
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

  private var composerMemberAvatars: [SessionMemberAvatar] {
    SessionMemberAvatar.grouped(
      members, sessionIDs: [sessionID], ownerHash: LocalDataCrypto.shared.digestHex(ownerPubkey),
      contacts: contactsByPubkey, appSession: session
    )[sessionID, default: []]
  }

  func browsePosts(around postID: String?) {
    pendingScrollPostID = postID
    showsWatch = false
  }

  func showPost(_ postID: String, showsReactions: Bool = false) {
    pendingScrollPostID = nil
    reactionShortcutPostID = showsReactions ? postID : nil
    watchPostID = postID
    showsWatch = true
  }

  @ViewBuilder
  private var timelineHeaderActions: some View {
    if !rootPosts.isEmpty {
      LinkstrHeaderButton(title: "watch posts", icon: "play.rectangle") {
        let resumePost = rootPosts.first { $0.rootID == watchPostID }
        if let postID = (resumePost ?? rootPosts.first)?.rootID { showPost(postID) }
      }
    }
    LinkstrHeaderButton(title: canManageSession ? "manage session" : "view members", icon: "person.2") {
      isPresentingMembers = true
    }
    if canShareLinks, !rootPosts.isEmpty {
      LinkstrHeaderButton(title: "share a link", icon: "plus") { isPresentingNewPost = true }
    }
  }

  var body: some View {
    let sessionEntity = sessionEntity
    let isShowingWatch = sessionEntity != nil && showsWatch && !rootPosts.isEmpty
    ZStack {
      if let sessionEntity, isShowingWatch {
        watchView(for: sessionEntity)
          .transition(.opacity)
      } else if let sessionEntity {
        timelineView(for: sessionEntity)
          .linkstrPinnedPageHeader {
            LinkstrPageHeader(title: sessionEntity.name, backLabel: "back to sessions") { timelineHeaderActions }
          }
          .transition(.opacity)
      } else {
        LinkstrCenteredEmptyStateView(
          title: "session unavailable",
          systemImage: "exclamationmark.triangle",
          description: "return to sessions to choose another one.",
          actionTitle: "back to sessions",
          actionSystemImage: "chevron.backward",
          action: { dismiss() }
        )
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsWatch)
    .scrollContentBackground(.hidden)
    .background(LinkstrBackgroundView())

    .toolbarVisibility(.hidden, for: .navigationBar, .tabBar)
    .sheet(isPresented: $isPresentingNewPost) {
      if let sessionEntity {
        NewPostSheet(sessionEntity: sessionEntity, memberAvatars: composerMemberAvatars)
      }
    }
    .sheet(isPresented: $isPresentingMembers) {
      if let sessionEntity {
        SessionManagementSheet(sessionEntity: sessionEntity)
      }
    }
    .sheet(item: $postPendingNoteEdit) { post in
      EditPostNoteSheet(post: post)
    }
    .sheet(isPresented: $isPresentingDeleteConfirmation, onDismiss: { postPendingDelete = nil }, content: {
      LinkstrConfirmationSheet(
        title: "delete post",
        message: "linkstr sends a deletion request and removes this post from the session on this device.",
        onConfirm: {
          guard let postPendingDelete, !isDeletingPost else { return }
          UINotificationFeedbackGenerator().notificationOccurred(.warning)
          isDeletingPost = true
          Task {
            await session.deletePostAwaitingRelay(postPendingDelete)
            await MainActor.run {
              isDeletingPost = false
            }
          }
        }
      )
    })
    .task(id: profileLookupPubkeys.stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .onAppear {
      dismissIfSessionWasDeleted()
    }
    .onChange(of: sessionEntities.map(\.storageID).stableTaskID) { _, _ in
      dismissIfSessionWasDeleted()
    }
    .onChange(of: rootPosts.isEmpty) { _, isEmpty in
      guard isEmpty else { return }
      showsWatch = false
      watchPostID = nil
      reactionShortcutPostID = nil
      pendingScrollPostID = nil
    }
    .onDisappear {
      session.cancelPendingMetadataRefreshesForHiddenSession()
    }
  }
}

extension SessionPostsView {
  @ViewBuilder
  func timelinePostActions<Content: View>(_ postLink: Content, row: PostListRow) -> some View {
    if row.isOutgoing || !row.reactionSummaries.isEmpty {
      let noteActionTitle = LinkstrPostPreview.text(row.post.note) == nil ? "add a note" : "edit note"
      postLink
        .contextMenu {
          if !row.reactionSummaries.isEmpty {
            Button("view reactions", systemImage: "face.smiling") {
              showPost(row.post.rootID, showsReactions: true)
            }
          }
          if row.isOutgoing, canShareLinks {
            Button(noteActionTitle, systemImage: "pencil") {
              postPendingNoteEdit = row.post
            }
          }
          if row.isOutgoing {
            Button(role: .destructive) {
              confirmTimelinePostDeletion(row.post)
            } label: {
              Label("delete post", systemImage: "trash")
            }
          }
        }
        .accessibilityHint("long press for post actions.")
        .accessibilityActions {
          if !row.reactionSummaries.isEmpty {
            Button("view reactions") { showPost(row.post.rootID, showsReactions: true) }
          }
          if row.isOutgoing, canShareLinks {
            Button(noteActionTitle) {
              postPendingNoteEdit = row.post
            }
          }
          if row.isOutgoing {
            Button("delete post") { confirmTimelinePostDeletion(row.post) }
          }
        }
    } else {
      postLink
    }
  }

  private func confirmTimelinePostDeletion(_ post: SessionMessageEntity) {
    guard !isDeletingPost else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    postPendingDelete = post
    isPresentingDeleteConfirmation = true
  }
}
