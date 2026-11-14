import AVFoundation
import Combine
import SwiftUI
import UIKit

struct WatchVideoSurface: View {
  let player: AVPlayer
  let aspectRatio: CGFloat
  let bottomInset: CGFloat
  let videoInsets: EdgeInsets?
  let onControlsHeightChange: (CGFloat) -> Void
  let openSystemPlayer: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let fillsPortrait = videoInsets == nil && aspectRatio < 0.72 && proxy.size.height > proxy.size.width
      WatchPlayerLayer(player: player, fillsPortrait: fillsPortrait)
        .padding(videoInsets ?? EdgeInsets())
        .contentShape(Rectangle())
        .onTapGesture { player.toggleWatchPlayback() }
        .accessibilityHidden(true)
    }
    .background(LinkstrTheme.background)
    .overlay(alignment: .bottom) {
      WatchPlaybackControls(
        player: player, bottomInset: bottomInset, openSystemPlayer: openSystemPlayer
      )
        .id(ObjectIdentifier(player))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
          onControlsHeightChange(max(0, height - bottomInset))
        }
    }
  }
}

private struct WatchPlaybackControls: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  let player: AVPlayer
  let bottomInset: CGFloat
  let openSystemPlayer: () -> Void
  @State private var playbackStatus: AVPlayer.TimeControlStatus = .paused
  @State private var duration: Double = 0
  @State private var elapsed: Double = 0
  @State private var scrubbing = false
  @State private var isMuted = false
  @State private var timeObserver: Any?

  private var isBuffering: Bool { playbackStatus == .waitingToPlayAtSpecifiedRate }
  private var isPlaying: Bool { playbackStatus != .paused }

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize, verticalSizeClass != .compact {
        VStack(spacing: 0) {
          HStack(spacing: LinkstrTheme.compactSpacing) {
            playButton
            Spacer(minLength: 0)
            timeLabel
            Spacer(minLength: 0)
            muteButton
            fullscreenButton
          }
          positionSlider
        }
      } else {
        HStack(spacing: LinkstrTheme.compactSpacing) {
          playButton
          positionSlider
          timeLabel
          muteButton
          fullscreenButton
        }
      }
    }
    .font(LinkstrTheme.font(.subheadline, weight: .semibold))
    .foregroundStyle(LinkstrTheme.textPrimary)
    .buttonStyle(.plain)
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .padding(.top, LinkstrTheme.compactSpacing)
    .padding(.bottom, LinkstrTheme.metaSpacing)
    .linkstrReadableContent()
    .padding(.bottom, bottomInset)
    .background {
      let scrim = LinkstrTheme.background.opacity(0.82)
      VStack(spacing: 0) {
        scrim
        LinearGradient(
          colors: [scrim, LinkstrTheme.background.opacity(0.94)], startPoint: .top, endPoint: .bottom
        )
          .frame(height: bottomInset)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
      playbackStatus = status
      updatePosition()
    }
    .onReceive(player.publisher(for: \.isMuted).receive(on: DispatchQueue.main)) { muted in
      isMuted = muted
    }
    .onAppear(perform: observeTime)
    .onDisappear {
      if let timeObserver { player.removeTimeObserver(timeObserver) }
      timeObserver = nil
    }
  }

  private var playButton: some View {
    Button {
      player.toggleWatchPlayback()
    } label: {
      Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .linkstrToolbarIconLabel()
    }
    .accessibilityLabel(isPlaying ? "pause video" : "play video")
    .accessibilityValue(isBuffering ? "buffering" : "")
  }

  private var fullscreenButton: some View {
    Button(action: openSystemPlayer) {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .linkstrToolbarIconLabel()
    }
    .accessibilityLabel("open system player")
    .accessibilityHint("view the full video without post details")
  }

  private var muteButton: some View {
    Button {
      player.isMuted.toggle()
    } label: {
      Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .linkstrToolbarIconLabel()
    }
    .accessibilityLabel(isMuted ? "unmute video" : "mute video")
  }

  private var positionSlider: some View {
    Slider(
      value: Binding(get: { min(duration, elapsed) }, set: { elapsed = $0 }),
      in: 0...max(0.001, duration),
      onEditingChanged: { editing in
        scrubbing = editing
        if !editing {
          seek(to: elapsed)
        }
      }
    )
    .controlSize(.small)
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
    .tint(LinkstrTheme.accent)
    .disabled(duration <= 0)
    .accessibilityLabel("video position")
    .accessibilityValue(
      duration > 0
        ? "\(timestamp(displayedPosition)) of \(timestamp(duration))"
        : "\(timestamp(elapsed)), duration unavailable"
    )
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: seek(by: 10)
      case .decrement: seek(by: -10)
      @unknown default: break
      }
    }
  }

  @ViewBuilder
  private var timeLabel: some View {
    if isBuffering {
      ProgressView()
        .controlSize(.small)
        .tint(LinkstrTheme.accent)
        .accessibilityHidden(true)
    } else if duration > 0 || elapsed > 0 {
      Text(duration > 0 ? "\(timestamp(displayedPosition)) / \(timestamp(duration))" : timestamp(elapsed))
        .font(LinkstrTheme.font(.caption2, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .accessibilityHidden(true)
    }
  }

  private func observeTime() {
    guard timeObserver == nil else { return }
    updatePosition()
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { _ in
      Task { @MainActor in updatePosition() }
    }
  }

  private func updatePosition() {
    duration = player.watchDuration
    guard !scrubbing else { return }
    let position = player.currentTime().seconds
    elapsed = position.isFinite ? max(0, position) : 0
  }

  private var displayedPosition: Double { min(duration, elapsed) }

  private func seek(by delta: Double) {
    seek(to: displayedPosition + delta)
  }

  private func seek(to position: Double) {
    guard duration > 0 else { return }
    elapsed = min(duration, max(0, position))
    player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
  }

  private func timestamp(_ seconds: Double) -> String {
    let rounded = Int(exactly: seconds.rounded(.down)) ?? 0
    if rounded >= 3_600 {
      return "\(rounded / 3_600):\(String(format: "%02d:%02d", rounded / 60 % 60, rounded % 60))"
    }
    return "\(rounded / 60):\(String(format: "%02d", rounded % 60))"
  }
}

private extension AVPlayer {
  var watchDuration: Double {
    let seconds = currentItem?.duration.seconds ?? 0
    return seconds.isFinite && seconds > 0 ? seconds : 0
  }

  func toggleWatchPlayback() {
    if timeControlStatus == .paused {
      if watchDuration > 0, currentTime().seconds >= watchDuration - 0.15 { seek(to: .zero) }
      play()
    } else {
      pause()
    }
  }
}

private struct WatchPlayerLayer: UIViewRepresentable {
  let player: AVPlayer
  let fillsPortrait: Bool

  func makeUIView(context: Context) -> PlayerView {
    PlayerView()
  }

  func updateUIView(_ view: PlayerView, context: Context) {
    view.playerLayer?.videoGravity = fillsPortrait ? .resizeAspectFill : .resizeAspect
    view.playerLayer?.player = player
  }

  static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
    view.playerLayer?.player = nil
  }

  final class PlayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
  }
}
