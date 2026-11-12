import UIKit
import XCTest

@testable import linkstr

final class DeepLinkCodecTests: XCTestCase {
  @MainActor
  func testDelayedDraftCompletionPreservesAReplacementRequest() throws {
    let handler = DeepLinkHandler()
    let originalShare = LinkstrDeepLinkCodec.ShareDraft(url: "https://example.com/first", note: nil)
    handler.pendingShareDraft = originalShare
    let finishOriginalShare = { handler.clearShareDraft(matching: originalShare) }
    let latestShare = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/latest", note: "new note"))
    XCTAssertTrue(handler.handle(url: latestShare))
    let replacementShare = try XCTUnwrap(handler.pendingShareDraft)
    finishOriginalShare()
    XCTAssertEqual(handler.pendingShareDraft, replacementShare)
    handler.clearShareDraft(matching: replacementShare)
    XCTAssertNil(handler.pendingShareDraft)

    let originalSave = LinkstrDeepLinkCodec.MediaSaveDraft(url: "https://example.com/first.mp4")
    handler.pendingMediaSaveDraft = originalSave
    let finishOriginalSave = { handler.clearMediaSaveDraft(matching: originalSave) }
    let latestSave = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "https://example.com/latest.mp4"))
    XCTAssertTrue(handler.handle(url: latestSave))
    let replacementSave = try XCTUnwrap(handler.pendingMediaSaveDraft)
    finishOriginalSave()
    XCTAssertEqual(handler.pendingMediaSaveDraft, replacementSave)
    handler.clearMediaSaveDraft(matching: replacementSave)
    XCTAssertNil(handler.pendingMediaSaveDraft)
  }

  @MainActor
  func testShareBackWaitsForDismissalAndKeepsLatestValidLink() async throws {
    try await verifyShareBack(container: nil)
  }

  @MainActor
  func testShareBackDismissesContainerHoldingActivityController() async throws {
    try await verifyShareBack(container: UIViewController())
  }

  @MainActor
  func testClearingRoutesCancelsHandoffWaitingForShareSheetDismissal() async throws {
    try await verifyShareBack(container: UIViewController(), cancelPending: true)
  }

  @MainActor
  private func verifyShareBack(container: UIViewController?, cancelPending: Bool = false) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKeyAndVisible()
    }

    let shareSheet = UIActivityViewController(
      activityItems: [URL(string: "https://example.com")!], applicationActivities: nil)
    shareSheet.popoverPresentationController?.sourceView = host.view
    if let container {
      container.addChild(shareSheet)
      shareSheet.didMove(toParent: container)
    }
    await withCheckedContinuation { continuation in
      host.present(container ?? shareSheet, animated: false) { continuation.resume() }
    }
    let handler = DeepLinkHandler()
    let first = try XCTUnwrap(LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/first"))
    let latest = try XCTUnwrap(LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/latest"))
    XCTAssertTrue(handler.handle(url: first))
    XCTAssertNil(handler.pendingShareDraft)
    XCTAssertTrue(handler.handle(url: latest))
    XCTAssertFalse(handler.handle(url: URL(string: "linkstr://share?url=ftp://example.com")!))
    if cancelPending { handler.clearPendingRoutes() }

    let completed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in handler.pendingShareDraft != nil }, object: nil)
    completed.isInverted = cancelPending
    await fulfillment(of: [completed], timeout: cancelPending ? 1 : 5)
    XCTAssertNil(host.presentedViewController)
    XCTAssertEqual(handler.pendingShareDraft?.url, cancelPending ? nil : "https://example.com/latest")
  }

  func testAppDeepLinkRoundtrip() throws {
    let urlString = "https://example.com/a%20b?first=1&next=a%2Bb#section"

    let deepLink = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(url: urlString))
    let sourceURL = try XCTUnwrap(URL(string: urlString))
    XCTAssertEqual(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: deepLink), .openURL(sourceURL))
    XCTAssertEqual(LinkstrDeepLinkCodec.webURL(fromInput: " \n\(deepLink)\n "), urlString)
    XCTAssertEqual(LinkstrDeepLinkCodec.webURL(fromInput: urlString), urlString)
    XCTAssertEqual(LinkstrDeepLinkCodec.webURL(fromInput: "example.com/post"), "https://example.com/post")
    XCTAssertNil(LinkstrURLValidator.normalizedWebURL(from: deepLink.absoluteString))
  }

  func testPostInputRejectsInvalidAndNestedDeepLinks() {
    XCTAssertEqual(
      LinkstrDeepLinkCodec.webURL(fromInput: "linkstr://open?url=https%3A%2F%2Fexample.com%2Fpost"),
      "https://example.com/post")
    for input in [
      "linkstr://open", "linkstr://watch?url=https://example.com/post",
      "linkstr://open/path?url=https://example.com/post",
      "linkstr://open?url=https://example.com/post trailing text",
      "linkstr://open?url=javascript%3Aalert(1)",
      "linkstr://open?url=linkstr%3A%2F%2Fopen%3Furl%3Dhttps%3A%2F%2Fexample.com",
      "ftp://example.com/post"
    ] {
      XCTAssertNil(LinkstrDeepLinkCodec.webURL(fromInput: input), input)
    }
  }

  func testShareDeepLinkRoundtripWithOptionalNote() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "example.com/watch",
        note: "  worth saving & tagging? yes  "
      )
    )

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: deepLink),
      .share(.init(url: "https://example.com/watch", note: "worth saving & tagging? yes"))
    )
    XCTAssertNil(LinkstrDeepLinkCodec.webURL(fromInput: deepLink.absoluteString))
  }

  func testShareDeepLinkOmitsBlankNote() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "https://example.com/watch",
        note: " \n\t "
      )
    )

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: deepLink),
      .share(.init(url: "https://example.com/watch", note: nil))
    )
  }

  func testShareDeepLinkLimitsNoteLength() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "https://example.com/watch",
        note: String(repeating: "a", count: 4_005)
      )
    )

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: deepLink),
      .share(.init(url: "https://example.com/watch", note: String(repeating: "a", count: 4_000)))
    )
  }

  func testMediaSaveDeepLinkRoundtrip() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "example.com/video.mp4"))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: deepLink),
      .mediaSave(.init(url: "https://example.com/video.mp4"))
    )
    XCTAssertNil(LinkstrDeepLinkCodec.webURL(fromInput: deepLink.absoluteString))
  }

  func testAppDeepLinkRejectsUnexpectedSchemeOrHost() throws {
    let url = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://x.com/jack/status/20"))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""

    let wrongScheme = URL(string: "https://open?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: wrongScheme))

    let wrongHost = URL(string: "linkstr://watch?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: wrongHost))

    let wrongPath = URL(string: "linkstr://open/deep?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: wrongPath))
  }

  func testAppDeepLinkRejectsNonWebPayloadURL() throws {
    XCTAssertNil(LinkstrDeepLinkCodec.makeAppDeepLink(url: "javascript:alert('xss')"))
    XCTAssertNil(LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "javascript:alert('xss')"))
    XCTAssertNil(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "javascript:alert('xss')"))
  }

  func testShareDeepLinkRejectsMissingPayloadURL() {
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: URL(string: "linkstr://share")!)
    )
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: URL(string: "linkstr://share?note=hi")!)
    )
  }

  func testMediaSaveDeepLinkRejectsMissingPayloadURL() {
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseRoute(
        fromAppDeepLink: URL(string: "linkstr://save")!)
    )
  }

  func testAppDeepLinkRejectsRemovedPayloadFormat() {
    let legacyURL = URL(
      string:
        "linkstr://open?p=eyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tL3ZpZGVvIiwidGltZXN0YW1wIjoxLCJtZXNzYWdlR1VJRCI6ImFiYyJ9"
    )!

    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: legacyURL))
  }
}
