import Observation
import SwiftData
import UIKit
import XCTest

@testable import linkstr

@MainActor
final class MetadataLifetimeTests: AppSessionTestCase {
  func testRefreshNotifiesThumbnailViewWhenImageReplacesSameFile() async throws {
    let file = ManagedLocalFileScope.shared.thumbnailFileURL(for: UUID().uuidString, fileExtension: "png")
    defer {
      try? FileManager.default.removeItem(at: file)
      ThumbnailImageCache.shared.removeImage(at: file.path)
    }
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
    let oldImage = renderer.pngData { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    let newImage = renderer.pngData { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    try oldImage.write(to: file, options: .atomic)
    let (session, container) = try makeSession(fetchLinkPreview: { _ in
      do { try newImage.write(to: file, options: .atomic) } catch { XCTFail("\(error)") }
      ThumbnailImageCache.shared.removeImage(at: file.path)
      return LinkPreviewData(title: "same title", thumbnailPath: file.path)
    })
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let post = try makePost("thumbnail", owner: owner, context: container.mainContext)
    try post.setMetadata(title: "same title", thumbnailURL: file.path)
    try container.mainContext.save()
    let previousTaskID = post.encryptedThumbnailURL
    let changed = expectation(description: "thumbnail view reloads")
    withObservationTracking { _ = post.encryptedThumbnailURL } onChange: { changed.fulfill() }

    let result = await session.refreshPostMetadata(post)

    XCTAssertEqual(result, .updated)
    XCTAssertNotEqual(post.encryptedThumbnailURL, previousTaskID)
    XCTAssertEqual(post.thumbnailURL, file.path)
    XCTAssertEqual(try Data(contentsOf: file), newImage)
    await fulfillment(of: [changed], timeout: 0.1)
  }

  func testInterruptedManualRefreshCannotApplyALatePreviewOrClearCurrentError() async throws {
    for deletesPost in [false, true] {
      var release: CheckedContinuation<LinkPreviewData?, Never>?
      let started = expectation(description: "manual preview started")
      let (session, container) = try makeSession(fetchLinkPreview: { _ in
        await withCheckedContinuation { release = $0; started.fulfill() }
      })
      try session.identityService.createNewIdentity()
      let owner = try XCTUnwrap(session.identityService.pubkeyHex)
      let post = try makePost("manual", owner: owner, context: container.mainContext)
      try post.setMetadata(title: "saved preview", thumbnailURL: nil)
      try container.mainContext.save()
      let refresh = Task { await session.refreshPostMetadata(post) }
      await fulfillment(of: [started], timeout: asyncExpectationTimeoutSeconds)
      let storageID = post.storageID
      if deletesPost {
        container.mainContext.delete(post)
        try container.mainContext.save()
      } else {
        refresh.cancel()
      }
      session.composeError = "current screen error"
      release?.resume(returning: LinkPreviewData(title: "late preview", thumbnailPath: nil))
      let result = await refresh.value

      XCTAssertEqual(result, .interrupted)
      if deletesPost {
        XCTAssertNil(try session.messageStore.message(storageID: storageID))
      } else {
        XCTAssertEqual(post.metadataTitle, "saved preview")
      }
      XCTAssertEqual(session.composeError, "current screen error")
      XCTAssertNil(session.metadataRefreshRetryAfterByStorageID[storageID])
    }
  }

  func testResetStopsOldPreviewWorkerFromTakingOverTheNewQueue() async throws {
    var oldRelease: CheckedContinuation<LinkPreviewData?, Never>?
    var newRelease: CheckedContinuation<LinkPreviewData?, Never>?
    let oldStarted = expectation(description: "old preview started")
    let newStarted = expectation(description: "new preview started")
    let overtookNewRequest = expectation(description: "queued preview started before active preview finished")
    overtookNewRequest.isInverted = true
    var newIsWaiting = true
    let (session, container) = try makeSession(fetchLinkPreview: { url in
      switch url {
      case "old":
        return await withCheckedContinuation { oldRelease = $0; oldStarted.fulfill() }
      case "new":
        return await withCheckedContinuation { newRelease = $0; newStarted.fulfill() }
      default:
        if newIsWaiting { overtookNewRequest.fulfill() }
        return LinkPreviewData(title: "queued preview", thumbnailPath: nil)
      }
    })
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    let posts = try ["old", "new", "queued"].map { try makePost($0, owner: owner, context: container.mainContext) }
    session.enqueueMetadataRefresh(for: posts[0])
    await fulfillment(of: [oldStarted], timeout: asyncExpectationTimeoutSeconds)
    session.resetRuntimeSessionState()
    session.enqueueMetadataRefresh(for: posts[1])
    session.enqueueMetadataRefresh(for: posts[2])
    await fulfillment(of: [newStarted], timeout: asyncExpectationTimeoutSeconds)
    oldRelease?.resume(returning: LinkPreviewData(title: "stale preview", thumbnailPath: nil))
    await fulfillment(of: [overtookNewRequest], timeout: 0.1)
    XCTAssertNil(posts[0].metadataTitle)
    XCTAssertEqual(session.activeMetadataRefreshStorageID, posts[1].storageID)
    XCTAssertEqual(session.enqueuedMetadataStorageIDs, Set(posts.dropFirst().map(\.storageID)))
    newIsWaiting = false
    newRelease?.resume(returning: LinkPreviewData(title: "new preview", thumbnailPath: nil))
    let deadline = Date(timeIntervalSinceNow: asyncExpectationTimeoutSeconds)
    while !session.enqueuedMetadataStorageIDs.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(posts[1].metadataTitle, "new preview")
    XCTAssertEqual(posts[2].metadataTitle, "queued preview")
    XCTAssertTrue(session.enqueuedMetadataStorageIDs.isEmpty)
  }

  private func makePost(_ id: String, owner: String, context: ModelContext) throws -> SessionMessageEntity {
    let post = try SessionMessageEntity(
      eventID: id, ownerPubkey: owner, conversationID: "session", rootID: id, kind: .root,
      senderPubkey: owner, url: id, note: nil, timestamp: .now, linkType: .generic
    )
    context.insert(post)
    try context.save()
    return post
  }
}
