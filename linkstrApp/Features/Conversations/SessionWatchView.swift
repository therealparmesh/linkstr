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

  func watchView() -> some View {
    GeometryReader { proxy in
      watchPager(insets: proxy.safeAreaInsets)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .simultaneousGesture(
          DragGesture(minimumDistance: 20)
            .onEnded { value in
              guard value.startLocation.x <= 24,
                value.translation.width >= 80,
                value.translation.width > abs(value.translation.height) * 2
              else { return }
              browsePosts(around: activeWatchPostID ?? watchPostID)
            }
        )
    }
  }

  private func watchPager(insets: EdgeInsets) -> some View {
    ScrollViewReader { proxy in
      watchPages(insets: insets)
        .onGeometryChange(for: CGSize.self) {
          $0.size
        } action: { previous, current in
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
          back: { browsePosts(around: post.rootID) },
          canDelete: post.senderPubkey == ownerPubkey,
          watchInsets: insets,
          isCovered: isPaging || isPresentingMembers || isPresentingNewPost || isPresentingDeleteConfirmation,
          showsReactions: reactionShortcutPostID == post.rootID,
          delete: {
            guard !isDeletingPost else { return }
            postPendingDelete = post
            isPresentingDeleteConfirmation = true
          }
        )
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

  private func activateWatchPost(_ postID: String) {
    guard activeWatchPostID != postID else { return }
    activeWatchPostID = postID
    onWatchPositionChange(postID)
  }

  private func advanceWatch(by delta: Int) {
    guard let index = rootPosts.firstIndex(where: { $0.rootID == watchPostID }),
      rootPosts.indices.contains(index + delta)
    else { return }
    watchPostID = rootPosts[index + delta].rootID
  }
}
