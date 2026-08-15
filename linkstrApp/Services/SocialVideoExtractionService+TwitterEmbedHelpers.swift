extension TwitterEmbedDocumentBuilder {
  static func embedJavaScriptRenderer() -> String {
    let postRenderRefreshDelays = TwitterEmbedTimingDefaults.javascriptArray(
      for: TwitterEmbedTimingDefaults.postRenderRefreshDelaysMilliseconds
    )
    return """
                    const renderTweet = () => {
                      const widgetAPI = window.twttr?.widgets;
                      if (!widgetAPI?.createTweet || !container) {
                        showFallback();
                        return;
                      }

                      container.innerHTML = "";

                      const width = Math.min(
                        550,
                        Math.max(
                          220,
                          Math.floor(
                            container.clientWidth ||
                            root?.clientWidth ||
                            window.innerWidth ||
                            550
                          )
                        )
                      );

                      widgetAPI.createTweet(tweetID, container, {
                        align: "center",
                        dnt: true,
                        theme: "dark",
                        width
                      }).then((element) => {
                        if (!element) {
                          showFallback();
                          return;
                        }

                        refresh();
                        \(postRenderRefreshDelays).forEach((delay) => {
                          window.setTimeout(refresh, delay);
                        });
                      }).catch(showFallback);
                    };
      """
  }

  static func embedJavaScriptBootstrap() -> String {
    let bootstrapRefreshDelays = TwitterEmbedTimingDefaults.javascriptArray(
      for: TwitterEmbedTimingDefaults.bootstrapRefreshDelaysMilliseconds
    )
    return """
                  const script = document.createElement("script");
                  script.src = "https://platform.twitter.com/widgets.js";
                  script.async = true;
                  script.onload = () => {
                    if (window.twttr?.ready) {
                      window.twttr.ready(renderTweet);
                    } else {
                      renderTweet();
                    }
                  };
                  script.onerror = showFallback;
                  document.head.appendChild(script);

                  window.addEventListener("resize", refresh);
                  window.addEventListener("message", refresh);

                  new MutationObserver(refresh).observe(body, {
                    subtree: true,
                    childList: true
                  });

                  if (window.ResizeObserver) {
                    new ResizeObserver(refresh).observe(body);
                  }

                  window.setTimeout(showFallback, \(TwitterEmbedTimingDefaults.fallbackDelayMilliseconds));
                  \(bootstrapRefreshDelays).forEach((delay) => {
                    window.setTimeout(() => {
                      refresh();
                    }, delay);
                  });
      """
  }
}
