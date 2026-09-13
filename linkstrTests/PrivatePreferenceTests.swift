import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class PrivatePreferenceTests: AppSessionTestCase {
  private let codec = PrivatePreferenceCodec()

  func testEncryptedRecordsValidateSignaturesOwnershipAndHiddenIdentifiers() throws {
    let owner = try XCTUnwrap(Keypair())
    let other = try XCTUnwrap(Keypair())
    let preference = PrivatePreference.alias(pubkey: other.publicKey.hex, name: "private nickname")
    let event = try codec.event(for: preference, keypair: owner, createdAt: 100)
    XCTAssertEqual(try codec.preference(from: event, keypair: owner), preference)
    let wire = try XCTUnwrap(String(data: JSONEncoder().encode(event), encoding: .utf8))
    XCTAssertFalse(wire.contains("private nickname"))
    XCTAssertFalse(wire.contains(other.publicKey.hex))
    XCTAssertThrowsError(try codec.preference(from: event, keypair: other))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    object["content"] = event.content + "x"
    let tampered = try JSONDecoder().decode(
      NostrEvent.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertThrowsError(try codec.preference(from: tampered, keypair: owner))
    let changed = PrivatePreference.alias(pubkey: other.publicKey.hex, name: nil)
    XCTAssertEqual(
      codec.identifier(for: preference, keypair: owner),
      codec.identifier(for: changed, keypair: owner))
    XCTAssertNotEqual(
      codec.identifier(for: preference, keypair: owner),
      codec.identifier(for: preference, keypair: other))
  }

  func testIndependentEditsMergeAndClearedValuesSurviveStaleEvents() throws {
    let (session, container) = try makeSession()
    defer { withExtendedLifetime(container) {} }
    let owner = try XCTUnwrap(Keypair())
    let contact = try XCTUnwrap(Keypair()).publicKey.hex
    let store = session.privatePreferenceStore
    let alias = PrivatePreference.alias(pubkey: contact, name: "friend")
    let archive = PrivatePreference.archive(sessionID: "session", archived: true)
    let aliasEvent = try codec.event(for: alias, keypair: owner, createdAt: 100)
    let archiveEvent = try codec.event(for: archive, keypair: owner, createdAt: 101)
    try store.receive(aliasEvent, keypair: owner)
    try store.receive(archiveEvent, keypair: owner)
    XCTAssertEqual(try store.records(ownerPubkey: owner.publicKey.hex).count, 2)
    for (preference, stale) in [
      (PrivatePreference.alias(pubkey: contact, name: nil), aliasEvent),
      (PrivatePreference.archive(sessionID: "session", archived: false), archiveEvent)
    ] {
      let newer = try codec.event(for: preference, keypair: owner, createdAt: 200)
      try store.receive(newer, keypair: owner)
      XCTAssertNil(try store.receive(stale, keypair: owner))
      let stored = try XCTUnwrap(store.record(for: preference, keypair: owner))
      XCTAssertEqual(try codec.preference(from: stored.event(), keypair: owner), preference)
      XCTAssertFalse(stored.needsPublish)
    }
    XCTAssertTrue(try store.records(ownerPubkey: contact).isEmpty)
  }

  func testAddressableTieBreakAndStaleUploadAcknowledgement() throws {
    let (session, container) = try makeSession()
    defer { withExtendedLifetime(container) {} }
    let owner = try XCTUnwrap(Keypair())
    let store = session.privatePreferenceStore
    let preference = PrivatePreference.archive(sessionID: "session", archived: true)
    let events = try [true, false].map {
      try codec.event(
        for: .archive(sessionID: "session", archived: $0), keypair: owner, createdAt: 100)
    }.sorted { $0.id < $1.id }
    try store.receive(events[0], keypair: owner)
    XCTAssertNil(try store.receive(events[1], keypair: owner))
    try store.save(preference, keypair: owner)
    let first = try XCTUnwrap(store.record(for: preference, keypair: owner)).event()
    try store.save(.archive(sessionID: "session", archived: false), keypair: owner)
    let latest = try XCTUnwrap(store.record(for: preference, keypair: owner))
    try store.markPublished(first, keypair: owner)
    XCTAssertTrue(latest.needsPublish)
    XCTAssertGreaterThan(try latest.event().createdAt, first.createdAt)
    try store.markPublished(latest.event(), keypair: owner)
    XCTAssertFalse(latest.needsPublish)
  }

  func testBackupArrivingBeforeContactsAndSessionsRestoresWithoutChangingFollows() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    session.refreshIdentityState()
    let owner = try XCTUnwrap(session.identityService.keypair)
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner.publicKey.hex) }
    let contactPubkey = try XCTUnwrap(Keypair()).publicKey.hex
    for preference in [
      PrivatePreference.alias(pubkey: contactPubkey, name: "friend"),
      PrivatePreference.archive(sessionID: "session", archived: true)
    ] {
      session.receivePrivatePreference(
        try codec.event(for: preference, keypair: owner, createdAt: 100))
    }
    XCTAssertTrue(
      try session.contactStore.followedPubkeys(ownerPubkey: owner.publicKey.hex).isEmpty)
    try session.persistLocalFollowedPubkeys(
      ownerPubkey: owner.publicKey.hex, followedPubkeys: [contactPubkey])
    let contact = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ContactEntity>()).first)
    XCTAssertEqual(contact.localAlias, "friend")
    let conversation = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner.publicKey.hex,
      createdByPubkey: owner.publicKey.hex,
      memberPubkeys: [owner.publicKey.hex], sessionID: "session"
    )
    try session.restorePrivateArchive(sessionID: "session")
    XCTAssertTrue(conversation.isArchived)
    session.preparePrivatePreferenceBackup()
    XCTAssertTrue(
      try session.privatePreferenceStore.records(
        ownerPubkey: owner.publicKey.hex, pendingOnly: true
      ).isEmpty)
  }

  func testExistingLocalValuesSeedOnceAndAreNotRecreatedAfterRemoteClears() throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    session.refreshIdentityState()
    let owner = try XCTUnwrap(session.identityService.keypair)
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner.publicKey.hex) }
    let pubkey = try XCTUnwrap(Keypair()).publicKey.hex
    let contact = try ContactEntity(
      ownerPubkey: owner.publicKey.hex, targetPubkey: pubkey, alias: "legacy",
      createdAt: .distantPast)
    container.mainContext.insert(contact)
    try container.mainContext.save()
    session.preparePrivatePreferenceBackup()
    let records = try session.privatePreferenceStore.records(
      ownerPubkey: owner.publicKey.hex, pendingOnly: true)
    XCTAssertEqual(records.count, 1)
    let event = try XCTUnwrap(records.first).event()
    session.preparePrivatePreferenceBackup()
    XCTAssertEqual(try records.first?.event().id, event.id)
    session.receivePrivatePreference(
      try codec.event(for: .alias(pubkey: pubkey, name: nil), keypair: owner, createdAt: 100))
    XCTAssertNil(contact.localAlias)
    session.preparePrivatePreferenceBackup()
    XCTAssertTrue(
      try session.privatePreferenceStore.records(
        ownerPubkey: owner.publicKey.hex, pendingOnly: true
      ).isEmpty)
  }

  func testCanceledUploadKeepsPendingDataForReconnect() async throws {
    let started = expectation(description: "upload started")
    var finish: CheckedContinuation<String, Error>?
    var retrying = false
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishRelayEvent: { event in
        if retrying { return event.id }
        return try await withCheckedThrowingContinuation {
          finish = $0
          started.fulfill()
        }
      }
    )
    defer { withExtendedLifetime(container) {} }
    try session.identityService.createNewIdentity()
    session.refreshIdentityState()
    let owner = try XCTUnwrap(session.identityService.keypair)
    session.isForeground = true
    try session.savePrivatePreference(.archive(sessionID: "session", archived: true))
    await fulfillment(of: [started], timeout: 1)
    let task = session.privatePreferenceSyncTask
    session.replaceNostrService()
    finish?.resume(returning: "accepted")
    await task?.value
    XCTAssertEqual(
      try session.privatePreferenceStore.records(
        ownerPubkey: owner.publicKey.hex, pendingOnly: true
      ).count, 1)
    retrying = true
    session.schedulePrivatePreferenceSync()
    await session.privatePreferenceSyncTask?.value
    XCTAssertTrue(
      try session.privatePreferenceStore.records(
        ownerPubkey: owner.publicKey.hex, pendingOnly: true
      ).isEmpty)
  }

  func testAddingBackupStoragePreservesExistingEncryptedAliasesOnDisk() throws {
    let owner = try XCTUnwrap(Keypair())
    let pubkey = try XCTUnwrap(Keypair()).publicKey.hex
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner.publicKey.hex)
    }
    let url = directory.appendingPathComponent("preferences.store")
    let encryptedAlias = try autoreleasepool {
      let schema = Schema([ContactEntity.self, SessionEntity.self])
      let container = try ModelContainer(
        for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
      let contact = try ContactEntity(
        ownerPubkey: owner.publicKey.hex, targetPubkey: pubkey, alias: "kept")
      container.mainContext.insert(contact)
      try container.mainContext.save()
      return contact.encryptedAlias
    }
    let schema = Schema([ContactEntity.self, SessionEntity.self, PrivatePreferenceEntity.self])
    let container = try ModelContainer(
      for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    let contact = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<ContactEntity>()).first)
    XCTAssertEqual(contact.encryptedAlias, encryptedAlias)
    XCTAssertEqual(contact.localAlias, "kept")
    let store = PrivatePreferenceStore(modelContext: container.mainContext)
    try store.save(.alias(pubkey: pubkey, name: "kept"), keypair: owner)
    XCTAssertEqual(try store.records(ownerPubkey: owner.publicKey.hex, pendingOnly: true).count, 1)
    XCTAssertEqual(contact.encryptedAlias, encryptedAlias)
  }

  func testRestoreKeepsUnreadableLocalDataUntilOriginalKeyReturns() throws {
    let (session, container) = try makeSession()
    let owner = try XCTUnwrap(Keypair())
    let pubkey = try XCTUnwrap(Keypair()).publicKey.hex
    let keyName = "local_data_key.\(owner.publicKey.hex)"
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner.publicKey.hex) }
    let contact = try ContactEntity(
      ownerPubkey: owner.publicKey.hex, targetPubkey: pubkey, alias: "original")
    container.mainContext.insert(contact)
    try container.mainContext.save()
    let ciphertext = contact.encryptedAlias
    let key = try XCTUnwrap(KeychainStore.shared.get(keyName))
    try LocalDataCrypto.shared.clearKey(ownerPubkey: owner.publicKey.hex)
    session.importNsec(owner.privateKey.nsec)

    session.receivePrivatePreference(
      try codec.event(for: .alias(pubkey: pubkey, name: "synced"), keypair: owner, createdAt: 100))
    XCTAssertEqual(contact.encryptedAlias, ciphertext)
    XCTAssertNil(try KeychainStore.shared.get(keyName))
    XCTAssertNotNil(session.composeError)

    try KeychainStore.shared.set(key, for: keyName)
    try session.restorePrivatePreferences()
    XCTAssertEqual(contact.localAlias, "synced")
    XCTAssertEqual(try KeychainStore.shared.get(keyName), key)
  }
}
