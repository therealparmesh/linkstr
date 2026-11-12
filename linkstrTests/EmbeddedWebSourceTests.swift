import JavaScriptCore
import SwiftUI
import WebKit
import XCTest

@testable import linkstr

final class EmbeddedWebSourceTests: XCTestCase {
  @MainActor
  func testTikTokShareLinkReusesSavedVideoSourceForLocalAndOfficialPlayback() async throws {
    let shortURL = try XCTUnwrap(URL(string: "https://www.tiktok.com/t/offline-test/"))
    let canonicalURL = try XCTUnwrap(URL(string: "https://www.tiktok.com/@example/video/123456789"))
    let officialPlayer = try XCTUnwrap(URL(string: "https://www.tiktok.com/player/v1/123456789"))
    let view = AdaptiveMediaView<EmptyView, EmptyView>(
      sourceURL: shortURL,
      openSourceAction: {},
      cachedCanonicalSourceURL: canonicalURL,
      resolveCachedLocalMedia: { sourceURL in
        XCTAssertEqual(sourceURL, canonicalURL)
        return PlayableMedia(playbackURL: URL(fileURLWithPath: "/saved.mp4"), headers: [:], isLocalFile: true)
      }
    )

    let presentation = await view.resolvePlaybackPresentation(sourceURL: shortURL, taskID: view.playbackReloadTaskID)

    XCTAssertEqual(presentation?.canonicalSourceURL, canonicalURL)
    XCTAssertEqual(presentation?.mediaStrategy, .extractionPreferred(embedURL: officialPlayer))
  }

  func testTikTokReportsDocumentedPlaybackErrorsWithoutInterceptingAutoplayOrUntrustedMessages() throws {
    let context = try XCTUnwrap(JSContext())
    context.evaluateScript("""
      const location = { origin: 'https://www.tiktok.com', pathname: '/player/v1/123456789' };
      const states = [];
      let handler;
      const window = {
        addEventListener: (_, listener) => { handler = listener; },
        webkit: { messageHandlers: { linkstrEmbedMetrics: {
          postMessage: payload => states.push(payload.tiktokPlayerFailure)
        } } }
      };
      const emit = (errorCode, origin = location.origin, source = window) => handler({
        origin, source, data: { 'x-tiktok-player': true, type: 'onPlayerError', value: { errorCode } }
      });
      """)
    context.evaluateScript(tiktokPlayerDiagnosticsScript)
    context.evaluateScript("""
      emit(3002); emit(9999); emit(2001, 'https://example.org'); emit(2001, location.origin, {});
      """)
    XCTAssertEqual(context.evaluateScript("states.length")?.toInt32(), 0)
    context.evaluateScript("emit(1001); emit(2001); emit(3001);")
    context.evaluateScript("""
      handler({ origin: location.origin, source: window,
        data: { 'x-tiktok-player': true, type: 'onStateChange', value: 1 } });
      """)
    XCTAssertEqual(context.evaluateScript("JSON.stringify(states)")?.toString(), "[true,true,true]")
    XCTAssertNil(context.exception)
  }

  @MainActor
  func testTikTokPlaybackErrorsLeaveTheWebDocumentRunning() async throws {
    let url = try XCTUnwrap(URL(string: "https://www.tiktok.com/player/v1/123456789"))
    let coordinator = EmbeddedWebView.Coordinator()
    coordinator.source = .url(url)
    let config = WKWebViewConfiguration()
    let handlerName = EmbeddedWebView.Coordinator.metricsHandlerName
    config.userContentController.add(coordinator, name: handlerName)
    config.userContentController.addUserScript(WKUserScript(
      source: tiktokPlayerDiagnosticsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
    ))
    let webView = WKWebView(frame: .zero, configuration: config)
    defer {
      config.userContentController.removeScriptMessageHandler(forName: handlerName)
      webView.stopLoading()
    }
    let errorsReported = expectation(description: "TikTok reported errors without discarding its document")
    errorsReported.expectedFulfillmentCount = 3
    coordinator.onProviderFailure = { errorsReported.fulfill() }
    coordinator.onLoadFailure = { _ in XCTFail("A TikTok player error must not discard the web document") }
    webView.loadHTMLString("""
      <script>
        for (const errorCode of [1001, 2001, 3001]) {
          window.postMessage({
            'x-tiktok-player': true, type: 'onPlayerError', value: { errorCode }
          }, location.origin);
        }
        window.postMessage({
          'x-tiktok-player': true, type: 'onPlayerReady'
        }, location.origin);
      </script>
      """, baseURL: url)
    await fulfillment(of: [errorsReported], timeout: 8)
    let documentSurvived = try await webView.evaluateJavaScript("document.body != null")
    XCTAssertEqual(documentSurvived as? Bool, true)
  }

