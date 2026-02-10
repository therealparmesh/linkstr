import AVFoundation
import AVKit
import SafariServices
import SwiftData
import SwiftUI
import WebKit

struct ThreadView: View {
  private enum LocalPlaybackMode {
    case localPreferred
    case embedPreferred
  }

  private struct FullScreenWebItem: Identifiable {
    let id = UUID()
    let url: URL
  }

  @EnvironmentObject private var session: AppSession
  @Environment(\.openURL) private var openURL

  let post: SessionMessageEntity

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.displayName)])
  private var contacts: [ContactEntity]

  @State private var replyText = ""
  @State private var extractionState: ExtractionState?
  @State private var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State private var extractionFallbackReason: String?
  @State private var fullScreenWebItem: FullScreenWebItem?
  @FocusState private var isComposerFocused: Bool

  private var replies: [SessionMessageEntity] {
    allMessages.filter { $0.kind == .reply && $0.rootID == post.rootID }
  }

  private var threadTitle: String {
    guard let myPubkey = session.identityService.pubkeyHex else {
      return "Thread"
    }
    let other = post.senderPubkey == myPubkey ? post.receiverPubkey : post.senderPubkey
    return session.contactName(for: other, contacts: contacts)
  }

  private var hasUnreadIncomingReplies: Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return replies.contains { $0.senderPubkey != myPubkey && $0.readAt == nil }
  }

  private var mediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: post.url)
  }

  private var sourceURL: URL? {
    guard let urlString = post.url else { return nil }
    return URL(string: urlString)
  }

  private var mediaAspectRatio: CGFloat {
    guard let urlString = post.url, let sourceURL = URL(string: urlString) else {
      return 16.0 / 9.0
    }
    return URLClassifier.preferredMediaAspectRatio(for: sourceURL, strategy: mediaStrategy)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 10) {
          postCard
            .id("post-card")

          ForEach(replies) { reply in
            ReplyBubbleRow(
              text: reply.note ?? "",
              timestamp: reply.timestamp,
              isOutgoing: isOutgoing(reply)
            )
            .id(reply.eventID)
          }

          Color.clear
            .frame(height: 1)
            .id("bottom-anchor")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
      }
      .background(chatBackground)
      .safeAreaInset(edge: .bottom) {
        composerBar(proxy: proxy)
      }
      .navigationTitle(threadTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .fullScreenCover(item: $fullScreenWebItem) { item in
        FullScreenSafariView(url: item.url)
          .ignoresSafeArea()
      }
      .task {
        session.markPostRepliesRead(postID: post.rootID)
        await prepareMediaIfNeeded()
      }
      .onChange(of: replies.count) { _, _ in
        session.markPostRepliesRead(postID: post.rootID)
        scrollToBottom(using: proxy)
      }
    }
  }

  private var postCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(contentKindLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)

        Spacer()

        Text(post.timestamp.linkstrMessageTimestampLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if let title = post.metadataTitle, !title.isEmpty {
        Text(title)
          .font(.custom(LinkstrTheme.titleFont, size: 18))
          .foregroundStyle(LinkstrTheme.textPrimary)
      }

      if let url = post.url {
        Text(url)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
      }

      if let note = post.note, !note.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("NOTE")
            .font(.custom(LinkstrTheme.titleFont, size: 11))
            .foregroundStyle(LinkstrTheme.neonAmber)
          Text(note)
            .font(.custom(LinkstrTheme.bodyFont, size: 13))
            .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.94))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinkstrTheme.panelSoft)
        )
      }

      mediaBlock

      HStack(spacing: 8) {
        Image(systemName: "bubble.left.and.bubble.right")
          .foregroundStyle(LinkstrTheme.textSecondary)
        Text(replyCountLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)
        if hasUnreadIncomingReplies {
          Circle()
            .fill(LinkstrTheme.neonAmber)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread replies")
        }
      }
    }
    .padding(12)
    .linkstrNeonCard()
  }

  private var contentKindLabel: String {
    mediaStrategy.contentKindLabel
  }

  @ViewBuilder
  private var mediaBlock: some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      switch mediaStrategy {
      case .extractionPreferred(let embedURL):
        if localPlaybackMode == .embedPreferred {
          embedPlaybackBlock(embedURL: embedURL)
        } else {
          localPlaybackBlock(embedURL: embedURL)
        }
      case .embedOnly(let embedURL):
        mediaSurface {
          EmbeddedWebView(url: embedURL)
        }
      case .link:
        Button("Open in Safari") {
          openURL(url)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(LinkstrPrimaryButtonStyle())
      }
    }
  }

  private var chatBackground: some View {
    LinkstrBackgroundView()
  }

  private func composerBar(proxy: ScrollViewProxy) -> some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Write a reply", text: $replyText, axis: .vertical)
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .focused($isComposerFocused)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinkstrTheme.panelSoft)
        )
        .foregroundStyle(LinkstrTheme.textPrimary)

      Button {
        sendReply(using: proxy)
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 30))
          .foregroundStyle(LinkstrTheme.neonCyan)
      }
      .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(LinkstrTheme.panel.opacity(0.92))
  }

  private func sendReply(using proxy: ScrollViewProxy) {
    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    session.sendReply(text: text, post: post)
    replyText = ""
    isComposerFocused = false
    scrollToBottom(using: proxy)
  }

  private func scrollToBottom(using proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.25)) {
      proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
  }

  private func isOutgoing(_ message: SessionMessageEntity) -> Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return message.senderPubkey == myPubkey
  }

  private func prepareMediaIfNeeded() async {
    guard let urlString = post.url, let url = URL(string: urlString) else { return }
    guard mediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }

    if let path = post.cachedMediaPath, post.cachedMediaSourceURL == urlString {
      let local = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: local.path) {
        extractionFallbackReason = nil
        extractionState = .ready(PlayableMedia(playbackURL: local, headers: [:], isLocalFile: true))
        return
      }
    }
    post.cachedMediaPath = nil
    post.cachedMediaSourceURL = nil

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(from: url)
    extractionState = result

    if case .ready(let media) = result, media.isLocalFile {
      post.cachedMediaPath = media.playbackURL.path
      post.cachedMediaSourceURL = urlString
      extractionFallbackReason = nil
    }

    if case .cannotExtract(let reason) = result {
      extractionFallbackReason = reason
      localPlaybackMode = .embedPreferred
    }
  }

  @ViewBuilder
  private func localPlaybackBlock(embedURL: URL) -> some View {
    switch extractionState {
    case .ready(let media):
      VStack(alignment: .leading, spacing: 8) {
        mediaSurface {
          InlineVideoPlayer(media: media)
        }
        Button("Use Embedded Player") {
          localPlaybackMode = .embedPreferred
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(LinkstrSecondaryButtonStyle())

        Button("Open Embed Fullscreen") {
          fullScreenWebItem = FullScreenWebItem(url: embedURL)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(LinkstrSecondaryButtonStyle())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .cannotExtract:
      embedPlaybackBlock(embedURL: embedURL)
    case nil:
      HStack(spacing: 8) {
        ProgressView()
        Text("Preparing video playback…")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 8)
    }
  }

  private func embedPlaybackBlock(embedURL: URL) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      mediaSurface {
        EmbeddedWebView(url: embedURL)
      }

      if let extractionFallbackReason {
        Text("Video playback unavailable: \(extractionFallbackReason)")
          .font(.footnote)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      Button("Try Local Playback") {
        Task {
          localPlaybackMode = .localPreferred
          if case .cannotExtract = extractionState {
            extractionState = nil
            extractionFallbackReason = nil
            await prepareMediaIfNeeded()
          }
        }
      }
      .frame(maxWidth: .infinity)
      .buttonStyle(LinkstrSecondaryButtonStyle())

      Button("Open Embed Fullscreen") {
        fullScreenWebItem = FullScreenWebItem(url: embedURL)
      }
      .frame(maxWidth: .infinity)
      .buttonStyle(LinkstrSecondaryButtonStyle())

      if let sourceURL {
        Button("Open Source in Safari") {
          openURL(sourceURL)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(LinkstrSecondaryButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func mediaSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity)
      .aspectRatio(mediaAspectRatio, contentMode: .fit)
      .background(LinkstrTheme.panelSoft)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var replyCountLabel: String {
    replies.count == 1 ? "1 reply" : "\(replies.count) replies"
  }
}

private struct ReplyBubbleRow: View {
  let text: String
  let timestamp: Date
  let isOutgoing: Bool

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      if isOutgoing { Spacer(minLength: 40) }

      VStack(alignment: .leading, spacing: 5) {
        Text(text)
          .font(.custom(LinkstrTheme.bodyFont, size: 14))
          .foregroundStyle(isOutgoing ? LinkstrTheme.bgBottom : LinkstrTheme.textPrimary)

        Text(timestamp.linkstrMessageTimestampLabel)
          .font(.caption2)
          .foregroundStyle(
            isOutgoing ? LinkstrTheme.bgBottom.opacity(0.76) : LinkstrTheme.textSecondary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isOutgoing ? LinkstrTheme.neonCyan : LinkstrTheme.panel)
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(
                isOutgoing
                  ? LinkstrTheme.neonCyan.opacity(0.38) : LinkstrTheme.neonPink.opacity(0.26),
                lineWidth: 1
              )
          )
          .shadow(color: LinkstrTheme.neonPink.opacity(isOutgoing ? 0.0 : 0.12), radius: 8, y: 2)
      )

      if !isOutgoing { Spacer(minLength: 40) }
    }
  }
}

private struct InlineVideoPlayer: View {
  let media: PlayableMedia
  @State private var player: AVPlayer?
  @State private var isShowingFullscreenPlayer = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let player {
          VideoPlayer(player: player)
            .onAppear { player.play() }
        } else {
          ProgressView()
        }
      }

      Button {
        isShowingFullscreenPlayer = true
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .padding(8)
          .background(
            Circle()
              .fill(LinkstrTheme.panel.opacity(0.84))
          )
      }
      .padding(8)
    }
    .fullScreenCover(isPresented: $isShowingFullscreenPlayer) {
      if let player {
        FullScreenAVPlayerView(player: player)
          .ignoresSafeArea()
          .background(Color.black)
      }
    }
    .task {
      let item: AVPlayerItem
      if media.headers.isEmpty {
        item = AVPlayerItem(url: media.playbackURL)
      } else {
        let asset = AVURLAsset(
          url: media.playbackURL, options: ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
        item = AVPlayerItem(asset: asset)
      }
      player = AVPlayer(playerItem: item)
    }
    .onDisappear {
      player?.pause()
    }
  }
}

