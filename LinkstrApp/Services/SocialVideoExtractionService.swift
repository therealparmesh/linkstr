import Foundation
import WebKit

struct PlayableMedia {
  let playbackURL: URL
  let headers: [String: String]
  let isLocalFile: Bool
}

enum ExtractionState {
  case ready([PlayableMedia])
  case cannotExtract(String)
}

private enum SocialVideoTimingDefaults {
  static let mediaCandidateCollectionTimeout: TimeInterval = 12
  static let apiRequestTimeout: TimeInterval = 8
  static let lightweightFetchTimeout: TimeInterval = 6
  static let earlyFinishDebounce: TimeInterval = 1.5
}

private enum TwitterEmbedTimingDefaults {
  static let readyTransitionDurationSeconds: TimeInterval = 0.18
  static let postRenderRefreshDelaysMilliseconds = [40, 120, 260, 520, 1000, 1800]
  static let bootstrapRefreshDelaysMilliseconds = [80, 220, 480, 900, 1600]
  static let fallbackDelayMilliseconds = 3_200

  static func javascriptArray(for values: [Int]) -> String {
    "[\(values.map(String.init).joined(separator: ", "))]"
  }
}

final class SocialVideoExtractionService: NSObject {
  static let shared = SocialVideoExtractionService()

  private override init() {
    super.init()
  }

  func extractPlayableMedia(from sourceURL: URL) async -> ExtractionState {
    if SocialURLHeuristics.isTikTokHost(sourceURL) {
      if SocialURLHeuristics.tikTokVideoID(from: sourceURL) != nil {
        let directTikTokCandidates = await loadTikTokAPIPlayURLs(from: sourceURL)
        if let resolved = resolvePlayableMedia(
          from: directTikTokCandidates,
          sourceURL: sourceURL,
          userAgent: Self.tikTokAPIUserAgent,
          cookies: []
        ) {
          return resolved
        }
      }
    }

    if SocialURLHeuristics.isInstagramHost(sourceURL),
      let embedPageURL = instagramEmbedPageURL(from: sourceURL)
    {
      let sniffResult = await sniffMediaURLs(
        from: embedPageURL, userAgent: Self.desktopUserAgent)
      let ranked = rankCandidates(sniffResult.urls, sourceURL: sourceURL)
      if let resolved = resolvePlayableMedia(
        from: ranked,
        sourceURL: sourceURL,
        userAgent: Self.desktopUserAgent,
        cookies: sniffResult.cookies
      ) {
        return resolved
      }
    }

    if SocialURLHeuristics.isFacebookHost(sourceURL),
      SocialURLHeuristics.isFacebookReelURL(sourceURL)
        || SocialURLHeuristics.isFacebookVideoURL(sourceURL)
    {
      let ogVideoCandidates = await facebookOGVideoURLs(from: sourceURL)
      let ranked = rankCandidates(ogVideoCandidates, sourceURL: sourceURL)
      if let resolved = resolvePlayableMedia(
        from: ranked,
        sourceURL: sourceURL,
        userAgent: Self.mobileUserAgent,
        cookies: []
      ) {
        return resolved
      }
    }

    if SocialURLHeuristics.isTwitterStatusURL(sourceURL) {
      let summary = await TwitterStatusResolutionService.shared.mediaSummary(for: sourceURL)
      if summary.hasVideo == false {
        return .cannotExtract("this post does not include a playable video.")
      }

      if let resolved = resolvePlayableMedia(
        from: summary.candidateURLs,
        sourceURL: sourceURL,
        userAgent: Self.mobileUserAgent,
        cookies: []
      ) {
        return resolved
      }
    }

    for userAgent in [Self.mobileUserAgent, Self.desktopUserAgent] {
      // Try a lightweight HTML scrape first — it resolves in ~1-2s for
      // providers that embed CDN media URLs in server-rendered HTML
      // (e.g. Facebook).  Only fall back to the heavier headless-
      // WebView sniff (up to 12s) when the scrape finds nothing usable.
      // Retry the scrape once in case the provider returns a login wall
      // or empty page on the first attempt.
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

      // Scrape didn't yield a playable candidate — try the WebView sniff.
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

  func cachePlayableMediaLocally(_ media: PlayableMedia) async -> PlayableMedia? {
    guard !media.isLocalFile else {
      return media
    }
    guard media.playbackURL.scheme?.lowercased() == "https" else {
      return nil
    }

    do {
      if media.playbackURL.absoluteString.lowercased().contains(".m3u8") {
        let localURL = try await HLSDownloadManager.shared.download(
          assetURL: media.playbackURL,
          headers: media.headers
        )
        return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
      }

      let localURL = try await VideoCacheService.shared.downloadMP4(
        from: media.playbackURL,
        headers: media.headers
      )
      return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
    } catch {
      return nil
    }
  }

  private func resolvePlayableMedia(
    from candidates: [URL],
    sourceURL: URL,
    userAgent: String,
    cookies: [HTTPCookie]
  ) -> ExtractionState? {
    // Filter to HTTPS candidates that aren't known-bad assets (logos,
    // watermarks, etc.) and pass identity matching.  All checks are
    // cheap and synchronous so we never consume short-lived CDN tokens
    // before the player gets to use them.
    let viable = candidates.filter { url in
      guard url.scheme?.lowercased() == "https" else { return false }
      guard !isKnownBadCandidate(url) else { return false }
      return matchesSourceIdentity(url, sourceURL: sourceURL)
    }
    guard !viable.isEmpty else { return nil }

    let mediaList = viable.map { url in
      let headers = buildHeaders(
        for: url, sourcePageURL: sourceURL, cookies: cookies, userAgent: userAgent)
      return PlayableMedia(playbackURL: url, headers: headers, isLocalFile: false)
    }
    return .ready(mediaList)
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

  // MARK: - Instagram embed page

  private func instagramEmbedPageURL(from sourceURL: URL) -> URL? {
    guard
      SocialURLHeuristics.isInstagramReelURL(sourceURL)
        || SocialURLHeuristics.isInstagramVideoPostURL(sourceURL),
      let canonical = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL)
    else { return nil }

    return canonical.appendingPathComponent("embed")
  }

  // MARK: - Facebook og:video extraction

  /// Extracts direct CDN video URLs from Facebook's `og:video` meta tags.
  /// Facebook embeds the playable `.mp4` URL in server-rendered HTML when
  /// fetched with a mobile user-agent, making this faster and more reliable
  /// than the generic scraper or headless WebView sniff.
  private func facebookOGVideoURLs(from sourceURL: URL) async -> [URL] {
    var request = URLRequest(url: sourceURL)
    request.httpMethod = "GET"
    request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    request.timeoutInterval = SocialVideoTimingDefaults.lightweightFetchTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200..<400).contains(httpResponse.statusCode)
      {
        return []
      }

      guard
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
      else { return [] }

      return Self.extractOGVideoURLs(fromHTML: html)
    } catch {
      return []
    }
  }