  @MainActor
  func testManagedEmbedHeightUsesContentInsteadOfWebViewViewport() async throws {
    try await assertManagedEmbedHeight(
      containerID: "tweet-container", document: TwitterEmbedDocumentBuilder.documentHTML(tweetID: "20")
    )
    let videoURL = try XCTUnwrap(URL(string: "https://www.facebook.com/watch/?v=123456789012345"))
    guard case .html(let document, _) = EmbeddedWebSource.facebookVideo(for: videoURL) else {
      return XCTFail("Expected a managed Facebook document")
    }
    try await assertManagedEmbedHeight(containerID: "facebook-container", document: document)
  }

  @MainActor
  func testURLBasedEmbedBecomesReadyOnceWhenItsDocumentCommits() throws {
    let url = try XCTUnwrap(URL(string: "https://www.tiktok.com/player/v1/123456789"))
    let coordinator = EmbeddedWebView.Coordinator()
    coordinator.source = .url(url)
    var readiness: [Bool] = []
    coordinator.onContentReadyChange = { readiness.append($0) }
    let webView = WKWebView()

    coordinator.prepareForNewLoad()
    XCTAssertTrue(readiness.isEmpty)
    (coordinator as WKNavigationDelegate).webView?(webView, didCommit: nil)
    coordinator.webView(webView, didFinish: nil)

    XCTAssertEqual(readiness, [true])
  }

  func testFacebookVideoUsesOfficialOEmbedWithoutReplacingReels() throws {
    let videoURL = try XCTUnwrap(
      URL(string: "https://m.facebook.com/watch/?v=123456789012345")
    )
    guard case .html(let document, let baseURL) = EmbeddedWebSource.facebookVideo(for: videoURL)
    else {
      return XCTFail("Expected a Facebook oEmbed document")
    }

    XCTAssertEqual(baseURL?.absoluteString, "https://www.facebook.com")
    XCTAssertTrue(document.contains("https://graph.facebook.com/oembed_video?"))
    XCTAssertTrue(document.contains("123456789012345"))
    XCTAssertNil(
      EmbeddedWebSource.facebookVideo(
        for: try XCTUnwrap(URL(string: "https://www.facebook.com/reel/123456789012345/"))
      )
    )
  }

  @MainActor
  func testBlockedWebNavigationDoesNotInvalidateTheEmbed() {
    let coordinator = EmbeddedWebView.Coordinator()
    var reportedFailure = false
    coordinator.onLoadFailure = { reportedFailure = $0 == .unavailable }

    coordinator.webView(
      WKWebView(),
      didFailProvisionalNavigation: nil,
      withError: NSError(domain: "WebKitErrorDomain", code: 102)
    )
    XCTAssertFalse(reportedFailure)

    coordinator.webView(
      WKWebView(),
      didFailProvisionalNavigation: nil,
      withError: URLError(.timedOut)
    )
    XCTAssertTrue(reportedFailure)
  }

  @MainActor
  func testWebContentProcessTerminationReportsLoadFailure() {
    let coordinator = EmbeddedWebView.Coordinator()
    var failureCount = 0
    coordinator.onLoadFailure = { failure in
      XCTAssertEqual(failure, .unavailable)
      failureCount += 1
    }

    coordinator.webViewWebContentProcessDidTerminate(WKWebView())

    XCTAssertEqual(failureCount, 1)
  }
}

private extension EmbeddedWebSourceTests {
  @MainActor
  func assertManagedEmbedHeight(containerID: String, document: String) async throws {
    let coordinator = EmbeddedWebView.Coordinator()
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
    // Keep the shipped layout, replacing provider scripts with deterministic content.
    let document = document
      .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
      .replacingOccurrences(
        of: "<div id=\"\(containerID)\"></div>",
        with: "<div id=\"\(containerID)\" style=\"height:240px\"><div style=\"height:240px\">post</div></div>"
      )
    coordinator.source = .html(document: document, baseURL: nil)
    webView.navigationDelegate = coordinator
    let measured = expectation(description: "measured \(containerID) content")
    measured.assertForOverFulfill = false
    coordinator.onIntrinsicHeightChange = { height in
      XCTAssertEqual(height, 240)
      measured.fulfill()
    }
    defer {
      coordinator.clearHandlers()
      webView.navigationDelegate = nil
      webView.stopLoading()
    }
    webView.loadHTMLString(document, baseURL: nil)
    await fulfillment(of: [measured], timeout: 5)
    webView.frame.size.height = 120
    let allowsVerticalOverflow = try await webView.evaluateJavaScript("""
      (() => {
        const root = document.documentElement;
        return root.scrollHeight > root.clientHeight && [root, document.body].every(element =>
          !['hidden', 'clip'].includes(getComputedStyle(element).overflowY));
      })()
      """)
    XCTAssertEqual(allowsVerticalOverflow as? Bool, true, "\(containerID) must allow scrolling in a short viewport")
  }
}

