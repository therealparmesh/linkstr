import NostrSDK
import XCTest

@testable import linkstr

struct NostrEventTestSupport: EventVerifying {
  static let payloadKinds: [LinkstrPayloadKind] = [
    .root, .rootDelete, .sessionCreate, .sessionMembers, .sessionDelete, .reaction
  ]

  static func payload(
    _ kind: LinkstrPayloadKind, members: [String], sessionID: String = "session",
    rootID: String = String(repeating: "a", count: 64), timestamp: Int64 = 100
  ) -> LinkstrPayload {
    LinkstrPayload(
      conversationID: sessionID, rootID: kind == .root ? "" : rootID, kind: kind,
      url: kind == .root ? "https://example.com" : nil, note: nil, timestamp: timestamp,
      sessionName: kind == .sessionCreate || kind == .sessionMembers ? "Friends" : nil,
      memberPubkeys: kind == .sessionCreate || kind == .sessionMembers ? members : nil,
      emoji: kind == .reaction ? "👍" : nil, reactionActive: kind == .reaction ? true : nil
    )
  }

  static func rumor(_ payload: LinkstrPayload, author: PublicKey) throws -> NostrEvent {
    try payload.validated()
    let content = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
    return NostrEvent.Builder<NostrEvent>(kind: .unknown(44_001))
      .createdAt(payload.timestamp).content(content).build(pubkey: author)
  }

  @MainActor
  static func deliver(
    _ event: NostrEvent, to service: NostrDMService, subscriptionID: String = "live"
  ) async throws {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
    let wire = try JSONSerialization.data(withJSONObject: ["EVENT", subscriptionID, object])
    let response = try JSONDecoder().decode(RelayResponse.self, from: wire)
    guard case .event(let decodedSubscription, let decodedEvent) = response else {
      return XCTFail("expected an event response")
    }
    await service.handleIncomingEvent(decodedEvent, subscriptionID: decodedSubscription)
  }

  static func changing<T: Codable>(_ event: T, field: String, to value: String) throws -> T {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    object[field] = value
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
