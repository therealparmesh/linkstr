import SwiftUI
import WebKit

enum EmbeddedWebSource: Equatable {
  case url(URL)
  case html(document: String, baseURL: URL?)

  static let fallbackMessage = "couldn’t load the official embed. open the original link in your browser."
  static let fallbackCSS = """
    .linkstr-embed-fallback {
      box-sizing: border-box;
      min-height: 220px;
      display: grid;
      place-items: center;
      padding: 24px;
      color: \(LinkstrTheme.secondaryTextCSS);
      text-align: center;
      font: -apple-system-body;
    }
    """

  var usesManagedHTMLDocument: Bool {
    if case .html = self {
      return true
    }
    return false
  }

  var isFacebookVideoDocument: Bool {
    guard case .html(_, let baseURL) = self else { return false }
    return baseURL.map(SocialURLHeuristics.isFacebookHost) == true
  }

  var customUserAgent: String? {
    isFacebookVideoDocument ? SocialVideoExtractionService.mobileUserAgent : nil
  }
}

private enum EmbeddedWebViewTimingDefaults {
  static let metricPollDelays: [TimeInterval] = [0.05, 0.2, 0.5, 1, 1.5]
}

private let socialEmbedViewportScript = """
  (() => {
    const host = location.hostname.toLowerCase();
    const isInstagram = host === 'instagram.com' || host.endsWith('.instagram.com');
    const isFacebook = host === 'facebook.com' || host.endsWith('.facebook.com');
    if ((!isInstagram && !isFacebook) || document.querySelector('meta[name="viewport"]')) {
      return;
    }

    const viewport = document.createElement('meta');
    viewport.name = 'viewport';
    viewport.content = 'width=device-width, initial-scale=1';
    (document.head || document.documentElement).appendChild(viewport);
  })();
  """

let tiktokPlayerDiagnosticsScript = """
  (() => {
    if (location.origin !== 'https://www.tiktok.com' || !location.pathname.startsWith('/player/v1/')) return;
    // The standalone player posts its host messages back to the top-level window.
    window.addEventListener('message', event => {
      if (event.source !== window || event.origin !== location.origin) return;
      const data = event.data;
      if (data?.['x-tiktok-player'] !== true) return;
      // Autoplay rejection (3002) still permits a user-initiated play.
      const playbackError = data.type === 'onPlayerError' && [1001, 2001, 3001].includes(data.value?.errorCode);
      if (playbackError) {
        window.webkit?.messageHandlers?.linkstrEmbedMetrics?.postMessage({ tiktokPlayerFailure: playbackError });
      }
    });
  })();
  """

struct EmbeddedWebView: UIViewRepresentable {
  enum LoadFailure {
    case unavailable
    case tiktokRateLimited
  }

  let source: EmbeddedWebSource
  var onIntrinsicHeightChange: ((CGFloat) -> Void)?
  var onContentReadyChange: ((Bool) -> Void)?
  var onRenderedPostChange: ((Bool) -> Void)?
  var onProviderFailure: (() -> Void)?
  var onLoadFailure: ((LoadFailure) -> Void)?
  var isPlaybackSuspended = false
  var allowsVerticalScroll = false
}

extension EmbeddedWebView {
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    static let metricsHandlerName = "linkstrEmbedMetrics"

    var source: EmbeddedWebSource?
    var isPlaybackSuspended = false
    var onIntrinsicHeightChange: ((CGFloat) -> Void)?
    var onContentReadyChange: ((Bool) -> Void)?
    var onRenderedPostChange: ((Bool) -> Void)?
    var onProviderFailure: (() -> Void)?
    var onLoadFailure: ((LoadFailure) -> Void)?

    private var pendingMetricPolls: [DispatchWorkItem] = []
    private var metricPollingID = UUID()
    private var lastReportedHeight: CGFloat = 0
    private var lastReportedReadyState = false
    private var lastReportedRenderedPost = false

