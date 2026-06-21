import SwiftData
import XCTest

@testable import linkstr

extension AppSessionIngestTests {

  struct IngestOp {
    let id: String
    let sender: String
    let time: TimeInterval
    let sessionID: String
  }

  // MARK: - Ingest Helpers

  func ingestSessionCreate(
    _ session: AppSession,
    _ event: IngestOp,
    name: String,
    members: [String],
    source: DirectMessageIngestSource = .live
  ) {
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: event.id,
        senderPubkey: event.sender,
        createdAt: Date(timeIntervalSince1970: event.time),
        payload: LinkstrPayload(
          conversationID: event.sessionID,
          rootID: "op-create",
          kind: .sessionCreate,
          url: nil,
          note: nil,
          timestamp: Int64(event.time),
          sessionName: name,
          memberPubkeys: members
        ),
        source: source
      ))
  }

  func ingestSessionMembers(
    _ session: AppSession,
    _ event: IngestOp,
    members: [String],
    rootID: String? = nil,
    name: String? = nil,
    source: DirectMessageIngestSource = .live
  ) {
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: event.id,
        senderPubkey: event.sender,
        createdAt: Date(timeIntervalSince1970: event.time),
        payload: LinkstrPayload(
          conversationID: event.sessionID,
          rootID: rootID ?? "op-\(event.id)",
          kind: .sessionMembers,
          url: nil,
          note: nil,
          timestamp: Int64(event.time),
          sessionName: name,
          memberPubkeys: members
        ),
        source: source
      ))
  }

  func ingestRoot(
    _ session: AppSession,
    _ event: IngestOp,
    url: String,
    note: String? = nil,
    transportEventID: String? = nil,
    source: DirectMessageIngestSource = .live
  ) {
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: event.id,
        transportEventID: transportEventID,
        senderPubkey: event.sender,
        createdAt: Date(timeIntervalSince1970: event.time),
        payload: LinkstrPayload(
          conversationID: event.sessionID,
          rootID: event.id,
          kind: .root,
          url: url,
          note: note,
          timestamp: Int64(event.time)
        ),
        source: source
      ))
  }

  func ingestReaction(
    _ session: AppSession,
    _ event: IngestOp,
    rootID: String,
    emoji: String = "👍",
    active: Bool = true,
    source: DirectMessageIngestSource = .live
  ) {
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: event.id,
        senderPubkey: event.sender,
        createdAt: Date(timeIntervalSince1970: event.time),
        payload: LinkstrPayload(
          conversationID: event.sessionID,
          rootID: rootID,
          kind: .reaction,
          url: nil,
          note: nil,
          timestamp: Int64(event.time),
          emoji: emoji,
          reactionActive: active
        ),
        source: source
      ))
  }

  func ingestRootDelete(
    _ session: AppSession,
    _ event: IngestOp,
    rootID: String,
    source: DirectMessageIngestSource = .live
  ) {
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: event.id,
        senderPubkey: event.sender,
        createdAt: Date(timeIntervalSince1970: event.time),
        payload: LinkstrPayload(
          conversationID: event.sessionID,
          rootID: rootID,
          kind: .rootDelete,
          url: nil,
          note: nil,
          timestamp: Int64(event.time)
        ),
        source: source
      ))
  }

  func ingestSessionDelete(
    _ session: AppSession,
    _ event: IngestOp,
    rootID: String? = nil,
    source: DirectMessageIngestSource = .live
  ) {
    session.ingestForTesting(
      makeIncomingMessage(
        eventID: event.id,
        senderPubkey: event.sender,
        createdAt: Date(timeIntervalSince1970: event.time),
        payload: LinkstrPayload(
          conversationID: event.sessionID,
          rootID: rootID ?? "op-\(event.id)",
          kind: .sessionDelete,
          url: nil,
          note: nil,
          timestamp: Int64(event.time)
        ),
        source: source
      ))
  }

  // MARK: - Assertion Helpers

  func assertSessionFullyPurged(
    in context: ModelContext,
    ownerPubkey: String,
    sessionID: String,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    XCTAssertTrue(
      try context.fetch(
        FetchDescriptor<SessionEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty, file: file, line: line)
    XCTAssertTrue(
      try context.fetch(
        FetchDescriptor<SessionMemberEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty, file: file, line: line)
    XCTAssertTrue(
      try context.fetch(
        FetchDescriptor<SessionMemberIntervalEntity>(
          predicate: #Predicate { $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID }
        )
      ).isEmpty, file: file, line: line)
  }

  func assertActiveMembers(
    in context: ModelContext,
    ownerPubkey: String,
    sessionID: String,
    expected: Set<String>,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    let activeMembers = try context.fetch(
      FetchDescriptor<SessionMemberEntity>(
        predicate: #Predicate {
          $0.ownerPubkey == ownerPubkey && $0.sessionID == sessionID && $0.isActive == true
        }
      ))
    XCTAssertEqual(
      Set(activeMembers.map(\.memberPubkey)), expected, file: file, line: line)
  }
}
