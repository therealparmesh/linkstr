import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionAccountAndStorageTests {
  func testHandleProtectedDataAvailabilityRetriesIdentityLoad() async throws {
    let keypair = try TestKeyMaterialFactory.makeKeypair()
    var loadAttempts = 0
    var shouldLoadIdentity = false
    let (session, container) = try makeSession(
      loadIdentity: { identityService in
        defer { loadAttempts += 1 }
        guard shouldLoadIdentity else {
          return .missing
        }
        try? identityService.importNsec(keypair.privateKey.nsec)
        return .loaded
      },
      identityRetryDelayNanoseconds: 0,
      skipPersistedFollowListStateLoad: true
    )
    _ = container

    await session.boot()
    XCTAssertFalse(session.hasIdentity)

    shouldLoadIdentity = true
    session.handleProtectedDataDidBecomeAvailable()
    await Task.yield()
    await Task.yield()

    XCTAssertTrue(session.hasIdentity)
    XCTAssertGreaterThanOrEqual(loadAttempts, 2)
  }

  func testHandleAppDidBecomeActiveRetriesIdentityLoad() async throws {
    let keypair = try TestKeyMaterialFactory.makeKeypair()
    var loadAttempts = 0
    var shouldLoadIdentity = false
    let (session, container) = try makeSession(
      loadIdentity: { identityService in
        defer { loadAttempts += 1 }
        guard shouldLoadIdentity else {
          return .missing
        }
        try? identityService.importNsec(keypair.privateKey.nsec)
        return .loaded
      },
      identityRetryDelayNanoseconds: 0,
      skipPersistedFollowListStateLoad: true
    )
    _ = container

    await session.boot()
    XCTAssertFalse(session.hasIdentity)

    shouldLoadIdentity = true
    session.handleAppDidBecomeActive()
    await Task.yield()
    await Task.yield()

    XCTAssertTrue(session.hasIdentity)
    XCTAssertGreaterThanOrEqual(loadAttempts, 2)
  }

  func testAppBootstrapFallsBackToRecoveryModeWhenPersistentStoreUnavailable() throws {
    var storeAttempts: [Bool] = []
    let persistentError = NSError(
      domain: "AppBootstrapStateTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "persistent store unavailable"]
    )

    let bootstrap = AppBootstrapState(
      makeContainer: { schema, isStoredInMemoryOnly in
        storeAttempts.append(isStoredInMemoryOnly)
        if isStoredInMemoryOnly == false {
          throw persistentError
        }

        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
      }
    )

    XCTAssertEqual(storeAttempts, [false, true])
    switch bootstrap.startupState {
    case .ready(_, let recoveryMessage, let isUsingTemporaryStore):
      XCTAssertEqual(
        recoveryMessage,
        """
        linkstr couldn't open its local storage on this device. you can retry \
        startup or continue in a temporary in-memory mode. temporary changes \
        won't persist after the app closes.

        storage error: persistent store unavailable
        """
      )
      XCTAssertFalse(isUsingTemporaryStore)
    case .loading, .fatal:
      XCTFail("expected recovery-ready startup state")
    }

    bootstrap.continueWithTemporaryStore()

    switch bootstrap.startupState {
    case .ready(_, _, let isUsingTemporaryStore):
      XCTAssertTrue(isUsingTemporaryStore)
    case .loading, .fatal:
      XCTFail("expected temporary-store startup state")
    }
  }

  func testAppBootstrapShowsFatalStartupMessageWhenAllStoreInitializationFails() {
    let persistentError = NSError(
      domain: "AppBootstrapStateTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "persistent store unavailable"]
    )
    let fallbackError = NSError(
      domain: "AppBootstrapStateTests",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "temporary store unavailable"]
    )

    let bootstrap = AppBootstrapState(
      makeContainer: { _, isStoredInMemoryOnly in
        if isStoredInMemoryOnly {
          throw fallbackError
        }
        throw persistentError
      }
    )

    switch bootstrap.startupState {
    case .fatal(let message):
      XCTAssertEqual(
        message,
        """
        linkstr couldn't start because both persistent and temporary local storage failed to initialize.

        persistent store error: persistent store unavailable

        temporary store error: temporary store unavailable
        """
      )
    case .loading, .ready:
      XCTFail("expected fatal startup state")
    }
  }

  func testLogOutClearLocalDataRemovesStoredThumbnailFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailURL = makeManagedThumbnailURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)

    let message = try makeMessage(
      eventID: "message-thumbnail",
      conversationID: "conversation-thumbnail",
      rootID: "message-thumbnail",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title", thumbnailURL: thumbnailURL.path)
    container.mainContext.insert(message)
    try container.mainContext.save()

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))

    session.logOut(clearLocalData: true)

    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
  }

  func testLogOutClearLocalDataRemovesStoredVideoFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let cachedMediaURL = makeManagedVideoURL()
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let message = try makeMessage(
      eventID: "message-video",
      conversationID: "conversation-video",
      rootID: "message-video",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    message.cachedMediaPath = cachedMediaURL.path
    message.cachedMediaSourceURL = "https://example.com/video.mp4"
    container.mainContext.insert(message)
    try container.mainContext.save()

    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMediaURL.path))

    session.logOut(clearLocalData: true)

    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testLogOutClearLocalDataDoesNotRemoveUnmanagedThumbnailFiles() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailURL = makeUnmanagedTempURL(
      prefix: "linkstr-unmanaged-thumbnail",
      fileExtension: "png"
    )
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)

    let message = try makeMessage(
      eventID: "message-unmanaged-thumbnail",
      conversationID: "conversation-unmanaged-thumbnail",
      rootID: "message-unmanaged-thumbnail",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title", thumbnailURL: thumbnailURL.path)
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.logOut(clearLocalData: true)

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
  }

  func testClearCachedMediaClearsManagedVideoFilesAcrossRetainedAccounts() throws {
    let fixture = try setUpTwoRetainedAccountsWithMedia()
    let session = fixture.session
    let container = fixture.container
    let urls = fixture.urls

    session.clearCachedMedia()

    let storedMessages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(storedMessages.count, 2)
    XCTAssertEqual(
      Set(storedMessages.compactMap(\.metadataTitle)),
      ["Title first", "Title second"]
    )
    XCTAssertEqual(
      Set(storedMessages.compactMap(\.thumbnailURL)),
      [urls.firstThumbnailURL.path, urls.secondThumbnailURL.path]
    )
    XCTAssertTrue(storedMessages.allSatisfy { $0.cachedMediaPath == nil })
    XCTAssertTrue(storedMessages.allSatisfy { $0.cachedMediaSourceURL == nil })
    XCTAssertFalse(FileManager.default.fileExists(atPath: urls.firstCachedMediaURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: urls.secondCachedMediaURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: urls.firstThumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: urls.secondThumbnailURL.path))
    XCTAssertEqual(
      try fetchContacts(in: container.mainContext).compactMap(\.localAlias).sorted(),
      ["Alias first", "Alias second"]
    )
    XCTAssertEqual(
      try container.mainContext.fetch(FetchDescriptor<SessionEntity>())
        .filter { $0.isArchived }
        .map(\.sessionID)
        .sorted(),
      ["session-first", "session-second"]
    )
    XCTAssertNil(session.composeError)
  }

  func testClearCachedMetadataStillWorksWhenSignedOutAcrossRetainedAccounts() throws {
    let fixture = try setUpTwoRetainedAccountsWithMedia()
    let session = fixture.session
    let container = fixture.container
    let urls = fixture.urls

    session.logOut(clearLocalData: false)

    session.clearCachedMetadata()

    let storedMessages = try fetchMessages(in: container.mainContext)
    XCTAssertEqual(storedMessages.count, 2)
    XCTAssertTrue(storedMessages.allSatisfy { $0.metadataTitle == nil })
    XCTAssertTrue(storedMessages.allSatisfy { $0.thumbnailURL == nil })
    XCTAssertEqual(
      Set(storedMessages.compactMap(\.cachedMediaPath)),
      [urls.firstCachedMediaURL.path, urls.secondCachedMediaURL.path]
    )
    XCTAssertEqual(
      Set(storedMessages.compactMap(\.cachedMediaSourceURL)),
      ["https://example.com/first.mp4", "https://example.com/second.mp4"]
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: urls.firstThumbnailURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: urls.secondThumbnailURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: urls.firstCachedMediaURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: urls.secondCachedMediaURL.path))
    XCTAssertEqual(
      try fetchContacts(in: container.mainContext).compactMap(\.localAlias).sorted(),
      ["Alias first", "Alias second"]
    )
    XCTAssertEqual(
      try container.mainContext.fetch(FetchDescriptor<SessionEntity>())
        .filter { $0.isArchived }
        .map(\.sessionID)
        .sorted(),
      ["session-first", "session-second"]
    )
    XCTAssertNil(session.composeError)
  }

  struct RetainedAccountsFixture {
    let session: AppSession
    let container: ModelContainer
    let urls: RetainedAccountURLs
  }

  struct RetainedAccountURLs {
    let firstThumbnailURL: URL
    let firstCachedMediaURL: URL
    let secondThumbnailURL: URL
    let secondCachedMediaURL: URL
  }

  func setUpTwoRetainedAccountsWithMedia() throws -> RetainedAccountsFixture {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)

    let firstThumbnailURL = makeManagedThumbnailURL()
    let firstCachedMediaURL = makeManagedVideoURL()
    let secondThumbnailURL = makeManagedThumbnailURL()
    let secondCachedMediaURL = makeManagedVideoURL()
    try Data("thumb-a".utf8).write(to: firstThumbnailURL, options: .atomic)
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
    try Data("thumb-b".utf8).write(to: secondThumbnailURL, options: .atomic)
    try Data("video-b".utf8).write(to: secondCachedMediaURL, options: .atomic)
    try insertRetainedAccountStorageFixture(
      in: container.mainContext,
      ownerPubkey: secondOwner,
      label: "second",
      thumbnailURL: secondThumbnailURL,
      cachedMediaURL: secondCachedMediaURL
    )

    let urls = RetainedAccountURLs(
      firstThumbnailURL: firstThumbnailURL,
      firstCachedMediaURL: firstCachedMediaURL,
      secondThumbnailURL: secondThumbnailURL,
      secondCachedMediaURL: secondCachedMediaURL
    )
    return RetainedAccountsFixture(session: session, container: container, urls: urls)
  }

}
