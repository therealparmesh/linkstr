import AVFoundation
import Foundation
import WebKit

struct PlayableMedia {
  let playbackURL: URL
  let headers: [String: String]
  let isLocalFile: Bool
}

enum ExtractionState {
  case ready(PlayableMedia)
  case cannotExtract(String)
}

final class SocialVideoExtractionService: NSObject {
  static let shared = SocialVideoExtractionService()

  private override init() {
    super.init()
  }

  func extractPlayableMedia(from sourceURL: URL) async -> ExtractionState {
    if isTikTokURL(sourceURL) {
      let directTikTokCandidates = await loadTikTokAPIPlayURLs(from: sourceURL)
      if let resolved = await resolvePlayableMedia(
        from: directTikTokCandidates,
        sourceURL: sourceURL,
        userAgent: Self.tikTokAPIUserAgent,
        cookies: []
      ) {
        return resolved
      }
    }

    for userAgent in [Self.desktopUserAgent, Self.mobileUserAgent] {
      let sniffResult = await sniffMediaURLs(from: sourceURL, userAgent: userAgent)
      let sniffedCandidates = sniffResult.urls
      let pageCandidates = await scrapeMediaURLsFromPage(sourceURL: sourceURL, userAgent: userAgent)
      let candidates = mergeCandidates(primary: sniffedCandidates, secondary: pageCandidates)
      guard !candidates.isEmpty else { continue }

      let rankedCandidates = rankCandidates(candidates, sourceURL: sourceURL)
      if let resolved = await resolvePlayableMedia(
        from: rankedCandidates,
        sourceURL: sourceURL,
        userAgent: userAgent,
        cookies: sniffResult.cookies
      ) {
        return resolved
      }
    }

    return .cannotExtract("Could not find a usable video stream for this post")
  }

  private func resolvePlayableMedia(
    from candidates: [URL],
    sourceURL: URL,
    userAgent: String,
    cookies: [HTTPCookie]
  ) async -> ExtractionState? {
    for candidateURL in candidates {
      // All providers in scope expose HTTPS media URLs and ATS expects secure transport.
      guard candidateURL.scheme?.lowercased() == "https" else { continue }

      if !matchesSourceIdentity(candidateURL, sourceURL: sourceURL) {
        continue
      }

      let headers = buildHeaders(
        for: candidateURL,
        sourcePageURL: sourceURL,
        cookies: cookies,
        userAgent: userAgent
      )

      guard await isLikelyPlayable(candidateURL, headers: headers) else {
        continue
      }

      let asset = AVURLAsset(url: candidateURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      let isProtected = (try? await asset.load(.hasProtectedContent)) ?? false
      if isProtected {
        continue
      }

      do {
        if candidateURL.absoluteString.lowercased().contains(".m3u8") {
          let localURL = try await HLSDownloadManager.shared.download(
            assetURL: candidateURL, headers: headers)
          return .ready(PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true))
        }

        let localURL = try await VideoCacheService.shared.downloadMP4(
          from: candidateURL, headers: headers)
        return .ready(PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true))
      } catch {
        // Fallback to direct playback with captured headers if local caching fails.
        return .ready(
          PlayableMedia(playbackURL: candidateURL, headers: headers, isLocalFile: false))
      }
    }

