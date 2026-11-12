import XCTest

@testable import linkstr

final class VideoCacheTests: XCTestCase {
  func testCompletedDownloadsPreserveExistingMediaAndRecoverAfterCacheRemoval() async throws {
    let root = makeTemporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("videos", isDirectory: true)
    let service = VideoCacheService(videoDirectory: directory)
    let source = URL(string: "https://example.com/\(UUID().uuidString).mp4")!
    let first = try downloadedMedia(in: root, contents: "first")
    let saved = try await service.storeDownloadedVideo(at: first, from: source)

    XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    let duplicate = try downloadedMedia(in: root, contents: "replacement")
    let reused = try await service.storeDownloadedVideo(at: duplicate, from: source)
    XCTAssertEqual(reused, saved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
    XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "first")
    let cached = try await service.downloadMP4(from: source, headers: [:])
    XCTAssertEqual(cached, saved)

    try FileManager.default.removeItem(at: directory)
    let fresh = try downloadedMedia(in: root, contents: "fresh")
    let restored = try await service.storeDownloadedVideo(at: fresh, from: source)
    XCTAssertEqual(restored, saved)
    XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "fresh")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
  }

  private func downloadedMedia(in directory: URL, contents: String) throws -> URL {
    let file = directory.appendingPathComponent(UUID().uuidString)
    try Data(contents.utf8).write(to: file)
    return file
  }

  func testEvictionKeepsCountingFilesThatCouldNotBeDeleted() async throws {
    let directory = makeTemporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldest = directory.appendingPathComponent("oldest.mp4")
    let newer = directory.appendingPathComponent("newer.mp4")
    let newest = directory.appendingPathComponent("newest.mp4")
    for (index, url) in [oldest, newer, newest].enumerated() {
      try Data("1234".utf8).write(to: url)
      LocalFileMetrics.touch(url, date: Date(timeIntervalSince1970: Double(index)))
    }
    let service = VideoCacheService(
      videoDirectory: directory,
      fileManager: RemovalFailingFileManager(protectedURL: oldest), maxVideoCacheBytes: 8)

    await service.registerCachedMedia(at: newest)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
  }

  func testVideoCacheServiceRegisterEvictsLeastRecentlyUsedVideosWhenOverLimit() async throws {
    let rootDirectory = makeTemporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let videoDirectory = rootDirectory.appendingPathComponent("videos", isDirectory: true)
    try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)

    let oldestURL = videoDirectory.appendingPathComponent("oldest.mp4")
    let newerURL = videoDirectory.appendingPathComponent("newer.mp4")
    let newestURL = videoDirectory.appendingPathComponent("newest.mp4")

    try Data("1111".utf8).write(to: oldestURL, options: .atomic)
    try Data("2222".utf8).write(to: newerURL, options: .atomic)
    try Data("3333".utf8).write(to: newestURL, options: .atomic)

    LocalFileMetrics.touch(oldestURL, date: Date(timeIntervalSince1970: 10))
    LocalFileMetrics.touch(newerURL, date: Date(timeIntervalSince1970: 20))
    LocalFileMetrics.touch(newestURL, date: Date(timeIntervalSince1970: 30))

    let service = VideoCacheService(
      videoDirectory: videoDirectory,
      maxVideoCacheBytes: 8
    )

    await service.registerCachedMedia(at: newestURL)

    XCTAssertFalse(FileManager.default.fileExists(atPath: oldestURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newerURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newestURL.path))
  }

}

private final class RemovalFailingFileManager: FileManager, @unchecked Sendable {
  let protectedURL: URL

  init(protectedURL: URL) {
    self.protectedURL = protectedURL
    super.init()
  }

  override func removeItem(at url: URL) throws {
    if url.standardizedFileURL == protectedURL.standardizedFileURL {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: url)
  }
}

// MARK: - Free Functions

private func makeTemporaryCacheDirectory() -> URL {
  let directory =
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("linkstr-cache-tests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
