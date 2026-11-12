import AVFoundation
import XCTest

@testable import linkstr

final class QRScannerLifetimeTests: XCTestCase {
  @MainActor
  func testDismissalDuringCameraStartupStopsAfterStartupWithoutBlockingMainThread() async {
    let started = expectation(description: "camera startup began")
    let finished = expectation(description: "camera startup completed")
    let stopped = expectation(description: "camera shutdown completed")
    let gate = DispatchSemaphore(value: 0)
    let capture = DelayedCaptureSession()
    capture.onStart = {
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill()
      XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
      capture.record("start")
      finished.fulfill()
    }
    capture.onStop = {
      XCTAssertFalse(Thread.isMainThread, "Camera shutdown must not block the UI")
      capture.record("stop")
      stopped.fulfill()
    }
    defer { capture.onStart = nil; capture.onStop = nil }
    let coordinator = LinkstrQRScannerRepresentable.Coordinator(onScanned: { _ in }, onFailure: {})
    coordinator.start(capture)
    await fulfillment(of: [started], timeout: 3)
    coordinator.stop()
    coordinator.stop()
    gate.signal()
    await fulfillment(of: [finished, stopped], timeout: 3)
    XCTAssertEqual(capture.events, ["start", "stop"], "A dismissed scanner must not restart its camera")
  }
}

private final class DelayedCaptureSession: AVCaptureSession, @unchecked Sendable {
  var onStart: (() -> Void)?
  var onStop: (() -> Void)?
  private let lock = NSLock()
  private var recordedEvents: [String] = []
  var events: [String] { lock.withLock { recordedEvents } }

  func record(_ event: String) { lock.withLock { recordedEvents.append(event) } }
  override func startRunning() { onStart?() }
  override func stopRunning() { onStop?() }
}
