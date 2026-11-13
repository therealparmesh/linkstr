import SwiftUI

extension SessionPostsView {
  // Keep nested media reload IDs out of the pager's selected post.
  private struct WatchPageID: Hashable {
    let postID: String
  }

  private var watchPagePosition: Binding<WatchPageID?> {
    Binding(
      get: { watchPostID.map { WatchPageID(postID: $0) } },
      set: { watchPostID = $0?.postID }
    )
  }

  func watchView(for group: SessionEntity) -> some View {
    GeometryReader { proxy in
      ZStack(alignment: .top) {
        let safeArea = proxy.safeAreaInsets
        let contentInsets = EdgeInsets(
          top: safeArea.top + watchHeaderHeight, leading: safeArea.leading,
          bottom: safeArea.bottom, trailing: safeArea.trailing
        )
        watchPager(insets: contentInsets)
          .ignoresSafeArea(.container, edges: [.top, .bottom])
        watchHeader(group, topInset: safeArea.top)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { watchHeaderHeight = $0 }
      }
    }
  }

  private func watchPager(insets: EdgeInsets) -> some View {
    ScrollViewReader { proxy in
      watchPages(insets: insets)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { previous, current in
          guard previous != .zero, previous != current, let watchPostID else { return }
          proxy.scrollTo(WatchPageID(postID: watchPostID), anchor: .top)
        }
        .onAppear {
          guard let watchPostID, rootPosts.contains(where: { $0.rootID == watchPostID }) else { return }
          proxy.scrollTo(WatchPageID(postID: watchPostID), anchor: .top)
        }
    }
  }

