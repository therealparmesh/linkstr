import Foundation

extension SocialVideoExtractionService {
  func extractFromFacebook(
    sourceURL: URL,
    budget: MediaDiscoveryBudget
  ) async -> ExtractionState? {
    guard SocialURLHeuristics.isFacebookHost(sourceURL),
      SocialURLHeuristics.isFacebookReelURL(sourceURL)
        || SocialURLHeuristics.isFacebookVideoURL(sourceURL)
    else {
      return nil
    }
    guard budget.permitsAttempt else { return nil }
    let ogVideoCandidates = await facebookPageVideoURLs(from: sourceURL)
    let ranked = rankCandidates(ogVideoCandidates, sourceURL: sourceURL)
    if let resolved = resolvePlayableMedia(
      from: ranked,
      sourceURL: sourceURL,
      userAgent: Self.mobileUserAgent,
      cookies: []
    ) {
      return resolved
    }

    if budget.permitsAttempt,
      SocialURLHeuristics.facebookVideoID(from: sourceURL) != nil {
      let fallbackResult = await extractViaGenericSniff(
        sourceURL: sourceURL,
        budget: budget
      )
      if case .ready = fallbackResult {
        return fallbackResult
      }
    }
    return .cannotExtract("could not find a usable video stream for this post.")
  }

  func facebookIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    mediaIdentityScore(
      expectedID: SocialURLHeuristics.facebookVideoID(from: sourceURL),
      candidateID: SocialURLHeuristics.facebookVideoID(fromCandidateURL: url),
      value: value,
      host: host,
      allowedHostTokens: ["facebook", "fbcdn", "fbsbx"]
    )
  }

  /// Extracts direct CDN video URLs from post-scoped Open Graph metadata.
  private func facebookPageVideoURLs(from sourceURL: URL) async -> [URL] {
    var pageURLs = [sourceURL]
    if let videoID = SocialURLHeuristics.facebookVideoID(from: sourceURL),
      let mobileReelURL = URL(string: "https://m.facebook.com/reel/\(videoID)/"),
      mobileReelURL != sourceURL {
      pageURLs.append(mobileReelURL)
    }

    for pageURL in pageURLs {
      guard let page = await SocialMediaPageLoader.load(
        pageURL, userAgent: Self.mobileUserAgent),
        let html = page.html
      else {
        continue
      }
      let videoURLs = Self.extractFacebookPageVideoURLs(
        fromHTML: html,
        pageURL: page.finalURL,
        sourceURL: sourceURL
      )
      if !videoURLs.isEmpty {
        return videoURLs
      }
    }
    return []
  }

  static func extractFacebookPageVideoURLs(
    fromHTML html: String,
    pageURL: URL,
    sourceURL: URL
  ) -> [URL] {
    let expectedID = SocialURLHeuristics.facebookVideoID(from: sourceURL)
    let canonicalPageID = URLCanonicalizationService.facebookCanonicalCandidateURL(fromHTML: html)
      .flatMap { SocialURLHeuristics.facebookVideoID(from: $0) }
    let pageID = canonicalPageID ?? SocialURLHeuristics.facebookVideoID(from: pageURL)
    guard let pageID, expectedID == nil || pageID == expectedID else {
      return []
    }
    return Self.extractOGVideoURLs(fromHTML: html)
  }
}

private struct RumbleOEmbedPayload: Decodable {
  let html: String
}

