import SwiftUI
import WebKit

#if canImport(UIKit)
  import UIKit
#endif

enum EmbeddedWebSource: Equatable {
  case url(URL)
  case html(document: String, baseURL: URL?)

  var usesManagedHTMLDocument: Bool {
    if case .html = self {
      return true
    }
    return false
  }
}

private enum EmbeddedWebViewTimingDefaults {
  static let metricPollDelays: [TimeInterval] = [0.05, 0.2, 0.5, 1, 1.5]
}

struct EmbeddedWebView: UIViewRepresentable {
  let source: EmbeddedWebSource
  var onIntrinsicHeightChange: ((CGFloat) -> Void)?
  var onContentReadyChange: ((Bool) -> Void)?
  var onLoadFailure: (() -> Void)?

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    static let metricsHandlerName = "linkstrEmbedMetrics"

    var source: EmbeddedWebSource?
    var onIntrinsicHeightChange: ((CGFloat) -> Void)?
    var onContentReadyChange: ((Bool) -> Void)?
    var onLoadFailure: (() -> Void)?

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

      if navigationAction.navigationType == .linkActivated {
        guard WebNavigationGuard.allowsNavigation(to: targetURL) else {
          decisionHandler(.cancel)
          return
        }
        // Allow same-origin link navigations to proceed inside the webview
        // (e.g. play buttons, internal navigation) instead of bouncing to Safari.
        if isSameOrigin(targetURL, as: webView.url) {
          decisionHandler(.allow)
          return
        }
        openExternally(targetURL)
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
      if let targetURL = navigationAction.request.url,
        WebNavigationGuard.allowsNavigation(to: targetURL) {
        // For same-origin navigations (e.g. window.open or target="_blank"),
        // load in the existing webview so inline playback works instead of
        // bouncing to Safari.
        if isSameOrigin(targetURL, as: webView.url) {
          webView.load(navigationAction.request)
        } else {
          openExternally(targetURL)
        }
      }
      return nil
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
      onLoadFailure = nil
    }

    private func reportLoadFailure(_ error: Error) {
      guard (error as? URLError)?.code != .cancelled else { return }
      onLoadFailure?()
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
      pendingMetricPolls.forEach { $0.cancel() }
      pendingMetricPolls.removeAll()
    }

    private func pollMetrics(from webView: WKWebView) {
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
            const ready = body?.classList.contains('linkstr-embed-ready') ?? false;
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
        let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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

    private func isSameOrigin(_ url: URL, as other: URL?) -> Bool {
      guard let otherHost = other?.host?.lowercased(),
        let targetHost = url.host?.lowercased()
      else { return false }
      return targetHost == otherHost || targetHost.hasSuffix(".\(otherHost)")
        || otherHost.hasSuffix(".\(targetHost)")
    }

    private func openExternally(_ url: URL) {
      #if canImport(UIKit)
        UIApplication.shared.open(url)
      #endif
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
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.userContentController.add(context.coordinator, name: Coordinator.metricsHandlerName)
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
    context.coordinator.onLoadFailure = onLoadFailure

    guard sourceChanged else { return }
    context.coordinator.prepareForNewLoad()

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

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    uiView.navigationDelegate = nil
    uiView.uiDelegate = nil
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
