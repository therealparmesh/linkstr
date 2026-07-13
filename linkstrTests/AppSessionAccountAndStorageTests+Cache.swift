import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionAccountAndStorageTests {
  func testBootStartsNostrWithoutWaitingForSecondForegroundEvent() async throws {
    var nostrStartCount = 0
    let (session, container) = try makeSession(
      skipPersistedFollowListStateLoad: true,
      onNostrStart: {
        nostrStartCount += 1
      }
    )
    _ = container
    try session.identityService.createNewIdentity()

    await session.boot()

    for _ in 0..<10 where nostrStartCount == 0 {
      await Task.yield()
    }

    XCTAssertTrue(session.didFinishBoot)
    XCTAssertEqual(nostrStartCount, 1)
  }

  func testCreateAccountAfterBootStartsNostr() async throws {
    var nostrStartCount = 0
    let (session, container) = try makeSession(
      skipPersistedFollowListStateLoad: true,
      onNostrStart: {
        nostrStartCount += 1
      }
    )
    _ = container

    await session.boot()

    XCTAssertTrue(session.didFinishBoot)
    XCTAssertEqual(nostrStartCount, 0)

    session.createAccount()
    for _ in 0..<10 where nostrStartCount == 0 {
      await Task.yield()
    }

    XCTAssertTrue(session.hasIdentity)
    XCTAssertEqual(nostrStartCount, 1)
  }

  func testClearableCachedMediaBytesAggregatesRetainedAccountVideoUsage() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)

    let firstThumbnailURL = makeManagedThumbnailURL()
    let firstCachedMediaURL = makeManagedVideoURL()
    try Data("thumb-a".utf8).write(to: firstThumbnailURL, options: .atomic)
    let firstVideoData = Data("video-a".utf8)
    try firstVideoData.write(to: firstCachedMediaURL, options: .atomic)
    try insertRetainedAccountStorageFixture(
      in: container.mainContext,
      ownerPubkey: firstOwner,
      label: "first",
      thumbnailURL: firstThumbnailURL,
      cachedMediaURL: firstCachedMediaURL
    )

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logOut(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    let secondThumbnailURL = makeManagedThumbnailURL()
    let secondCachedMediaURL = makeManagedVideoURL()
    try Data("thumb-b".utf8).write(to: secondThumbnailURL, options: .atomic)
    let secondVideoData = Data("video-bb".utf8)
    try secondVideoData.write(to: secondCachedMediaURL, options: .atomic)
    try insertRetainedAccountStorageFixture(
      in: container.mainContext,
      ownerPubkey: secondOwner,
      label: "second",
      thumbnailURL: secondThumbnailURL,
      cachedMediaURL: secondCachedMediaURL
    )

    let clearableStorageBytes = session.clearableStorageUsage().cachedMediaBytes

    XCTAssertEqual(clearableStorageBytes, Int64(firstVideoData.count + secondVideoData.count))
  }

  func testClearableMetadataBytesAggregatesRetainedAccountPreviewUsage() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)

    let firstThumbnailData = Data("thumb-a".utf8)
    let firstThumbnailURL = makeManagedThumbnailURL()
    let firstCachedMediaURL = makeManagedVideoURL()
    try firstThumbnailData.write(to: firstThumbnailURL, options: .atomic)
    try Data("video-a".utf8).write(to: firstCachedMediaURL, options: .atomic)
    try insertRetainedAccountStorageFixture(
      in: container.mainContext,
      ownerPubkey: firstOwner,
      label: "first",
      thumbnailURL: firstThumbnailURL,
      cachedMediaURL: firstCachedMediaURL
    )

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logOut(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    let secondThumbnailData = Data("thumb-bb".utf8)
    let secondThumbnailURL = makeManagedThumbnailURL()
    let secondCachedMediaURL = makeManagedVideoURL()
    try secondThumbnailData.write(to: secondThumbnailURL, options: .atomic)
    try Data("video-b".utf8).write(to: secondCachedMediaURL, options: .atomic)
    try insertRetainedAccountStorageFixture(
      in: container.mainContext,
      ownerPubkey: secondOwner,
      label: "second",
      thumbnailURL: secondThumbnailURL,
      cachedMediaURL: secondCachedMediaURL
    )

    let clearableMetadataBytes = session.clearableStorageUsage().previewBytes

    XCTAssertEqual(
      clearableMetadataBytes,
      Int64(firstThumbnailData.count + secondThumbnailData.count)
    )
  }

  func testRefreshPostMetadataUpdatesStoredMetadataWhenPreviewChanges() async throws {
    let refreshedThumbnailURL = makeManagedThumbnailURL()
    try Data("refreshed-thumbnail".utf8).write(to: refreshedThumbnailURL, options: .atomic)
    defer {
      try? FileManager.default.removeItem(at: refreshedThumbnailURL)
    }

    let (session, container) = try makeSession(
      fetchLinkPreview: { _ in
        LinkPreviewData(title: "Refreshed Title", thumbnailPath: refreshedThumbnailURL.path)
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let message = try makeMessage(
      eventID: "message-refresh-metadata",
      conversationID: "conversation-refresh-metadata",
      rootID: "message-refresh-metadata",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Old Title", thumbnailURL: nil)
    container.mainContext.insert(message)
    try container.mainContext.save()

    let result = await session.refreshPostMetadata(message)

    let stored = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertTrue(result)
    XCTAssertEqual(stored.metadataTitle, "Refreshed Title")
    XCTAssertEqual(stored.thumbnailURL, refreshedThumbnailURL.path)
  }

  func testRefreshPostMetadataReturnsFalseWhenPreviewMatchesStoredMetadata() async throws {
    let thumbnailURL = makeManagedThumbnailURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }

    let (session, container) = try makeSession(
      fetchLinkPreview: { _ in
        LinkPreviewData(title: "Same Title", thumbnailPath: thumbnailURL.path)
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let message = try makeMessage(
      eventID: "message-refresh-noop",
      conversationID: "conversation-refresh-noop",
      rootID: "message-refresh-noop",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Same Title", thumbnailURL: thumbnailURL.path)
    container.mainContext.insert(message)
    try container.mainContext.save()

    let result = await session.refreshPostMetadata(message)

    let stored = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertFalse(result)
    XCTAssertEqual(stored.metadataTitle, "Same Title")
    XCTAssertEqual(stored.thumbnailURL, thumbnailURL.path)
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

  func testContactDuplicationIsScopedPerAccount() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    let sharedNPub = try TestKeyMaterialFactory.makeNPub()
    let didAddFirst = await session.addContact(npub: sharedNPub, alias: "Alice-A")
    XCTAssertTrue(didAddFirst)

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logOut(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    XCTAssertNotEqual(firstOwner, secondOwner)

    let didAddSecond = await session.addContact(npub: sharedNPub, alias: "Alice-B")
    XCTAssertTrue(didAddSecond)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 2)
    XCTAssertEqual(Set(contacts.map(\.ownerPubkey)).count, 2)
  }

  func testSameEventIDCanBeStoredForDifferentAccounts() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)

    let firstMessage = try makeMessage(
      eventID: "shared-event-id",
      conversationID: "conversation-a",
      rootID: "shared-event-id",
      kind: .root,
      senderPubkey: "peer-a",
      receiverPubkey: firstOwner,
      ownerPubkey: firstOwner
    )
    container.mainContext.insert(firstMessage)
    try container.mainContext.save()

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logOut(clearLocalData: false)
    session.importNsec(secondKeypair.privateKey.nsec)
    let secondOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    XCTAssertNotEqual(firstOwner, secondOwner)

    let secondMessage = try makeMessage(
      eventID: "shared-event-id",
      conversationID: "conversation-b",
      rootID: "shared-event-id",
      kind: .root,
      senderPubkey: "peer-b",
      receiverPubkey: secondOwner,
      ownerPubkey: secondOwner
    )
    container.mainContext.insert(secondMessage)
    XCTAssertNoThrow(try container.mainContext.save())

    let messages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(Set(messages.map(\.ownerPubkey)).count, 2)
    XCTAssertEqual(Set(messages.map(\.storageID)).count, 2)
  }

  func insertRetainedAccountStorageFixture(
    in context: ModelContext,
    ownerPubkey: String,
    label: String,
    thumbnailURL: URL,
    cachedMediaURL: URL
  ) throws {
    let sessionEntity = try SessionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: "session-\(label)",
      name: "Session \(label)",
      createdByPubkey: ownerPubkey,
      createdAt: .now,
      updatedAt: .now,
      isArchived: true
    )
    context.insert(sessionEntity)

    let contact = try ContactEntity(
      ownerPubkey: ownerPubkey,
      targetPubkey: String(repeating: label == "first" ? "a" : "b", count: 64),
      alias: "Alias \(label)"
    )
    context.insert(contact)

    let message = try makeMessage(
      eventID: "message-\(label)",
      conversationID: "session-\(label)",
      rootID: "message-\(label)",
      kind: .root,
      senderPubkey: "peer-\(label)",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title \(label)", thumbnailURL: thumbnailURL.path)
    message.cachedMediaPath = cachedMediaURL.path
    message.cachedMediaSourceURL = "https://example.com/\(label).mp4"
    context.insert(message)
    try context.save()
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