actor URLCanonicalizationService {
  static let shared = URLCanonicalizationService()

  private var cache: [String: URL] = [:]
  private var rumbleEmbedURLCache: [String: URL] = [:]

  func canonicalPlaybackURL(for sourceURL: URL) async -> URL {
    let cacheKey = sourceURL.absoluteString
    if let cached = cache[cacheKey] {
      return cached
    }

    let resolved = await resolveUncached(sourceURL)
    let skipCacheOnIdentity =
      Self.requiresFacebookPageResolution(sourceURL)
      || SocialURLHeuristics.isTikTokShortURL(sourceURL)
    if !skipCacheOnIdentity || resolved != sourceURL {
      cache[cacheKey] = resolved
    }
    return resolved
  }

  func preferredRumbleEmbedURL(for sourceURL: URL) async -> URL? {
    let cacheKey = sourceURL.absoluteString
    if let cached = rumbleEmbedURLCache[cacheKey] {
      return cached
    }

    let resolved = await rumbleEmbedURL(from: sourceURL)
    if let resolved {
      rumbleEmbedURLCache[cacheKey] = resolved
    }
    return resolved
  }

  func invalidate(for sourceURL: URL) {
    let cacheKey = sourceURL.absoluteString
    cache.removeValue(forKey: cacheKey)
    rumbleEmbedURLCache.removeValue(forKey: cacheKey)
  }

  private func resolveUncached(_ sourceURL: URL) async -> URL {
    if let instagramCanonicalURL = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL) {
      return instagramCanonicalURL
    }

    if SocialURLHeuristics.isTikTokShortURL(sourceURL),
      let tikTokCanonicalURL = await resolvedTikTokVideoPageURL(from: sourceURL) {
      return tikTokCanonicalURL
    }

    guard SocialURLHeuristics.isFacebookHost(sourceURL) else {
      return sourceURL
    }

    if URLClassifier.isDedicatedEmbedURL(sourceURL) {
      return sourceURL
    }

    guard Self.requiresFacebookPageResolution(sourceURL) else {
      return Self.canonicalFacebookURL(from: sourceURL) ?? sourceURL
    }

    if let canonical = await resolvedFacebookURL(from: sourceURL) {
      return canonical
    }

    if let fallback = fallbackCanonicalFacebookURL(from: sourceURL) {
      return fallback
    }

    let parts = SocialURLHeuristics.normalizedPathComponents(for: sourceURL)
    if parts.first == "watch" {
      return Self.canonicalFacebookURL(from: sourceURL) ?? sourceURL
    }

    return sourceURL
  }

  private static func requiresFacebookPageResolution(_ sourceURL: URL) -> Bool {
    guard SocialURLHeuristics.isFacebookHost(sourceURL),
      !URLClassifier.isDedicatedEmbedURL(sourceURL)
    else {
      return false
    }

    let parts = SocialURLHeuristics.normalizedPathComponents(for: sourceURL)
    if parts.first == "reel" || parts.first == "reels" {
      return false
    }

    return SocialURLHeuristics.isFacebookShareURL(sourceURL)
      || SocialURLHeuristics.hostMatches(sourceURL, domain: "fb.watch")
      || SocialURLHeuristics.isFacebookVideoURL(sourceURL)
  }

  private func resolvedTikTokVideoPageURL(from sourceURL: URL) async -> URL? {
    guard
      let page = await SocialMediaPageLoader.load(
        sourceURL,
        userAgent: SocialVideoExtractionService.mobileUserAgent
      )
    else { return nil }
    return Self.canonicalTikTokVideoURL(from: page.finalURL)
  }

  static func canonicalTikTokVideoURL(from resolvedURL: URL) -> URL? {
    guard SocialURLHeuristics.isTikTokHost(resolvedURL),
      SocialURLHeuristics.tikTokVideoID(from: resolvedURL) != nil,
      var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)
    else {
      return nil
    }

    components.scheme = "https"
    components.host = "www.tiktok.com"
    components.port = nil
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private func resolvedFacebookURL(from sourceURL: URL) async -> URL? {
    guard
      let page = await SocialMediaPageLoader.load(
        sourceURL,
        userAgent: SocialVideoExtractionService.mobileUserAgent
      )
    else { return nil }

    return Self.canonicalFacebookURL(pageFinalURL: page.finalURL, html: page.html)
  }

  static func canonicalFacebookURL(pageFinalURL: URL, html: String?) -> URL? {
    if let html,
      let candidateURL = facebookCanonicalCandidateURL(fromHTML: html),
      let canonicalURL = canonicalFacebookURL(from: candidateURL) {
      return canonicalURL
    }
    return canonicalFacebookURL(from: pageFinalURL)
  }

  private static func canonicalFacebookURL(from candidateURL: URL, depth: Int = 3) -> URL? {
    guard SocialURLHeuristics.isFacebookHost(candidateURL) else { return nil }

    if depth > 0, let loginNextURL = facebookLoginNextURL(from: candidateURL) {
      return canonicalFacebookURL(from: loginNextURL, depth: depth - 1)
    }

    guard let videoID = SocialURLHeuristics.facebookVideoID(from: candidateURL) else {
      return nil
    }
    if SocialURLHeuristics.isFacebookReelURL(candidateURL) {
      return URL(string: "https://www.facebook.com/reel/\(videoID)/")
    }

    var components = URLComponents(string: "https://www.facebook.com/watch/")
    components?.queryItems = [URLQueryItem(name: "v", value: videoID)]
    return components?.url
  }

  static func facebookCanonicalCandidateURL(fromHTML html: String) -> URL? {
    let metaCandidates = HTMLTagAttributeScanner.attributes(inTagsNamed: "meta", html: html)
      .compactMap { attributes -> String? in
        guard let property = attributes["property"]?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          property.caseInsensitiveCompare("og:url") == .orderedSame
        else {
          return nil
        }
        return attributes["content"]
      }

    let linkCandidates = HTMLTagAttributeScanner.attributes(inTagsNamed: "link", html: html)
      .compactMap { attributes -> String? in
        guard let rel = attributes["rel"] else { return nil }
        let relTokens = rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard relTokens.contains("canonical") else { return nil }
        return attributes["href"]
      }

    for raw in metaCandidates + linkCandidates {
      let normalized = normalizedEmbeddedURL(raw)
      if let url = URL(string: normalized) {
        return url
      }
    }

    return nil
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
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode)
      else {
        return nil
      }

      let payload = try JSONDecoder().decode(RumbleOEmbedPayload.self, from: data)
      guard
        let rawEmbedURL = HTMLTagAttributeScanner.attributes(
          inTagsNamed: "iframe",
          html: payload.html
        ).compactMap({ $0["src"] }).first
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
}
