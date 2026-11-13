import WebKit
import XCTest

@testable import linkstr

final class EmbeddedWebLifetimeTests: XCTestCase {
  @MainActor
  func testOldDocumentMetricsCannotUpdateReplacementDocument() async throws {
    let coordinator = EmbeddedWebView.Coordinator()
    let webView = DeferredMetricsWebView()
    var heights: [CGFloat] = []
    var readiness: [Bool] = []
    coordinator.onIntrinsicHeightChange = { heights.append($0) }
    coordinator.onContentReadyChange = { readiness.append($0) }
    defer { coordinator.clearHandlers() }

    coordinator.source = .html(document: "old document", baseURL: nil)
    coordinator.prepareForNewLoad()
    let oldPoll = expectation(description: "old document metric evaluation starts")
    webView.onEvaluation = { oldPoll.fulfill() }
    coordinator.webView(webView, didFinish: nil)
    await fulfillment(of: [oldPoll], timeout: 2)
    let oldCompletion = try XCTUnwrap(webView.pendingCompletion)

    coordinator.source = .html(document: "new document", baseURL: nil)
    coordinator.prepareForNewLoad()
    heights.removeAll()
    readiness.removeAll()
    oldCompletion(["height": CGFloat(900), "ready": true], nil)
    XCTAssertTrue(heights.isEmpty, "Old document height must not resize the replacement")
    XCTAssertTrue(readiness.isEmpty, "Old readiness must not reveal the replacement before it is ready")

    let newPoll = expectation(description: "replacement document metric evaluation starts")
    webView.onEvaluation = { newPoll.fulfill() }
    coordinator.webView(webView, didFinish: nil)
    await fulfillment(of: [newPoll], timeout: 2)
    let newCompletion = try XCTUnwrap(webView.pendingCompletion)
    newCompletion(["height": CGFloat(240), "ready": true], nil)
    XCTAssertEqual(heights, [240])
    XCTAssertEqual(readiness, [true])
  }
  @MainActor
  func testTwitterFallbackBecomesReadyWithoutReportingAVisiblePost() async throws {
    for stalledWidget in [false, true] {
      try await assertTwitterFallback(stalledWidget: stalledWidget)
    }
  }

  @MainActor
  private func assertTwitterFallback(stalledWidget: Bool) async throws {
    let coordinator = EmbeddedWebView.Coordinator()
    let handlerName = EmbeddedWebView.Coordinator.metricsHandlerName
    let config = WKWebViewConfiguration()
    config.userContentController.add(coordinator, name: handlerName)
    installManualTwitterFallbackTimer(in: config)
    let document = twitterDocument(stalledWidget: stalledWidget)
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
    coordinator.source = .html(document: document, baseURL: nil)
    webView.navigationDelegate = coordinator
    defer {
      config.userContentController.removeScriptMessageHandler(forName: handlerName)
      webView.navigationDelegate = nil
      webView.stopLoading()
    }

    let fallbackReady = expectation(description: "fallback is visible")
    let postRendered = expectation(description: "official widget is visible")
    var hasRenderedPost = false
    coordinator.onContentReadyChange = { if $0 { fallbackReady.fulfill() } }
    coordinator.onRenderedPostChange = {
      hasRenderedPost = $0
      if $0 { postRendered.fulfill() }
    }
    await loadEmbedFixture(document, in: webView)
    _ = try await webView.evaluateJavaScript("window.runFallbackTimer()")
    await fulfillment(of: [fallbackReady], timeout: 5)
    XCTAssertFalse(hasRenderedPost)

    let fallbackText = try await webView.evaluateJavaScript(
      "document.querySelector('.linkstr-embed-fallback')?.textContent ?? ''"
    )
    XCTAssertEqual(fallbackText as? String, EmbeddedWebSource.fallbackMessage)
    let fillsWidth = try await webView.evaluateJavaScript("""
      document.querySelector('.linkstr-embed-fallback').getBoundingClientRect().width >=
        document.querySelector('#tweet-container').clientWidth - 1
      """)
    XCTAssertEqual(fillsWidth as? Bool, true, "Provider placeholders must not squeeze recovery guidance")
    _ = try await webView.evaluateJavaScript("""
      document.querySelector('#tweet-container').appendChild(document.createElement('twitter-widget'));
      true;
      """)
    await fulfillment(of: [postRendered], timeout: 5)
    XCTAssertTrue(hasRenderedPost)
    let fallback = try await webView.evaluateJavaScript("!!document.querySelector('.linkstr-embed-fallback')")
    XCTAssertEqual(fallback as? Bool, false, "Late success must remove recovery guidance")
    if stalledWidget {
      let placeholderSurvived = try await webView.evaluateJavaScript(
        "document.getElementById('pending-widget') != null"
      )
      XCTAssertEqual(placeholderSurvived as? Bool, true, "Do not destroy nodes owned by the provider")
    }
  }

  private func installManualTwitterFallbackTimer(in config: WKWebViewConfiguration) {
    config.userContentController.addUserScript(WKUserScript(
      source: """
        const schedule = window.setTimeout;
        window.setTimeout = function(callback, delay, ...args) {
          if (delay === \(TwitterEmbedTimingDefaults.fallbackDelayMilliseconds)) {
            window.runFallbackTimer = () => { callback(...args); return true; };
            return 0;
          }
          return schedule.call(window, callback, delay, ...args);
        };
        """,
      injectionTime: .atDocumentStart, forMainFrameOnly: true
    ))
  }

  private func twitterDocument(stalledWidget: Bool) -> String {
    var document = TwitterEmbedDocumentBuilder.documentHTML(tweetID: "20")
      .replacingOccurrences(of: "https://platform.twitter.com/widgets.js", with: "data:text/javascript,")
    if stalledWidget {
      document = document.replacingOccurrences(of: "<script>", with: """
        <script>
        window.twttr = { widgets: { createTweet: (_, container) => {
          const placeholder = document.createElement('div');
          placeholder.id = 'pending-widget';
          container.appendChild(placeholder);
          return new Promise(() => {});
        } } };
        """)
    }
    return document
  }
}

@MainActor
private final class DeferredMetricsWebView: WKWebView {
  var pendingCompletion: (@MainActor @Sendable (Any?, Error?) -> Void)?
  var onEvaluation: (() -> Void)?

  override func evaluateJavaScript(
    _ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
  ) {
    pendingCompletion = completionHandler
    let callback = onEvaluation
    onEvaluation = nil
    callback?()
  }
}