private struct EmbeddedWebView: UIViewRepresentable {
  let url: URL

  final class Coordinator {
    var loadedURLString: String?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.allowsAirPlayForMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.isOpaque = false
    webView.backgroundColor = .clear
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    guard context.coordinator.loadedURLString != url.absoluteString else { return }
    context.coordinator.loadedURLString = url.absoluteString

    // Wrap provider URLs in an iframe so allowfullscreen is explicitly enabled.
    let html = """
      <!doctype html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            width: 100%;
            height: 100%;
            background: #000;
            overflow: hidden;
          }
          iframe {
            position: absolute;
            inset: 0;
            border: 0;
            width: 100%;
            height: 100%;
          }
        </style>
      </head>
      <body>
        <iframe
          src="\(url.absoluteString)"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen; web-share"
          allowfullscreen
          webkitallowfullscreen
          mozallowfullscreen
          referrerpolicy="no-referrer-when-downgrade">
        </iframe>
      </body>
      </html>
      """
    uiView.loadHTMLString(
      html, baseURL: URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")"))
  }
}

private struct FullScreenAVPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.showsPlaybackControls = true
    controller.entersFullScreenWhenPlaybackBegins = true
    controller.exitsFullScreenWhenPlaybackEnds = false
    controller.player = player
    player.play()
    return controller
  }

  func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
    uiViewController.player = player
  }
}

private struct FullScreenSafariView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let controller = SFSafariViewController(url: url)
    controller.dismissButtonStyle = .close
    return controller
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
