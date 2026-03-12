import XCTest

@testable import Linkstr

final class SessionMembershipTimelineBuilderTests: XCTestCase {
  func testChangesHideBaselineSnapshotAndKeepLaterTransitions() {
    let baseline = Date(timeIntervalSince1970: 100)
    let removedAt = Date(timeIntervalSince1970: 130)
    let addedAt = Date(timeIntervalSince1970: 140)

    let changes = SessionMembershipTimelineBuilder.changes(
      from: [
        SessionMembershipTimelineInterval(
          memberPubkey: "alice",
          startAt: baseline,
          endAt: nil
        ),
        SessionMembershipTimelineInterval(
          memberPubkey: "bob",
          startAt: baseline,
          endAt: removedAt
        ),
        SessionMembershipTimelineInterval(
          memberPubkey: "carol",
          startAt: addedAt,
          endAt: nil
        ),
      ]
    )

    XCTAssertEqual(
      changes,
      [
        SessionMembershipTimelineChange(
          memberPubkey: "bob",
          timestamp: removedAt,
          kind: .left
        ),
        SessionMembershipTimelineChange(
          memberPubkey: "carol",
          timestamp: addedAt,
          kind: .joined
        ),
      ]
    )
  }

  func testChangesEmitLeaveAndRejoinForSameMemberAfterBaseline() {
    let baseline = Date(timeIntervalSince1970: 100)
    let removedAt = Date(timeIntervalSince1970: 120)
    let readdedAt = Date(timeIntervalSince1970: 150)

    let changes = SessionMembershipTimelineBuilder.changes(
      from: [
        SessionMembershipTimelineInterval(
          memberPubkey: "alice",
          startAt: baseline,
          endAt: nil
        ),
        SessionMembershipTimelineInterval(
          memberPubkey: "bob",
          startAt: baseline,
          endAt: removedAt
        ),
        SessionMembershipTimelineInterval(
          memberPubkey: "bob",
          startAt: readdedAt,
          endAt: nil
        ),
      ]
    )

    XCTAssertEqual(
      changes,
      [
        SessionMembershipTimelineChange(
          memberPubkey: "bob",
          timestamp: removedAt,
          kind: .left
        ),
        SessionMembershipTimelineChange(
          memberPubkey: "bob",
          timestamp: readdedAt,
          kind: .joined
        ),
      ]
    )
  }
}
