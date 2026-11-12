import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class SessionOrderingTests: AppSessionTestCase {
  func testSessionCreationUsesThePublishedTimestampForMembership() async throws {
    var sent: LinkstrPayload?
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        sent = payload
        return SentPayloadReceipt(rumorEventID: "creation", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let created = await session.createSessionAwaitingRelay(name: "Session", memberNPubs: [])
    let payload = try XCTUnwrap(sent)
    let target = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<SessionEntity>()).first)
    let timestamp = Date(timeIntervalSince1970: TimeInterval(payload.timestamp))

    XCTAssertTrue(created)
    XCTAssertEqual(target.membershipStateUpdatedAt, timestamp)
    XCTAssertTrue(try session.messageStore.isMemberActive(
      sessionID: target.sessionID, ownerPubkey: owner, memberPubkey: owner, at: timestamp
    ))
  }

  func testSequentialMembershipUpdatesKeepTheirOrderOnTheWire() async throws {
    var payloads: [LinkstrPayload] = []
    let (session, container) = try makeSession(
      disableNostrStartup: false, hasConnectedRelays: { true },
      sendPayload: { payload, _ in
        payloads.append(payload)
        return SentPayloadReceipt(rumorEventID: "update-\(payloads.count)", publishedEventIDs: [])
      }
    )
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let target = try insertSessionFixture(
      in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
    )
    let first = await session.updateSessionMembersAwaitingRelay(session: target, memberNPubs: [], sessionName: "First")
    let second = await session.updateSessionMembersAwaitingRelay(
      session: target, memberNPubs: [], sessionName: "Second")
    let firstPayload = try XCTUnwrap(payloads.first)
    let secondPayload = try XCTUnwrap(payloads.last)

    XCTAssertTrue(first && second)
    XCTAssertEqual(payloads.count, 2)
    XCTAssertGreaterThan(secondPayload.timestamp, firstPayload.timestamp)
    XCTAssertEqual(target.membershipStateUpdatedAt, Date(timeIntervalSince1970: TimeInterval(secondPayload.timestamp)))
    XCTAssertEqual(target.name, "Second")
  }

  func testMembershipCompletionAcceptsItsOwnEchoButPreservesNewerSnapshots() async throws {
    for newerSnapshot in [false, true] {
      var sent: LinkstrPayload?
      var release: CheckedContinuation<Void, Never>?
      let started = expectation(description: "membership publication started")
      let (session, container) = try makeSession(
        disableNostrStartup: false, hasConnectedRelays: { true },
        sendPayload: { payload, _ in
          sent = payload
          await withCheckedContinuation {
            release = $0
            started.fulfill()
          }
          return SentPayloadReceipt(rumorEventID: "local-update", publishedEventIDs: [])
        }
      )
      try session.identityService.createNewIdentity()
      let owner = try XCTUnwrap(session.identityService.pubkeyHex)
      let target = try insertSessionFixture(
        in: container.mainContext, ownerPubkey: owner, createdByPubkey: owner, memberPubkeys: [owner]
      )
      let publication = Task {
        await session.updateSessionMembersAwaitingRelay(session: target, memberNPubs: [], sessionName: "Local")
      }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      let payload = try XCTUnwrap(sent)
      let timestamp = payload.timestamp + (newerSnapshot ? 10 : 0)
      let outcome = session.persistIncomingSessionMembers(ReceivedDirectMessage(
        eventID: newerSnapshot ? "remote-update" : "local-update", transportEventID: nil, senderPubkey: owner,
        payload: LinkstrPayload(
          conversationID: target.sessionID, rootID: "update", kind: .sessionMembers,
          url: nil, note: nil, timestamp: timestamp, sessionName: newerSnapshot ? "Remote" : "Local",
          memberPubkeys: [owner]
        ), createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)), source: .historical
      ))
      release?.resume()
      let didUpdate = await publication.value

      XCTAssertEqual(outcome, .applied)
      XCTAssertEqual(didUpdate, !newerSnapshot)
      XCTAssertEqual(target.name, newerSnapshot ? "Remote" : "Local")
    }
  }
}
