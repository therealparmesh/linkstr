import Foundation

enum TwitterEmbedTimingDefaults {
  static let readyTransitionDurationSeconds: TimeInterval = 0.18
  static let postRenderRefreshDelaysMilliseconds = [40, 120, 260, 520, 1000, 1800]
  static let bootstrapRefreshDelaysMilliseconds = [80, 220, 480, 900, 1600]
  static let fallbackDelayMilliseconds = 3_200

  static func javascriptArray(for values: [Int]) -> String {
    "[\(values.map(String.init).joined(separator: ", "))]"
  }
}

enum TwitterEmbedDocumentBuilder {
  static func documentHTML(tweetID: String) -> String {
    let css = embedCSS()
    let javascript = embedJavaScript(tweetID: tweetID)
    return """
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <style>
      \(css)
          </style>
        </head>
        <body>
          <div id="tweet-container"></div>
          <script>
      \(javascript)
          </script>
        </body>
      </html>
      """
  }

  private static func embedCSS() -> String {
    """
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              color-scheme: dark;
              overflow: hidden;
            }

            body {
              opacity: 0;
              transition: opacity \(TwitterEmbedTimingDefaults.readyTransitionDurationSeconds)s ease;
            }

            body.linkstr-embed-ready {
              opacity: 1;
            }

            #tweet-container {
              width: 100%;
              min-height: 220px;
              display: flex;
              justify-content: center;
            }

            #tweet-container > * {
              width: 100% !important;
              max-width: 100% !important;
              margin: 0 auto !important;
            }

            #tweet-container iframe {
              width: 100% !important;
              max-width: 100% !important;
            }

            .linkstr-embed-fallback {
              min-height: 220px;
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 24px;
              color: rgba(255, 255, 255, 0.74);
              text-align: center;
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
              font-size: 15px;
              line-height: 1.4;
            }
    """
  }

  private static func embedJavaScript(tweetID: String) -> String {
    let helperFunctions = embedJavaScriptHelpers(tweetID: tweetID)
    let bootstrapLogic = embedJavaScriptBootstrap()
    return """
              (() => {
      \(helperFunctions)

      \(bootstrapLogic)
              })();
      """
  }

  private static func embedJavaScriptHelpers(tweetID: String) -> String {
    let utilities = embedJavaScriptUtilities(tweetID: tweetID)
    let renderer = embedJavaScriptRenderer()
    return """
        \(utilities)

        \(renderer)
      """
  }

  private static func embedJavaScriptUtilities(tweetID: String) -> String {
    let constants = embedJavaScriptConstants(tweetID: tweetID)
    let domHandlers = embedJavaScriptDOMHandlers()
    return """
        \(constants)

        \(domHandlers)
      """
  }

  private static func embedJavaScriptConstants(tweetID: String) -> String {
    return """
                      const tweetID = "\(tweetID)";
                      const readyClass = "linkstr-embed-ready";
                      const body = document.body;
                      const root = document.documentElement;
                      const container = document.getElementById("tweet-container");
                      const metricsHandler = window.webkit?.messageHandlers?.linkstrEmbedMetrics;

                      const height = () => Math.max(
                        root?.scrollHeight ?? 0,
                        body?.scrollHeight ?? 0,
                        container?.scrollHeight ?? 0,
                        root?.offsetHeight ?? 0,
                        body?.offsetHeight ?? 0,
                        container?.offsetHeight ?? 0,
                        root?.clientHeight ?? 0,
                        body?.clientHeight ?? 0,
                        container?.clientHeight ?? 0
                      );

                      const postMetrics = (readyOverride) => {
                        metricsHandler?.postMessage({
                          height: Math.ceil(height()),
                          ready: readyOverride ?? body.classList.contains(readyClass)
                        });
                      };

                      const markReady = () => {
                        if (body.classList.contains(readyClass) === false) {
                          body.classList.add(readyClass);
                        }
                        postMetrics(true);
                      };

                      const hasRenderedTweet = () =>
                        container?.querySelector("iframe[src*='platform.twitter.com']") ||
                        container?.querySelector("iframe[src*='syndication.twitter.com']") ||
                        container?.querySelector("twitter-widget") ||
                        container?.querySelector(".twitter-tweet-rendered");
      """
  }

  private static func embedJavaScriptDOMHandlers() -> String {
    return """
                      const sizeRenderedTweet = () => {
                        const rootElement = container?.firstElementChild;
                        if (rootElement) {
                          rootElement.style.width = "100%";
                          rootElement.style.maxWidth = "100%";
                          rootElement.style.margin = "0 auto";
                        }

                        const iframe = container?.querySelector("iframe");
                        if (iframe) {
                          iframe.style.width = "100%";
                          iframe.style.maxWidth = "100%";
                        }
                      };

                      const showFallback = () => {
                        if (!container || container.children.length > 0) {
                          markReady();
                          return;
                        }

                        container.innerHTML =
                          '<div class="linkstr-embed-fallback">' +
                          'couldn\\'t load this post preview. use open in browser.</div>';
                        markReady();
                      };

                      const refresh = () => {
                        sizeRenderedTweet();
                        postMetrics();
                        if (hasRenderedTweet()) {
                          markReady();
                        }
                      };
      """
  }

}
