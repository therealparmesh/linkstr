import SwiftUI

extension SessionPostsView {
  func watchView(for group: SessionEntity) -> some View {
    GeometryReader { proxy in
      ZStack(alignment: .top) {
        watchPager(insets: proxy.safeAreaInsets)
          .ignoresSafeArea(.container, edges: [.top, .bottom])
        watchHeader(group, topInset: proxy.safeAreaInsets.top)
      }
    }
  }

  private func watchPager(insets: EdgeInsets) -> some View {
    ScrollViewReader { proxy in
      watchPages(insets: insets)
        .onAppear {
          guard let watchPostID, rootPosts.contains(where: { $0.rootID == watchPostID }) else { return }
          proxy.scrollTo(watchPostID, anchor: .top)
        }
    }
  }

  private func watchPages(insets: EdgeInsets) -> some View {
    ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        ForEach(rootPosts, id: \.rootID) { post in
          watchPage(post, insets: insets)
          .id(post.rootID)
        }
      }
      .scrollTargetLayout()
    }
    .scrollIndicators(.hidden)
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $watchPostID, anchor: .center)
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
    Group {
      if post.rootID == activeWatchPostID {
        PostDetailView(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          postID: post.rootID,
          sender: senderLabel(for: post, myPubkey: ownerPubkey, contactsByPubkey: contactsByPubkey),
          canDelete: post.senderPubkey == ownerPubkey,
          watchInsets: insets,
          isCovered: isPaging || isPresentingMembers || isPresentingNewPost || isPresentingDeleteConfirmation
        ) {
          guard !isDeletingPost else { return }
          postPendingDelete = post
          isPresentingDeleteConfirmation = true
        }
      } else {
        WatchPostBackdrop(post: post)
          .accessibilityHidden(true)
      }
    }
    .containerRelativeFrame([.horizontal, .vertical])
  }

  private func watchHeader(_ group: SessionEntity, topInset: CGFloat) -> some View {
    HStack(spacing: 9) {
      watchBackButton

      Button {
        isPresentingMembers = true
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(group.name)
            .font(LinkstrTheme.font(.headline, weight: .semibold))
            .lineLimit(1)
          Text(canShareLinks ? memberCountLabel : "read only")
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .accessibilityHint(canManageSession ? "manage session" : "view members")

      Spacer(minLength: 0)

      watchPostsButton

      if canShareLinks {
        Button {
          isPresentingNewPost = true
        } label: {
          Image(systemName: "plus")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("share a link")
      }
    }
    .font(LinkstrTheme.font(.body, weight: .semibold))
    .buttonStyle(.plain)
    .foregroundStyle(LinkstrTheme.textPrimary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(alignment: .top) {
      LinearGradient(colors: [.black.opacity(0.86), .clear], startPoint: .top, endPoint: .bottom)
        .padding(.top, -topInset)
        .padding(.bottom, -30)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private var watchBackButton: some View {
    Button {
      if returnsToTimelineFromWatch {
        browsePosts()
      } else {
        dismiss()
      }
    } label: {
      Image(systemName: "chevron.left")
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(returnsToTimelineFromWatch ? "back to posts" : "back to sessions")
  }

  private var watchPostsButton: some View {
    Button(action: browsePosts) {
      Image(systemName: "list.bullet")
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("all session posts")
    .accessibilityHint("show the message list")
    .contextMenu {
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
