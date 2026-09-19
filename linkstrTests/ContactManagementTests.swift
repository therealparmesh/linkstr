import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class ContactManagementTests: AppSessionTestCase {
  func testContactEditsPreserveFollowTagMetadataAfterUpgrade() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let retainedKey = try TestKeyMaterialFactory.makePubkeyHex()
    let removedKey = try TestKeyMaterialFactory.makePubkeyHex()
    let newKey = try TestKeyMaterialFactory.makePubkeyHex()
    let retainedTag = try PubkeyTag(
      pubkey: retainedKey, relayURL: URL(string: "wss://relay.example"), petname: "public name").tag
    let otherTag = try JSONDecoder().decode(Tag.self, from: Data("[\"custom\",\"value\"]".utf8))
    let incoming = ReceivedFollowList(
      eventID: "initial", authorPubkey: owner, followedPubkeys: [retainedKey, removedKey],
      createdAt: Date(timeIntervalSince1970: 100),
      tags: [retainedTag, try PubkeyTag(pubkey: removedKey).tag, otherTag])
    try session.applyFollowListState(incoming)
    let state = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    state.followListTags = nil
    try container.mainContext.save()
    session.ingestFollowListForTesting(incoming)

    let added = await session.ensureContact(pubkey: newKey)
    XCTAssertTrue(added)
    let removedContact = try XCTUnwrap(
      fetchContacts(in: container.mainContext).first { $0.targetPubkey == removedKey })
    let removed = await session.removeContact(removedContact)
    XCTAssertTrue(removed)
    let tags = try session.accountStateStore.followListTags(ownerPubkey: owner)
    XCTAssertTrue(tags.contains(retainedTag))
    XCTAssertTrue(tags.contains(otherTag))
    XCTAssertEqual(Set(tags.filter { $0.name == "p" }.map(\.value)), Set([retainedKey, newKey]))
  }

  func testQueuedChangesPreserveOtherContactsAndQuickAddPreservesAlias() async throws {
    var lists: [[String]] = []
    var release: CheckedContinuation<Void, Never>?
    let publicationStarted = expectation(description: "publication started")
    var shouldSuspend = false
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishFollowList: { keys in
        lists.append(keys)
        if shouldSuspend {
          shouldSuspend = false
          await withCheckedContinuation {
            release = $0
            publicationStarted.fulfill()
          }
        }
        return "receipt-\(lists.count)"
      }
    )
    try session.identityService.createNewIdentity()
    let first = try TestKeyMaterialFactory.makeNPub()
    let second = try TestKeyMaterialFactory.makePubkeyHex()
    let added = await session.addContact(npub: first, alias: "private name")
    XCTAssertTrue(added)
    let contact = try XCTUnwrap(fetchContacts(in: container.mainContext).first)
    let firstKey = contact.targetPubkey
    let ensured = await session.ensureContact(pubkey: firstKey)
    XCTAssertTrue(ensured)
    XCTAssertEqual(contact.localAlias, "private name")
    XCTAssertEqual(lists.count, 1)

    shouldSuspend = true
    let add = Task { await session.ensureContact(pubkey: second) }
    await fulfillment(of: [publicationStarted], timeout: 1)
    let remove = Task { await session.removeContact(contact) }
    release?.resume()
    let addResult = await add.value
    let removeResult = await remove.value
    XCTAssertTrue(addResult)
    XCTAssertTrue(removeResult)
    XCTAssertEqual(lists.count, 3)
    XCTAssertEqual(lists[1], [firstKey, second].sorted())
    XCTAssertEqual(lists[2], [second])
    XCTAssertEqual(try fetchContacts(in: container.mainContext).map(\.targetPubkey), [second])
    XCTAssertEqual(session.latestAppliedFollowListEventID, "receipt-3")
    let watermark = try session.accountStateStore.followListWatermark(
      ownerPubkey: XCTUnwrap(session.identityService.pubkeyHex))
    XCTAssertEqual(watermark.createdAt, session.latestAppliedFollowListCreatedAt)
    XCTAssertEqual(watermark.eventID, "receipt-3")
  }

  func testNewerRemoteListDuringPublicationIsRebased() async throws {
    var release: CheckedContinuation<Void, Never>?
    var lists: [[String]] = []
    let started = expectation(description: "first publication")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishFollowList: { keys in
        lists.append(keys)
        if lists.count == 1 {
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
        }
        return "receipt-\(lists.count)"
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let local = try TestKeyMaterialFactory.makePubkeyHex()
    let remote = try TestKeyMaterialFactory.makePubkeyHex()
    let add = Task { await session.ensureContact(pubkey: local) }
    await fulfillment(of: [started], timeout: 1)
    session.ingestFollowListForTesting(
      ReceivedFollowList(
        eventID: "remote", authorPubkey: owner, followedPubkeys: [remote],
        createdAt: .now.addingTimeInterval(2)
      ))
    release?.resume()
    let result = await add.value
    XCTAssertTrue(result)
    XCTAssertEqual(lists, [[local], [local, remote].sorted()])
    XCTAssertEqual(
      Set(try fetchContacts(in: container.mainContext).map(\.targetPubkey)), Set([local, remote]))
  }

  func testSigningOutDiscardsInFlightAndQueuedContactChanges() async throws {
    var release: CheckedContinuation<Void, Never>?
    var publications = 0
    let started = expectation(description: "publication")
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      publishFollowList: { _ in
        publications += 1
        await withCheckedContinuation {
          release = $0
          started.fulfill()
        }
        return "receipt"
      }
    )
    try session.identityService.createNewIdentity()
    let first = try TestKeyMaterialFactory.makePubkeyHex()
    let second = try TestKeyMaterialFactory.makePubkeyHex()
    let add = Task { await session.ensureContact(pubkey: first) }
    await fulfillment(of: [started], timeout: 1)
    let queued = Task { await session.ensureContact(pubkey: second) }
    await Task.yield()
    session.logOut(clearLocalData: false)
    release?.resume()
    let firstResult = await add.value
    let secondResult = await queued.value
    XCTAssertFalse(firstResult)
    XCTAssertFalse(secondResult)
    XCTAssertEqual(publications, 1)
    XCTAssertTrue(try fetchContacts(in: container.mainContext).isEmpty)
  }

  func testProfileLookupsAreBoundedAndEmptyResultsExpire() throws {
    var batches: [[String]] = []
    let (session, _) = try makeSession(requestProfileMetadata: {
      batches.append($0)
      return true
    })
    defer { session.pauseRemoteProfileRequests() }
    let keys = try (0..<101).map { _ in try TestKeyMaterialFactory.makePubkeyHex() }.sorted()
    session.requestRemoteProfilesIfNeeded(pubkeyHexes: keys)
    XCTAssertEqual(batches.map(\.count), [50, 50])
    session.finishRemoteProfileLookup(try lookupID(for: batches[0], in: session), completed: true)
    XCTAssertEqual(batches.map(\.count), [50, 50, 1])
    session.requestRemoteProfilesIfNeeded(pubkeyHexes: keys)
    XCTAssertEqual(batches.count, 3)
    let key = try XCTUnwrap(batches[0].first)
    session.remoteProfileRetryAfter[key] = .distantPast
    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [key])
    XCTAssertEqual(batches.count, 3)
    session.finishRemoteProfileLookup(try lookupID(for: batches[1], in: session), completed: true)
    XCTAssertEqual(batches.last, [key])
    XCTAssertEqual(session.remoteProfileAttempts[key], 1)
    XCTAssertNil(session.remoteProfilesByPubkey[key])
    let expiredRequest = try lookupID(for: [key], in: session)
    session.finishRemoteProfileLookup(expiredRequest, completed: false)
    let retry = try lookupID(for: [key], in: session)
    session.finishRemoteProfileLookup(expiredRequest, completed: true)
    XCTAssertNotNil(session.remoteProfileLookups[retry])
    for _ in 0..<2 {
      session.finishRemoteProfileLookup(try lookupID(for: [key], in: session), completed: false)
    }
    let attempts = batches.count
    session.requestRemoteProfilesIfNeeded(pubkeyHexes: [key])
    XCTAssertEqual(batches.count, attempts)
    XCTAssertEqual(session.remoteProfileAttempts[key], 3)
  }

  func testSmallProfileRequestsShareTheSameTwoBatchLimit() throws {
    var batches: [[String]] = []
    let (session, _) = try makeSession(requestProfileMetadata: {
      batches.append($0)
      return true
    })
    defer { session.pauseRemoteProfileRequests() }
    let keys = try (0..<5).map { _ in try TestKeyMaterialFactory.makePubkeyHex() }
    for key in keys { session.requestRemoteProfilesIfNeeded(pubkeyHexes: [key]) }
    XCTAssertEqual(batches, [[keys[0]], [keys[1]]])

    let firstRequest = try lookupID(for: batches[0], in: session)
    session.finishRemoteProfileLookup(firstRequest, completed: true)
    XCTAssertEqual(batches[2], Array(keys.suffix(3)).sorted())
    XCTAssertEqual(session.remoteProfileLookups.count, 2)
    session.finishRemoteProfileLookup(firstRequest, completed: true)
    XCTAssertEqual(batches.count, 3)
  }

  private func lookupID(for keys: [String], in session: AppSession) throws -> UUID {
    try XCTUnwrap(session.remoteProfileLookups.first { Set($0.value.keys) == Set(keys) }?.key)
  }
}
