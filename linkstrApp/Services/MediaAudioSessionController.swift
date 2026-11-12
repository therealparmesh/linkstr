import AVFoundation
import OSLog

final class MediaAudioSessionController: @unchecked Sendable {
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
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var playbackOwners = 0
  // Only accessed on queue; ownership is separately protected by lock.
  private var isActive = false

  var retainCount: Int { lock.withLock { playbackOwners } }

  init(
    backend: any Backend = SystemMediaAudioSessionBackend(),
    queue: DispatchQueue = DispatchQueue(label: "com.parmscript.linkstr.playback-audio", qos: .userInitiated)
  ) {
    self.backend = backend
    self.queue = queue
  }

  func acquirePlayback() {
    // Count owners independently of activation success so every release remains balanced.
    lock.withLock { playbackOwners += 1 }
    queue.async { self.updateActivation() }
  }

  func releasePlayback() {
    let releasedLastOwner = lock.withLock {
      guard playbackOwners > 0 else { return false }
      playbackOwners -= 1
      return playbackOwners == 0
    }
    if releasedLastOwner { queue.async { self.updateActivation() } }
  }

  private func updateActivation() {
    let requested = retainCount > 0
    guard requested != isActive else { return }
    if !requested { isActive = false }
    do {
      if requested { try backend.setCategory(.playback, mode: .moviePlayback, options: []) }
      try backend.setActive(requested, options: requested ? [] : [.notifyOthersOnDeactivation])
      isActive = requested
    } catch {
      LinkstrPlaybackDiagnostics.logger.notice(
        "audio session failed; requested: \(requested); error: \(error.localizedDescription, privacy: .private)"
      )
    }
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
