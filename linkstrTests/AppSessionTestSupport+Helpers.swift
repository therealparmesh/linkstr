import NostrSDK
import XCTest

@testable import linkstr

extension AppSessionTestCase {
  func makeIncomingMessage(
    eventID: String,
    transportEventID: String? = nil,
    senderPubkey: String,
    createdAt: Date,
    payload: LinkstrPayload,
    source: DirectMessageIngestSource = .live
  ) -> ReceivedDirectMessage {
    return ReceivedDirectMessage(
      eventID: eventID,
      transportEventID: transportEventID,
      senderPubkey: senderPubkey,
      payload: payload,
      createdAt: createdAt,
      source: source
    )
  }

  func makeIncomingProfileMetadata(
    eventID: String,
    authorPubkey: String,
    createdAt: Date,
    chosenName: String?,
    rawContent: String? = nil
  ) throws -> ReceivedProfileMetadata {
    let resolvedContent: String
    if let rawContent {
      resolvedContent = rawContent
    } else {
      resolvedContent = try NostrProfileMetadata.mergedContent(
        existingContent: nil,
        chosenName: chosenName
      )
    }

    return ReceivedProfileMetadata(
      eventID: eventID,
      authorPubkey: authorPubkey,
      chosenName: chosenName,
      rawContent: resolvedContent,
      createdAt: createdAt
    )
  }
}
