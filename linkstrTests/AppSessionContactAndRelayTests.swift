import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class AppSessionContactAndRelayTests: AppSessionTestCase {
  func testAddContactStoresTrimmedValues() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: "  \(npub)  ", alias: "  Alice  ")
    XCTAssertTrue(didAdd)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.npub, npub)
    XCTAssertEqual(contacts.first?.displayName, "Alice")
    XCTAssertEqual(contacts.first?.localAlias, "Alice")
    XCTAssertNotEqual(contacts.first?.encryptedAlias, "Alice")
  }

  func testAddContactOverwritesExistingAliasAndRejectsInvalidNPub() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let didAddDuplicate = await session.addContact(npub: "  \(npub)  ", alias: "Alice 2")
    XCTAssertTrue(didAddDuplicate)
    XCTAssertNil(session.composeError)

    let didAddInvalid = await session.addContact(npub: "not-an-npub", alias: "Bob")
    XCTAssertFalse(didAddInvalid)
    XCTAssertEqual(session.composeError, "invalid public key (npub).")

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.npub, npub)
    XCTAssertEqual(contacts.first?.localAlias, "Alice 2")
  }

  func testAddContactOverwriteDoesNotRepublishFollowList() async throws {
    var publishedFollowLists: [[String]] = []
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishFollowList: { followedPubkeys in
        publishedFollowLists.append(followedPubkeys)
        return "follow-list-add-contact"
      }
    )
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let didOverwrite = await session.addContact(npub: npub, alias: "Alice 2")
    XCTAssertTrue(didOverwrite)

    let contacts = try fetchContacts(in: container.mainContext)
    XCTAssertEqual(contacts.count, 1)
    XCTAssertEqual(contacts.first?.localAlias, "Alice 2")
    XCTAssertEqual(publishedFollowLists.count, 1)
    XCTAssertEqual(publishedFollowLists.first, [contacts[0].targetPubkey])
  }

  func testUpdateContactAliasCanSetAndClearAlias() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "Alice")
    XCTAssertTrue(didAdd)

    let contacts = try fetchContacts(in: container.mainContext)
    let alice = try XCTUnwrap(contacts.first)

    let didUpdate = session.updateContactAlias(alice, alias: "Alice Updated")
    XCTAssertTrue(didUpdate)
    XCTAssertEqual(alice.displayName, "Alice Updated")

    let didClearAlias = session.updateContactAlias(alice, alias: "   ")
    XCTAssertTrue(didClearAlias)
    XCTAssertNil(alice.localAlias)
    XCTAssertEqual(alice.displayName, alice.npub)
  }

  func testIncomingProfileMetadataBecomesFallbackDisplayNameUntilAliased() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "")
    XCTAssertTrue(didAdd)

    let initialContact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-alice",
        authorPubkey: initialContact.targetPubkey,
        createdAt: Date(timeIntervalSince1970: 120),
        chosenName: "Alice From Nostr"
      )
    )

    let initialIdentity = session.resolvedIdentity(for: initialContact)
    XCTAssertEqual(initialIdentity.displayName, "Alice From Nostr")
    XCTAssertEqual(initialIdentity.chosenName, "Alice From Nostr")
    XCTAssertNil(initialIdentity.aliasedChosenName)

    let didUpdateAlias = session.updateContactAlias(initialContact, alias: "Alice Local")
    XCTAssertTrue(didUpdateAlias)
    let resolvedIdentity = session.resolvedIdentity(for: initialContact)
    XCTAssertEqual(resolvedIdentity.displayName, "Alice Local")
    XCTAssertEqual(resolvedIdentity.aliasedChosenName, "Alice From Nostr")
  }

  func testIncomingProfileMetadataIgnoresOlderReplaceableEvent() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let npub = try TestKeyMaterialFactory.makeNPub()

    let didAdd = await session.addContact(npub: npub, alias: "")
    XCTAssertTrue(didAdd)

    let contact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-new",
        authorPubkey: contact.targetPubkey,
        createdAt: Date(timeIntervalSince1970: 200),
        chosenName: "New Name"
      )
    )
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-old",
        authorPubkey: contact.targetPubkey,
        createdAt: Date(timeIntervalSince1970: 100),
        chosenName: "Old Name"
      )
    )

    let identity = session.resolvedIdentity(for: contact)
    XCTAssertEqual(identity.displayName, "New Name")
    XCTAssertEqual(identity.chosenName, "New Name")
  }

  func testIncomingProfileMetadataCachesNamesForNonContacts() async throws {
    let (session, container) = try makeSession()
    _ = container
    try session.identityService.createNewIdentity()
    let participantPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-non-contact",
        authorPubkey: participantPubkey,
        createdAt: Date(timeIntervalSince1970: 220),
        chosenName: "Session Peer"
      )
    )

    XCTAssertEqual(session.remoteProfilesByPubkey.count, 1)
    XCTAssertEqual(session.remoteProfilesByPubkey[participantPubkey]?.chosenName, "Session Peer")
    XCTAssertEqual(session.displayName(for: participantPubkey, contacts: []), "Session Peer")
  }

  func testAddContactAppliesCachedKnownProfileMetadataImmediately() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let keypair = try TestKeyMaterialFactory.makeKeypair()

    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-before-follow",
        authorPubkey: keypair.publicKey.hex,
        createdAt: Date(timeIntervalSince1970: 240),
        chosenName: "Known Before Follow"
      )
    )

    let didAdd = await session.addContact(npub: keypair.publicKey.npub, alias: "")
    XCTAssertTrue(didAdd)

    let contact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    let identity = session.resolvedIdentity(for: contact)
    XCTAssertEqual(identity.chosenName, "Known Before Follow")
    XCTAssertEqual(identity.displayName, "Known Before Follow")
  }

  func testRequestRemoteProfilesIfNeededCoalescesImmediateDuplicateRequests() async throws {
    var requestedPubkeyBatches: [[String]] = []
    let (session, container) = try makeSession(
      requestProfileMetadata: { requestedPubkeys in
        requestedPubkeyBatches.append(requestedPubkeys.sorted())
        return true
      }
    )
    _ = container
    try session.identityService.createNewIdentity()
    let firstPubkey = try TestKeyMaterialFactory.makePubkeyHex()
    let secondPubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [firstPubkey, secondPubkey, firstPubkey])
    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [firstPubkey, secondPubkey])

    XCTAssertEqual(requestedPubkeyBatches.count, 1)
    let requestedPubkeys = try XCTUnwrap(requestedPubkeyBatches.first)
    XCTAssertEqual(requestedPubkeys, [firstPubkey, secondPubkey].sorted())
  }

  func testRequestRemoteProfilesIfNeededDoesNotRetainSessionAcrossRetryDelay() async throws {
    weak var weakSession: AppSession?
    var requestedPubkeyBatches: [[String]] = []
    var sessionAndContainer: (AppSession, ModelContainer)? = try makeSession(
      requestProfileMetadata: { requestedPubkeys in
        requestedPubkeyBatches.append(requestedPubkeys.sorted())
        return true
      }
    )
    weakSession = sessionAndContainer?.0

    do {
      let session = try XCTUnwrap(sessionAndContainer?.0)
      try session.identityService.createNewIdentity()
      let pubkey = try TestKeyMaterialFactory.makePubkeyHex()

      session.requestRemoteProfilesIfNeeded(pubkeyHexes: [pubkey])
      XCTAssertEqual(requestedPubkeyBatches, [[pubkey]])
    }

    sessionAndContainer = nil
    for _ in 0..<5 {
      await Task.yield()
    }

    XCTAssertNil(weakSession)
  }

  func testRequestRemoteProfilesIfNeededRetriesWhenLookupPathBecomesAvailable() async throws {
    var allowRequests = false
    var requestedPubkeyBatches: [[String]] = []
    let (session, container) = try makeSession(
      requestProfileMetadata: { requestedPubkeys in
        guard allowRequests else { return false }
        requestedPubkeyBatches.append(requestedPubkeys.sorted())
        return true
      },
      remoteProfileLookupRetryNanoseconds: shortRemoteProfileLookupRetryNanoseconds
    )
    _ = container
    try session.identityService.createNewIdentity()
    let pubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [pubkey])
    XCTAssertTrue(requestedPubkeyBatches.isEmpty)

    allowRequests = true
    session.simulateRuntimeRelayStatusForTesting(
      relayURL: "wss://relay.example", status: .connected)

    XCTAssertEqual(requestedPubkeyBatches, [[pubkey]])
  }
}

