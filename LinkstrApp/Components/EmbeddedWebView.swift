import SwiftUI
import WebKit

struct EmbeddedWebView: UIViewRepresentable {
  let url: URL

  final class Coordinator {
    var loadedURLString: String?
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
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.isOpaque = false
    webView.backgroundColor = .clear
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    guard context.coordinator.loadedURLString != url.absoluteString else { return }
    context.coordinator.loadedURLString = url.absoluteString

    // Wrap provider URLs in an iframe so allowfullscreen is explicitly enabled.
    let html = """
      <!doctype html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            width: 100%;
            height: 100%;
            background: #000;
            overflow: hidden;
          }
          iframe {
            position: absolute;
            inset: 0;
            border: 0;
            width: 100%;
            height: 100%;
          }
        </style>
      </head>
      <body>
        <iframe
          src="\(url.absoluteString)"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen; web-share"
          allowfullscreen
          webkitallowfullscreen
          mozallowfullscreen
          referrerpolicy="no-referrer-when-downgrade">
        </iframe>
      </body>
      </html>
      """
    uiView.loadHTMLString(
      html, baseURL: URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")"))
  }
}
