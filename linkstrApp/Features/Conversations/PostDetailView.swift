import SwiftData
import SwiftUI

struct PostDetailView: View {
  @EnvironmentObject var session: AppSession
  @Environment(\.modelContext) var modelContext
  @Environment(\.openURL) var openURL

  let ownerPubkey: String
  let sessionID: String
  let sender: String
  let canDelete: Bool
  let watchInsets: EdgeInsets
  let isCovered: Bool
  let delete: () -> Void

  enum Sheet: String, Identifiable {
    case reactions
    case details
    case editNote

    var id: Self { self }
  }

  @State var activeSheet: Sheet?

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
    postID: String,
    sender: String,
    canDelete: Bool,
    watchInsets: EdgeInsets,
    isCovered: Bool,
    delete: @escaping () -> Void
  ) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.sender = sender
    self.canDelete = canDelete
    self.watchInsets = watchInsets
    self.isCovered = isCovered
    self.delete = delete
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
        watchPost(post)
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
    .task(id: post?.storageID) {
      guard let post else { return }
      session.markRootPostRead(postID: post.rootID)
      session.refreshMetadataForVisiblePostIfNeeded(post)
      await PushNotificationService.shared.clearDeliveredNotifications(sessionID: sessionID, postID: post.rootID)
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .editNote:
        if let post { EditPostNoteSheet(post: post) }
      case .details, .reactions:
        postSheet(showsReactions: sheet == .reactions)
      }
    }
  }

  private func postSheet(showsReactions: Bool) -> some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if showsReactions {
            postCardReadOnlyNotice
            postCardReactionRow
            postCardReactionBreakdown
            if reactionBreakdown.isEmpty {
              Text("no reactions yet")
                .font(LinkstrTheme.font(.subheadline))
                .foregroundStyle(LinkstrTheme.textSecondary)
            }
          } else if let post {
            postDetails(post)
          }
        }
        .padding(LinkstrTheme.screenHorizontalPadding)
        .linkstrReadableContent()
      }
      .background(LinkstrBackgroundView())
      .navigationTitle(showsReactions ? "reactions" : "post details")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("done") { activeSheet = nil }
        }
      }
      .sheet(isPresented: $isPresentingEmojiPicker) {
        LinkstrEmojiPickerSheet { emoji in toggleReaction(emoji) }
          .presentationDetents([.large])
      }
    }
    .presentationDetents(showsReactions ? [.medium, .large] : [.large])
    .presentationDragIndicator(.visible)
  }

  private func postDetails(_ post: SessionMessageEntity) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(sender), \(post.timestamp.linkstrMessageTimestampLabel)")
        .font(LinkstrTheme.font(.caption))
        .foregroundStyle(LinkstrTheme.textSecondary)

      if let title = LinkstrPostPreview.title(for: post) {
        Text(title)
          .font(LinkstrTheme.font(.title3, weight: .semibold))
      }

      postCardNoteBlock

      if let editedAt = post.noteEditedAt {
        Text("note edited \(editedAt.linkstrMessageTimestampLabel)")
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if let url = post.url, let destination = URL(string: url) {
        Text(url)
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
        Link(destination: destination) {
          LinkstrActionButtonLabel(title: "open original link", systemImage: "arrow.up.right")
        }
        .linkstrPrimaryButton()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: remotePostTextRequestID) { remotePostText = await resolvedRemotePostText() }
  }
}

struct WatchPostBackdrop: View {
  let post: SessionMessageEntity

  var body: some View {
    GeometryReader { proxy in
      let width = min(max(1, proxy.size.width - 36), 520)
      VStack(spacing: 12) {
        LinkstrPostThumbnail(post: post, width: width, height: max(1, min(width * 0.62, proxy.size.height * 0.43)))
        if let title = LinkstrPostPreview.title(for: post) ?? LinkstrPostPreview.source(for: post.url) {
          Text(title)
            .font(LinkstrTheme.font(.title3, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .frame(width: width)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.bottom, min(proxy.size.height * 0.12, 78))
    }
    .background(LinkstrTheme.background)
    .accessibilityHidden(true)
  }
}

struct WatchActionLabel: View {
  let title: String
  let icon: String

  var body: some View {
    VStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 21, weight: .medium))
      Text(title)
        .font(LinkstrTheme.font(.caption2, weight: .semibold))
        .lineLimit(1)
    }
    .frame(minWidth: 46, minHeight: 44)
    .contentShape(Rectangle())
  }
}