extension AppSessionContactAndRelayTests {
  func testDisconnectedRelayStatusIsAppliedImmediatelyAfterConnecting() throws {
    let (session, container) = try makeSession()
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()

    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .connected)
    session.simulateRuntimeRelayStatusForTesting(relayURL: relay.url, status: .disconnected)

    XCTAssertEqual(session.relayStatus(for: relay), .disconnected)
  }

  func testStaleRelayCallbackDoesNotUpdateReplacementRuntime() async throws {
    let (session, container) = try makeSession()
    let relay = RelayEntity(url: "wss://relay.example.com")
    container.mainContext.insert(relay)
    try container.mainContext.save()
    session.beginForegroundCycle()
    let staleHandler = session.makeRelayStatusHandler()

    session.replaceNostrService()
    staleHandler(relay.url, .connected, nil)
    await Task.yield()

    XCTAssertEqual(session.relayStatus(for: relay), .disconnected)
  }

  func testRemoteProfileRetryStopsAfterProfileStateReset() async throws {
    var requestedPubkeyBatches: [[String]] = []
    let (session, _) = try makeSession(
      requestProfileMetadata: { requestedPubkeys in
        requestedPubkeyBatches.append(requestedPubkeys)
        return true
      },
      remoteProfileLookupRetryNanoseconds: shortRemoteProfileLookupRetryNanoseconds
    )
    let pubkey = try TestKeyMaterialFactory.makePubkeyHex()

    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [pubkey])
    session.resetRemoteProfileStateInMemory()
    try await Task.sleep(nanoseconds: shortRemoteProfileLookupRetryNanoseconds * 2)

    XCTAssertEqual(requestedPubkeyBatches, [[pubkey]])
  }
}
