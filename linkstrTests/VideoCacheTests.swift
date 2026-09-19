import XCTest

@testable import linkstr

final class VideoCacheTests: XCTestCase {
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
      thumbnailDirectory: directory.appendingPathComponent("thumbnails"), videoDirectory: directory,
      fileManager: RemovalFailingFileManager(protectedURL: oldest), maxVideoCacheBytes: 8)

    await service.registerCachedMedia(at: newest)
    let usage = await service.currentUsage()
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    XCTAssertEqual(usage.videoBytes, 8)
  }

  func testVideoCacheServiceCurrentUsageCountsVideoAndThumbnailBytes() async throws {
    let rootDirectory = makeTemporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let thumbnailDirectory = rootDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    let videoDirectory = rootDirectory.appendingPathComponent("videos", isDirectory: true)
    try FileManager.default.createDirectory(
      at: thumbnailDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)

    let thumbnailData = Data("thumb".utf8)
    let videoData = Data("video-file".utf8)
    let thumbnailURL = thumbnailDirectory.appendingPathComponent("one.png")
    let videoURL = videoDirectory.appendingPathComponent("one.mp4")
    try thumbnailData.write(to: thumbnailURL, options: .atomic)
    try videoData.write(to: videoURL, options: .atomic)

    let service = VideoCacheService(
      thumbnailDirectory: thumbnailDirectory,
      videoDirectory: videoDirectory,
      maxVideoCacheBytes: 64
    )

    let usage = await service.currentUsage()

    XCTAssertEqual(usage.thumbnailBytes, Int64(thumbnailData.count))
    XCTAssertEqual(usage.videoBytes, Int64(videoData.count))
    XCTAssertEqual(usage.videoCacheLimitBytes, 64)
  }

  func testVideoCacheServiceRegisterEvictsLeastRecentlyUsedVideosWhenOverLimit() async throws {
    let rootDirectory = makeTemporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: rootDirectory) }

    let thumbnailDirectory = rootDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    let videoDirectory = rootDirectory.appendingPathComponent("videos", isDirectory: true)
    try FileManager.default.createDirectory(
      at: thumbnailDirectory, withIntermediateDirectories: true)
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
      thumbnailDirectory: thumbnailDirectory,
      videoDirectory: videoDirectory,
      maxVideoCacheBytes: 8
    )

    await service.registerCachedMedia(at: newestURL)
    let usage = await service.currentUsage()

    XCTAssertFalse(FileManager.default.fileExists(atPath: oldestURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newerURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newestURL.path))
    XCTAssertEqual(usage.videoBytes, 8)
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
