import XCTest

@testable import linkstr

final class HLSMediaRegistryTests: XCTestCase {
  func testRegistrationKeepsSystemLocationAndRestoresRelativePaths() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let source = URL(string: "https://example.com/video.m3u8")!
    let original = try fixture.package("first")
    let registry = HLSMediaRegistry(root: fixture.root, defaults: fixture.defaults)

    XCTAssertEqual(try registry.register(original, for: source).path, original.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    let duplicate = try fixture.package("duplicate")
    XCTAssertEqual(try registry.register(duplicate, for: source).path, original.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
    XCTAssertEqual(registry.registeredURLs.map(\.path), [original.path])

    let rebasedRoot = fixture.root.appendingPathComponent("new-container")
    try FileManager.default.createDirectory(at: rebasedRoot, withIntermediateDirectories: true)
    let rebasedPackage = rebasedRoot.appendingPathComponent(original.lastPathComponent)
    try FileManager.default.copyItem(at: original, to: rebasedPackage)
    let restored = HLSMediaRegistry(root: rebasedRoot, defaults: fixture.defaults)
    XCTAssertEqual(restored.cachedURL(for: source)?.path, rebasedPackage.path)
    try FileManager.default.removeItem(at: rebasedPackage)
    XCTAssertNil(restored.cachedURL(for: source))
    XCTAssertTrue(restored.registeredURLs.isEmpty)
  }

  func testRegistrationRejectsLocationsOutsideItsContainer() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let package = try fixture.package("outside")
    let ownedRoot = fixture.root.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
    let registry = HLSMediaRegistry(root: ownedRoot, defaults: fixture.defaults)
    let source = URL(string: "https://example.com/video.m3u8")!
    XCTAssertThrowsError(try registry.register(package, for: source))
    let link = ownedRoot.appendingPathComponent("redirect")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
    XCTAssertThrowsError(try registry.register(link, for: source))
    XCTAssertTrue(registry.registeredURLs.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
  }

  func testVideoCacheEvictsRegisteredHLSPackagesWithoutMovingThem() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let registry = HLSMediaRegistry(root: fixture.root, defaults: fixture.defaults)
    let package = try fixture.package("system-download")
    try Data("1234".utf8).write(to: package.appendingPathComponent("test-data"))
    _ = try registry.register(package, for: URL(string: "https://example.com/video.m3u8")!)
    let videos = fixture.root.appendingPathComponent("videos")
    try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
    let nativeVideo = videos.appendingPathComponent("video.mp4")
    try Data("5678".utf8).write(to: nativeVideo)
    let cache = VideoCacheService(
      videoDirectory: videos, maxVideoCacheBytes: 4,
      additionalMediaURLs: { registry.registeredURLs }
    )
    LocalFileMetrics.touch(package, date: .distantPast)
    await cache.registerCachedMedia(at: nativeVideo)
    XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nativeVideo.path))
    XCTAssertTrue(registry.registeredURLs.isEmpty)
  }
}

private struct Fixture {
  let suite = "hls-tests-\(UUID().uuidString)"
  let root: URL
  let defaults: UserDefaults

  init() throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
      .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func package(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
}
