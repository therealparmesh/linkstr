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
  var watchVideoInsets: EdgeInsets?
  var onWatchControlsHeightChange: (CGFloat) -> Void = { _ in }
  @State private var player: AVPlayer?
  @State private var isShowingFullscreenPlayer = false
  @State private var statusObservation: NSKeyValueObservation?
  @State private var presentationSizeObservation: NSKeyValueObservation?
  @State private var resumeAfterCover = false
  @State private var hasAudio = true

  private var shouldSuspend: Bool { isCovered || (immersive && scenePhase != .active) }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let player {
          Group {
            if immersive {
              WatchVideoSurface(
                player: player, aspectRatio: aspectRatio, bottomInset: watchBottomInset,
                videoInsets: watchVideoInsets,
                isMuted: $watchMuted, hasAudio: hasAudio, onControlsHeightChange: onWatchControlsHeightChange,
                openSystemPlayer: { isShowingFullscreenPlayer = true }
              )
            } else {
              VideoPlayer(player: player)
            }
          }
          .scopedPlaybackAudioSession()
        } else {
          ProgressView()
            .tint(LinkstrTheme.accent)
            .accessibilityLabel("loading video")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

      if player != nil, !immersive {
        Button {
          isShowingFullscreenPlayer = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .linkstrMediaOverlayIconLabel()
        }
        .accessibilityLabel("open system player")
        .padding(8)
      }
    }
    .background {
      if let player {
        SystemPlayerPresentation(player: player, isPresented: $isShowingFullscreenPlayer)
          .frame(width: 0, height: 0)
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
      hasAudio = true

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
          Task { @MainActor in
            guard player?.currentItem === observed else { return }
            onPlaybackFailed?()
          }
        }
      }
      presentationSizeObservation = item.observe(
        \.presentationSize,
        options: [.initial, .new]
      ) { observed, _ in
        guard let aspectRatio = MediaPresentationGeometry.aspectRatio(
          for: observed.presentationSize
        ) else { return }
        Task { @MainActor in
          guard player?.currentItem === observed else { return }
          onAspectRatioChange?(aspectRatio)
        }
      }
      let newPlayer = AVPlayer(playerItem: item)
      newPlayer.isMuted = immersive && watchMuted
      player = newPlayer
      resumeAfterCover = shouldSuspend
      if !shouldSuspend { newPlayer.play() }
      if immersive, media.isLocalFile, asset.assetCache == nil,
        let tracks = try? await asset.loadTracks(withMediaType: .audio),
        !Task.isCancelled, player === newPlayer {
        hasAudio = !tracks.isEmpty
      }
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
      guard !isShowingFullscreenPlayer else { return }
      player?.pause()
      player = nil
      statusObservation?.invalidate()
      statusObservation = nil
      presentationSizeObservation?.invalidate()
      presentationSizeObservation = nil
    }
  }
}

private struct SystemPlayerPresentation: UIViewControllerRepresentable {
  let player: AVPlayer
  @Binding var isPresented: Bool

  func makeUIViewController(context: Context) -> SystemPlayerPresenter {
    SystemPlayerPresenter()
  }

  func updateUIViewController(_ controller: SystemPlayerPresenter, context: Context) {
    controller.update(player: player, isPresented: isPresented) { isPresented = false }
  }

  static func dismantleUIViewController(_ controller: SystemPlayerPresenter, coordinator: ()) {
    controller.dismissPlayer(animated: false)
  }
}

private final class SystemPlayerPresenter: UIViewController, AVPlayerViewControllerDelegate {
  private var player: AVPlayer?
  private var playerController: AVPlayerViewController?
  private var wantsPresentation = false
  private var onDismiss: (() -> Void)?

  func update(player: AVPlayer, isPresented: Bool, onDismiss: @escaping () -> Void) {
    self.player = player
    self.onDismiss = onDismiss
    wantsPresentation = isPresented
    if isPresented {
      presentPlayerIfNeeded()
    } else if playerController != nil {
      dismissPlayer(animated: true)
    }
  }

  func dismissPlayer(animated: Bool) {
    guard let playerController else { return }
    wantsPresentation = false
    self.playerController = nil
    // Dismantling an idle child must not dismiss the containing SwiftUI presentation.
    playerController.dismiss(animated: animated)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    presentPlayerIfNeeded()
  }

  private func presentPlayerIfNeeded() {
    guard wantsPresentation, playerController == nil, viewIfLoaded?.window != nil, let player else { return }
    let pausedPosition = player.timeControlStatus == .paused ? player.currentTime() : nil
    let controller = AVPlayerViewController()
    controller.player = player
    controller.delegate = self
    // Keep the inline player and its pause/seek state alive underneath the native player.
    controller.modalPresentationStyle = .overFullScreen
    controller.exitsFullScreenWhenPlaybackEnds = false
    playerController = controller
    present(controller, animated: true) {
      if let pausedPosition, pausedPosition.isNumeric,
        player.timeControlStatus == .paused, player.currentTime() != pausedPosition {
        player.seek(to: pausedPosition, toleranceBefore: .zero, toleranceAfter: .zero)
      }
    }
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    coordinator.animate(alongsideTransition: nil) { [weak self] context in
      guard !context.isCancelled else { return }
      self?.wantsPresentation = false
      self?.playerController = nil
      self?.onDismiss?()
    }
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
