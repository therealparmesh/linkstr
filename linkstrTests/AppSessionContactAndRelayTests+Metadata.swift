import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionContactAndRelayTests {
  func testMetadataResponseDoesNotUpdateADeletedPost() async throws {
    var release: CheckedContinuation<LinkPreviewData?, Never>?
    let started = expectation(description: "metadata request")
    let (session, container) = try makeSession(fetchLinkPreview: { _ in
      await withCheckedContinuation {
        release = $0
        started.fulfill()
      }
    })
    try session.identityService.createNewIdentity()
    let message = try makeMetadataRoot(
      eventID: "deleted", url: "metadata-test-deleted",
      ownerPubkey: XCTUnwrap(session.identityService.pubkeyHex))
    let storageID = message.storageID
    container.mainContext.insert(message)
    try container.mainContext.save()
    let refresh = Task { try await session.refreshMetadata(for: message, force: true) }
    await fulfillment(of: [started], timeout: 1)
    container.mainContext.delete(message)
    try container.mainContext.save()
    release?.resume(returning: LinkPreviewData(title: "obsolete", thumbnailPath: nil))

    let changed = try await refresh.value
    XCTAssertFalse(changed)
    XCTAssertNil(try session.messageStore.message(storageID: storageID))
    XCTAssertNil(session.metadataRefreshRetryAfterByStorageID[storageID])
  }

  func testNewerProfileReceivedDuringPublicationIsNotOverwritten() async throws {
    var release: CheckedContinuation<Void, Never>?
    let started = expectation(description: "profile publication")
    var published: NostrEvent?
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishRelayEvent: { event in
        published = event
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        return event.id
      })
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let publication = Task { await session.updateOwnProfileName("Local") }
    await fulfillment(of: [started], timeout: 1)
    let newerDate = try XCTUnwrap(published?.createdDate).addingTimeInterval(1)
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "newer", authorPubkey: owner, createdAt: newerDate, chosenName: "Remote"))
    release?.resume()

    let result = await publication.value
    XCTAssertFalse(result)
    XCTAssertEqual(session.currentProfileName, "Remote")
    XCTAssertEqual(try fetchAccountStates(in: container.mainContext).first?.nostrProfileName, "Remote")
    XCTAssertEqual(session.profileNameErrorMessage, "profile changed on another device. try again.")
  }

  func testSequentialProfileEditsPublishIncreasingTimestamps() async throws {
    var events: [NostrEvent] = []
    let (session, _) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishRelayEvent: { event in
        events.append(event)
        return event.id
      })
    try session.identityService.createNewIdentity()
    let first = await session.updateOwnProfileName("First")
    let second = await session.updateOwnProfileName("Second")
    XCTAssertTrue(first)
    XCTAssertTrue(second)
    XCTAssertEqual(events.count, 2)
    XCTAssertGreaterThan(try XCTUnwrap(events.last?.createdAt), try XCTUnwrap(events.first?.createdAt))
    XCTAssertEqual(session.currentProfileName, "Second")
  }

  func testProfilePublicationCannotUpdateAccountAfterIdentityChanges() async throws {
    var release: CheckedContinuation<Void, Never>?
    let started = expectation(description: "profile publication")
    let (session, _) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishRelayEvent: { event in
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        return event.id
      })
    try session.identityService.createNewIdentity()
    let replacement = try TestKeyMaterialFactory.makeKeypair()
    let publication = Task { await session.updateOwnProfileName("Old Account") }
    await fulfillment(of: [started], timeout: 1)
    session.importNsec(replacement.privateKey.nsec)
    release?.resume()
    let result = await publication.value

    XCTAssertFalse(result)
    XCTAssertEqual(session.identityService.pubkeyHex, replacement.publicKey.hex)
    XCTAssertNil(session.currentProfileName)
    XCTAssertNil(session.profileNameErrorMessage)
  }

  func testContactProfileCachePersistsAndRemainsAccountScoped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let schema = Schema([ContactEntity.self])
    let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("contacts.store"))
    let owner = try TestKeyMaterialFactory.makePubkeyHex()
    let otherOwner = try TestKeyMaterialFactory.makePubkeyHex()
    let target = try TestKeyMaterialFactory.makePubkeyHex()
    let profile = KnownProfileSnapshot(
      chosenName: "Saved Name", updatedAt: Date(timeIntervalSince1970: 200), eventID: "profile"
    )

    do {
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let store = ContactStore(modelContext: container.mainContext)
      try store.replaceFollowedPubkeys(ownerPubkey: owner, pubkeyHexes: [target])
      try store.replaceFollowedPubkeys(ownerPubkey: otherOwner, pubkeyHexes: [target])
      _ = try store.updateProfile(profile, ownerPubkey: owner, targetPubkey: target)
    }

    let container = try ModelContainer(for: schema, configurations: [configuration])
    let contacts = try fetchContacts(in: container.mainContext)
    let contact = try XCTUnwrap(contacts.first { $0.ownerPubkey == owner })
    let otherContact = try XCTUnwrap(contacts.first { $0.ownerPubkey == otherOwner })
    XCTAssertEqual(contact.profileSnapshot, profile)
    XCTAssertEqual(contact.displayName, "Saved Name")
    XCTAssertNil(otherContact.profileSnapshot)

    let store = ContactStore(modelContext: container.mainContext)
    try store.replaceFollowedPubkeys(ownerPubkey: owner, pubkeyHexes: [])
    XCTAssertEqual(try fetchContacts(in: container.mainContext).map(\.ownerPubkey), [otherOwner])
  }

  func testUpdateOwnProfileNamePublishesMergedMetadataContentAndPersistsState() async throws {
    var publishedEvent: NostrEvent?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in
        publishedEvent = event
        return event.id
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let existingContent =
      #"{"about":"still here","display_name":"Old Name","name":"Old Name","picture":"https://example.com/picture.png"}"#
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-self-old",
        authorPubkey: ownerPubkey,
        createdAt: Date(timeIntervalSince1970: 150),
        chosenName: "Old Name",
        rawContent: existingContent
      )
    )

    let didSave = await session.updateOwnProfileName(
      "New Name",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(session.currentProfileName, "New Name")
    XCTAssertEqual(publishedEvent?.kind, .metadata)

    let publishedContentData = try XCTUnwrap(publishedEvent?.content.data(using: .utf8))
    let publishedContent = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publishedContentData) as? [String: String]
    )
    XCTAssertEqual(publishedContent["name"], "New Name")
    XCTAssertEqual(publishedContent["display_name"], "New Name")
    XCTAssertEqual(publishedContent["about"], "still here")
    XCTAssertEqual(publishedContent["picture"], "https://example.com/picture.png")

    let accountState = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    XCTAssertEqual(accountState.nostrProfileName, "New Name")
    XCTAssertEqual(accountState.profileMetadataContent, publishedEvent?.content)
  }

  func testUpdateOwnProfileNameNormalizesWhitespaceBeforePersisting() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()

    let didSave = await session.updateOwnProfileName(
      "  Alice \n\t Bob \u{0007}  ",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(session.currentProfileName, "Alice Bob")

    let accountState = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    let publishedContentData = try XCTUnwrap(
      accountState.profileMetadataContent?.data(using: .utf8))
    let publishedContent = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publishedContentData) as? [String: String]
    )
    XCTAssertEqual(publishedContent["name"], "Alice Bob")
    XCTAssertEqual(publishedContent["display_name"], "Alice Bob")
  }

  func testCancelPendingMetadataRefreshesForHiddenSessionDropsStaleQueuedWork() async throws {
    let recorder = MetadataPreviewRecorder()
    let (session, container) = try makeSession(
      fetchLinkPreview: { url in
        await recorder.record(url)
        if url.contains("first") {
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return LinkPreviewData(title: "preview for \(url)", thumbnailPath: nil)
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let first = try makeMetadataRoot(
      eventID: "first", url: "metadata-test-first", ownerPubkey: myPubkey)
    let second = try makeMetadataRoot(
      eventID: "second", url: "metadata-test-second", ownerPubkey: myPubkey)
    let third = try makeMetadataRoot(
      eventID: "third", url: "metadata-test-third", ownerPubkey: myPubkey)
    container.mainContext.insert(first)
    container.mainContext.insert(second)
    container.mainContext.insert(third)
    try container.mainContext.save()

    session.refreshMetadataForVisiblePostIfNeeded(first)
    session.refreshMetadataForVisiblePostIfNeeded(second)

    let firstRequestDeadline = Date(timeIntervalSinceNow: 1)
    while (await recorder.snapshot()).isEmpty, Date() < firstRequestDeadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let firstSnapshot = await recorder.snapshot()
    XCTAssertEqual(firstSnapshot, ["metadata-test-first"])
    XCTAssertEqual(session.testingPendingMetadataRefreshCount, 2)

    session.cancelPendingMetadataRefreshesForHiddenSession()
    session.refreshMetadataForVisiblePostIfNeeded(third)

    let thirdRequestDeadline = Date(timeIntervalSinceNow: 1)
    while third.metadataTitle == nil, Date() < thirdRequestDeadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let finalSnapshot = await recorder.snapshot()
    XCTAssertEqual(finalSnapshot, ["metadata-test-first", "metadata-test-third"])
    XCTAssertNil(second.metadataTitle)
    XCTAssertEqual(third.metadataTitle, "preview for metadata-test-third")
  }

  func testIncompleteMetadataRefreshWaitsBeforeAutomaticRetry() async throws {
    let recorder = MetadataPreviewRecorder()
    let (session, container) = try makeSession(
      metadataRefreshRetryInterval: 0.2,
      fetchLinkPreview: { url in
        await recorder.record(url)
        return LinkPreviewData(title: "Preview", thumbnailPath: nil)
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)
    let message = try makeMetadataRoot(
      eventID: "cooldown", url: "metadata-test-cooldown", ownerPubkey: myPubkey)
    container.mainContext.insert(message)
    try container.mainContext.save()

    session.refreshMetadataForVisiblePostIfNeeded(message)
    let firstRequestDeadline = Date(timeIntervalSinceNow: 1)
    while session.testingPendingMetadataRefreshCount > 0, Date() < firstRequestDeadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    session.refreshMetadataForVisiblePostIfNeeded(message)
    try await Task.sleep(nanoseconds: 20_000_000)
    let requestCountDuringCooldown = await recorder.snapshot().count
    XCTAssertEqual(requestCountDuringCooldown, 1)

    try await Task.sleep(nanoseconds: 200_000_000)
    session.refreshMetadataForVisiblePostIfNeeded(message)
    let retryDeadline = Date(timeIntervalSinceNow: 1)
    while (await recorder.snapshot()).count < 2, Date() < retryDeadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    while session.testingPendingMetadataRefreshCount > 0, Date() < retryDeadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let requestCountAfterCooldown = await recorder.snapshot().count
    XCTAssertEqual(requestCountAfterCooldown, 2)
  }

  func makeMetadataRoot(
    eventID: String,
    url: String,
    ownerPubkey: String
  ) throws -> SessionMessageEntity {
    try SessionMessageEntity(
      eventID: eventID,
      ownerPubkey: ownerPubkey,
      conversationID: "session-visible-metadata-cancel",
      rootID: eventID,
      kind: .root,
      senderPubkey: ownerPubkey,
      url: url,
      note: nil,
      timestamp: .now,
      linkType: .twitter
    )
  }
}

actor MetadataPreviewRecorder {
  var requestedURLs: [String] = []

  func record(_ url: String) {
    requestedURLs.append(url)
  }

  func snapshot() -> [String] {
    requestedURLs
  }
}
