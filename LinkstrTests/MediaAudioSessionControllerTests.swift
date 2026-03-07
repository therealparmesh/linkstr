import AVFoundation
import XCTest

@testable import Linkstr

@MainActor
final class MediaAudioSessionControllerTests: XCTestCase {
  func testAcquirePlaybackConfiguresAndActivatesPlaybackSession() {
    let backend = FakeMediaAudioSessionBackend()
    let controller = MediaAudioSessionController(backend: backend)

    controller.acquirePlayback()

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(
      backend.categoryCalls,
      [.init(category: .playback, mode: .moviePlayback, options: [])]
    )
    XCTAssertEqual(backend.activeCalls, [.init(active: true, options: [])])
  }

  func testMultipleAcquiresActivateOnlyOnceUntilFinalRelease() {
    let backend = FakeMediaAudioSessionBackend()
    let controller = MediaAudioSessionController(backend: backend)

    controller.acquirePlayback()
    controller.acquirePlayback()
    controller.releasePlayback()

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(backend.categoryCalls.count, 1)
    XCTAssertEqual(backend.activeCalls, [.init(active: true, options: [])])

    controller.releasePlayback()

    XCTAssertEqual(controller.retainCount, 0)
    XCTAssertEqual(
      backend.activeCalls,
      [
        .init(active: true, options: []),
        .init(active: false, options: [.notifyOthersOnDeactivation]),
      ]
    )
  }

  func testReleasePlaybackWithoutAcquireDoesNothing() {
    let backend = FakeMediaAudioSessionBackend()
    let controller = MediaAudioSessionController(backend: backend)

    controller.releasePlayback()

    XCTAssertEqual(controller.retainCount, 0)
    XCTAssertTrue(backend.categoryCalls.isEmpty)
    XCTAssertTrue(backend.activeCalls.isEmpty)
  }

  func testFailedActivationDoesNotRetainPlaybackSession() {
    let backend = FakeMediaAudioSessionBackend()
    backend.failActivation = true
    let controller = MediaAudioSessionController(backend: backend)

    controller.acquirePlayback()

    XCTAssertEqual(controller.retainCount, 0)
    XCTAssertEqual(backend.categoryCalls.count, 1)
    XCTAssertEqual(backend.activeCalls, [.init(active: true, options: [])])

    backend.failActivation = false
    controller.acquirePlayback()

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(backend.categoryCalls.count, 2)
    XCTAssertEqual(
      backend.activeCalls,
      [
        .init(active: true, options: []),
        .init(active: true, options: []),
      ]
    )
  }
}

private final class FakeMediaAudioSessionBackend: MediaAudioSessionController.Backend {
  struct CategoryCall: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
  }

  struct ActiveCall: Equatable {
    let active: Bool
    let options: AVAudioSession.SetActiveOptions
  }

  enum Failure: Error {
    case activationFailed
  }

  var categoryCalls: [CategoryCall] = []
  var activeCalls: [ActiveCall] = []
  var failActivation = false

  func setCategory(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions
  ) throws {
    categoryCalls.append(CategoryCall(category: category, mode: mode, options: options))
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    activeCalls.append(ActiveCall(active: active, options: options))
    if active, failActivation {
      throw Failure.activationFailed
    }
  }
}
