import AVFoundation
import XCTest

@testable import linkstr

@MainActor
final class MediaAudioSessionControllerTests: XCTestCase {
  func testMultipleAcquiresActivateOnlyOnceUntilFinalRelease() async {
    let backend = FakeMediaAudioSessionBackend()
    let queue = DispatchQueue(label: "audio-tests")
    let controller = MediaAudioSessionController(backend: backend, queue: queue)

    controller.acquirePlayback()
    controller.acquirePlayback()
    controller.releasePlayback()
    await drain(queue)

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(
      backend.categoryCalls,
      [.init(category: .playback, mode: .moviePlayback, options: [])]
    )
    XCTAssertEqual(backend.activeCalls, [.init(active: true, options: [])])

    controller.releasePlayback()
    await drain(queue)

    XCTAssertEqual(controller.retainCount, 0)
    XCTAssertEqual(
      backend.activeCalls,
      [
        .init(active: true, options: []),
        .init(active: false, options: [.notifyOthersOnDeactivation])
      ]
    )
  }

  func testReleasePlaybackWithoutAcquireDoesNothing() async {
    let backend = FakeMediaAudioSessionBackend()
    let queue = DispatchQueue(label: "audio-tests")
    let controller = MediaAudioSessionController(backend: backend, queue: queue)

    controller.releasePlayback()
    await drain(queue)

    XCTAssertEqual(controller.retainCount, 0)
    XCTAssertTrue(backend.categoryCalls.isEmpty)
    XCTAssertTrue(backend.activeCalls.isEmpty)
  }

  func testFailedActivationKeepsOwnersBalancedAndNextAcquireRetries() async {
    let backend = FakeMediaAudioSessionBackend()
    backend.failActivation = true
    let queue = DispatchQueue(label: "audio-tests")
    let controller = MediaAudioSessionController(backend: backend, queue: queue)

    controller.acquirePlayback()
    await drain(queue)

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(backend.categoryCalls.count, 1)
    XCTAssertEqual(backend.activeCalls, [.init(active: true, options: [])])

    backend.failActivation = false
    controller.acquirePlayback()
    await drain(queue)
    controller.releasePlayback()
    await drain(queue)

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(backend.categoryCalls.count, 2)
    XCTAssertEqual(
      backend.activeCalls,
      [
        .init(active: true, options: []),
        .init(active: true, options: [])
      ]
    )
    controller.releasePlayback()
    await drain(queue)
    XCTAssertEqual(controller.retainCount, 0)
    XCTAssertEqual(backend.activeCalls.last, .init(active: false, options: [.notifyOthersOnDeactivation]))
  }

  func testClosingDuringActivationDoesNotBlockMainActorOrLeaveAudioActive() async {
    let backend = FakeMediaAudioSessionBackend()
    let queue = DispatchQueue(label: "audio-tests")
    let controller = MediaAudioSessionController(backend: backend, queue: queue)
    let started = expectation(description: "activation started off main thread")
    let gate = DispatchSemaphore(value: 0)
    backend.onActivate = {
      started.fulfill()
      XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
    }

    controller.acquirePlayback()
    await fulfillment(of: [started], timeout: 1)
    controller.releasePlayback()
    XCTAssertEqual(controller.retainCount, 0)
    gate.signal()
    await drain(queue)

    XCTAssertEqual(backend.activeCalls.map(\.active), [true, false])
  }

  func testQuicklyReplacingPlayerKeepsTheExistingActivation() async {
    let backend = FakeMediaAudioSessionBackend()
    let queue = DispatchQueue(label: "audio-tests")
    let controller = MediaAudioSessionController(backend: backend, queue: queue)
    controller.acquirePlayback()
    await drain(queue)
    let gate = DispatchSemaphore(value: 0)
    queue.async { XCTAssertEqual(gate.wait(timeout: .now() + 2), .success) }

    controller.releasePlayback()
    controller.acquirePlayback()
    gate.signal()
    await drain(queue)

    XCTAssertEqual(controller.retainCount, 1)
    XCTAssertEqual(backend.activeCalls.map(\.active), [true])
    controller.releasePlayback()
    await drain(queue)
    XCTAssertEqual(backend.activeCalls.map(\.active), [true, false])
  }

  private func drain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
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
  var onActivate: (() -> Void)?

  func setCategory(
    _ category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions
  ) throws {
    XCTAssertFalse(Thread.isMainThread)
    categoryCalls.append(CategoryCall(category: category, mode: mode, options: options))
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    XCTAssertFalse(Thread.isMainThread)
    activeCalls.append(ActiveCall(active: active, options: options))
    if active { onActivate?() }
    if active, failActivation {
      throw Failure.activationFailed
    }
  }
}
