import Foundation
import WebKit

extension SocialVideoExtractionService {
  func extractViaGenericSniff(sourceURL: URL) async -> ExtractionState {
    for userAgent in [Self.mobileUserAgent, Self.desktopUserAgent] {
      var scrapeCandidates = await scrapeMediaURLsFromPage(
        sourceURL: sourceURL, userAgent: userAgent)
      if scrapeCandidates.isEmpty {
        try? await Task.sleep(for: .milliseconds(300))
        scrapeCandidates = await scrapeMediaURLsFromPage(
          sourceURL: sourceURL, userAgent: userAgent)
      }

      if !scrapeCandidates.isEmpty {
        let ranked = rankCandidates(scrapeCandidates, sourceURL: sourceURL)
        if let resolved = resolvePlayableMedia(
          from: ranked,
          sourceURL: sourceURL,
          userAgent: userAgent,
          cookies: []
        ) {
          return resolved
        }
      }

      let sniffResult = await sniffMediaURLs(
        from: sourceURL, userAgent: userAgent)
      let candidates = mergeCandidates(
        primary: sniffResult.urls, secondary: scrapeCandidates)
      guard !candidates.isEmpty else { continue }

      let rankedCandidates = rankCandidates(candidates, sourceURL: sourceURL)
      if let resolved = resolvePlayableMedia(
        from: rankedCandidates,
        sourceURL: sourceURL,
        userAgent: userAgent,
        cookies: sniffResult.cookies
      ) {
        return resolved
      }
    }

    return .cannotExtract("could not find a usable video stream for this post.")
  }

  @MainActor
  func sniffMediaURLs(from sourceURL: URL, userAgent: String) async -> (
    urls: [URL], cookies: [HTTPCookie]
  ) {
    let collector = MediaCandidateCollector(
      sourceURL: sourceURL,
      userAgent: userAgent,
      injectionScript: Self.injectionScript
    )
    return await collector.collect()
  }

  func mergeCandidates(primary: [URL], secondary: [URL]) -> [URL] {
    var seen = Set<String>()
    return (primary + secondary).filter { url in
      seen.insert(url.absoluteString.lowercased()).inserted
    }
  }

  func scrapeMediaURLsFromPage(sourceURL: URL, userAgent: String) async -> [URL] {
    var request = URLRequest(url: sourceURL)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("*/*", forHTTPHeaderField: "Accept")

    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      guard var html = String(data: data, encoding: .utf8) else { return [] }

      html = Self.unescapeJSONStringLiterals(html)

      let regex = try NSRegularExpression(pattern: #"https://[^"'\s<]+"#)
      let nsRange = NSRange(html.startIndex..., in: html)
      let matches = regex.matches(in: html, range: nsRange)

      var urls: [URL] = []
      var seen = Set<String>()

      for match in matches {
        guard let range = Range(match.range, in: html) else { continue }
        var candidate = String(html[range]).trimmingCharacters(
          in: CharacterSet(charactersIn: ")]},"))
        candidate = HTMLTextDecoder.decodeHTMLEntities(candidate)
        let lower = candidate.lowercased()
        guard Self.isLikelyMediaURLString(lower), seen.insert(lower).inserted,
          let url = URL(string: candidate)
        else { continue }
        urls.append(url)
      }

      return urls
    } catch {
      return []
    }
  }

  /// Decode JSON-escaped text so that embedded URLs become plain `https://…`
  /// strings the regex scraper can extract.
  static func unescapeJSONStringLiterals(_ text: String) -> String {
    guard
      let unicodeEscapePattern = try? NSRegularExpression(
        pattern: #"\\u([0-9A-Fa-f]{4})"#
      )
    else {
      return text
    }
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var result = text
    let matches = unicodeEscapePattern.matches(in: text, range: fullRange)
    for match in matches.reversed() {
      guard match.numberOfRanges > 1,
        let hexRange = Range(match.range(at: 1), in: result),
        let matchRange = Range(match.range, in: result),
        let scalar = UInt32(result[hexRange], radix: 16),
        let unicode = Unicode.Scalar(scalar)
      else { continue }
      result.replaceSubrange(matchRange, with: String(unicode))
    }

    result = result.replacingOccurrences(of: "\\/", with: "/")
    result = result.replacingOccurrences(of: "\\", with: "")

    return result
  }

