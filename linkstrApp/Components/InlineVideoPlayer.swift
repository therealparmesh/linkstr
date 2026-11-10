import AVFoundation
import AVKit
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct InlineVideoPlayer: View {
  @AppStorage("loopLocalVideos") private var loopLocalVideos = true
  @AppStorage("watchMuted") private var watchMuted = false
  @Environment(\.scenePhase) private var scenePhase

  let media: PlayableMedia
  var onPlaybackReady: (() -> Void)?
  var onPlaybackFailed: (() -> Void)?
  var onAspectRatioChange: ((CGFloat) -> Void)?
  var immersive = false
  var aspectRatio: CGFloat = 16.0 / 9.0
  var isCovered = false
  var watchBottomInset: CGFloat = 0
  var systemPlayerRequest: Binding<Bool>?
  @State private var player: AVPlayer?
  @State private var isShowingFullscreenPlayer = false
  @State private var statusObservation: NSKeyValueObservation?
  @State private var presentationSizeObservation: NSKeyValueObservation?
  @State private var resumeAfterCover = false

  private var fullscreen: Binding<Bool> { systemPlayerRequest ?? $isShowingFullscreenPlayer }

  private var shouldSuspend: Bool { immersive && (isCovered || scenePhase != .active) }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let player {
          Group {
            if immersive {
              WatchVideoSurface(
                player: player, aspectRatio: aspectRatio, bottomInset: watchBottomInset, isMuted: $watchMuted
              )
            } else {
              VideoPlayer(player: player)
            }
          }
          .scopedPlaybackAudioSession()
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

      if player != nil, !immersive {
        Button {
          isShowingFullscreenPlayer = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(LinkstrTheme.font(.footnote, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .frame(
              width: LinkstrTheme.minimumInteractiveDimension,
              height: LinkstrTheme.minimumInteractiveDimension)
            .background(Circle().fill(LinkstrTheme.panel.opacity(0.84)))
        }
        .accessibilityLabel("open video fullscreen")
        .padding(8)
      }
    }
    .fullScreenCover(isPresented: fullscreen) {
      if let player {
        FullScreenAVPlayerView(player: player)
          .scopedPlaybackAudioSession()
          .ignoresSafeArea()
          .background(Color.black)
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
    ) { notification in
      guard loopLocalVideos, !shouldSuspend,
        let endedItem = notification.object as? AVPlayerItem,
        let player,
        player.currentItem === endedItem
      else { return }

      player.seek(to: .zero)
      player.play()
    }
    .task(id: media.playbackURL) {
      statusObservation?.invalidate()
      statusObservation = nil
      presentationSizeObservation?.invalidate()
      presentationSizeObservation = nil
      player?.pause()
      player = nil

      guard let asset = await media.loadVideoAsset() else {
        guard !Task.isCancelled else { return }
        onPlaybackFailed?()
        return
      }
      guard !Task.isCancelled else { return }
      onPlaybackReady?()

      let item = AVPlayerItem(asset: asset)
      statusObservation = item.observe(\.status, options: [.new]) { observed, _ in
        if observed.status == .failed {
          Task { @MainActor in onPlaybackFailed?() }
        }
      }
      presentationSizeObservation = item.observe(
        \.presentationSize,
        options: [.initial, .new]
      ) { observed, _ in
        guard let aspectRatio = MediaPresentationGeometry.aspectRatio(
          for: observed.presentationSize
        ) else { return }
        Task { @MainActor in onAspectRatioChange?(aspectRatio) }
      }
      let newPlayer = AVPlayer(playerItem: item)
      newPlayer.isMuted = immersive && watchMuted
      player = newPlayer
      resumeAfterCover = shouldSuspend
      if !shouldSuspend { newPlayer.play() }
    }
    .onChange(of: shouldSuspend) { _, shouldSuspend in
      guard let player else { return }
      if shouldSuspend {
        resumeAfterCover = player.timeControlStatus != .paused
        player.pause()
      } else if resumeAfterCover {
        resumeAfterCover = false
        player.play()
      }
    }
    .onChange(of: watchMuted) { _, isMuted in
      if immersive { player?.isMuted = isMuted }
    }
    .onDisappear {
      guard !fullscreen.wrappedValue else { return }
      player?.pause()
      player = nil
      statusObservation?.invalidate()
      statusObservation = nil
      presentationSizeObservation?.invalidate()
      presentationSizeObservation = nil
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

private struct ScopedPlaybackAudioSessionModifier: ViewModifier {
  @State private var hasAcquiredPlaybackAudioSession = false

  func body(content: Content) -> some View {
    content
      .onAppear {
        guard !hasAcquiredPlaybackAudioSession else { return }
        MediaAudioSessionController.shared.acquirePlayback()
        hasAcquiredPlaybackAudioSession = true
      }
      .onDisappear {
        guard hasAcquiredPlaybackAudioSession else { return }
        MediaAudioSessionController.shared.releasePlayback()
        hasAcquiredPlaybackAudioSession = false
      }
  }
}

extension View {
  func scopedPlaybackAudioSession() -> some View {
    modifier(ScopedPlaybackAudioSessionModifier())
  }
}
