import AVFoundation
import Combine
import SwiftUI
import UIKit

struct WatchVideoSurface: View {
  let player: AVPlayer
  let aspectRatio: CGFloat
  let bottomInset: CGFloat
  @Binding var isMuted: Bool

  var body: some View {
    GeometryReader { proxy in
      let fillsPortrait = aspectRatio < 0.72 && proxy.size.height > proxy.size.width
      WatchPlayerLayer(player: player, fillsPortrait: fillsPortrait)
        .contentShape(Rectangle())
        .onTapGesture { player.toggleWatchPlayback() }
        .accessibilityHidden(true)
    }
    .background(.black)
    .overlay(alignment: .bottom) {
      WatchPlaybackControls(player: player, bottomInset: bottomInset, isMuted: $isMuted)
        .id(ObjectIdentifier(player))
    }
  }
}

private struct WatchPlaybackControls: View {
  let player: AVPlayer
  let bottomInset: CGFloat
  @Binding var isMuted: Bool
  @State private var isPlaying = true
  @State private var duration: Double = 0
  @State private var elapsed: Double = 0
  @State private var scrubbing = false
  @State private var timeObserver: Any?

  var body: some View {
    HStack(spacing: 7) {
      Button {
        player.toggleWatchPlayback()
      } label: {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel(isPlaying ? "pause video" : "play video")

      Slider(
        value: $elapsed, in: 0...max(0.001, duration),
        onEditingChanged: { editing in
          scrubbing = editing
          if !editing {
            player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
          }
        }
      )
      .controlSize(.small)
      .tint(LinkstrTheme.accent)
      .disabled(duration <= 0)
      .accessibilityLabel("video position")
      .accessibilityValue("\(timestamp(elapsed)) of \(timestamp(duration))")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: seek(by: 10)
        case .decrement: seek(by: -10)
        @unknown default: break
        }
      }

      if duration > 0 {
        Text("\(timestamp(elapsed)) / \(timestamp(duration))")
          .font(LinkstrTheme.font(.caption2, weight: .medium).monospacedDigit())
          .lineLimit(1)
          .accessibilityHidden(true)
      }

      Button {
        isMuted.toggle()
      } label: {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel(isMuted ? "unmute video" : "mute video")
    }
    .font(LinkstrTheme.font(.subheadline, weight: .semibold))
    .foregroundStyle(LinkstrTheme.textPrimary)
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .padding(.bottom, bottomInset)
    .background(.black.opacity(0.75))
    .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
      isPlaying = status != .paused
      updatePosition()
    }
    .onAppear(perform: observeTime)
    .onDisappear {
      if let timeObserver { player.removeTimeObserver(timeObserver) }
      timeObserver = nil
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
    elapsed = position.isFinite ? min(duration, max(0, position)) : 0
  }

  private func seek(by delta: Double) {
    elapsed = min(duration, max(0, elapsed + delta))
    player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
  }

  private func timestamp(_ seconds: Double) -> String {
    let rounded = Int(seconds.rounded(.down))
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