    private var isLoadingTikTokPlayer: Bool {
      guard case .url(let url) = source else { return false }
      return url.scheme == "https" && url.host == "www.tiktok.com" && URLClassifier.isDedicatedEmbedURL(url)
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == Self.metricsHandlerName, message.frameInfo.isMainFrame else { return }
      if source?.usesManagedHTMLDocument == true {
        applyMetrics(from: message.body)
      } else if isLoadingTikTokPlayer,
        message.frameInfo.securityOrigin.protocol == "https",
        message.frameInfo.securityOrigin.host == "www.tiktok.com",
        let payload = message.body as? [String: Any], payload["tiktokPlayerFailure"] as? Bool == true {
        onProviderFailure?()
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor response: WKNavigationResponse,
      decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
      if isLoadingTikTokPlayer, response.isForMainFrame,
        let http = response.response as? HTTPURLResponse, http.url?.host == "www.tiktok.com",
        http.statusCode == 429, http.expectedContentLength == 0 {
        decisionHandler(.cancel)
        onLoadFailure?(.tiktokRateLimited)
      } else {
        decisionHandler(.allow)
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let targetURL = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }

      if navigationAction.navigationType == .linkActivated {
        decisionHandler(.cancel)
        return
      }

      if WebNavigationGuard.allowsNavigation(to: targetURL) {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      if case .url = source { onContentReadyChange?(true) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard source?.usesManagedHTMLDocument == true else { return }
      scheduleMetricPolling(for: webView)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError error: Error
    ) {
      reportLoadFailure(error)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      reportLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      cancelPendingMetricPolls()
      onLoadFailure?(.unavailable)
    }

    func prepareForNewLoad() {
      cancelPendingMetricPolls()
      lastReportedHeight = 0
      lastReportedReadyState = false
      lastReportedRenderedPost = false
      onContentReadyChange?(false)
      onRenderedPostChange?(false)
    }

    func clearHandlers() {
      cancelPendingMetricPolls()
      onIntrinsicHeightChange = nil
      onContentReadyChange = nil
      onRenderedPostChange = nil
      onProviderFailure = nil
      onLoadFailure = nil
    }

    private func reportLoadFailure(_ error: Error) {
      let nsError = error as NSError
      if (error as? URLError)?.code == .cancelled
        || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) {
        return
      }
      onLoadFailure?(.unavailable)
    }

    private func scheduleMetricPolling(for webView: WKWebView) {
      cancelPendingMetricPolls()

      for delay in EmbeddedWebViewTimingDefaults.metricPollDelays {
        let workItem = DispatchWorkItem { [weak self, weak webView] in
          guard let self, let webView else { return }
          self.pollMetrics(from: webView)
        }
        pendingMetricPolls.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
      }
    }

    private func cancelPendingMetricPolls() {
      metricPollingID = UUID()
      pendingMetricPolls.forEach { $0.cancel() }
      pendingMetricPolls.removeAll()
    }

    private func pollMetrics(from webView: WKWebView) {
      let pollingID = metricPollingID
      let script = """
          (() => {
            const root = document.documentElement;
            const body = document.body;
            const embed = document.querySelector('#tweet-container, #facebook-container');
            const height = embed ? Math.max(
              embed.scrollHeight, embed.offsetHeight, embed.clientHeight
            ) : Math.max(
              root?.scrollHeight ?? 0,
              body?.scrollHeight ?? 0,
              root?.offsetHeight ?? 0,
              body?.offsetHeight ?? 0,
              root?.clientHeight ?? 0,
              body?.clientHeight ?? 0
            );
            const ready = body?.classList.contains('linkstr-embed-ready') ?? false;
            return { height: Math.ceil(height), ready };
          })();
        """

      webView.evaluateJavaScript(script) { [weak self] result, _ in
        guard let self, self.metricPollingID == pollingID else { return }
        self.applyMetrics(from: result)
      }
    }

    private func applyMetrics(from payload: Any?) {
      guard let metrics = payload as? [String: Any] else { return }
      if let height = metrics["height"] as? CGFloat, height > 0, abs(height - lastReportedHeight) > 1 {
        lastReportedHeight = height
        onIntrinsicHeightChange?(height)
      }

      if let ready = metrics["ready"] as? Bool, ready != lastReportedReadyState {
        lastReportedReadyState = ready
        onContentReadyChange?(ready)
      }

      if let hasRenderedPost = metrics["hasRenderedPost"] as? Bool,
        hasRenderedPost != lastReportedRenderedPost {
        lastReportedRenderedPost = hasRenderedPost
        onRenderedPostChange?(hasRenderedPost)
      }
    }
  }
}

extension EmbeddedWebView {
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.allowsAirPlayForMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.defaultWebpagePreferences.preferredContentMode = .mobile
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.userContentController.add(context.coordinator, name: Coordinator.metricsHandlerName)
    config.userContentController.addUserScript(
      WKUserScript(
        source: socialEmbedViewportScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    config.userContentController.addUserScript(
      WKUserScript(source: tiktokPlayerDiagnosticsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    )
    if #available(iOS 16.4, *) {
      config.preferences.isElementFullscreenEnabled = true
    }

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.scrollView.showsVerticalScrollIndicator = false
    webView.scrollView.showsHorizontalScrollIndicator = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.isOpaque = false
    webView.backgroundColor = .clear
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    let sourceChanged = context.coordinator.source != source
    context.coordinator.source = source
    context.coordinator.onIntrinsicHeightChange = onIntrinsicHeightChange
    context.coordinator.onContentReadyChange = onContentReadyChange
    context.coordinator.onRenderedPostChange = onRenderedPostChange
    context.coordinator.onProviderFailure = onProviderFailure
    context.coordinator.onLoadFailure = onLoadFailure
    uiView.scrollView.isScrollEnabled = allowsVerticalScroll
    uiView.scrollView.showsVerticalScrollIndicator = allowsVerticalScroll
    if context.coordinator.isPlaybackSuspended != isPlaybackSuspended {
      context.coordinator.isPlaybackSuspended = isPlaybackSuspended
      uiView.setAllMediaPlaybackSuspended(isPlaybackSuspended, completionHandler: nil)
    }

    guard sourceChanged else { return }
    context.coordinator.prepareForNewLoad()

    uiView.customUserAgent = source.customUserAgent
    switch source {
    case .url(let url):
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      if let host = url.host?.lowercased(),
        host == "youtube.com"
          || host.hasSuffix(".youtube.com")
          || host == "youtube-nocookie.com"
          || host.hasSuffix(".youtube-nocookie.com") {
        let appIdentityURL = youtubeWebViewIdentityURL
        request.setValue(appIdentityURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(appIdentityURL.absoluteString, forHTTPHeaderField: "Origin")
      }
      uiView.load(request)
    case .html(let document, let baseURL):
      uiView.loadHTMLString(document, baseURL: baseURL)
    }
  }
}

extension EmbeddedWebView {
  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    uiView.navigationDelegate = nil
    uiView.uiDelegate = nil
    uiView.stopLoading()
    uiView.pauseAllMediaPlayback(completionHandler: nil)
    uiView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.metricsHandlerName
    )
    coordinator.clearHandlers()
  }

  private var youtubeWebViewIdentityURL: URL {
    if let bundleID = Bundle.main.bundleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !bundleID.isEmpty,
      let url = URL(string: "https://\(bundleID)") {
      return url
    }
    return URL(string: "https://localhost")!
  }
}
