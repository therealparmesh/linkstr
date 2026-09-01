import Foundation

private enum FacebookEmbeddedVideoDefaults {
  static let readyFallbackMilliseconds = 5_000
}

private let facebookVideoDocumentTemplate = """
  <!doctype html>
  <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <style>
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          color-scheme: dark;
          overflow: hidden;
        }

        #facebook-container {
          width: 100%;
          min-height: 220px;
        }

        #facebook-container > *,
        #facebook-container span,
        #facebook-container iframe {
          width: 100% !important;
          max-width: 100% !important;
          margin: 0 !important;
        }
      </style>
    </head>
    <body>
      <div id="facebook-container"></div>
      <script>
        (() => {
          const container = document.getElementById("facebook-container");
          const metricsHandler = window.webkit?.messageHandlers?.linkstrEmbedMetrics;
          const markReady = () => {
            document.body.classList.add("linkstr-embed-ready");
            metricsHandler?.postMessage({
              height: Math.ceil(document.documentElement.scrollHeight),
              ready: true
            });
          };

          const observer = new MutationObserver(() => {
            if (container.querySelector("iframe")) {
              observer.disconnect();
              requestAnimationFrame(markReady);
            }
          });
          observer.observe(container, { childList: true, subtree: true });

          fetch("__LINKSTR_FACEBOOK_OEMBED_ENDPOINT__")
            .then(response => {
              if (!response.ok) throw new Error("oEmbed request failed");
              return response.json();
            })
            .then(payload => {
              if (typeof payload.html !== "string" || payload.html.length === 0) {
                throw new Error("oEmbed response was empty");
              }
              container.innerHTML = payload.html;
              container.querySelectorAll("script").forEach(oldScript => {
                const script = document.createElement("script");
                for (const attribute of oldScript.attributes) {
                  script.setAttribute(attribute.name, attribute.value);
                }
                script.textContent = oldScript.textContent;
                oldScript.replaceWith(script);
              });
            })
            .catch(() => {
              container.textContent = "embedded playback unavailable.";
              markReady();
            });

          window.setTimeout(markReady, __LINKSTR_FACEBOOK_READY_TIMEOUT__);
        })();
      </script>
    </body>
  </html>
  """

extension EmbeddedWebSource {
  static func facebookVideo(for sourceURL: URL) -> EmbeddedWebSource? {
    let embeddedURL = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name.caseInsensitiveCompare("href") == .orderedSame })?.value
      .flatMap(URL.init(string:))
    let permalinkURL = embeddedURL ?? sourceURL

    guard SocialURLHeuristics.isFacebookHost(permalinkURL),
      let videoID = SocialURLHeuristics.facebookVideoID(from: permalinkURL),
      !SocialURLHeuristics.isFacebookReelURL(permalinkURL)
    else {
      return nil
    }

    var videoURL = URLComponents(string: "https://m.facebook.com/watch/")
    videoURL?.queryItems = [URLQueryItem(name: "v", value: videoID)]
    guard let videoURL = videoURL?.url else { return nil }

    var endpoint = URLComponents(string: "https://graph.facebook.com/oembed_video")
    endpoint?.queryItems = [URLQueryItem(name: "url", value: videoURL.absoluteString)]
    guard let endpointURL = endpoint?.url else { return nil }

    return .html(
      document: facebookVideoDocument(endpointURL: endpointURL),
      baseURL: URL(string: "https://www.facebook.com")
    )
  }

  private static func facebookVideoDocument(endpointURL: URL) -> String {
    facebookVideoDocumentTemplate
      .replacingOccurrences(
        of: "__LINKSTR_FACEBOOK_OEMBED_ENDPOINT__",
        with: endpointURL.absoluteString
      )
      .replacingOccurrences(
        of: "__LINKSTR_FACEBOOK_READY_TIMEOUT__",
        with: String(FacebookEmbeddedVideoDefaults.readyFallbackMilliseconds)
      )
  }
}
