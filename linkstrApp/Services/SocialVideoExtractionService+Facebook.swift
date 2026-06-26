import Foundation

extension SocialVideoExtractionService {
  func extractFromFacebook(sourceURL: URL) async -> ExtractionState? {
    guard SocialURLHeuristics.isFacebookHost(sourceURL),
      SocialURLHeuristics.isFacebookReelURL(sourceURL)
        || SocialURLHeuristics.isFacebookVideoURL(sourceURL)
    else {
      return nil
    }
    let ogVideoCandidates = await facebookOGVideoURLs(from: sourceURL)
    let ranked = rankCandidates(ogVideoCandidates, sourceURL: sourceURL)
    return resolvePlayableMedia(
      from: ranked,
      sourceURL: sourceURL,
      userAgent: Self.mobileUserAgent,
      cookies: []
    )
  }

  func facebookIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    guard let expectedID = SocialURLHeuristics.facebookVideoID(from: sourceURL) else { return 0 }
    var score = 0
    if value.contains(expectedID) { score += 50 }
    if let candidateID = SocialURLHeuristics.facebookVideoID(fromCandidateURL: url) {
      score += candidateID == expectedID ? 100 : -100
    }
    if !(host.contains("facebook") || host.contains("fbcdn") || host.contains("fbsbx")) {
      score -= 25
    }
    return score
  }

  /// Extracts direct CDN video URLs from `og:video` meta tags.
  /// Some providers embed the playable `.mp4` URL in server-rendered HTML when
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
        !(200..<400).contains(httpResponse.statusCode) {
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
}

private struct RumbleOEmbedPayload: Decodable {
  let html: String
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
    if let instagramCanonicalURL = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL) {
      return instagramCanonicalURL
    }

    let isFacebookShare = SocialURLHeuristics.isFacebookShareURL(sourceURL)
    let isFbWatch = sourceURL.host?.lowercased().hasSuffix("fb.watch") == true
    guard isFacebookShare || isFbWatch else {
      return sourceURL
    }

    if let redirectedURL = await firstRedirectTarget(from: sourceURL),
      let canonical = canonicalFacebookURL(from: redirectedURL) {
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
        !(200..<400).contains(httpResponse.statusCode) {
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
      let videoId = URLComponents(url: candidateURL, resolvingAgainstBaseURL: false)?.queryItems?
        .first(
          where: { $0.name.lowercased() == "v" })?.value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !videoId.isEmpty {
      var components = URLComponents(string: "https://www.facebook.com/watch/")
      components?.queryItems = [URLQueryItem(name: "v", value: videoId)]
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
      #"<link[^>]+href=['"]([^'"]+)['"][^>]+rel=['"]canonical['"][^>]*>"#
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