  /// Parses `og:video`, `og:video:url`, and `og:video:secure_url` meta tags,
  /// decodes HTML entities in the extracted URL, and returns all valid URLs.
  private static func extractOGVideoURLs(fromHTML html: String) -> [URL] {
    let patterns = [
      #"<meta[^>]+property=['"]og:video(?::secure_url|:url)?['"][^>]+content=['"]([^'"]+)['"][^>]*>"#,
      #"<meta[^>]+content=['"]([^'"]+)['"][^>]+property=['"]og:video(?::secure_url|:url)?['"][^>]*>"#,
    ]

    var seen = Set<String>()
    var urls: [URL] = []

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }

      let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
      let matches = regex.matches(in: html, range: nsRange)

      for match in matches {
        guard match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: html)
        else { continue }

        let raw = String(html[captureRange])
        let decoded = decodeHTMLEntities(raw)
        let lower = decoded.lowercased()

        guard isLikelyMediaURLString(lower),
          seen.insert(lower).inserted,
          let url = URL(string: decoded)
        else { continue }

        urls.append(url)
      }
    }

    return urls
  }

  private static func decodeHTMLEntities(_ text: String) -> String {
    var result =
      text
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
    result = replaceNumericHTMLEntities(result)
    return result
  }

  private static func replaceNumericHTMLEntities(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);|&#(\d+);"#) else {
      return text
    }
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var result = text
    for match in regex.matches(in: text, range: fullRange).reversed() {
      guard let matchRange = Range(match.range, in: result) else { continue }
      let scalar: UInt32?
      if let hexRange = Range(match.range(at: 1), in: result) {
        scalar = UInt32(result[hexRange], radix: 16)
      } else if let decRange = Range(match.range(at: 2), in: result) {
        scalar = UInt32(result[decRange], radix: 10)
      } else {
        scalar = nil
      }
      guard let scalar, let unicode = Unicode.Scalar(scalar) else { continue }
      result.replaceSubrange(matchRange, with: String(unicode))
    }
    return result
  }

  // MARK: - TikTok feed API

  private func loadTikTokAPIPlayURLs(from sourceURL: URL) async -> [URL] {
    guard let awemeID = SocialURLHeuristics.tikTokVideoID(from: sourceURL) else {
      return []
    }

    // Try endpoints sequentially — concurrent requests to TikTok's API
    // servers get rate-limited or blocked.
    for feedEndpoint in Self.tikTokFeedEndpoints {
      let urls = await loadTikTokFeedURLs(endpoint: feedEndpoint, awemeID: awemeID)
      if !urls.isEmpty {
        return urls
      }
    }
    return []
  }

  private func loadTikTokFeedURLs(endpoint feedEndpoint: String, awemeID: String) async -> [URL] {
    guard var components = URLComponents(string: feedEndpoint) else { return [] }
    components.queryItems = [URLQueryItem(name: "aweme_id", value: awemeID)]
    guard let endpoint = components.url else { return [] }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "OPTIONS"
    request.setValue(Self.tikTokAPIUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = SocialVideoTimingDefaults.apiRequestTimeout

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
        guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else {
          return nil
        }
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
    let host = url.host?.lowercased() ?? ""

    var score = 0

    // Format signals
    if value.contains(".m3u8") { score += 35 }
    if value.contains(".mp4") { score += 30 }
    if value.contains("mime_type=video_mp4") { score += 15 }

    // Semantic path signals
    if value.contains("video") { score += 15 }
    if value.contains("play") { score += 10 }
    if value.contains("download") { score += 8 }

    // Provider video CDN host (+25)
    if host.contains("video") && host.contains("fbcdn") { score += 25 }
    if Self.isLikelyInstagramSignedVideoURLString(value) { score += 30 }
    if host.contains("cdninstagram") && value.contains(".mp4") { score += 25 }
    if host.contains("fbcdn") && value.contains(".mp4") { score += 20 }
    if host.hasSuffix("twimg.com") && host.contains("video") { score += 25 }

    // TikTok CDN host/path (+25/+15)
    if value.contains("/aweme/v1/play/") { score += 25 }
    if value.contains("/video/tos/") { score += 25 }
    if host.contains("tiktokcdn") || host.contains("byteoversea") || host.contains("akamaized") {
      score += 15
    }

    // Same host as source page
    if host == sourceURL.host?.lowercased() { score += 5 }

    // Post ID found in URL (+50) / exact ID match (+100, mismatch -100)
    if let expectedTikTokID = SocialURLHeuristics.tikTokVideoID(from: sourceURL) {
      if value.contains(expectedTikTokID) { score += 50 }
      if let candidateID = SocialURLHeuristics.tikTokVideoID(fromCandidateURL: url) {
        score += candidateID == expectedTikTokID ? 100 : -100
      }
      if !(host.contains("tiktok") || host.contains("byte") || host.contains("akamaized")) {
        score -= 25
      }
    }

    if let expectedInstagramID = SocialURLHeuristics.instagramPostID(from: sourceURL) {
      if value.contains(expectedInstagramID) { score += 50 }
      if let candidateID = SocialURLHeuristics.instagramPostID(fromCandidateURL: url) {
        score += candidateID == expectedInstagramID ? 100 : -100
      }
      if !(host.contains("instagram") || host.contains("cdninstagram") || host.contains("fbcdn")) {
        score -= 25
      }
    }

    if let expectedFacebookID = SocialURLHeuristics.facebookVideoID(from: sourceURL) {
      if value.contains(expectedFacebookID) { score += 50 }
      if let candidateID = SocialURLHeuristics.facebookVideoID(fromCandidateURL: url) {
        score += candidateID == expectedFacebookID ? 100 : -100
      }
      if !(host.contains("facebook") || host.contains("fbcdn") || host.contains("fbsbx")) {
        score -= 25
      }
    }

    // Negative signals
    if Self.blockedPlaybackCandidateTokens.contains(where: value.contains) {
      score -= 40
    }
    if host.contains("cdninstagram")
      && !value.contains(".mp4")
      && !value.contains(".m3u8")
      && !Self.isLikelyInstagramSignedVideoURLString(value)
    {
      score -= 40
    }

    return score
  }

  private func isKnownBadCandidate(_ url: URL) -> Bool {
    let value = url.absoluteString.lowercased()
    return Self.blockedVisualAssetTokens.contains(where: value.contains)
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

  static func isLikelyMediaURLString(_ lower: String) -> Bool {
    // Generic video markers
    lower.contains(".m3u8")
      || lower.contains(".mp4")
      || lower.contains("mime_type=video_mp4")
      // TikTok
      || lower.contains("/aweme/v1/play/")
      || lower.contains("/video/tos/")
      || lower.contains("playaddr")
      || lower.contains("play_addr")
      // Facebook / Instagram CDN (host-level, not path-version-specific)
      || lower.contains("video.xx.fbcdn.net")
      || lower.contains("scontent.cdninstagram.com")
      || (lower.contains("cdninstagram.com") && lower.contains(".mp4"))
      || (lower.contains("fbcdn.net") && lower.contains("/video"))
      || isLikelyInstagramSignedVideoURLString(lower)
      // Twitter / X
      || lower.contains("video.twimg.com")
  }

  private static func isLikelyInstagramSignedVideoURLString(_ lower: String) -> Bool {
    guard lower.contains("cdninstagram.com") || lower.contains("fbcdn.net") else { return false }
    // Instagram CDN video URLs are often signed and omit a literal `.mp4`.
    // Match the broader signed video delivery shape instead of a single path
    // family number so minor CDN renames do not break extraction immediately.
    guard lower.contains("/o1/v/") else { return false }
    return !hasStaticImageExtension(lower)
  }

  private static func hasStaticImageExtension(_ lower: String) -> Bool {
    [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".heif"].contains {
      lower.contains($0)
    }
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
        // Decode HTML entities that survive in meta-tag or inline-JSON contexts
        candidate = Self.decodeHTMLEntities(candidate)
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
  private static let tikTokFeedEndpoints = [
    "https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/feed/",
    "https://api16-normal-useast5.tiktokv.us/aweme/v1/feed/",
    "https://api19-normal-c-useast1a.tiktokv.com/aweme/v1/feed/",
    "https://api16-core-c-useast1a.tiktokv.com/aweme/v1/feed/",
    "https://api21-normal-c-useast2a.tiktokv.com/aweme/v1/feed/",
  ]
  /// Decode JSON-escaped text so that embedded URLs become plain `https://…`
  /// strings the regex scraper can extract.  Handles all `\uXXXX` unicode
  /// escapes (not just `\u002F` / `\u0026`), JSON-escaped forward slashes
  /// (`\/`), and stray lone backslashes — in that order so no sequence is
  /// partially consumed by a later step.
  private static func unescapeJSONStringLiterals(_ text: String) -> String {
    // 1. Decode all \uXXXX sequences (covers \u002F, \u0026, \u0025, etc.)
    let unicodeEscapePattern = try! NSRegularExpression(pattern: #"\\u([0-9A-Fa-f]{4})"#)
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var result = text
    // Process from last match to first so ranges stay valid.
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

    // 2. JSON-escaped forward slash
    result = result.replacingOccurrences(of: "\\/", with: "/")

    // 3. Remove remaining lone backslashes (JSON string escape char)
    result = result.replacingOccurrences(of: "\\", with: "")

    return result
  }

  private static let blockedVisualAssetTokens = [
    "logo", "watermark", "avatar", "icon", "poster", "thumb", "sprite", "preview", "init",
  ]
  private static let blockedPlaybackCandidateTokens =
    blockedVisualAssetTokens + ["audio", "mute", "sticker", "ads", "track"]

  private static let injectionScript = """
    (function() {
      const candidatePattern = /(\\.m3u8|\\.mp4|mime_type=video_mp4|\\/aweme\\/v1\\/play\\/|\\/video\\/tos\\/|playaddr|play_addr|video\\.xx\\.fbcdn\\.net|cdninstagram\\.com.*\\.mp4|fbcdn\\.net.*\\/video|(?:cdninstagram\\.com|fbcdn\\.net).*\\/o1\\/v\\/|video\\.twimg\\.com)/i;

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

private struct RumbleOEmbedPayload: Decodable {
  let html: String
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
    "video.xx.fbcdn.net", "cdninstagram.com", "video.twimg.com",
  ]

  private var earlyFinishTask: Task<Void, Never>?

  private func registerCandidate(_ url: URL) {
    let lower = url.absoluteString.lowercased()
    guard SocialVideoExtractionService.isLikelyMediaURLString(lower) else { return }

    if candidateSet.insert(lower).inserted {
      candidateOrder.append(url)

      // When a high-confidence video candidate arrives, schedule a short
      // debounce window to collect any companions (e.g. multiple quality
      // variants that arrive together) then finish early instead of
      // waiting the full collection timeout.
      if earlyFinishTask == nil,
        Self.highConfidencePatterns.contains(where: lower.contains)
      {
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

struct TwitterStatusMediaSummary: Equatable {
  let candidateURLs: [URL]
  let hasVideo: Bool
  let preview: TwitterStatusPreview?

  static let empty = TwitterStatusMediaSummary(candidateURLs: [], hasVideo: false, preview: nil)
}

struct TwitterStatusPreview: Equatable {
  let title: String?
  let bodyText: String?
  let imageURL: URL?
}

struct TwitterStatusResolvedPresentation: Equatable {
  let strategy: URLClassifier.MediaStrategy
  let embedHTMLDocument: String?
}

actor TwitterStatusResolutionService {
  static let shared = TwitterStatusResolutionService()

  private let userAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
    + " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  private var mediaSummaryCache: [String: TwitterStatusMediaSummary] = [:]
  private var presentationCache: [String: TwitterStatusResolvedPresentation] = [:]

  func mediaSummary(for sourceURL: URL) async -> TwitterStatusMediaSummary {
    guard let cacheKey = cacheKey(for: sourceURL) else {
      return .empty
    }
    if let cached = mediaSummaryCache[cacheKey] {
      return cached
    }

    let summary = await fetchMediaSummary(for: sourceURL)
    if summary.hasVideo || !summary.candidateURLs.isEmpty || summary.preview != nil {
      mediaSummaryCache[cacheKey] = summary
    }
    return summary
  }

  func preview(for sourceURL: URL) async -> TwitterStatusPreview? {
    let summary = await mediaSummary(for: sourceURL)
    return summary.preview
  }

  func invalidate(for sourceURL: URL) {
    guard let cacheKey = cacheKey(for: sourceURL) else { return }
    mediaSummaryCache.removeValue(forKey: cacheKey)
    presentationCache.removeValue(forKey: cacheKey)
  }

  func resolvedPresentation(for sourceURL: URL) async -> TwitterStatusResolvedPresentation? {
    guard let statusID = SocialURLHeuristics.twitterStatusID(from: sourceURL) else {
      return nil
    }

    let cacheKey = statusID
    if let cached = presentationCache[cacheKey] {
      return cached
    }

    async let summaryTask = mediaSummary(for: sourceURL)
    async let embedAvailabilityTask = officialEmbedAvailable(for: sourceURL)

    let summary = await summaryTask
    let embedHTMLDocument =
      await embedAvailabilityTask
      ? TwitterEmbedDocumentBuilder.documentHTML(tweetID: statusID) : nil

    let fallbackEmbedURL =
      SocialURLHeuristics.twitterCanonicalStatusURL(from: sourceURL)
      ?? URLClassifier.twitterEmbedFallbackURL(for: sourceURL)
      ?? sourceURL

    let strategy: URLClassifier.MediaStrategy
    if summary.hasVideo {
      strategy = .extractionPreferred(embedURL: fallbackEmbedURL)
    } else if embedHTMLDocument != nil {
      strategy = .embedOnly(embedURL: fallbackEmbedURL)
    } else {
      strategy = .link
    }

    let resolved = TwitterStatusResolvedPresentation(
      strategy: strategy,
      embedHTMLDocument: embedHTMLDocument
    )
    if strategy != .link || embedHTMLDocument != nil {
      presentationCache[cacheKey] = resolved
    }
    return resolved
  }

  private func cacheKey(for sourceURL: URL) -> String? {
    SocialURLHeuristics.twitterStatusID(from: sourceURL)
  }

  private func fetchMediaSummary(for sourceURL: URL) async -> TwitterStatusMediaSummary {
    guard let statusID = SocialURLHeuristics.twitterStatusID(from: sourceURL) else {
      return .empty
    }

    let endpoints = [
      "https://api.vxtwitter.com/Twitter/status/\(statusID)",
      "https://api.fxtwitter.com/status/\(statusID)",
      "https://cdn.syndication.twimg.com/tweet-result?id=\(statusID)&token=0",
    ]

    var fallbackSummary: TwitterStatusMediaSummary?
    for rawEndpoint in endpoints {
      guard let endpoint = URL(string: rawEndpoint) else { continue }
      if let summary = await fetchMediaSummary(from: endpoint) {
        if summary.hasVideo || !summary.candidateURLs.isEmpty {
          return summary
        }
        if fallbackSummary == nil || (fallbackSummary?.preview == nil && summary.preview != nil) {
          fallbackSummary = summary
        }
      }
    }

    return fallbackSummary ?? .empty
  }

  private func fetchMediaSummary(from endpoint: URL) async -> TwitterStatusMediaSummary? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = SocialVideoTimingDefaults.apiRequestTimeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        !data.isEmpty,
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        return nil
      }

      return TwitterStatusResponseParser.mediaSummary(from: json)
    } catch {
      return nil
    }
  }

  private func officialEmbedAvailable(for sourceURL: URL) async -> Bool {
    guard let statusURL = SocialURLHeuristics.twitterCanonicalStatusURL(from: sourceURL),
      var components = URLComponents(string: "https://publish.twitter.com/oembed")
    else {
      return false
    }

    components.queryItems = [
      URLQueryItem(name: "url", value: statusURL.absoluteString),
      URLQueryItem(name: "omit_script", value: "false"),
      URLQueryItem(name: "dnt", value: "true"),
      URLQueryItem(name: "theme", value: "dark"),
      URLQueryItem(name: "align", value: "center"),
    ]
    guard let endpoint = components.url else { return false }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = SocialVideoTimingDefaults.apiRequestTimeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        !data.isEmpty,
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let html = json["html"] as? String
      else {
        return false
      }

      let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmedHTML.isEmpty
    } catch {
      return false
    }
  }
}

enum TwitterEmbedDocumentBuilder {
  static func documentHTML(tweetID: String) -> String {
    let postRenderRefreshDelays = TwitterEmbedTimingDefaults.javascriptArray(
      for: TwitterEmbedTimingDefaults.postRenderRefreshDelaysMilliseconds
    )
    let bootstrapRefreshDelays = TwitterEmbedTimingDefaults.javascriptArray(
      for: TwitterEmbedTimingDefaults.bootstrapRefreshDelaysMilliseconds
    )
    return """
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
          </style>
        </head>
        <body>
          <div id="tweet-container"></div>
          <script>
            (() => {
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
                  '<div class="linkstr-embed-fallback">couldn\\'t load this post preview. use open in browser.</div>';
                markReady();
              };

              const refresh = () => {
                sizeRenderedTweet();
                postMetrics(false);
                if (hasRenderedTweet()) {
                  markReady();
                }
              };

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
                childList: true,
                attributes: true
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
            })();
          </script>
        </body>
      </html>
      """
  }
}

enum TwitterStatusResponseParser {
  static func mediaSummary(from json: [String: Any]) -> TwitterStatusMediaSummary {
    let mediaContainer = ((json["tweet"] as? [String: Any])?["media"] as? [String: Any]) ?? [:]
    let mediaEntries = mediaEntries(from: mediaContainer, fallbackJSON: json)

    var hasVideo = false
    var candidateURLs: [URL] = []
    var seen = Set<String>()

    for entry in mediaEntries {
      let type = (entry["type"] as? String)?.lowercased() ?? ""
      let isVideoLike =
        type == "video"
        || type == "animated_gif"
        || type == "gif"
      guard isVideoLike else { continue }
      hasVideo = true

      collectMediaURL(entry["url"], into: &candidateURLs, seen: &seen)

      if let formats = entry["formats"] as? [[String: Any]] {
        for format in formats {
          collectMediaURL(format["url"], into: &candidateURLs, seen: &seen)
        }
      }

      if let variants = entry["variants"] as? [[String: Any]] {
        for variant in variants {
          collectMediaURL(variant["url"], into: &candidateURLs, seen: &seen)
        }
      }

      if let videoInfo = entry["video_info"] as? [String: Any],
        let variants = videoInfo["variants"] as? [[String: Any]]
      {
        for variant in variants {
          collectMediaURL(variant["url"], into: &candidateURLs, seen: &seen)
        }
      }
    }

    return TwitterStatusMediaSummary(
      candidateURLs: candidateURLs,
      hasVideo: hasVideo,
      preview: preview(from: json)
    )
  }

  private static func mediaEntries(
    from container: [String: Any],
    fallbackJSON: [String: Any]
  ) -> [[String: Any]] {
    let keys = ["videos", "all", "media", "items", "photos"]
    for key in keys {
      if let entries = container[key] as? [[String: Any]], !entries.isEmpty {
        return entries
      }
    }

    if let entry = container["video"] as? [String: Any] {
      return [entry]
    }

    if let entries = fallbackJSON["media_extended"] as? [[String: Any]], !entries.isEmpty {
      return entries
    }

    if let entries = fallbackJSON["mediaDetails"] as? [[String: Any]], !entries.isEmpty {
      return entries
    }

    return []
  }

  private static func preview(from json: [String: Any]) -> TwitterStatusPreview? {
    let title = previewTitle(from: json)
    let bodyText = previewBodyText(from: json)
    let imageURL = previewImageURL(from: json)
    guard title != nil || bodyText != nil || imageURL != nil else { return nil }
    return TwitterStatusPreview(title: title, bodyText: bodyText, imageURL: imageURL)
  }

  private static func previewTitle(from json: [String: Any]) -> String? {
    if let tweet = json["tweet"] as? [String: Any],
      let author = tweet["author"] as? [String: Any]
    {
      return formattedPreviewTitle(
        name: author["name"] as? String,
        screenName: author["screen_name"] as? String
      )
    }

    if let user = json["user"] as? [String: Any] {
      return formattedPreviewTitle(
        name: user["name"] as? String,
        screenName: user["screen_name"] as? String
      )
    }

    return formattedPreviewTitle(
      name: json["user_name"] as? String,
      screenName: json["user_screen_name"] as? String
    )
  }

  private static func formattedPreviewTitle(name: String?, screenName: String?) -> String? {
    let trimmedName = normalizedText(name)
    let trimmedScreenName = normalizedText(screenName)

    switch (trimmedName, trimmedScreenName) {
    case (let name?, let screenName?):
      return "\(name) (@\(screenName))"
    case (let name?, nil):
      return name
    case (nil, let screenName?):
      return "@\(screenName)"
    case (nil, nil):
      return nil
    }
  }

  private static func previewImageURL(from json: [String: Any]) -> URL? {
    if let tweet = json["tweet"] as? [String: Any],
      let media = tweet["media"] as? [String: Any]
    {
      let preferredKeys = ["photos", "all", "videos", "media", "items"]
      for key in preferredKeys {
        if let entries = media[key] as? [[String: Any]],
          let url = firstPreviewURL(in: entries)
        {
          return url
        }
      }
    }

    if let entries = json["media_extended"] as? [[String: Any]],
      let url = firstPreviewURL(in: entries)
    {
      return url
    }

    if let rawURLs = json["mediaURLs"] as? [String] {
      for rawURL in rawURLs {
        if let url = validatedPreviewURL(from: rawURL) {
          return url
        }
      }
    }

    return nil
  }

  private static func previewBodyText(from json: [String: Any]) -> String? {
    if let tweet = json["tweet"] as? [String: Any] {
      for key in ["text", "full_text", "content"] {
        if let value = normalizedText(tweet[key] as? String) {
          return value
        }
      }
    }

    for key in ["text", "full_text", "tweetText"] {
      if let value = normalizedText(json[key] as? String) {
        return value
      }
    }

    return nil
  }

  private static func firstPreviewURL(in entries: [[String: Any]]) -> URL? {
    for entry in entries {
      let type = (entry["type"] as? String)?.lowercased()
      if type == "photo" || type == "image" {
        if let url = validatedPreviewURL(from: entry["url"] as? String) {
          return url
        }
        if let url = validatedPreviewURL(from: entry["thumbnail_url"] as? String) {
          return url
        }
      }
    }

    for entry in entries {
      if let url = validatedPreviewURL(from: entry["thumbnail_url"] as? String) {
        return url
      }
      if let url = validatedPreviewURL(from: entry["url"] as? String) {
        return url
      }
    }

    return nil
  }

  private static func collectMediaURL(
    _ rawValue: Any?,
    into urls: inout [URL],
    seen: inout Set<String>
  ) {
    guard let raw = rawValue as? String else { return }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = normalized.lowercased()
    guard lower.hasPrefix("https://"), SocialVideoExtractionService.isLikelyMediaURLString(lower),
      let url = URL(string: normalized),
      seen.insert(lower).inserted
    else {
      return
    }
    urls.append(url)
  }

  private static func validatedPreviewURL(from rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.lowercased().hasPrefix("https://") else { return nil }
    return URL(string: normalized)
  }

  private static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - Social Post Preview

struct SocialPostPreview: Equatable {
  let bodyText: String?
  let authorName: String?
  let imageURL: URL?
}

actor SocialPostResolutionService {
  static let shared = SocialPostResolutionService()

  private let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15"
    + " (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

  private var cache: [String: SocialPostPreview] = [:]

  func preview(for sourceURL: URL) async -> SocialPostPreview? {
    let linkType = URLClassifier.classify(sourceURL)
    guard let cacheKey = cacheKey(for: sourceURL, linkType: linkType) else { return nil }

    if let cached = cache[cacheKey] {
      return cached
    }

    let resolved: SocialPostPreview?
    switch linkType {
    case .instagram:
      resolved = await fetchInstagramPreview(for: sourceURL)
    case .tiktok:
      resolved = await fetchTikTokPreview(for: sourceURL)
    case .facebook:
      resolved = await fetchFacebookPreview(for: sourceURL)
    default:
      return nil
    }

    if let resolved, resolved.bodyText != nil || resolved.authorName != nil {
      cache[cacheKey] = resolved
    }
    return resolved
  }

  func invalidate(for sourceURL: URL) {
    let linkType = URLClassifier.classify(sourceURL)
    guard let cacheKey = cacheKey(for: sourceURL, linkType: linkType) else { return }
    cache.removeValue(forKey: cacheKey)
  }

  private func cacheKey(for sourceURL: URL, linkType: LinkType) -> String? {
    switch linkType {
    case .instagram:
      return SocialURLHeuristics.instagramPostID(from: sourceURL)
    case .tiktok:
      return SocialURLHeuristics.tikTokVideoID(from: sourceURL)
    case .facebook:
      return SocialURLHeuristics.facebookVideoID(from: sourceURL)
    default:
      return nil
    }
  }

  // MARK: - Instagram

  private func fetchInstagramPreview(for sourceURL: URL) async -> SocialPostPreview? {
    guard let canonicalURL = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL)
    else { return nil }

    var request = URLRequest(url: canonicalURL)
    request.httpMethod = "GET"
    request.timeoutInterval = SocialVideoTimingDefaults.apiRequestTimeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        let html = String(data: data, encoding: .utf8)
      else { return nil }

      return SocialPostHTMLParser.instagramPreview(from: html)
    } catch {
      return nil
    }
  }

  // MARK: - Facebook

  private func fetchFacebookPreview(for sourceURL: URL) async -> SocialPostPreview? {
    var request = URLRequest(url: sourceURL)
    request.httpMethod = "GET"
    request.timeoutInterval = SocialVideoTimingDefaults.apiRequestTimeout
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        + " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<400).contains(httpResponse.statusCode),
        let html = String(data: data, encoding: .utf8)
          ?? String(data: data, encoding: .isoLatin1)
      else { return nil }

      return SocialPostHTMLParser.facebookPreview(from: html)
    } catch {
      return nil
    }
  }

  // MARK: - TikTok

  private func fetchTikTokPreview(for sourceURL: URL) async -> SocialPostPreview? {
    guard let videoID = SocialURLHeuristics.tikTokVideoID(from: sourceURL) else { return nil }

    let canonicalURLString =
      "https://www.tiktok.com/@_/video/\(videoID)"
    guard var components = URLComponents(string: "https://www.tiktok.com/oembed") else {
      return nil
    }
    components.queryItems = [URLQueryItem(name: "url", value: canonicalURLString)]
    guard let endpoint = components.url else { return nil }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = SocialVideoTimingDefaults.apiRequestTimeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        !data.isEmpty,
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }

      return SocialPostHTMLParser.tikTokPreview(from: json)
    } catch {
      return nil
    }
  }

  /// Whether the given URL's link type supports loading remote post text.
  nonisolated static func supportsRemotePostText(for url: URL) -> Bool {
    let linkType = URLClassifier.classify(url)
    switch linkType {
    case .twitter:
      return URLClassifier.mediaStrategy(for: url).allowsLocalPlaybackToggle
    case .instagram, .tiktok, .facebook:
      return true
    case .youtube, .rumble, .generic:
      return false
    }
  }

  /// Resolves the remote post body text for the given URL, if supported.
  static func resolveRemotePostText(for url: URL) async -> String? {
    let linkType = URLClassifier.classify(url)
    switch linkType {
    case .twitter:
      return await TwitterStatusResolutionService.shared.preview(for: url)?.bodyText
    case .instagram, .tiktok, .facebook:
      return await shared.preview(for: url)?.bodyText
    default:
      return nil
    }
  }
}

enum SocialPostHTMLParser {
  static func instagramPreview(from html: String) -> SocialPostPreview? {
    let bodyText = instagramBodyText(from: html)
    let authorName = instagramAuthorName(from: html)
    let imageURL = instagramImageURL(from: html)
    guard bodyText != nil || authorName != nil || imageURL != nil else { return nil }
    return SocialPostPreview(bodyText: bodyText, authorName: authorName, imageURL: imageURL)
  }

  static func tikTokPreview(from json: [String: Any]) -> SocialPostPreview? {
    let title = normalizedText(json["title"] as? String)
    let authorName = normalizedText(json["author_name"] as? String)
    let imageURL: URL?
    if let raw = normalizedText(json["thumbnail_url"] as? String),
      raw.lowercased().hasPrefix("https://")
    {
      imageURL = URL(string: raw)
    } else {
      imageURL = nil
    }
    guard title != nil || authorName != nil || imageURL != nil else { return nil }
    return SocialPostPreview(bodyText: title, authorName: authorName, imageURL: imageURL)
  }

  static func facebookPreview(from html: String) -> SocialPostPreview? {
    let bodyText = facebookBodyText(from: html)
    let authorName = facebookAuthorName(from: html)
    let imageURL = facebookImageURL(from: html)
    guard bodyText != nil || authorName != nil || imageURL != nil else { return nil }
    return SocialPostPreview(bodyText: bodyText, authorName: authorName, imageURL: imageURL)
  }

  // MARK: - Facebook HTML parsing

  private static func facebookBodyText(from html: String) -> String? {
    if let ogDescription = extractMetaContent(from: html, property: "og:description") {
      return normalizedText(ogDescription)
    }
    return nil
  }

  private static func facebookAuthorName(from html: String) -> String? {
    // og:title format: "Caption text | Author Name | Facebook"
    guard let ogTitle = extractMetaContent(from: html, property: "og:title") else { return nil }
    let parts = ogTitle.components(separatedBy: " | ")
    // The author name is typically the second-to-last segment (before "Facebook").
    guard parts.count >= 3 else { return nil }
    let candidate = parts[parts.count - 2]
    return normalizedText(candidate)
  }

  private static func facebookImageURL(from html: String) -> URL? {
    guard let raw = extractMetaContent(from: html, property: "og:image") else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("https://") else { return nil }
    return URL(string: trimmed)
  }

  // MARK: - Instagram HTML parsing

  private static func instagramBodyText(from html: String) -> String? {
    // Try og:description first — it contains the full caption prefixed with engagement stats.
    // Format: "120K likes, 527 comments - username on March 9, 2026: \"caption text\". "
    if let ogDescription = extractMetaContent(from: html, property: "og:description") {
      let cleaned = stripInstagramDescriptionPrefix(ogDescription)
      if let normalized = normalizedText(cleaned) {
        return normalized
      }
    }

    // Fall back to og:title which includes "Author on Instagram: \"caption\""
    if let ogTitle = extractMetaContent(from: html, property: "og:title") {
      let cleaned = stripInstagramTitlePrefix(ogTitle)
      if let normalized = normalizedText(cleaned) {
        return normalized
      }
    }

    return nil
  }

  private static func instagramImageURL(from html: String) -> URL? {
    guard let raw = extractMetaContent(from: html, property: "og:image") else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("https://") else { return nil }
    return URL(string: trimmed)
  }

  private static func instagramAuthorName(from html: String) -> String? {
    // twitter:title format: "Author Name (@handle) • Instagram reel"
    if let twitterTitle = extractMetaContent(from: html, name: "twitter:title") {
      let cleaned =
        twitterTitle
        .replacingOccurrences(of: " • Instagram reel", with: "")
        .replacingOccurrences(of: " • Instagram photo", with: "")
        .replacingOccurrences(of: " • Instagram video", with: "")
        .replacingOccurrences(of: " • Instagram", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram reel", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram photo", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram video", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram", with: "")
      return normalizedText(cleaned)
    }
    return nil
  }

  /// Strips the engagement stats prefix from Instagram og:description.
  /// Input: "120K likes, 527 comments - pg_agi_ on March 9, 2026: \"caption\". "
  /// Output: "caption"
  private static func stripInstagramDescriptionPrefix(_ text: String) -> String {
    // Pattern: "<stats> - <username> on <date>: "<caption>". "
    // The quote-colon pattern marks the start of the caption.
    let quoteColonPatterns = ["\": \"", "\": \u{201c}", ":\u{00a0}\u{201c}", ": \""]
    for pattern in quoteColonPatterns {
      if let range = text.range(of: pattern) {
        var caption = String(text[range.upperBound...])
        // Instagram wraps the caption in quotes and appends ". " at the end.
        // Strip the specific trailing suffix rather than trimming all periods.
        caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["\". ", "\".", "\u{201d}. ", "\u{201d}.", "\"", "\u{201d}"] {
          if caption.hasSuffix(suffix) {
            caption = String(caption.dropLast(suffix.count))
            break
          }
        }
        caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { return caption }
      }
    }
    return text
  }

  /// Strips the "Author on Instagram: " prefix from og:title.
  /// Input: "Playing God with AGI on Instagram: \"caption\""
  /// Output: "caption"
  private static func stripInstagramTitlePrefix(_ text: String) -> String {
    let pattern = " on Instagram: "
    if let range = text.range(of: pattern, options: .caseInsensitive) {
      var caption = String(text[range.upperBound...])
      caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
      // Strip surrounding quotes if present (the og:title wraps the caption in quotes).
      for (open, close) in [("\"", "\""), ("\u{201c}", "\u{201d}")] {
        if caption.hasPrefix(open), caption.hasSuffix(close), caption.count > 2 {
          caption = String(caption.dropFirst(open.count).dropLast(close.count))
          break
        }
      }
      caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
      if !caption.isEmpty { return caption }
    }
    return text
  }

  // MARK: - HTML meta tag extraction

  private static func extractMetaContent(from html: String, property: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: property)
    // Try property-first: <meta property="og:description" ... content="..." />
    let forwardPattern =
      #"<meta\s+property="\#(escaped)"[^>]*?\s+content="([^"]*)"#
    if let result = firstRegexCapture(in: html, pattern: forwardPattern) {
      return decodeHTMLEntities(result)
    }
    // Try content-first: <meta content="..." ... property="og:description" />
    let reversePattern =
      #"<meta\s+content="([^"]*)"[^>]*?\s+property="\#(escaped)""#
    return firstRegexCapture(in: html, pattern: reversePattern)
      .map(decodeHTMLEntities)
  }

  private static func extractMetaContent(from html: String, name: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    // Try name-first: <meta name="twitter:title" ... content="..." />
    let forwardPattern =
      #"<meta\s+name="\#(escaped)"[^>]*?\s+content="([^"]*)"#
    if let result = firstRegexCapture(in: html, pattern: forwardPattern) {
      return decodeHTMLEntities(result)
    }
    // Try content-first: <meta content="..." ... name="twitter:title" />
    let reversePattern =
      #"<meta\s+content="([^"]*)"[^>]*?\s+name="\#(escaped)""#
    return firstRegexCapture(in: html, pattern: reversePattern)
      .map(decodeHTMLEntities)
  }

  private static func firstRegexCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: nsRange),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[captureRange])
  }

  private static func decodeHTMLEntities(_ text: String) -> String {
    var result =
      text
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
    result = replaceNumericHTMLEntities(result)
    return result
  }

  private static func replaceNumericHTMLEntities(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);|&#(\d+);"#) else {
      return text
    }
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var result = text
    for match in regex.matches(in: text, range: fullRange).reversed() {
      guard let matchRange = Range(match.range, in: result) else { continue }
      let scalar: UInt32?
      if let hexRange = Range(match.range(at: 1), in: result) {
        scalar = UInt32(result[hexRange], radix: 16)
      } else if let decRange = Range(match.range(at: 2), in: result) {
        scalar = UInt32(result[decRange], radix: 10)
      } else {
        scalar = nil
      }
      guard let scalar, let unicode = Unicode.Scalar(scalar) else { continue }
      result.replaceSubrange(matchRange, with: String(unicode))
    }
    return result
  }

  private static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

actor URLCanonicalizationService {
  static let shared = URLCanonicalizationService()

  private var cache: [String: URL] = [:]
  private var embedURLCache: [String: URL] = [:]

  func canonicalPlaybackURL(for sourceURL: URL) async -> URL {
    let cacheKey = sourceURL.absoluteString
    if let cached = cache[cacheKey] {
      return cached
    }

    let resolved = await resolveUncached(sourceURL)
    let skipCacheOnIdentity =
      SocialURLHeuristics.isFacebookShareURL(sourceURL)
      || sourceURL.host?.lowercased().hasSuffix("fb.watch") == true
    if !skipCacheOnIdentity || resolved != sourceURL {
      cache[cacheKey] = resolved
    }
    return resolved
  }

  func preferredEmbedURL(for sourceURL: URL) async -> URL? {
    let cacheKey = sourceURL.absoluteString
    if let cached = embedURLCache[cacheKey] {
      return cached
    }

    let resolved: URL?
    switch URLClassifier.classify(sourceURL) {
    case .rumble:
      resolved = await rumbleEmbedURL(from: sourceURL)
    case .tiktok, .instagram, .facebook, .youtube, .twitter, .generic:
      resolved = nil
    }

    if let resolved {
      embedURLCache[cacheKey] = resolved
    }
    return resolved
  }

  func invalidate(for sourceURL: URL) {
    let cacheKey = sourceURL.absoluteString
    cache.removeValue(forKey: cacheKey)
    embedURLCache.removeValue(forKey: cacheKey)
  }

  private func resolveUncached(_ sourceURL: URL) async -> URL {
    let isFacebookShare = SocialURLHeuristics.isFacebookShareURL(sourceURL)
    let isFbWatch = sourceURL.host?.lowercased().hasSuffix("fb.watch") == true
    guard isFacebookShare || isFbWatch else {
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
    request.timeoutInterval = SocialVideoTimingDefaults.lightweightFetchTimeout
    return await FirstRedirectResolver.resolve(
      request: request,
      timeout: SocialVideoTimingDefaults.lightweightFetchTimeout
    )
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
    request.timeoutInterval = SocialVideoTimingDefaults.lightweightFetchTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200..<400).contains(httpResponse.statusCode)
      {
        return nil
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

  private func canonicalFacebookURL(from candidateURL: URL, depth: Int = 3) -> URL? {
    if depth > 0, let loginNextURL = facebookLoginNextURL(from: candidateURL) {
      return canonicalFacebookURL(from: loginNextURL, depth: depth - 1)
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

  private func rumbleEmbedURL(from sourceURL: URL) async -> URL? {
    let parts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
      .filter { !$0.isEmpty }
    if parts.first == "embed" {
      return sourceURL
    }

    var components = URLComponents(string: "https://rumble.com/api/Media/oembed.json")
    components?.queryItems = [URLQueryItem(name: "url", value: sourceURL.absoluteString)]
    guard let requestURL = components?.url else {
      return nil
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = "GET"
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        + " (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = SocialVideoTimingDefaults.lightweightFetchTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode)
      else {
        return nil
      }

      let payload = try JSONDecoder().decode(RumbleOEmbedPayload.self, from: data)
      guard
        let rawEmbedURL = Self.firstCapturedGroup(
          in: payload.html,
          pattern: #"<iframe[^>]*\ssrc=['"]([^'"]+)['"][^>]*>"#
        )
      else {
        return nil
      }

      let normalized = Self.normalizedEmbeddedURL(rawEmbedURL)
      guard let embedURL = URL(string: normalized), SocialURLHeuristics.isRumbleHost(embedURL)
      else {
        return nil
      }

      return embedURL
    } catch {
      return nil
    }
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