  private func watchPages(insets: EdgeInsets) -> some View {
    ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        ForEach(rootPosts, id: \.rootID) { post in
          watchPage(post, insets: insets)
          .id(WatchPageID(postID: post.rootID))
        }
      }
      .scrollTargetLayout()
    }
    .scrollIndicators(.hidden)
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: watchPagePosition, anchor: .center)
    .defaultScrollAnchor(.top, for: .alignment)
    .background(LinkstrTheme.background)
    .onChange(of: rootPosts.map(\.rootID), initial: true) { previous, current in
      guard let first = current.first else { return }
      if let watchPostID, current.contains(watchPostID) { return }
      let index = watchPostID.flatMap { previous.firstIndex(of: $0) } ?? 0
      watchPostID = current.indices.contains(index) ? current[index] : current.last ?? first
    }
    .onChange(of: watchPostID, initial: true) { _, postID in
      if !isPaging, let postID { activateWatchPost(postID) }
    }
    .onScrollPhaseChange { _, phase in
      isPaging = phase != .idle
      if !isPaging, let watchPostID { activateWatchPost(watchPostID) }
    }
    .onDisappear {
      isPaging = false
      activeWatchPostID = nil
    }
    .accessibilityScrollAction { edge in
      switch edge {
      case .top: advanceWatch(by: -1)
      case .bottom: advanceWatch(by: 1)
      default: break
      }
    }
  }

  private func watchPage(_ post: SessionMessageEntity, insets: EdgeInsets) -> some View {
    let selectedPostID = activeWatchPostID ?? watchPostID ?? rootPosts.first?.rootID
    return Group {
      if post.rootID == selectedPostID {
        PostDetailView(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          postID: post.rootID,
          sender: senderLabel(for: post, myPubkey: ownerPubkey, contactsByPubkey: contactsByPubkey),
          canDelete: post.senderPubkey == ownerPubkey,
          watchInsets: insets,
          isCovered: isPaging || isPresentingMembers || isPresentingNewPost || isPresentingDeleteConfirmation,
          showsReactions: reactionShortcutPostID == post.rootID
        ) {
          guard !isDeletingPost else { return }
          postPendingDelete = post
          isPresentingDeleteConfirmation = true
        }
        .onAppear {
          if reactionShortcutPostID == post.rootID { reactionShortcutPostID = nil }
        }
      } else {
        WatchPostBackdrop(post: post)
          .accessibilityHidden(true)
      }
    }
    .containerRelativeFrame([.horizontal, .vertical])
  }

  private func watchHeader(_ group: SessionEntity, topInset: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.tightSpacing) {
      LinkstrPageTopBar {
        watchBackButton
      } actions: {
        watchHeaderActions
      }
      watchSessionTitle(group)
    }
    .font(LinkstrTheme.font(.body, weight: .semibold))
    .buttonStyle(.plain)
    .foregroundStyle(LinkstrTheme.textPrimary)
    .linkstrPageHeaderLayout()
    .background(alignment: .top) {
      LinearGradient(
        stops: [
          .init(color: LinkstrTheme.background.opacity(0.72), location: 0),
          .init(color: LinkstrTheme.background.opacity(0.52), location: 0.72),
          .init(color: LinkstrTheme.background.opacity(0), location: 1)
        ], startPoint: .top, endPoint: .bottom
      )
      .padding(.top, -topInset)
      .padding(.bottom, -22)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private func watchSessionTitle(_ group: SessionEntity) -> some View {
    Button {
      isPresentingMembers = true
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
          .font(LinkstrTheme.font(verticalSizeClass == .compact ? .headline : .title2, weight: .bold))
          .lineLimit(dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact ? 2 : 1)
        HStack(spacing: LinkstrTheme.metaSpacing) {
          Text(canShareLinks ? memberCountLabel : "read-only session")
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)
          LinkstrDisclosureIndicator()
        }
      }
      .multilineTextAlignment(.leading)
      .frame(minHeight: LinkstrTheme.minimumInteractiveDimension, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityHint(canManageSession ? "manage session" : "view members")
  }

  @ViewBuilder
  private var watchHeaderActions: some View {
    watchPostsButton

    if canShareLinks {
      LinkstrHeaderButton(title: "share a link", icon: "plus", foreground: LinkstrTheme.textPrimary) {
        isPresentingNewPost = true
      }
    }
  }

  private var watchBackButton: some View {
    LinkstrHeaderButton(
      title: "back to posts", icon: "chevron.backward", foreground: LinkstrTheme.textPrimary
    ) {
      browsePosts(around: watchPostID)
    }
    .accessibilityHint("return to the post you were viewing")
  }

  private var watchPostsButton: some View {
    LinkstrHeaderButton(
      title: "all session posts", icon: "list.bullet", foreground: LinkstrTheme.textPrimary
    ) {
      browsePosts(around: nil)
    }
    .accessibilityHint("start at the newest posts")
    .contextMenu { watchNavigationActions }
    .accessibilityActions { watchNavigationActions }
  }

  @ViewBuilder
  private var watchNavigationActions: some View {
    if canMoveWatch(by: -1) {
      Button("previous post", systemImage: "chevron.up") { advanceWatch(by: -1) }
    }
    if canMoveWatch(by: 1) {
      Button("next post", systemImage: "chevron.down") { advanceWatch(by: 1) }
    }
    if hasUnreadLinks {
      Button("mark all as read", systemImage: "checkmark.circle") {
        session.markSessionRead(sessionID: sessionID, ownerPubkey: ownerPubkey)
      }
    }
  }

  private func activateWatchPost(_ postID: String) {
    guard activeWatchPostID != postID else { return }
    activeWatchPostID = postID
    onWatchPositionChange(postID)
  }

  private var memberCountLabel: String {
    members.count == 1 ? "1 member" : "\(members.count) members"
  }

  private func canMoveWatch(by delta: Int) -> Bool {
    guard let index = rootPosts.firstIndex(where: { $0.rootID == watchPostID }) else { return false }
    return rootPosts.indices.contains(index + delta)
  }

  private func advanceWatch(by delta: Int) {
    guard let index = rootPosts.firstIndex(where: { $0.rootID == watchPostID }),
      rootPosts.indices.contains(index + delta)
    else { return }
    watchPostID = rootPosts[index + delta].rootID
  }
}
