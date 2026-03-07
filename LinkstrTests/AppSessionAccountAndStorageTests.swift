import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
final class AppSessionAccountAndStorageTests: AppSessionTestCase {
  func testLogoutClearLocalDataRemovesContactsAndMessages() async throws {
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

    session.logout(clearLocalData: true)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
  }

  func testLogoutWithoutClearingLocalDataKeepsContactsAndMessages() async throws {
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

    session.logout(clearLocalData: false)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(try fetchContacts(in: container.mainContext).count, 1)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).count, 1)
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
  func testLogoutClearLocalDataRemovesStoredThumbnailFiles() throws {
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

    session.logout(clearLocalData: true)

    XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
  }

  func testLogoutClearLocalDataDoesNotRemoveUnmanagedThumbnailFiles() throws {
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

    session.logout(clearLocalData: true)

    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
  }

  func testContactDuplicationIsScopedPerAccount() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let firstOwner = try XCTUnwrap(session.identityService.pubkeyHex)
    let sharedNPub = try TestKeyMaterialFactory.makeNPub()
    let didAddFirst = await session.addContact(npub: sharedNPub, alias: "Alice-A")
    XCTAssertTrue(didAddFirst)

    let secondKeypair = try TestKeyMaterialFactory.makeKeypair()
    session.logout(clearLocalData: false)
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
    session.logout(clearLocalData: false)
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
