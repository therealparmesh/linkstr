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
  @State private var pendingScrollPostID: String?

  init(ownerPubkey: String, sessionID: String, scrollToPostID: String? = nil) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    _pendingScrollPostID = State(initialValue: scrollToPostID)

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
        ScrollViewReader { proxy in
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
                  actionTitle: contentState.canCreatePosts ? "new post" : nil,
                  actionSystemImage: "square.and.pencil",
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
