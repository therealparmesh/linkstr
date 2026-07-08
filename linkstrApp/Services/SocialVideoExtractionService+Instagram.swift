import Foundation

extension SocialVideoExtractionService {
  func extractFromInstagram(sourceURL: URL) async -> ExtractionState? {
    guard SocialURLHeuristics.isInstagramHost(sourceURL),
      SocialURLHeuristics.isInstagramReelURL(sourceURL)
        || SocialURLHeuristics.isInstagramVideoPostURL(sourceURL),
      let canonicalSourceURL = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL)
    else {
      return nil
    }

    if let pageSummary = await instagramPageMediaSummary(from: canonicalSourceURL) {
      let ranked = rankCandidates(pageSummary.videoURLs, sourceURL: canonicalSourceURL)
      if let resolved = resolvePlayableMedia(
        from: ranked,
        sourceURL: canonicalSourceURL,
        userAgent: Self.desktopUserAgent,
        cookies: []
      ) {
        return resolved
      }

      if pageSummary.mediaKind == .nonVideo {
        return .cannotExtract("this Instagram post does not include a playable video.")
      }
    }

    let lightweightProbeURL = Self.instagramLightweightPlaybackURL(for: canonicalSourceURL)
    for probeURL in Self.instagramPlaybackProbeURLs(
      sourceURL: sourceURL,
      canonicalURL: canonicalSourceURL
    ) {
      let attempts = probeURL == lightweightProbeURL ? 2 : 1
      for attempt in 0..<attempts {
        let state = await extractViaGenericSniff(sourceURL: probeURL)
        if case .ready = state {
          return state
        }
        if attempt + 1 < attempts {
          try? await Task.sleep(for: .milliseconds(300))
        }
      }
    }

    return .cannotExtract("could not find a usable video stream for this post.")
  }

  static func instagramPlaybackProbeURLs(sourceURL: URL, canonicalURL: URL) -> [URL] {
    var urls: [URL] = []
    var seen = Set<String>()

    appendUnique(Self.instagramLightweightPlaybackURL(for: canonicalURL), to: &urls, seen: &seen)
    appendUnique(sourceURL, to: &urls, seen: &seen)
    appendUnique(canonicalURL, to: &urls, seen: &seen)
    appendUnique(canonicalURL.appendingPathComponent("embed"), to: &urls, seen: &seen)

    return urls
  }

  private static func instagramLightweightPlaybackURL(for canonicalURL: URL) -> URL? {
    guard var components = URLComponents(url: canonicalURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    // Some Instagram share-token pages hide video resources that this public page still exposes.
    components.queryItems = [URLQueryItem(name: "l", value: "1")]
    return components.url
  }

  private static func appendUnique(_ url: URL?, to urls: inout [URL], seen: inout Set<String>) {
    guard let url else { return }
    let key = url.absoluteString.lowercased()
    guard seen.insert(key).inserted else { return }
    urls.append(url)
  }

  func instagramIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    guard let expectedID = SocialURLHeuristics.instagramPostID(from: sourceURL) else { return 0 }
    var score = 0
    if value.contains(expectedID) { score += 50 }
    if let candidateID = SocialURLHeuristics.instagramPostID(fromCandidateURL: url) {
      score += candidateID == expectedID ? 100 : -100
    }
    if !(host.contains("instagram") || host.contains("cdninstagram") || host.contains("fbcdn")) {
      score -= 25
    }
    return score
  }

  // MARK: - Instagram embed page

  private func instagramPageMediaSummary(from canonicalURL: URL) async -> (
    videoURLs: [URL], mediaKind: SocialPostHTMLParser.InstagramMediaKind
  )? {
    var request = URLRequest(url: canonicalURL)
    request.httpMethod = "GET"
    request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
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

      guard
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
      else { return nil }

      return (
        videoURLs: Self.extractOGVideoURLs(fromHTML: html),
        mediaKind: SocialPostHTMLParser.instagramMediaKind(from: html)
      )
    } catch {
      return nil
    }
  }

  // MARK: - Open Graph video extraction

  /// Parses `og:video`, `og:video:url`, and `og:video:secure_url` meta tags,
  /// decodes HTML entities in the extracted URL, and returns all valid URLs.
  static func extractOGVideoURLs(fromHTML html: String) -> [URL] {
    let videoProperties = Set(["og:video", "og:video:url", "og:video:secure_url"])
    var seen = Set<String>()
    var urls: [URL] = []

    for attributes in HTMLTagAttributeScanner.attributes(inTagsNamed: "meta", html: html) {
      guard let property = attributes["property"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
        videoProperties.contains(property),
        let raw = attributes["content"]
      else { continue }

      let decoded = HTMLTextDecoder.decodeHTMLEntities(raw)
      let lower = decoded.lowercased()

      guard isLikelyMediaURLString(lower),
        seen.insert(lower).inserted,
        let url = URL(string: decoded)
      else { continue }

      urls.append(url)
    }

    return urls
  }
}
