import XCTest

@testable import Linkstr

final class ManagedLocalFileScopeTests: XCTestCase {
  func testManagedFileURLAcceptsManagedDirectories() {
    let scope = ManagedLocalFileScope.shared
    let thumbnailURL = scope.thumbnailFileURL(for: "unit-thumb", fileExtension: "png")
    let videoURL = scope.cachedVideoFileURL(
      for: URL(string: "https://example.com/video.mp4")!,
      preferredExtension: "mp4"
    )

    XCTAssertEqual(
      scope.managedFileURL(fromPath: thumbnailURL.path),
      thumbnailURL.standardizedFileURL.resolvingSymlinksInPath()
    )
    XCTAssertEqual(
      scope.managedFileURL(fromPath: videoURL.path),
      videoURL.standardizedFileURL.resolvingSymlinksInPath()
    )
  }

  func testManagedFileURLRejectsUnmanagedOrBlankPaths() {
    let scope = ManagedLocalFileScope.shared
    let unmanagedURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("unmanaged-\(UUID().uuidString).png")

    XCTAssertNil(scope.managedFileURL(fromPath: nil))
    XCTAssertNil(scope.managedFileURL(fromPath: "   "))
    XCTAssertNil(scope.managedFileURL(fromPath: unmanagedURL.path))
    XCTAssertFalse(scope.isManagedFileURL(unmanagedURL))
  }
}
