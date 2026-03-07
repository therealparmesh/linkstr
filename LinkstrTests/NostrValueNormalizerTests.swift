import NostrSDK
import XCTest

@testable import Linkstr

final class NostrValueNormalizerTests: XCTestCase {
  func testNormalizedEventIDTrimsWhitespaceAndDropsBlankValues() {
    XCTAssertEqual(NostrValueNormalizer.normalizedEventID("  event-id  "), "event-id")
    XCTAssertNil(NostrValueNormalizer.normalizedEventID("   "))
    XCTAssertNil(NostrValueNormalizer.normalizedEventID(nil))
  }

  func testValidatedNormalizedPubkeyHexesRejectsInvalidCandidate() throws {
    let keypair = try XCTUnwrap(Keypair())
    XCTAssertNil(
      NostrValueNormalizer.validatedNormalizedPubkeyHexes([
        keypair.publicKey.hex,
        "not-a-pubkey",
      ]))
  }

  func testDedupedNormalizedPubkeyHexesNormalizesAndDedupes() throws {
    let keypair = try XCTUnwrap(Keypair())
    XCTAssertEqual(
      NostrValueNormalizer.dedupedNormalizedPubkeyHexes([
        keypair.publicKey.hex.uppercased(),
        keypair.publicKey.hex,
        "not-a-pubkey",
      ]),
      [keypair.publicKey.hex]
    )
  }

  func testShouldApplyStateUpdateUsesTimestampThenEventIDTiebreak() {
    let currentUpdatedAt = Date(timeIntervalSince1970: 100)
    let newerUpdatedAt = Date(timeIntervalSince1970: 101)

    XCTAssertTrue(
      NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: nil,
        currentEventID: nil,
        incomingUpdatedAt: currentUpdatedAt,
        incomingEventID: "a"
      ))
    XCTAssertTrue(
      NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: currentUpdatedAt,
        currentEventID: "b",
        incomingUpdatedAt: newerUpdatedAt,
        incomingEventID: "a"
      ))
    XCTAssertFalse(
      NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: currentUpdatedAt,
        currentEventID: "b",
        incomingUpdatedAt: currentUpdatedAt,
        incomingEventID: "a"
      ))
    XCTAssertTrue(
      NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: currentUpdatedAt,
        currentEventID: "a",
        incomingUpdatedAt: currentUpdatedAt,
        incomingEventID: "b"
      ))
  }
}
