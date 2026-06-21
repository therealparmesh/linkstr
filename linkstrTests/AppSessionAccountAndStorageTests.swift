import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class AppSessionAccountAndStorageTests: AppSessionTestCase {
  private struct CleanupFailure: LocalizedError {
    var errorDescription: String? {
      "couldn't remove account keys from this device."
    }
  }

  func testLogOutClearLocalDataRemovesContactsAndMessages() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()
    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let message = try makeMessage(
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

    let message = try makeMessage(
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

    let message = try makeMessage(
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
    async throws {
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
    let message = try makeMessage(
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
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
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
    let message = try makeMessage(
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
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
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
    let (session, container) = try makeSession(
      loadIdentity: { identityService in
        loadAttempts += 1
        if loadAttempts == 1 {
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

    XCTAssertTrue(session.didFinishBoot)
    XCTAssertTrue(session.hasIdentity)
    XCTAssertGreaterThanOrEqual(loadAttempts, 2)
  }

  func testLogOutClearLocalDataSurfacesCleanupFailure() throws {
    let (session, container) = try makeSession(
      clearLocalAccountData: { _ in
        throw CleanupFailure()
      }
    )
    _ = container
    try session.identityService.createNewIdentity()

    session.logOut(clearLocalData: true)

    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(
      session.composeError,
      "signed out, but some local data could not be removed. couldn't remove account keys from this device."
    )
  }

  func testDeleteAccountAwaitingRelaySurfacesCleanupFailureAfterIdentityClears() async throws {
    let (session, container) = try makeSession(
      clearLocalAccountData: { _ in
        throw CleanupFailure()
      }
    )
    _ = container
    try session.identityService.createNewIdentity()

    let didDelete = await session.deleteAccountAwaitingRelay()

    XCTAssertFalse(didDelete)
    XCTAssertNil(session.identityService.keypair)
    XCTAssertEqual(
      session.composeError,
      "account deletion finished, but some local data could not be removed. "
        + "couldn't remove account keys from this device."
    )
  }

}