    return nil
  }

  private func isTikTokURL(_ url: URL) -> Bool {
    SocialURLHeuristics.isTikTokHost(url)
  }

  private func matchesSourceIdentity(_ candidateURL: URL, sourceURL: URL) -> Bool {
    if let expectedID = SocialURLHeuristics.tikTokVideoID(from: sourceURL) {
      if let candidateID = SocialURLHeuristics.tikTokVideoID(fromCandidateURL: candidateURL),
        expectedID != candidateID
      {
        return false
      }
    }

    if let expectedID = SocialURLHeuristics.instagramPostID(from: sourceURL),
      let candidateID = SocialURLHeuristics.instagramPostID(fromCandidateURL: candidateURL),
      expectedID != candidateID
    {
      return false
    }

    if let expectedID = SocialURLHeuristics.facebookVideoID(from: sourceURL),
      let candidateID = SocialURLHeuristics.facebookVideoID(fromCandidateURL: candidateURL),
      expectedID != candidateID
    {
      return false
    }

    if SocialURLHeuristics.isTwitterStatusURL(sourceURL) {
      let host = candidateURL.host?.lowercased() ?? ""
      let isTwitterMediaHost =
        host == "twimg.com"
        || host.hasSuffix(".twimg.com")
        || SocialURLHeuristics.isTwitterHost(candidateURL)
      if !isTwitterMediaHost {
        return false
      }
    }

    return true
  }

  private func loadTikTokAPIPlayURLs(from sourceURL: URL) async -> [URL] {
    guard let awemeID = SocialURLHeuristics.tikTokVideoID(from: sourceURL),
      var components = URLComponents(string: Self.tikTokFeedEndpoint)
    else {
      return []
    }

    components.queryItems = [URLQueryItem(name: "aweme_id", value: awemeID)]
    guard let endpoint = components.url else { return [] }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "OPTIONS"
    request.setValue(Self.tikTokAPIUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        !data.isEmpty
      else { return [] }

      let payload = try JSONDecoder().decode(TikTokFeedPayload.self, from: data)
      guard let item = payload.awemeList.first(where: { $0.awemeID == awemeID }) else {
        return []
      }

      var rawURLs: [String] = []
      rawURLs.append(contentsOf: item.video.playAddr.urlList)
      rawURLs.append(contentsOf: item.video.downloadAddr?.urlList ?? [])
      for bitRate in item.video.bitRates ?? [] {
        rawURLs.append(contentsOf: bitRate.playAddr.urlList)
      }

      var seen = Set<String>()
      return rawURLs.compactMap { raw in
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else { return nil }
        return URL(string: normalized)
      }
    } catch {
      return []
    }
  }

  @MainActor
  private func sniffMediaURLs(from sourceURL: URL, userAgent: String) async -> (
    urls: [URL], cookies: [HTTPCookie]
  ) {
    let collector = MediaCandidateCollector(
      sourceURL: sourceURL,
      userAgent: userAgent,
      injectionScript: Self.injectionScript
    )
    return await collector.collect()
  }

  private func rankCandidates(_ urls: [URL], sourceURL: URL) -> [URL] {
    urls
      .map { (url: $0, score: score(for: $0, sourceURL: sourceURL)) }
      .filter { $0.score > -30 }
      .sorted { lhs, rhs in
        if lhs.score == rhs.score {
          return lhs.url.absoluteString.count < rhs.url.absoluteString.count
        }
        return lhs.score > rhs.score
      }
      .map(\.url)
  }

  private func score(for url: URL, sourceURL: URL) -> Int {
    let value = url.absoluteString.lowercased()

    var score = 0

    if value.contains(".m3u8") { score += 35 }
    if value.contains(".mp4") { score += 28 }
    if value.contains("/video/tos/") { score += 34 }
    if value.contains("/aweme/v1/play/") { score += 30 }
    if value.contains("mime_type=video_mp4") { score += 16 }
    if value.contains("video.xx.fbcdn.net") { score += 30 }
    if value.contains("fbcdn.net/v/t42.1790-2") { score += 24 }
    if value.contains("fbcdn.net/v/t39.25447-2") { score += 24 }
    if value.contains("cdninstagram.com/v/t50.2886-16") { score += 28 }
    if value.contains("cdninstagram.com/v/t66.30100-16") { score += 28 }
    if value.contains("video.twimg.com") { score += 34 }
    if value.contains("/ext_tw_video/") { score += 24 }
    if value.contains("/amplify_video/") { score += 24 }
    if value.contains("/tweet_video/") { score += 20 }
    if value.contains("video") { score += 14 }
    if value.contains("play") { score += 10 }
    if value.contains("download") { score += 8 }
    if value.contains("ply_type=2") { score += 10 }
    if value.contains("br=") || value.contains("bt=") { score += 6 }
    if value.contains("tiktokcdn") || value.contains("byteoversea") || value.contains("akamaized") {
      score += 14
    }

    if url.host == sourceURL.host { score += 4 }

    if let expectedTikTokID = SocialURLHeuristics.tikTokVideoID(from: sourceURL) {
      if value.contains(expectedTikTokID) {
        score += 95
      }

      if let candidateTikTokID = SocialURLHeuristics.tikTokVideoID(fromCandidateURL: url) {
        score += candidateTikTokID == expectedTikTokID ? 125 : -125
      }

      if let host = url.host?.lowercased(),
        !(host.contains("tiktok") || host.contains("byte") || host.contains("akamaized"))
      {
        score -= 28
      }
    }

    if let expectedInstagramID = SocialURLHeuristics.instagramPostID(from: sourceURL) {
      if value.contains(expectedInstagramID) {
        score += 40
      }

      if let candidateInstagramID = SocialURLHeuristics.instagramPostID(fromCandidateURL: url) {
        score += candidateInstagramID == expectedInstagramID ? 80 : -120
      }

      if let host = url.host?.lowercased(),
        !(host.contains("instagram") || host.contains("cdninstagram") || host.contains("fbcdn"))
      {
        score -= 24
      }
    }

    if let expectedFacebookID = SocialURLHeuristics.facebookVideoID(from: sourceURL) {
      if value.contains(expectedFacebookID) {
        score += 35
      }

      if let candidateFacebookID = SocialURLHeuristics.facebookVideoID(fromCandidateURL: url) {
        score += candidateFacebookID == expectedFacebookID ? 80 : -120
      }

      if let host = url.host?.lowercased(),
        !(host.contains("facebook") || host.contains("fbcdn") || host.contains("fbsbx"))
      {
        score -= 20
      }
    }

    let negativeTokens = [
      "logo", "watermark", "avatar", "icon", "poster", "thumb", "sprite", "preview", "init",
      "audio",
      "mute", "sticker", "ads", "track",
    ]

    if negativeTokens.contains(where: value.contains) {
      score -= 45
    }
    if value.contains("cdninstagram.com/v/t51.82787-15") || value.contains("fbcdn.net/h") {
      score -= 50
    }

    return score
  }

  private func isLikelyPlayable(_ candidateURL: URL, headers: [String: String]) async -> Bool {
    guard !isKnownBadCandidate(candidateURL) else {
      return false
    }

    let asset = AVURLAsset(url: candidateURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

    let playable = (try? await asset.load(.isPlayable)) ?? false
    guard playable else { return false }

    if let duration = try? await asset.load(.duration) {
      let seconds = CMTimeGetSeconds(duration)
      if seconds.isFinite, seconds > 0, seconds < 6 {
        return false
      }
    }

    if let tracks = try? await asset.load(.tracks),
      let videoTrack = tracks.first(where: { $0.mediaType == .video }),
      let size = try? await videoTrack.load(.naturalSize)
    {
      let width = abs(size.width)
      let height = abs(size.height)
      if width > 0, height > 0, min(width, height) < 220 {
        return false
      }
    }

    return true
  }

  private func isKnownBadCandidate(_ url: URL) -> Bool {
    let value = url.absoluteString.lowercased()
    let blocked = ["logo", "watermark", "preview", "thumb", "poster", "sprite", "init", "avatar"]
    return blocked.contains(where: value.contains)
  }

  private func buildHeaders(
    for mediaURL: URL,
    sourcePageURL: URL,
    cookies: [HTTPCookie],
    userAgent: String
  ) -> [String: String] {
    var headers: [String: String] = [
      "User-Agent": userAgent,
      "Accept": "*/*",
    ]

    headers["Referer"] = sourcePageURL.absoluteString
    if let scheme = sourcePageURL.scheme, let host = sourcePageURL.host {
      headers["Origin"] = "\(scheme)://\(host)"
    }

    guard let mediaHost = mediaURL.host?.lowercased() else {
      return headers
    }

    let cookieHeader =
      cookies
      .filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
          .lowercased()
        return mediaHost == domain || mediaHost.hasSuffix("." + domain)
      }
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")

    if !cookieHeader.isEmpty {
      headers["Cookie"] = cookieHeader
    }

    return headers
  }

  fileprivate static func isLikelyMediaURLString(_ lower: String) -> Bool {
    lower.contains(".m3u8")
      || lower.contains(".mp4")
      || lower.contains("mime_type=video_mp4")
      || lower.contains("/aweme/v1/play/")
      || lower.contains("/video/tos/")
      || lower.contains("playaddr")
      || lower.contains("play_addr")
      || lower.contains("video.xx.fbcdn.net")
      || lower.contains("fbcdn.net/v/t42.1790-2")
      || lower.contains("fbcdn.net/v/t39.25447-2")
      || lower.contains("cdninstagram.com/v/t50.2886-16")
      || lower.contains("cdninstagram.com/v/t66.30100-16")
      || lower.contains("video.twimg.com")
      || lower.contains("/ext_tw_video/")
      || lower.contains("/amplify_video/")
      || lower.contains("/tweet_video/")
  }

  private func mergeCandidates(primary: [URL], secondary: [URL]) -> [URL] {
    var seen = Set<String>()
    return (primary + secondary).filter { url in
      seen.insert(url.absoluteString.lowercased()).inserted
    }
  }

  private func scrapeMediaURLsFromPage(sourceURL: URL, userAgent: String) async -> [URL] {
    var request = URLRequest(url: sourceURL)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("*/*", forHTTPHeaderField: "Accept")

    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      guard var html = String(data: data, encoding: .utf8) else { return [] }

      html =
        html
        .replacingOccurrences(of: "\\u002F", with: "/")
        .replacingOccurrences(of: "\\u0026", with: "&")
        .replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "\\", with: "")

      let regex = try NSRegularExpression(pattern: #"https://[^"'\s<]+"#)
      let nsRange = NSRange(html.startIndex..., in: html)
      let matches = regex.matches(in: html, range: nsRange)

      var urls: [URL] = []
      var seen = Set<String>()

      for match in matches {
        guard let range = Range(match.range, in: html) else { continue }
        let candidate = String(html[range]).trimmingCharacters(
          in: CharacterSet(charactersIn: ")]},"))
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

  private static let desktopUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
  private static let mobileUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  private static let tikTokAPIUserAgent =
    "com.zhiliaoapp.musically/300904 (2018111632; U; Android 10; en_US; Pixel 4; Build/QQ3A.200805.001; Cronet/58.0.2991.0)"
  private static let tikTokFeedEndpoint = "https://api16-normal-useast5.tiktokv.us/aweme/v1/feed/"

  private static let injectionScript = """
    (function() {
      const candidatePattern = /(\\.m3u8|\\.mp4|mime_type=video_mp4|\\/aweme\\/v1\\/play\\/|\\/video\\/tos\\/|playaddr|play_addr|video\\.xx\\.fbcdn\\.net|fbcdn\\.net\\/v\\/t42\\.1790-2|fbcdn\\.net\\/v\\/t39\\.25447-2|cdninstagram\\.com\\/v\\/t50\\.2886-16|cdninstagram\\.com\\/v\\/t66\\.30100-16|video\\.twimg\\.com|\\/ext_tw_video\\/|\\/amplify_video\\/|\\/tweet_video\\/)/i;

      const send = (u) => {
        if (!u || typeof u !== 'string') return;
        if (candidatePattern.test(u)) {
          window.webkit.messageHandlers.linkstrVideo.postMessage(u);
        }
      };

      const scanTextForURLs = (text) => {
        if (!text || typeof text !== 'string') return;
        const matches = text.match(/https:\\/\\/[^\"'\\s<]+/g);
        if (!matches) return;
        matches.forEach((raw) => {
          const normalized = raw
            .replace(/\\\\u002F/g, '/')
            .replace(/\\\\u0026/g, '&')
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

private struct TikTokFeedPayload: Decodable {
  let awemeList: [TikTokFeedItem]

  enum CodingKeys: String, CodingKey {
    case awemeList = "aweme_list"
  }
}

private struct TikTokFeedItem: Decodable {
  let awemeID: String
  let video: TikTokFeedVideo

  enum CodingKeys: String, CodingKey {
    case awemeID = "aweme_id"
    case video
  }
}

private struct TikTokFeedVideo: Decodable {
  let playAddr: TikTokFeedAddress
  let downloadAddr: TikTokFeedAddress?
  let bitRates: [TikTokFeedBitRate]?

  enum CodingKeys: String, CodingKey {
    case playAddr = "play_addr"
    case downloadAddr = "download_addr"
    case bitRates = "bit_rate"
  }
}

private struct TikTokFeedBitRate: Decodable {
  let playAddr: TikTokFeedAddress

  enum CodingKeys: String, CodingKey {
    case playAddr = "play_addr"
  }
}

private struct TikTokFeedAddress: Decodable {
  let urlList: [String]

  enum CodingKeys: String, CodingKey {
    case urlList = "url_list"
  }
}

@MainActor
private final class MediaCandidateCollector: NSObject, WKNavigationDelegate, WKScriptMessageHandler
{
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
        try? await Task.sleep(for: .seconds(12))
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

    contentController?.removeScriptMessageHandler(forName: "linkstrVideo")
    contentController = nil

    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView = nil
  }

  private func registerCandidate(_ url: URL) {
    let lower = url.absoluteString.lowercased()
    guard SocialVideoExtractionService.isLikelyMediaURLString(lower) else { return }

    if candidateSet.insert(lower).inserted {
      candidateOrder.append(url)
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

actor URLCanonicalizationService {
  static let shared = URLCanonicalizationService()

  private let requestTimeout: TimeInterval = 6
  private var cache: [String: URL] = [:]

  func canonicalPlaybackURL(for sourceURL: URL) async -> URL {
    let cacheKey = sourceURL.absoluteString
    if let cached = cache[cacheKey] {
      return cached
    }

    let resolved = await resolveUncached(sourceURL)
    let isFacebookShare = SocialURLHeuristics.isFacebookShareURL(sourceURL)
    if !isFacebookShare || resolved != sourceURL {
      cache[cacheKey] = resolved
    }
    return resolved
  }

  private func resolveUncached(_ sourceURL: URL) async -> URL {
    guard SocialURLHeuristics.isFacebookShareURL(sourceURL) else {
      return sourceURL
    }

    if let redirectedURL = await firstRedirectTarget(from: sourceURL),
      let canonical = canonicalFacebookURL(from: redirectedURL)
    {
      return canonical
    }

    if let canonicalFromPage = await canonicalFacebookURLFromPage(sourceURL) {
      return canonicalFromPage
    }

    if let fallback = fallbackCanonicalFacebookURL(from: sourceURL) {
      return fallback
    }

    return sourceURL
  }

  private func firstRedirectTarget(from sourceURL: URL) async -> URL? {
    var request = URLRequest(url: sourceURL)
    request.httpMethod = "GET"
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        + " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.timeoutInterval = requestTimeout
    return await FirstRedirectResolver.resolve(request: request, timeout: requestTimeout)
  }

  private func canonicalFacebookURLFromPage(_ sourceURL: URL) async -> URL? {
    var request = URLRequest(url: sourceURL)
    request.httpMethod = "GET"
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        + " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    request.timeoutInterval = requestTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200..<400).contains(httpResponse.statusCode)
      {
        return nil
      }

      if let responseURL = response.url,
        let canonicalFromResponseURL = canonicalFacebookURL(from: responseURL)
      {
        return canonicalFromResponseURL
      }

      guard !data.isEmpty else { return nil }
      let html =
        String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
      guard let html else { return nil }

      guard let candidateURL = Self.facebookCanonicalCandidateURL(fromHTML: html) else {
        return nil
      }

      return canonicalFacebookURL(from: candidateURL)
    } catch {
      return nil
    }
  }

  private func canonicalFacebookURL(from candidateURL: URL) -> URL? {
    if let loginNextURL = facebookLoginNextURL(from: candidateURL) {
      return canonicalFacebookURL(from: loginNextURL)
    }

    let parts = candidateURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
      .filter { !$0.isEmpty }

    if let reelIndex = parts.firstIndex(of: "reel"), reelIndex + 1 < parts.count {
      let id = parts[reelIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty else { return nil }
      return URL(string: "https://www.facebook.com/reel/\(id)/")
    }

    if parts.first == "watch",
      let v = URLComponents(url: candidateURL, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name.lowercased() == "v" })?.value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !v.isEmpty
    {
      var components = URLComponents(string: "https://www.facebook.com/watch/")
      components?.queryItems = [URLQueryItem(name: "v", value: v)]
      return components?.url
    }

    if let videosIndex = parts.firstIndex(of: "videos"), videosIndex + 1 < parts.count {
      let id = parts[videosIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty else { return nil }
      return URL(string: "https://www.facebook.com/watch/?v=\(id)")
    }

    return nil
  }

  static func facebookCanonicalCandidateURL(fromHTML html: String) -> URL? {
    let patterns = [
      #"<meta[^>]+property=['"]og:url['"][^>]+content=['"]([^'"]+)['"][^>]*>"#,
      #"<meta[^>]+content=['"]([^'"]+)['"][^>]+property=['"]og:url['"][^>]*>"#,
      #"<link[^>]+rel=['"]canonical['"][^>]+href=['"]([^'"]+)['"][^>]*>"#,
      #"<link[^>]+href=['"]([^'"]+)['"][^>]+rel=['"]canonical['"][^>]*>"#,
    ]

    for pattern in patterns {
      guard let raw = firstCapturedGroup(in: html, pattern: pattern) else { continue }
      let normalized = normalizedEmbeddedURL(raw)
      if let url = URL(string: normalized) {
        return url
      }
    }

    return nil
  }

  private static func firstCapturedGroup(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  private static func normalizedEmbeddedURL(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "\\/", with: "/")
  }

  private func facebookLoginNextURL(from url: URL) -> URL? {
    guard SocialURLHeuristics.isFacebookHost(url) else { return nil }

    let parts = url.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
      .filter { !$0.isEmpty }
    guard parts.first == "login" else { return nil }

    guard
      let rawNext = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name.lowercased() == "next" })?.value
    else {
      return nil
    }

    if let nextURL = URL(string: rawNext) {
      return nextURL
    }
    if let decoded = rawNext.removingPercentEncoding {
      return URL(string: decoded)
    }
    return nil
  }

  private func fallbackCanonicalFacebookURL(from sourceURL: URL) -> URL? {
    let parts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }

    guard parts.count >= 3, parts[0].lowercased() == "share" else {
      return nil
    }

    let marker = parts[1].lowercased()
    let token = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return nil }

    switch marker {
    case "r", "reel":
      return URL(string: "https://www.facebook.com/reel/\(token)/")
    case "v":
      if !token.allSatisfy(\.isNumber) {
        return URL(string: "https://www.facebook.com/reel/\(token)/")
      }
      var components = URLComponents(string: "https://www.facebook.com/watch/")
      components?.queryItems = [URLQueryItem(name: "v", value: token)]
      return components?.url
    default:
      return nil
    }
  }
}

private final class FirstRedirectResolver: NSObject, URLSessionTaskDelegate {
  private var continuation: CheckedContinuation<URL?, Never>?
  private var hasFinished = false
  private var session: URLSession?

  static func resolve(request: URLRequest, timeout: TimeInterval) async -> URL? {
    let resolver = FirstRedirectResolver()
    return await resolver.start(request: request, timeout: timeout)
  }

  private func start(request: URLRequest, timeout: TimeInterval) async -> URL? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation

      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = timeout
      configuration.timeoutIntervalForResource = timeout

      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session

      let task = session.dataTask(with: request)
      task.resume()
    }
  }

  private func finish(with url: URL?) {
    guard !hasFinished else { return }
    hasFinished = true
    continuation?.resume(returning: url)
    continuation = nil
    session?.invalidateAndCancel()
    session = nil
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    finish(with: request.url)
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    finish(with: nil)
  }
}
