import UIKit
import XCTest

@testable import linkstr

final class DeepLinkCodecTests: XCTestCase {
  @MainActor
  func testShareBackWaitsForDismissalAndKeepsLatestValidLink() async throws {
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
    await withCheckedContinuation { continuation in
      host.present(shareSheet, animated: false) { continuation.resume() }
    }
    let handler = DeepLinkHandler()
    let first = try XCTUnwrap(LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/first"))
    let latest = try XCTUnwrap(LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/latest"))
    XCTAssertTrue(handler.handle(url: first))
    XCTAssertNil(handler.pendingShareDraft)
    XCTAssertTrue(handler.handle(url: latest))
    XCTAssertFalse(handler.handle(url: URL(string: "linkstr://share?url=ftp://example.com")!))

    let completed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in handler.pendingShareDraft != nil }, object: nil)
    await fulfillment(of: [completed], timeout: 5)
    XCTAssertNil(host.presentedViewController)
    XCTAssertEqual(handler.pendingShareDraft?.url, "https://example.com/latest")
  }

  func testAppDeepLinkRoundtrip() throws {
    let urlString = "https://example.com/a%20b?first=1&next=a%2Bb#section"

    let deepLink = try XCTUnwrap(LinkstrDeepLinkCodec.makeAppDeepLink(url: urlString))
    let parsed = try XCTUnwrap(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: deepLink))
    XCTAssertEqual(parsed, urlString)
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

    let draft = try XCTUnwrap(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.url, "https://example.com/watch")
    XCTAssertEqual(draft.note, "worth saving & tagging? yes")
  }

  func testShareDeepLinkOmitsBlankNote() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "https://example.com/watch",
        note: " \n\t "
      )
    )

    let draft = try XCTUnwrap(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.url, "https://example.com/watch")
    XCTAssertNil(draft.note)
  }

  func testShareDeepLinkLimitsNoteLength() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(
        url: "https://example.com/watch",
        note: String(repeating: "a", count: 4_005)
      )
    )

    let draft = try XCTUnwrap(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.note?.count, 4_000)
  }

  func testMediaSaveDeepLinkRoundtrip() throws {
    let deepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "example.com/video.mp4"))

    let draft = try XCTUnwrap(
      LinkstrDeepLinkCodec.parseMediaSaveDraft(fromAppDeepLink: deepLink))
    XCTAssertEqual(draft.url, "https://example.com/video.mp4")
  }

  func testRouteParsingDistinguishesOpenShareAndMediaSave() throws {
    let openDeepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://example.com/open"))
    let shareDeepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeShareAppDeepLink(url: "https://example.com/share"))
    let mediaSaveDeepLink = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: "https://example.com/video.mp4"))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: openDeepLink),
      .openURL("https://example.com/open")
    )
    XCTAssertNil(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: openDeepLink))
    XCTAssertNil(LinkstrDeepLinkCodec.parseMediaSaveDraft(fromAppDeepLink: openDeepLink))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: shareDeepLink),
      .share(LinkstrDeepLinkCodec.ShareDraft(url: "https://example.com/share", note: nil))
    )
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: shareDeepLink))
    XCTAssertNil(LinkstrDeepLinkCodec.parseMediaSaveDraft(fromAppDeepLink: shareDeepLink))

    XCTAssertEqual(
      LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: mediaSaveDeepLink),
      .mediaSave(
        LinkstrDeepLinkCodec.MediaSaveDraft(url: "https://example.com/video.mp4"))
    )
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: mediaSaveDeepLink))
    XCTAssertNil(LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: mediaSaveDeepLink))
  }

  func testAppDeepLinkRejectsUnexpectedSchemeOrHost() throws {
    let url = try XCTUnwrap(
      LinkstrDeepLinkCodec.makeAppDeepLink(url: "https://x.com/jack/status/20"))
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""

    let wrongScheme = URL(string: "https://open?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongScheme))

    let wrongHost = URL(string: "linkstr://watch?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongHost))
    XCTAssertNil(LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: wrongHost))

    let wrongPath = URL(string: "linkstr://open/deep?\(query)")!
    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: wrongPath))
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
      LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: URL(string: "linkstr://share")!)
    )
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseShareDraft(fromAppDeepLink: URL(string: "linkstr://share?note=hi")!)
    )
  }

  func testMediaSaveDeepLinkRejectsMissingPayloadURL() {
    XCTAssertNil(
      LinkstrDeepLinkCodec.parseMediaSaveDraft(
        fromAppDeepLink: URL(string: "linkstr://save")!)
    )
  }

  func testAppDeepLinkRejectsRemovedPayloadFormat() {
    let legacyURL = URL(
      string:
        "linkstr://open?p=eyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tL3ZpZGVvIiwidGltZXN0YW1wIjoxLCJtZXNzYWdlR1VJRCI6ImFiYyJ9"
    )!

    XCTAssertNil(LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: legacyURL))
  }
}
