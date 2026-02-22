import AVFoundation
import AVKit
import SwiftUI

struct InlineVideoPlayer: View {
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

struct AdaptiveVideoPlaybackView: View {
  private enum LocalPlaybackMode {
    case localPreferred
    case embedPreferred
  }

  let sourceURL: URL
  let showOpenSourceButtonInEmbedMode: Bool
  let openSourceAction: (() -> Void)?
  let resolveCachedLocalMedia: ((URL) -> PlayableMedia?)?
  let persistLocalMedia: ((URL, PlayableMedia) -> Void)?

  @State private var canonicalSourceURL: URL?
  @State private var extractionState: ExtractionState?
  @State private var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State private var extractionFallbackReason: String?

  init(
    sourceURL: URL,
    showOpenSourceButtonInEmbedMode: Bool = true,
    openSourceAction: (() -> Void)? = nil,
    resolveCachedLocalMedia: ((URL) -> PlayableMedia?)? = nil,
    persistLocalMedia: ((URL, PlayableMedia) -> Void)? = nil
  ) {
    self.sourceURL = sourceURL
    self.showOpenSourceButtonInEmbedMode = showOpenSourceButtonInEmbedMode
    self.openSourceAction = openSourceAction
    self.resolveCachedLocalMedia = resolveCachedLocalMedia
    self.persistLocalMedia = persistLocalMedia
  }

  var body: some View {
    content
      .task(id: sourceURL.absoluteString) {
        canonicalSourceURL = await URLCanonicalizationService.shared.canonicalPlaybackURL(
          for: sourceURL)
        extractionState = nil
        extractionFallbackReason = nil
        localPlaybackMode = .localPreferred
        await prepareMediaIfNeeded()
      }
  }

  @ViewBuilder
  private var content: some View {
    switch effectiveMediaStrategy {
    case .extractionPreferred(let embedURL):
      if localPlaybackMode == .embedPreferred {
        embedPlaybackBlock(embedURL: embedURL, allowsTryLocalPlayback: true)
      } else {
        extractionPlaybackBlock(embedURL: embedURL)
      }
    case .embedOnly(let embedURL):
      embedPlaybackBlock(embedURL: embedURL, allowsTryLocalPlayback: false)
    case .link:
      if let openSourceAction {
        Button("Open in Safari") {
          openSourceAction()
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(LinkstrPrimaryButtonStyle())
      } else {
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func extractionPlaybackBlock(embedURL: URL) -> some View {
    switch extractionState {
    case .ready(let media):
      VStack(alignment: .leading, spacing: 8) {
        mediaSurface {
          InlineVideoPlayer(media: media)
        }

        if let openSourceAction {
          HStack(spacing: 8) {
            Button {
              localPlaybackMode = .embedPreferred
            } label: {
              Text("Use Embedded")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LinkstrSecondaryButtonStyle())

            Button {
              openSourceAction()
            } label: {
              Text("Open in Safari")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LinkstrSecondaryButtonStyle())
          }
        } else {
          Button {
            localPlaybackMode = .embedPreferred
          } label: {
            Text("Use Embedded")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrSecondaryButtonStyle())
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

    case .cannotExtract:
      embedPlaybackBlock(embedURL: embedURL, allowsTryLocalPlayback: true)

    case nil:
      HStack(spacing: 8) {
        ProgressView()
        Text("Preparing video playback...")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 8)
    }
  }

  private func embedPlaybackBlock(embedURL: URL, allowsTryLocalPlayback: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      mediaSurface {
        EmbeddedWebView(url: embedURL)
      }

      if let extractionFallbackReason {
        Text("Video playback unavailable: \(extractionFallbackReason)")
          .font(.footnote)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      let canOpenSource = showOpenSourceButtonInEmbedMode && openSourceAction != nil

      if allowsTryLocalPlayback, let openSourceAction, canOpenSource {
        HStack(spacing: 8) {
          Button {
            Task {
              localPlaybackMode = .localPreferred
              extractionState = nil
              extractionFallbackReason = nil
              await prepareMediaIfNeeded()
            }
          } label: {
            Text("Try Local Playback")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrSecondaryButtonStyle())

          Button {
            openSourceAction()
          } label: {
            Text("Open in Safari")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrSecondaryButtonStyle())
        }
      } else if allowsTryLocalPlayback {
        Button {
          Task {
            localPlaybackMode = .localPreferred
            extractionState = nil
            extractionFallbackReason = nil
            await prepareMediaIfNeeded()
          }
        } label: {
          Text("Try Local Playback")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LinkstrSecondaryButtonStyle())
      } else if canOpenSource, let openSourceAction {
        Button {
          openSourceAction()
        } label: {
          Text("Open in Safari")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LinkstrSecondaryButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func mediaSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity)
      .aspectRatio(effectiveMediaAspectRatio, contentMode: .fit)
      .background(LinkstrTheme.panelSoft)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func prepareMediaIfNeeded() async {
    guard effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cached = resolveCachedLocalMedia?(playbackSourceURL) {
      extractionState = .ready(cached)
      extractionFallbackReason = nil
      return
    }

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: playbackSourceURL)
    extractionState = result

    switch result {
    case .ready(let media):
      extractionFallbackReason = nil
      if media.isLocalFile {
        persistLocalMedia?(playbackSourceURL, media)
      }
    case .cannotExtract(let reason):
      extractionFallbackReason = reason
      localPlaybackMode = .embedPreferred
    }
  }

  private var effectiveSourceURL: URL {
    canonicalSourceURL ?? sourceURL
  }

  private var effectiveMediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: effectiveSourceURL)
  }

  private var effectiveMediaAspectRatio: CGFloat {
    URLClassifier.preferredMediaAspectRatio(
      for: effectiveSourceURL, strategy: effectiveMediaStrategy)
  }
}
