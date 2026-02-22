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

    let lockLayoutScript = WKUserScript(
      source: """
          (function() {
            const apply = () => {
              if (document.documentElement) {
                document.documentElement.style.margin = '0';
                document.documentElement.style.padding = '0';
                document.documentElement.style.overflow = 'hidden';
              }
              if (document.body) {
                document.body.style.margin = '0';
                document.body.style.padding = '0';
                document.body.style.overflow = 'hidden';
                document.body.style.background = '#000';
              }
            };
            apply();
            window.addEventListener('load', apply);
          })();
        """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    config.userContentController.addUserScript(lockLayoutScript)

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.scrollView.showsVerticalScrollIndicator = false
    webView.scrollView.showsHorizontalScrollIndicator = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.customUserAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
      + " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    webView.isOpaque = false
    webView.backgroundColor = .clear
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    guard context.coordinator.loadedURLString != url.absoluteString else { return }
    context.coordinator.loadedURLString = url.absoluteString

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    uiView.load(request)
  }
}
