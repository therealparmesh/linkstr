import XCTest

@testable import linkstr

final class ManagedLocalFileScopeTests: XCTestCase {
  func testManagedFileURLAcceptsManagedDirectories() {
    let scope = ManagedLocalFileScope.shared
    let thumbnailURL = scope.thumbnailFileURL(for: "unit-thumb", fileExtension: "png")
    let videoURL = scope.videoDirectory.appendingPathComponent("unit-video.mp4")

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
  }

  func testManagedFileURLRebasesLegacyThumbnailPathIntoCurrentManagedDirectory() throws {
    let scope = ManagedLocalFileScope.shared
    let thumbnailURL = scope.thumbnailFileURL(
      for: "legacy-thumb-\(UUID().uuidString)",
      fileExtension: "png"
    )
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }

    let legacyPath =
      "/var/mobile/Containers/Data/Application/OLD/Library/Application Support/linkstr/thumbnails/"
      + thumbnailURL.lastPathComponent

    XCTAssertEqual(
      scope.managedFileURL(fromPath: legacyPath),
      thumbnailURL.standardizedFileURL.resolvingSymlinksInPath()
    )
  }
}
