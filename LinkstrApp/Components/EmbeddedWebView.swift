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
}

struct EmbeddedWebView: UIViewRepresentable {
  let source: EmbeddedWebSource

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loadedSourceKey: String?

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
    guard context.coordinator.loadedSourceKey != source.cacheKey else { return }
    context.coordinator.loadedSourceKey = source.cacheKey

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
