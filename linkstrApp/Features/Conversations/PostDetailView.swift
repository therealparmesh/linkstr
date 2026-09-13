import SwiftData
import SwiftUI

struct PostDetailView: View {
  @EnvironmentObject var session: AppSession
  @Environment(\.modelContext) var modelContext
  @Environment(\.openURL) var openURL

  let ownerPubkey: String
  let sessionID: String
  let postID: String

  @State var isPresentingEmojiPicker = false
  @State var contacts: [ContactEntity] = []
  @Query var posts: [SessionMessageEntity]
  @Query var reactions: [SessionReactionEntity]
  @Query var members: [SessionMemberEntity]
  @State var remotePostText: String?
  @State var isRefreshingMetadata = false
  @State var mediaReloadID = 0

  init(
    ownerPubkey: String,
    sessionID: String,
    postID: String
  ) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.postID = postID
    let storageID = SessionMessageEntity.storageID(ownerPubkey: ownerPubkey, eventID: postID)
    let rootKind = SessionMessageKind.root.rawValue
    _posts = Query(filter: #Predicate<SessionMessageEntity> {
      $0.storageID == storageID && $0.conversationID == sessionID && $0.kindRaw == rootKind
    })
    _reactions = Query(
      filter: #Predicate<SessionReactionEntity> {
        $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID
          && $0.postID == postID && $0.isActive
      },
      sort: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    _members = Query(
      filter: #Predicate<SessionMemberEntity> {
        $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID && $0.isActive
      },
      sort: [SortDescriptor(\.createdAt)]
    )
  }

  var post: SessionMessageEntity? {
    posts.first
  }

  var body: some View {
    Group {
      if let post {
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            postCardContent(post)
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
      } else {
        ContentUnavailableView(
          "post unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("this post is no longer available.")
        )
      }
    }
    .task(id: profileLookupPubkeys.stableTaskID) {
      contacts = (try? fetchContacts(senderPubkeys: Set(reactions.map(\.senderPubkey)))) ?? []
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .background(LinkstrBackgroundView())
    .linkstrBarChrome()
    .toolbar {
      if let post {
        ToolbarItemGroup(placement: .topBarTrailing) {
          metadataRefreshButton(for: post)
          if let shareDeepLinkURL {
            shareDeepLinkButton(for: shareDeepLinkURL)
          }
        }
      } else if let shareDeepLinkURL {
        ToolbarItem(placement: .topBarTrailing) {
          shareDeepLinkButton(for: shareDeepLinkURL)
        }
      }
    }
    .task(id: post?.storageID) {
      guard let post else { return }
      session.markRootPostRead(postID: post.rootID)
      session.refreshMetadataForVisiblePostIfNeeded(post)
      await PushNotificationService.shared.clearDeliveredNotifications(sessionID: sessionID, postID: post.rootID)
    }
    .task(id: remotePostTextRequestID) {
      remotePostText = await resolvedRemotePostText()
    }
    .sheet(isPresented: $isPresentingEmojiPicker) {
      LinkstrEmojiPickerSheet { emoji in
        toggleReaction(emoji)
      }
      .presentationDetents([.fraction(0.92)])
    }
  }
}
