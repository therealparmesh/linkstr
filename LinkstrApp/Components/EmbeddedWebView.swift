import SwiftUI
import WebKit

enum EmbeddedWebSource: Equatable {
  case url(URL)
  case html(document: String, baseURL: URL?)

  var cacheKey: String {
    switch self {
    case .url(let url):
      return "url:\(url.absoluteString)"
    case .html(let document, let baseURL):
      return "html:\(baseURL?.absoluteString ?? "nil"):\(document)"
    }
  }

  var usesManagedHTMLDocument: Bool {
    if case .html = self {
      return true
    }
    return false
  }
}

struct EmbeddedWebView: UIViewRepresentable {
  let source: EmbeddedWebSource
  var onIntrinsicHeightChange: ((CGFloat) -> Void)? = nil
  var onContentReadyChange: ((Bool) -> Void)? = nil

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let metricsHandlerName = "linkstrEmbedMetrics"
    private static let metricPollDelays: [TimeInterval] = [0.05, 0.18, 0.4, 0.9, 1.6]

    var loadedSourceKey: String?
    var source: EmbeddedWebSource?
    var onIntrinsicHeightChange: ((CGFloat) -> Void)?
    var onContentReadyChange: ((Bool) -> Void)?

    private var pendingMetricPolls: [DispatchWorkItem] = []
    private var lastReportedHeight: CGFloat = 0
    private var lastReportedReadyState = false

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == Self.metricsHandlerName else { return }
      applyMetrics(from: message.body)
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

      let scheme = targetURL.scheme?.lowercased() ?? ""
      if ["http", "https", "about", "data", "blob"].contains(scheme) {
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      scheduleMetricPolling(for: webView)
    }

    func prepareForNewLoad() {
      cancelPendingMetricPolls()
      lastReportedHeight = 0
      lastReportedReadyState = false
      onContentReadyChange?(false)
    }

    func clearHandlers() {
      cancelPendingMetricPolls()
      onIntrinsicHeightChange = nil
      onContentReadyChange = nil
    }

    private func scheduleMetricPolling(for webView: WKWebView) {
      cancelPendingMetricPolls()

      for delay in Self.metricPollDelays {
        let workItem = DispatchWorkItem { [weak self, weak webView] in
          guard let self, let webView else { return }
          self.pollMetrics(from: webView)
        }
        pendingMetricPolls.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
      }
    }

    private func cancelPendingMetricPolls() {
      pendingMetricPolls.forEach { $0.cancel() }
      pendingMetricPolls.removeAll()
    }

    private func pollMetrics(from webView: WKWebView) {
      let forceReady = source?.usesManagedHTMLDocument == false
      let script = """
          (() => {
            const root = document.documentElement;
            const body = document.body;
            const height = Math.max(
              root?.scrollHeight ?? 0,
              body?.scrollHeight ?? 0,
              root?.offsetHeight ?? 0,
              body?.offsetHeight ?? 0,
              root?.clientHeight ?? 0,
              body?.clientHeight ?? 0
            );
            const ready = \(forceReady ? "true" : "(body?.classList.contains('linkstr-embed-ready') ?? false)");
            return JSON.stringify({ height: Math.ceil(height), ready });
          })();
        """

      webView.evaluateJavaScript(script) { [weak self] result, _ in
        guard let self else { return }
        self.applyMetrics(from: result)
      }
    }

    private func applyMetrics(from payload: Any?) {
      let metrics = decodeMetrics(from: payload)
      if let height = metrics.height, height > 0, abs(height - lastReportedHeight) > 1 {
        lastReportedHeight = height
        onIntrinsicHeightChange?(height)
      }

      if let ready = metrics.ready, ready != lastReportedReadyState {
        lastReportedReadyState = ready
        onContentReadyChange?(ready)
      }
    }

    private func decodeMetrics(from payload: Any?) -> (height: CGFloat?, ready: Bool?) {
      if let dictionary = payload as? [String: Any] {
        return (
          height: CGFloat((dictionary["height"] as? NSNumber)?.doubleValue ?? 0),
          ready: dictionary["ready"] as? Bool
        )
      }

      if let json = payload as? String,
        let data = json.data(using: .utf8),
        let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        return (
          height: CGFloat((dictionary["height"] as? NSNumber)?.doubleValue ?? 0),
          ready: dictionary["ready"] as? Bool
        )
      }

      if let number = payload as? NSNumber {
        return (height: CGFloat(number.doubleValue), ready: nil)
      }

      return (height: nil, ready: nil)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.allowsAirPlayForMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.userContentController.add(context.coordinator, name: Coordinator.metricsHandlerName)
    if #available(iOS 16.4, *) {
      config.preferences.isElementFullscreenEnabled = true
    }

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
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
    context.coordinator.source = source
    context.coordinator.onIntrinsicHeightChange = onIntrinsicHeightChange
    context.coordinator.onContentReadyChange = onContentReadyChange

    guard context.coordinator.loadedSourceKey != source.cacheKey else { return }
    context.coordinator.loadedSourceKey = source.cacheKey
    context.coordinator.prepareForNewLoad()

    switch source {
    case .url(let url):
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      if let host = url.host?.lowercased(),
        host == "youtube.com"
          || host.hasSuffix(".youtube.com")
          || host == "youtube-nocookie.com"
          || host.hasSuffix(".youtube-nocookie.com")
      {
        let appIdentityURL = youtubeWebViewIdentityURL
        request.setValue(appIdentityURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(appIdentityURL.absoluteString, forHTTPHeaderField: "Origin")
      }
      uiView.load(request)
    case .html(let document, let baseURL):
      uiView.loadHTMLString(document, baseURL: baseURL)
    }
  }

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    uiView.navigationDelegate = nil
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
      let url = URL(string: "https://\(bundleID)")
    {
      return url
    }

    return URL(string: "https://localhost")!
  }
}
