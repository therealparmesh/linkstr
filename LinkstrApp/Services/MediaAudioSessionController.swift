import AVFoundation
import Foundation

@MainActor
final class MediaAudioSessionController {
  protocol Backend {
    func setCategory(
      _ category: AVAudioSession.Category,
      mode: AVAudioSession.Mode,
      options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
  }

  static let shared = MediaAudioSessionController()

  private let backend: any Backend
  private(set) var retainCount = 0

  init(backend: any Backend = SystemMediaAudioSessionBackend()) {
    self.backend = backend
  }

  func acquirePlayback() {
    if retainCount > 0 {
      retainCount += 1
      return
    }

    do {
      try backend.setCategory(.playback, mode: .moviePlayback, options: [])
      try backend.setActive(true, options: [])
      retainCount = 1
    } catch {
      retainCount = 0
    }
  }

  func releasePlayback() {
    guard retainCount > 0 else { return }

    if retainCount > 1 {
      retainCount -= 1
      return
    }

    retainCount = 0
    try? backend.setActive(false, options: [.notifyOthersOnDeactivation])
  }
}

private struct SystemMediaAudioSessionBackend: MediaAudioSessionController.Backend {
  private let session: AVAudioSession

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  func setCategory(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions
  ) throws {
    try session.setCategory(category, mode: mode, options: options)
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    try session.setActive(active, options: options)
  }
}
