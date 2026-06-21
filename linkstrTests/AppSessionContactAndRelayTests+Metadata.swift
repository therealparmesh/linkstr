import NostrSDK
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import linkstr

extension AppSessionContactAndRelayTests {
  func testUpdateOwnProfileNamePublishesMergedMetadataContentAndPersistsState() async throws {
    var publishedEvent: NostrEvent?
    let (session, container) = try makeSession(
      disableNostrStartup: false,
      hasConnectedRelays: { true },
      publishRelayEvent: { event in
        publishedEvent = event
        return event.id
      }
    )
    try session.identityService.createNewIdentity()
    let ownerPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let existingContent =
      #"{"about":"still here","display_name":"Old Name","name":"Old Name","picture":"https://example.com/picture.png"}"#
    session.ingestProfileMetadataForTesting(
      try makeIncomingProfileMetadata(
        eventID: "profile-self-old",
        authorPubkey: ownerPubkey,
        createdAt: Date(timeIntervalSince1970: 150),
        chosenName: "Old Name",
        rawContent: existingContent
      )
    )

    let didSave = await session.updateOwnProfileName(
      "New Name",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(session.currentProfileName, "New Name")
    XCTAssertEqual(publishedEvent?.kind, .metadata)

    let publishedContentData = try XCTUnwrap(publishedEvent?.content.data(using: .utf8))
    let publishedContent = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publishedContentData) as? [String: String]
    )
    XCTAssertEqual(publishedContent["name"], "New Name")
    XCTAssertEqual(publishedContent["display_name"], "New Name")
    XCTAssertEqual(publishedContent["about"], "still here")
    XCTAssertEqual(publishedContent["picture"], "https://example.com/picture.png")

    let accountState = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    XCTAssertEqual(accountState.nostrProfileName, "New Name")
    XCTAssertEqual(accountState.profileMetadataContent, publishedEvent?.content)
  }

  func testUpdateOwnProfileNameNormalizesWhitespaceBeforePersisting() async throws {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()

    let didSave = await session.updateOwnProfileName(
      "  Alice \n\t Bob \u{0007}  ",
      timeoutSeconds: shortRelayMutationTimeoutSeconds,
      pollIntervalSeconds: shortRelayMutationPollIntervalSeconds
    )

    XCTAssertTrue(didSave)
    XCTAssertEqual(session.currentProfileName, "Alice Bob")

    let accountState = try XCTUnwrap(fetchAccountStates(in: container.mainContext).first)
    let publishedContentData = try XCTUnwrap(
      accountState.profileMetadataContent?.data(using: .utf8))
    let publishedContent = try XCTUnwrap(
      JSONSerialization.jsonObject(with: publishedContentData) as? [String: String]
    )
    XCTAssertEqual(publishedContent["name"], "Alice Bob")
    XCTAssertEqual(publishedContent["display_name"], "Alice Bob")
  }

  func testCancelPendingMetadataRefreshesForHiddenSessionDropsStaleQueuedWork() async throws {
    let recorder = MetadataPreviewRecorder()
    let (session, container) = try makeSession(
      fetchLinkPreview: { url in
        await recorder.record(url)
        if url.contains("first") {
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return LinkPreviewData(title: "preview for \(url)", thumbnailPath: nil)
      }
    )
    try session.identityService.createNewIdentity()
    let myPubkey = try XCTUnwrap(session.identityService.pubkeyHex)

    let first = try makeMetadataRoot(
      eventID: "first", url: "metadata-test-first", ownerPubkey: myPubkey)
    let second = try makeMetadataRoot(
      eventID: "second", url: "metadata-test-second", ownerPubkey: myPubkey)
    let third = try makeMetadataRoot(
      eventID: "third", url: "metadata-test-third", ownerPubkey: myPubkey)
    container.mainContext.insert(first)
    container.mainContext.insert(second)
    container.mainContext.insert(third)
    try container.mainContext.save()

    session.refreshMetadataForVisiblePostIfNeeded(first)
    session.refreshMetadataForVisiblePostIfNeeded(second)

    let firstRequestDeadline = Date(timeIntervalSinceNow: 1)
    while (await recorder.snapshot()).isEmpty, Date() < firstRequestDeadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let firstSnapshot = await recorder.snapshot()
    XCTAssertEqual(firstSnapshot, ["metadata-test-first"])
    XCTAssertEqual(session.testingPendingMetadataRefreshCount, 2)

    session.cancelPendingMetadataRefreshesForHiddenSession()
    session.refreshMetadataForVisiblePostIfNeeded(third)

    let thirdRequestDeadline = Date(timeIntervalSinceNow: 1)
    while third.metadataTitle == nil, Date() < thirdRequestDeadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let finalSnapshot = await recorder.snapshot()
    XCTAssertEqual(finalSnapshot, ["metadata-test-first", "metadata-test-third"])
    XCTAssertNil(second.metadataTitle)
    XCTAssertEqual(third.metadataTitle, "preview for metadata-test-third")
  }

  func makeMetadataRoot(
    eventID: String,
    url: String,
    ownerPubkey: String
  ) throws -> SessionMessageEntity {
    try SessionMessageEntity(
      eventID: eventID,
      ownerPubkey: ownerPubkey,
      conversationID: "session-visible-metadata-cancel",
      rootID: eventID,
      kind: .root,
      senderPubkey: ownerPubkey,
      url: url,
      note: nil,
      timestamp: .now,
      linkType: .twitter
    )
  }
}

actor MetadataPreviewRecorder {
  var requestedURLs: [String] = []

  func record(_ url: String) {
    requestedURLs.append(url)
  }

  func snapshot() -> [String] {
    requestedURLs
  }
}