  static let injectionScript = """
    (function() {
      const candidatePattern = new RegExp(
        '(\\\\.m3u8|\\\\.mp4|mime_type=video_mp4|/aweme/v1/play/|/video/tos/|' +
        'playaddr|play_addr|video\\\\.xx\\\\.fbcdn\\\\.net|' +
        'cdninstagram\\\\.com.*\\\\.mp4|fbcdn\\\\.net.*/video|' +
        '(?:cdninstagram\\\\.com|fbcdn\\\\.net).*/o1/v/|video\\\\.twimg\\\\.com)', 'i');

      const send = (u) => {
        if (!u || typeof u !== 'string') return;
        if (candidatePattern.test(u)) {
          window.webkit.messageHandlers.linkstrVideo.postMessage(u);
        }
      };

      const scanTextForURLs = (text) => {
        if (!text || typeof text !== 'string') return;
        const matches = text.match(/https:\\/\\/[^\\"'\\s<]+/g);
        if (!matches) return;
        matches.forEach((raw) => {
          const normalized = raw
            .replace(/\\\\u([0-9A-Fa-f]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
            .replace(/\\\\\\//g, '/')
            .replace(/\\\\/g, '');
          send(normalized);
        });
      };

      const scanVideoElements = () => {
        document.querySelectorAll('video').forEach((v) => {
          send(v.currentSrc || v.src);
          if (v.srcObject && v.srcObject.url) {
            send(v.srcObject.url);
          }
        });
      };

      const scanResources = () => {
        try {
          performance.getEntriesByType('resource').forEach((entry) => send(entry.name));
        } catch (_) {}
      };

      const origFetch = window.fetch;
      window.fetch = function() {
        const requestLike = arguments[0];
        const url = requestLike && requestLike.url ? requestLike.url : requestLike;
        if (typeof url === 'string') send(url);
        return origFetch.apply(this, arguments).then((response) => {
          try {
            response.clone().text().then(scanTextForURLs).catch(() => {});
          } catch (_) {}
          return response;
        });
      };

      const origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        if (typeof url === 'string') send(url);
        this.addEventListener('load', () => {
          try {
            if (typeof this.responseText === 'string') {
              scanTextForURLs(this.responseText);
            }
          } catch (_) {}
        });
        return origOpen.apply(this, arguments);
      };

      document.addEventListener('loadedmetadata', scanVideoElements, true);

      const observer = new MutationObserver(() => {
        scanVideoElements();
        scanResources();
      });

      observer.observe(document.documentElement || document.body, {
        childList: true,
        subtree: true,
        attributes: true
      });

      setInterval(() => {
        scanVideoElements();
        scanResources();
      }, 600);

      scanVideoElements();
      scanResources();
    })();
    """
}

@MainActor
final class MediaCandidateCollector: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  private let sourceURL: URL
  private let userAgent: String
  private let injectionScript: String

  private var continuation: CheckedContinuation<[URL], Never>?
  private var timeoutTask: Task<Void, Never>?
  private var candidateSet = Set<String>()
  private var candidateOrder: [URL] = []
  private var webView: WKWebView?
  private var contentController: WKUserContentController?

  init(sourceURL: URL, userAgent: String, injectionScript: String) {
    self.sourceURL = sourceURL
    self.userAgent = userAgent
    self.injectionScript = injectionScript
    super.init()
  }

  func collect() async -> (urls: [URL], cookies: [HTTPCookie]) {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.websiteDataStore = .nonPersistent()

    let controller = WKUserContentController()
    controller.add(self, name: "linkstrVideo")
    controller.addUserScript(
      WKUserScript(
        source: injectionScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )
    config.userContentController = controller
    self.contentController = controller

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.customUserAgent = userAgent
    self.webView = webView

    webView.load(URLRequest(url: sourceURL))

    let urls = await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
      self.continuation = continuation
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(
          for: .seconds(SocialVideoTimingDefaults.mediaCandidateCollectionTimeout))
        guard let self else { return }
        await MainActor.run {
          self.finish()
        }
      }
    }

    let cookies = await allCookies(from: webView.configuration.websiteDataStore.httpCookieStore)
    cleanup()
    return (urls, cookies)
  }

  private func cleanup() {
    timeoutTask?.cancel()
    timeoutTask = nil
    earlyFinishTask?.cancel()
    earlyFinishTask = nil

    contentController?.removeScriptMessageHandler(forName: "linkstrVideo")
    contentController = nil

    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
  }

  private static let highConfidencePatterns = [
    ".mp4", ".m3u8",
    "/aweme/v1/play/", "/video/tos/",
    "video.xx.fbcdn.net", "cdninstagram.com", "video.twimg.com"
  ]

  private var earlyFinishTask: Task<Void, Never>?

  private func registerCandidate(_ url: URL) {
    let lower = url.absoluteString.lowercased()
    guard SocialVideoExtractionService.isLikelyMediaURLString(lower) else { return }

    if candidateSet.insert(lower).inserted {
      candidateOrder.append(url)

      if earlyFinishTask == nil,
        Self.highConfidencePatterns.contains(where: lower.contains) {
        earlyFinishTask = Task { [weak self] in
          try? await Task.sleep(
            for: .seconds(SocialVideoTimingDefaults.earlyFinishDebounce))
          guard let self else { return }
          await MainActor.run { self.finish() }
        }
      }
    }
  }

  private func finish() {
    guard let continuation else { return }
    continuation.resume(returning: candidateOrder)
    self.continuation = nil
  }

  private func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
    await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
      store.getAllCookies { cookies in
        continuation.resume(returning: cookies)
      }
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url {
      registerCandidate(url)
      guard WebNavigationGuard.allowsNavigation(to: url) else {
        decisionHandler(.cancel)
        return
      }
    }
    decisionHandler(.allow)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == "linkstrVideo",
      let body = message.body as? String,
      let url = URL(string: body)
    else {
      return
    }

    registerCandidate(url)
  }
}