extension EmbeddedWebSourceTests {
  @MainActor
  func testFacebookStalledRequestShowsFallbackAndCanRecover() async throws {
    let url = try XCTUnwrap(URL(string: "https://www.facebook.com/watch/?v=123456789012345"))
    guard case .html(let document, _) = EmbeddedWebSource.facebookVideo(for: url) else {
      return XCTFail("Expected a managed Facebook document")
    }
    let coordinator = EmbeddedWebView.Coordinator()
    let config = WKWebViewConfiguration()
    let handlerName = EmbeddedWebView.Coordinator.metricsHandlerName
    config.userContentController.add(coordinator, name: handlerName)
    config.userContentController.addUserScript(WKUserScript(
      source: "window.fetch = () => new Promise(resolve => { window.resolveEmbed = resolve; });",
      injectionTime: .atDocumentStart, forMainFrameOnly: true
    ))
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
    coordinator.source = .html(document: document, baseURL: nil)
    defer {
      config.userContentController.removeScriptMessageHandler(forName: handlerName)
      coordinator.clearHandlers()
      webView.stopLoading()
    }
    let ready = expectation(description: "stalled request presents recovery guidance")
    coordinator.onContentReadyChange = { if $0 { ready.fulfill() } }
    webView.loadHTMLString(document, baseURL: nil)
    await fulfillment(of: [ready], timeout: 8)
    let fallback = try await webView.evaluateJavaScript(
      "document.querySelector('.linkstr-embed-fallback')?.textContent ?? ''"
    )
    XCTAssertEqual(fallback as? String, EmbeddedWebSource.fallbackMessage)
    let recovered = try await webView.callAsyncJavaScript("""
      await new Promise(resolve => {
        const observer = new MutationObserver(() => {
          if (document.querySelector('#facebook-container iframe')) {
            observer.disconnect();
            resolve();
          }
        });
        observer.observe(document.querySelector('#facebook-container'), { childList: true });
        window.resolveEmbed({ ok: true, json: async () => ({ html:
          '<span style="width:360px;height:640px">' +
          '<iframe title="video" style="width:360px;height:640px;border:0"></iframe></span>'
        }) });
      });
      return !!document.querySelector('#facebook-container iframe') &&
        !document.querySelector('.linkstr-embed-fallback');
      """, arguments: [:], in: nil, contentWorld: .page)
    XCTAssertEqual(recovered as? Bool, true)
    try await assertFacebookPlayerResizesWithoutCropping(webView)
  }

  @MainActor
  private func assertFacebookPlayerResizesWithoutCropping(_ webView: WKWebView) async throws {
    for width in [390.0, 700.0] {
      webView.frame.size.width = width
      let dimensions = try await webView.callAsyncJavaScript("""
        await new Promise(resolve => setTimeout(resolve, 50));
        const frame = document.querySelector('#facebook-container iframe').getBoundingClientRect();
        return [frame.width, frame.height];
        """, arguments: [:], in: nil, contentWorld: .page)
      let values = try XCTUnwrap(dimensions as? [Double])
      XCTAssertEqual(values.count, 2)
      guard values.count == 2 else { return }
      XCTAssertEqual(values[0], width, accuracy: 1)
      XCTAssertEqual(values[0] / values[1], 360.0 / 640.0, accuracy: 0.001)
    }
  }

  @MainActor
  func testFacebookSDKStallShowsFallbackWithoutPreventingLatePlayer() async throws {
    let url = try XCTUnwrap(URL(string: "https://www.facebook.com/watch/?v=123456789012345"))
    guard case .html(let document, _) = EmbeddedWebSource.facebookVideo(for: url) else {
      return XCTFail("Expected a managed Facebook document")
    }
    let coordinator = EmbeddedWebView.Coordinator()
    let config = WKWebViewConfiguration()
    let handlerName = EmbeddedWebView.Coordinator.metricsHandlerName
    config.userContentController.add(coordinator, name: handlerName)
    config.userContentController.addUserScript(WKUserScript(
      source: """
        window.fetch = async () => ({ ok: true, json: async () => ({
          html: '<div id="sdk-placeholder"></div>'
        }) });
        """,
      injectionTime: .atDocumentStart, forMainFrameOnly: true
    ))
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
    coordinator.source = .html(document: document, baseURL: nil)
    defer {
      config.userContentController.removeScriptMessageHandler(forName: handlerName)
      coordinator.clearHandlers()
      webView.stopLoading()
    }
    let ready = expectation(description: "SDK stall presents recovery guidance")
    coordinator.onContentReadyChange = { if $0 { ready.fulfill() } }
    webView.loadHTMLString(document, baseURL: nil)
    await fulfillment(of: [ready], timeout: 8)
    let fallback = try await webView.evaluateJavaScript(
      "document.querySelector('.linkstr-embed-fallback')?.textContent ?? ''"
    )
    XCTAssertEqual(fallback as? String, EmbeddedWebSource.fallbackMessage)
    let recovered = try await webView.callAsyncJavaScript("""
      const placeholder = document.querySelector('#sdk-placeholder');
      if (!placeholder) return false;
      placeholder.innerHTML = '<iframe title="video"></iframe>';
      await new Promise(resolve => setTimeout(resolve, 50));
      return !!document.querySelector('#sdk-placeholder iframe') &&
        !document.querySelector('.linkstr-embed-fallback');
      """, arguments: [:], in: nil, contentWorld: .page)
    XCTAssertEqual(recovered as? Bool, true)
  }
}
