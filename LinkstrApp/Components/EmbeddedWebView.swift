import SwiftUI
import WebKit

struct EmbeddedWebView: UIViewRepresentable {
  let url: URL

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loadedURLString: String?

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
    guard context.coordinator.loadedURLString != url.absoluteString else { return }
    context.coordinator.loadedURLString = url.absoluteString

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
