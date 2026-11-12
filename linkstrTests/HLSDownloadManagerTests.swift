import XCTest

@testable import linkstr

@MainActor
final class HLSDownloadManagerTests: XCTestCase {
  func testLocationIsNotPublishedUntilDownloadCompletesSuccessfully() async throws {
    for fails in [false, true] {
      let source = URL(string: "https://example.com/\(UUID().uuidString).m3u8")!
      let location = try package()
      defer { try? FileManager.default.removeItem(at: location) }
      let manager = HLSDownloadManager.shared
      let started = expectation(description: "download started")
      let task = DownloadTaskStub { started.fulfill() }
      let result = Task { try await manager.waitForDownload(task, sourceURL: source) }
      await fulfillment(of: [started], timeout: 2)

      manager.recordLocation(location, for: task.taskIdentifier)
      XCTAssertNil(ManagedLocalFileScope.shared.hlsRegistry.cachedURL(for: source))
      manager.completeDownload(task.taskIdentifier, error: fails ? URLError(.networkConnectionLost) : nil)
      do {
        let saved = try await result.value
        XCTAssertFalse(fails)
        XCTAssertEqual(saved.path, location.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
        XCTAssertEqual(ManagedLocalFileScope.shared.hlsRegistry.cachedURL(for: source)?.path, location.path)
      } catch {
        XCTAssertTrue(fails)
        XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        XCTAssertNil(ManagedLocalFileScope.shared.hlsRegistry.cachedURL(for: source))
      }
    }
  }

  func testCancellationBeforeAndAfterRegistrationDoesNotWaitForDelegateCompletion() async throws {
    for alreadyCancelled in [true, false] {
      let source = URL(string: "https://example.com/\(UUID().uuidString).m3u8")!
      let location = try package()
      defer { try? FileManager.default.removeItem(at: location) }
      let manager = HLSDownloadManager.shared
      let started = alreadyCancelled ? nil : expectation(description: "download started")
      let task = DownloadTaskStub {
        if let started { started.fulfill() } else { XCTFail("cancelled task was resumed") }
      }
      let result = Task {
        if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
        return try await manager.waitForDownload(task, sourceURL: source)
      }
      if let started {
        await fulfillment(of: [started], timeout: 2)
        manager.recordLocation(location, for: task.taskIdentifier)
        result.cancel()
      }
      do {
        _ = try await result.value
        XCTFail("cancelled download returned a package")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      // A late location or completion after cancellation must not publish a package.
      manager.recordLocation(location, for: task.taskIdentifier)
      manager.completeDownload(task.taskIdentifier, error: nil)
      XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
      XCTAssertNil(ManagedLocalFileScope.shared.hlsRegistry.cachedURL(for: source))
    }
  }

  private func package() throws -> URL {
    let location = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
      .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    return location
  }
}

private final class DownloadTaskStub: HLSDownloadTask {
  private let onResume: () -> Void
  private let identifier = Int.random(in: Int.min..<0)
  var taskIdentifier: Int { identifier }

  init(onResume: @escaping () -> Void) { self.onResume = onResume }
  func resume() { onResume() }
  func cancel() {}
}
