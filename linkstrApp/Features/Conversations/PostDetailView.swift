import LinkPresentation
import SwiftData
import SwiftUI
import UIKit

struct PostDetailView: View {
  @EnvironmentObject var session: AppSession
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.modelContext) var modelContext
  @Environment(\.openURL) var openURL

  let ownerPubkey: String
  let sessionID: String
  let sender: String
  let back: () -> Void
  let canDelete: Bool
  let watchInsets: EdgeInsets
  let isCovered: Bool
  let delete: () -> Void

  enum Sheet: String, Identifiable {
    case emojiPicker
    case editNote
    case share

    var id: Self { self }
  }

  @State private var headerHeight: CGFloat = 60
  @State var missingLinkControlsHeight: CGFloat = 120
  @State var activeSheet: Sheet?
  @State var detailsExpanded: Bool
  @State var selectedReactionEmoji: String?

  @State var contacts: [ContactEntity] = []
  @Query var posts: [SessionMessageEntity]
  @Query var reactions: [SessionReactionEntity]
  @Query var members: [SessionMemberEntity]
  @State var loadedPostText: (request: PostTextRequest, body: String)?
  @State var metadataRefreshRequest: UUID?
  @State var previewRefreshID = 0
  @State var mediaReloadID = 0

  init(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    sender: String,
    back: @escaping () -> Void,
    canDelete: Bool,
    watchInsets: EdgeInsets,
    isCovered: Bool,
    showsReactions: Bool,
    delete: @escaping () -> Void
  ) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.sender = sender
    self.back = back
    self.canDelete = canDelete
    self.watchInsets = watchInsets
    self.isCovered = isCovered
    self.delete = delete
    _detailsExpanded = State(initialValue: showsReactions)
    let storageID = SessionMessageEntity.storageID(ownerPubkey: ownerPubkey, eventID: postID)
    let rootKind = SessionMessageKind.root.rawValue
    _posts = Query(
      filter: #Predicate<SessionMessageEntity> {
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

  var contentInsets: EdgeInsets {
    EdgeInsets(
      top: watchInsets.top + headerHeight, leading: watchInsets.leading,
      bottom: watchInsets.bottom, trailing: watchInsets.trailing)
  }

  func postHeader(saveAction: (() -> Void)?, @ViewBuilder mediaMenu: () -> some View) -> some View {
    LinkstrPageTopBar(hasBackButton: true) {
      LinkstrHeaderButton(
        title: "back to posts", icon: "chevron.backward", foreground: LinkstrTheme.textPrimary, action: back)
    } actions: {
      if let saveAction {
        LinkstrHeaderButton(
          title: "save video", icon: "square.and.arrow.down", foreground: LinkstrTheme.textPrimary, action: saveAction)
      }
      if LinkstrPostPreview.webURL(for: post?.url) != nil {
        LinkstrHeaderButton(
          title: isRefreshingMetadata ? "refreshing post…" : "refresh post", icon: "arrow.clockwise",
          foreground: LinkstrTheme.textPrimary
        ) {
          metadataRefreshRequest = UUID()
        }
        .disabled(isRefreshingMetadata)
        .accessibilityHint("reloads the preview and retries playback")
      }
      if shareDeepLinkURL != nil {
        LinkstrHeaderButton(title: "share link", icon: "square.and.arrow.up", foreground: LinkstrTheme.textPrimary) {
          activeSheet = .share
        }
      }
      mediaMenu()
    }
    .linkstrPageHeaderLayout()
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      headerHeight = $0
    }
    .padding(.top, watchInsets.top)
    .background(reduceTransparency ? LinkstrTheme.background : LinkstrTheme.watchOverlay)
  }

  var isRefreshingMetadata: Bool { metadataRefreshRequest != nil }

  var body: some View {
    Group {
      if let post {
        watchPost(post)
          .environment(
            \.watchPanelBackground,
            reduceTransparency
              ? LinkstrTheme.background
              : (detailsExpanded ? LinkstrTheme.watchExpandedPanel : LinkstrTheme.watchOverlay))
      } else {
        LinkstrCenteredEmptyStateView(
          title: "post unavailable",
          systemImage: "exclamationmark.triangle",
          description: "return to the post list to keep browsing."
        )
        .background(LinkstrBackgroundView())
      }
    }
    .task(id: remotePostTextRequest) { await loadRemotePostText() }
    .task(id: metadataRefreshRequest) { await refreshPostMetadata() }
    .onDisappear { metadataRefreshRequest = nil }
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
    .onReceive(NotificationCenter.default.publisher(for: .linkstrWillPresentIncomingLink)) { _ in
      guard activeSheet == .emojiPicker else { return }
      activeSheet = nil
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .share:
        if let post, let shareDeepLinkURL {
          PostShareSheet(
            url: shareDeepLinkURL,
            title: LinkstrPostPreview.title(for: post) ?? LinkstrPostPreview.source(for: post.url) ?? "shared link"
          )
        }
      case .editNote:
        if let post { EditPostNoteSheet(post: post) }
      case .emojiPicker:
        emojiPicker
          .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
          .presentationDragIndicator(.visible)
      }
    }
  }

  private var emojiPicker: some View {
    LinkstrEmojiPickerSheet(summaries: reactionSummaries, onPick: toggleReaction)
  }

  func watchDetails(_ post: SessionMessageEntity) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      if remotePostText == nil, let title = LinkstrPostPreview.title(for: post) {
        Text(title)
          .font(LinkstrTheme.font(.headline))
          .accessibilityAddTraits(.isHeader)
          .textSelection(.enabled)
      }

      postCardNoteBlock

      if let editedAt = post.noteEditedAt {
        Text("note edited \(editedAt.linkstrMessageTimestampLabel)")
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if let destination = LinkstrPostPreview.webURL(for: post.url) {
        LinkstrURLText(address: destination.absoluteString)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct WatchPostBackdrop: View {
  let post: SessionMessageEntity

  var body: some View {
    GeometryReader { proxy in
      let width = min(max(1, proxy.size.width - 2 * LinkstrTheme.screenHorizontalPadding), 520)
      VStack(spacing: LinkstrTheme.rowSpacing) {
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

private struct PostShareSheet: UIViewControllerRepresentable {
  @Environment(\.dismiss) private var dismiss
  let url: URL
  let title: String

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let item = PostShareItem(url: url, title: title)
    let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
    return controller
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class PostShareItem: NSObject, UIActivityItemSource {
  let url: URL
  let title: String

  init(url: URL, title: String) {
    self.url = url
    self.title = title
  }

  func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
    url
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?
  ) -> Any? {
    url
  }

  func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
    let metadata = LPLinkMetadata()
    metadata.originalURL = url
    metadata.url = url
    metadata.title = title
    if let icon = UIImage(named: "LinkstrSplashIcon") {
      metadata.iconProvider = NSItemProvider(object: icon)
    }
    return metadata
  }
}
