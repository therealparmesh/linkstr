import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionAccountAndStorageTests: AppSessionTestCase {
  func testLogOutClearLocalDataRemovesContactsAndMessages() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = makeMessage(
      eventID: "message-1",
      conversationID: "conversation-1",
      rootID: "message-1",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: "me",
      ownerPubkey: try XCTUnwrap(session.identityService.pubkeyHex)
    )
    container.mainContext.insert(message)
    try container.mainContext.save()
    XCTAssertEqual(try fetchAccountStates(in: container.mainContext).count, 1)

    session.logOut(clearLocalData: true)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
  }

  func testLogOutWithoutClearingLocalDataKeepsContactsAndMessages() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = makeMessage(
      eventID: "message-2",
      conversationID: "conversation-2",
      rootID: "message-2",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: "me",
      ownerPubkey: try XCTUnwrap(session.identityService.pubkeyHex)
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.logOut(clearLocalData: false)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testCreateAccountRequiresBackupAcknowledgementBeforeLeavingOnboarding() throws {
    let (session, container) = try makeSession()
    _ = container

    session.createAccount()

    XCTAssertTrue(session.hasIdentity)
    XCTAssertTrue(session.shouldShowOnboarding)
    XCTAssertEqual(
      session.pendingCreatedAccountNsec,
      try session.identityService.revealNsec()
    )

    session.completePendingAccountCreation()

    XCTAssertFalse(session.shouldShowOnboarding)
    XCTAssertNil(session.pendingCreatedAccountNsec)
  }

  func testDeleteAccountClearsLocalDataAndIdentityWhenNostrNetworkIsDisabled() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = makeMessage(
      eventID: "message-delete-account",
      conversationID: "conversation-delete-account",
      rootID: "message-delete-account",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)

    let reaction = try SessionReactionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: "conversation-delete-account",
      postID: "message-delete-account",
      emoji: "🔥",
      senderPubkey: "peer",
      isActive: true,
      eventID: "reaction-delete-account"
    )
    container.mainContext.insert(reaction)
    try container.mainContext.save()

    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchReactions(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchAccountStates(in: container.mainContext).count, 1)

    let didDelete = await session.deleteAccountAwaitingRelay()

    XCTAssertTrue(didDelete)
    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchReactions(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
  }

  func testDeleteAccountAwaitingRelayPublishesFollowListAndVanishBeforeLocalCleanup()
    async throws
  {
    var publishedFollowLists: [[String]] = []
    var publishedEventKinds: [Int] = []
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishFollowList: { followedPubkeys in
        publishedFollowLists.append(followedPubkeys)
        return "follow-list-delete-account"
      },
      publishRelayEvent: { event in
        publishedEventKinds.append(event.kind.rawValue)
        return "vanish-delete-account"
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)
    let message = makeMessage(
      eventID: "message-delete-account-online",
      conversationID: "conversation-delete-account-online",
      rootID: "message-delete-account-online",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    let didDelete = await session.deleteAccountAwaitingRelay(
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertTrue(didDelete)
    XCTAssertEqual(publishedFollowLists.last, [])
    XCTAssertEqual(publishedEventKinds, [62])
    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
  }

  func testDeleteAccountAwaitingRelayKeepsLocalDataWhenRelayPublishFails() async throws {
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishFollowList: { _ in "follow-list-delete-account" },
      publishRelayEvent: { _ in
        throw NostrServiceError.publishRejected("blocked: policy")
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)
    let message = makeMessage(
      eventID: "message-delete-account-failure",
      conversationID: "conversation-delete-account-failure",
      rootID: "message-delete-account-failure",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    container.mainContext.insert(message)
    try container.mainContext.save()

    let didDelete = await session.deleteAccountAwaitingRelay(
      timeoutSeconds: 0.05,
      pollIntervalSeconds: 0.01
    )

    XCTAssertFalse(didDelete)
    XCTAssertEqual(session.composeError, "blocked: policy")
    XCTAssertNotNil(session.identityService.keypair)
    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
  }

  func testBootRetriesIdentityLoadBeforeShowingOnboarding() async throws {
    let keypair = try TestKeyMaterialFactory.makeKeypair()
    var loadAttempts = 0
    let (session, _) = try makeSession(
      disableNostrStartup: true,
      loadIdentity: { identityService in
        loadAttempts += 1
        if loadAttempts == 1 {
          return .missing
        }
        try? identityService.importNsec(keypair.privateKey.nsec)
        return .loaded
      },
      identityRetryDelayNanoseconds: 0,
      skipDefaultRelaySetup: true,
      skipPersistedFollowListStateLoad: true
    )

    await session.boot()

    XCTAssertTrue(session.didFinishBoot)
    XCTAssertTrue(session.hasIdentity)
    XCTAssertGreaterThanOrEqual(loadAttempts, 2)
  }

  func testBootStartsNostrWithoutWaitingForSecondForegroundEvent() async throws {
    var nostrStartCount = 0
    let (session, _) = try makeSession(
      disableNostrStartup: true,
      skipDefaultRelaySetup: true,
      skipPersistedFollowListStateLoad: true,
      onNostrStart: {
        nostrStartCount += 1
      }
    )
    try session.identityService.createNewIdentity()

    await session.boot()

    XCTAssertTrue(session.didFinishBoot)
    XCTAssertEqual(nostrStartCount, 1)
  }

  func testCreateAccountAfterBootStartsNostr() async throws {
    var nostrStartCount = 0
    let (session, _) = try makeSession(
      disableNostrStartup: true,
      skipDefaultRelaySetup: true,
      skipPersistedFollowListStateLoad: true,
      onNostrStart: {
        nostrStartCount += 1
      }
    )

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

  func testHandleProtectedDataAvailabilityRetriesIdentityLoad() async throws {
    let keypair = try TestKeyMaterialFactory.makeKeypair()
    var loadAttempts = 0
    var shouldLoadIdentity = false
    let (session, _) = try makeSession(
      disableNostrStartup: true,
      loadIdentity: { identityService in
        defer { loadAttempts += 1 }
        guard shouldLoadIdentity else {
          return .missing
        }
        try? identityService.importNsec(keypair.privateKey.nsec)
        return .loaded
      },
      identityRetryDelayNanoseconds: 0,
      skipDefaultRelaySetup: true,
      skipPersistedFollowListStateLoad: true
    )

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
    let (session, _) = try makeSession(
      disableNostrStartup: true,
      loadIdentity: { identityService in
        defer { loadAttempts += 1 }
        guard shouldLoadIdentity else {
          return .missing
        }
        try? identityService.importNsec(keypair.privateKey.nsec)
        return .loaded
      },
      identityRetryDelayNanoseconds: 0,
      skipDefaultRelaySetup: true,
      skipPersistedFollowListStateLoad: true
    )

    await session.boot()
    XCTAssertFalse(session.hasIdentity)

    shouldLoadIdentity = true
    session.handleAppDidBecomeActive()
    await Task.yield()
    await Task.yield()

    XCTAssertTrue(session.hasIdentity)
    XCTAssertGreaterThanOrEqual(loadAttempts, 2)
  }

  func testLogOutClearLocalDataSurfacesCleanupFailure() throws {
    let (session, _) = try makeSession(
      clearLocalAccountData: { _ in
        throw KeychainStoreError.deleteFailed(errSecNotAvailable)
      }
    )
    try session.identityService.createNewIdentity()

    session.logOut(clearLocalData: true)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(
      session.composeError,
      "signed out, but some local data could not be removed. couldn't remove account keys from this device."
    )
  }

  func testDeleteAccountAwaitingRelaySurfacesCleanupFailureAfterIdentityClears() async throws {
    let (session, _) = try makeSession(
      clearLocalAccountData: { _ in
        throw KeychainStoreError.deleteFailed(errSecNotAvailable)
      }
    )
    try session.identityService.createNewIdentity()

    let didDelete = await session.deleteAccountAwaitingRelay()

    XCTAssertFalse(didDelete)
    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(
      session.composeError,
      "account deletion finished, but some local data could not be removed. couldn't remove account keys from this device."
    )
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
        linkstr couldn't open its local storage on this device. you can retry startup or continue in a temporary in-memory mode. temporary changes won't persist after the app closes.

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

    let message = makeMessage(
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

    let message = makeMessage(
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

  func testClearCachedMediaAndPreviewsRemovesManagedFilesAndClearsHydratedMetadata() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailURL = makeManagedThumbnailURL()
    let cachedMediaURL = makeManagedVideoURL()
    try Data("thumbnail".utf8).write(to: thumbnailURL, options: .atomic)
    try Data("media".utf8).write(to: cachedMediaURL, options: .atomic)

    let message = makeMessage(
      eventID: "message-clear-preview-cache",
      conversationID: "conversation-clear-preview-cache",
      rootID: "message-clear-preview-cache",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title", thumbnailURL: thumbnailURL.path)
    message.cachedMediaPath = cachedMediaURL.path
    message.cachedMediaSourceURL = "https://example.com/video.mp4"
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.clearCachedMediaAndPreviews()

    let stored = try XCTUnwrap(try fetchMessages(in: container.mainContext).first)
    XCTAssertNil(stored.metadataTitle)
    XCTAssertNil(stored.thumbnailURL)
    XCTAssertNil(stored.cachedMediaPath)
    XCTAssertNil(stored.cachedMediaSourceURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedMediaURL.path))
  }

  func testClearableStorageBytesReportsCurrentAccountManagedUsage() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let thumbnailData = Data("thumbnail".utf8)
    let mediaData = Data("cached-video".utf8)
    let thumbnailURL = makeManagedThumbnailURL()
    let cachedMediaURL = makeManagedVideoURL()
    defer {
      try? FileManager.default.removeItem(at: thumbnailURL)
      try? FileManager.default.removeItem(at: cachedMediaURL)
    }

    try thumbnailData.write(to: thumbnailURL, options: .atomic)
    try mediaData.write(to: cachedMediaURL, options: .atomic)

    let message = makeMessage(
      eventID: "message-storage-usage",
      conversationID: "conversation-storage-usage",
      rootID: "message-storage-usage",
      kind: .root,
      senderPubkey: "peer",
      receiverPubkey: ownerPubkey,
      ownerPubkey: ownerPubkey
    )
    try message.setMetadata(title: "Title", thumbnailURL: thumbnailURL.path)
    message.cachedMediaPath = cachedMediaURL.path
    message.cachedMediaSourceURL = "https://example.com/video.mp4"
    container.mainContext.insert(message)
    try container.mainContext.save()

    let clearableStorageBytes = session.clearableStorageBytes()

    XCTAssertEqual(clearableStorageBytes, Int64(thumbnailData.count + mediaData.count))
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

    let firstMessage = makeMessage(
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

    let secondMessage = makeMessage(
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
}

private func makeTemporaryCacheDirectory() -> URL {
  let directory =
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("linkstr-cache-tests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
