import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionAccountAndStorageTests {
  func testClearingPreviewsRemovesThumbnailOnlyMetadataWithoutDeletingUnmanagedFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let unmanaged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("outside managed storage".utf8).write(to: unmanaged)
    defer { try? FileManager.default.removeItem(at: unmanaged) }
    for (index, thumbnail) in ["https://example.com/preview.jpg", unmanaged.path].enumerated() {
      let post = try makeMessage(
        eventID: "thumbnail-only-\(index)", conversationID: "session", rootID: "thumbnail-only-\(index)",
        kind: .root, senderPubkey: owner, receiverPubkey: owner, ownerPubkey: owner)
      try post.setMetadata(title: nil, thumbnailURL: thumbnail)
      container.mainContext.insert(post)
    }
    try container.mainContext.save()
    try session.messageStore.clearCachedMetadata()
    let posts = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(posts.count, 2)
    XCTAssertTrue(posts.allSatisfy { $0.thumbnailURL == nil && $0.metadataTitle == nil })
    XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))
  }

  func testClearingOnePostKeepsVideoUntilItsLastStoredReferenceIsRemoved() throws {
    for usesSystemLocation in [false, true] {
      try checkSharedMediaRemoval(usesSystemLocation: usesSystemLocation)
    }
  }

  private func checkSharedMediaRemoval(usesSystemLocation: Bool) throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let videoURL = usesSystemLocation
      ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
      : makeManagedVideoURL()
    if usesSystemLocation {
      try FileManager.default.createDirectory(at: videoURL, withIntermediateDirectories: true)
      _ = try ManagedLocalFileScope.shared.hlsRegistry.register(
        videoURL, for: URL(string: "https://example.com/\(UUID().uuidString).m3u8")!
      )
    } else {
      try Data("shared video".utf8).write(to: videoURL, options: .atomic)
    }
    defer { try? FileManager.default.removeItem(at: videoURL) }
    let posts = try ["first", "second"].map { id in
      let post = try makeMessage(
        eventID: id, conversationID: "session-\(id)", rootID: id, kind: .root,
        senderPubkey: owner, receiverPubkey: owner, ownerPubkey: owner
      )
      post.cachedMediaPath = videoURL.path
      post.cachedMediaSourceURL = "https://example.com/shared.mp4"
      container.mainContext.insert(post)
      return post
    }
    try container.mainContext.save()

    try session.messageStore.clearCachedMedia(messages: [posts[0]])

    XCTAssertNil(posts[0].cachedMediaPath)
    XCTAssertNil(posts[0].cachedMediaSourceURL)
    XCTAssertEqual(posts[1].cachedMediaPath, videoURL.path)
    XCTAssertEqual(posts[1].cachedMediaSourceURL, "https://example.com/shared.mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))

    try session.messageStore.clearCachedMedia(messages: [posts[1]])

    XCTAssertNil(posts[1].cachedMediaPath)
    XCTAssertNil(posts[1].cachedMediaSourceURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: videoURL.path))
  }

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

    try insertRetainedAccountStorageFixture(
      in: container.mainContext,
      ownerPubkey: secondOwner,
      label: "shared-video",
      thumbnailURL: firstThumbnailURL,
      cachedMediaURL: firstCachedMediaURL
    )

    let clearableStorageBytes = await session.clearableStorageUsage().cachedMediaBytes

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

    let clearableMetadataBytes = await session.clearableStorageUsage().previewBytes

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
    XCTAssertEqual(result, .updated)
    XCTAssertEqual(stored.metadataTitle, "Refreshed Title")
    XCTAssertEqual(stored.thumbnailURL, refreshedThumbnailURL.path)
  }

  func testRefreshPostMetadataReportsUnchangedWithoutNewTitleOrThumbnail() async throws {
    let thumbnailURL = makeManagedThumbnailURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }

    let (session, container) = try makeSession(
      fetchLinkPreview: { _ in
        LinkPreviewData(title: "Same Title", thumbnailPath: nil)
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
    XCTAssertEqual(result, .unchanged)
    XCTAssertEqual(stored.metadataTitle, "Same Title")
    XCTAssertEqual(stored.thumbnailURL, thumbnailURL.path)
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
