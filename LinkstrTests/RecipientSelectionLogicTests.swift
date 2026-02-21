import NostrSDK
import XCTest

@testable import Linkstr

final class SessionPayloadValidationTests: XCTestCase {
  func testSessionCreateValidationRequiresNameAndMembers() throws {
    let keypair = try XCTUnwrap(Keypair())
    let valid = LinkstrPayload(
      conversationID: "session-1",
      rootID: "op-1",
      kind: .sessionCreate,
      url: nil,
      note: nil,
      timestamp: 123,
      sessionName: "Friends",
      memberPubkeys: [keypair.publicKey.hex]
    )
    XCTAssertNoThrow(try valid.validated())

    let missingName = LinkstrPayload(
      conversationID: "session-1",
      rootID: "op-2",
      kind: .sessionCreate,
      url: nil,
      note: nil,
      timestamp: 123,
      sessionName: "  ",
      memberPubkeys: [keypair.publicKey.hex]
    )
    XCTAssertThrowsError(try missingName.validated())

    let missingMembers = LinkstrPayload(
      conversationID: "session-1",
      rootID: "op-3",
      kind: .sessionCreate,
      url: nil,
      note: nil,
      timestamp: 123,
      sessionName: "Friends",
      memberPubkeys: []
    )
    XCTAssertThrowsError(try missingMembers.validated())
  }

  func testReactionValidationRequiresEmojiAndState() {
    let valid = LinkstrPayload(
      conversationID: "session-1",
      rootID: "root-1",
      kind: .reaction,
      url: nil,
      note: nil,
      timestamp: 123,
      emoji: "👍",
      reactionActive: true
    )
    XCTAssertNoThrow(try valid.validated())

    let missingEmoji = LinkstrPayload(
      conversationID: "session-1",
      rootID: "root-1",
      kind: .reaction,
      url: nil,
      note: nil,
      timestamp: 123,
      emoji: nil,
      reactionActive: true
    )
    XCTAssertThrowsError(try missingEmoji.validated())

    let missingState = LinkstrPayload(
      conversationID: "session-1",
      rootID: "root-1",
      kind: .reaction,
      url: nil,
      note: nil,
      timestamp: 123,
      emoji: "👍",
      reactionActive: nil
    )
    XCTAssertThrowsError(try missingState.validated())
  }

  func testNormalizedMemberPubkeysDedupesAndRejectsInvalid() throws {
    let keypair = try XCTUnwrap(Keypair())
    let duplicateMembers = LinkstrPayload(
      conversationID: "session-1",
      rootID: "op-1",
      kind: .sessionMembers,
      url: nil,
      note: nil,
      timestamp: 123,
      memberPubkeys: [keypair.publicKey.hex, keypair.publicKey.hex]
    )
    XCTAssertEqual(duplicateMembers.normalizedMemberPubkeys(), [keypair.publicKey.hex])

    let invalidMembers = LinkstrPayload(
      conversationID: "session-1",
      rootID: "op-2",
      kind: .sessionMembers,
      url: nil,
      note: nil,
      timestamp: 123,
      memberPubkeys: ["not-a-pubkey"]
    )
    XCTAssertNil(invalidMembers.normalizedMemberPubkeys())
  }
}
