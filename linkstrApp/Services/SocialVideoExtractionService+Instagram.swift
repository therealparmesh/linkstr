import Foundation

extension SocialVideoExtractionService {
  func extractFromInstagram(sourceURL: URL) async -> ExtractionState? {
    guard SocialURLHeuristics.isInstagramHost(sourceURL),
      let embedPageURL = instagramEmbedPageURL(from: sourceURL)
    else {
      return nil
    }

    if let pageSummary = await instagramPageMediaSummary(from: sourceURL) {
      let ranked = rankCandidates(pageSummary.videoURLs, sourceURL: sourceURL)
      if let resolved = resolvePlayableMedia(
        from: ranked,
        sourceURL: sourceURL,
        userAgent: Self.desktopUserAgent,
        cookies: []
      ) {
        return resolved
      }

      if pageSummary.mediaKind == .nonVideo {
        return .cannotExtract("this Instagram post does not include a playable video.")
      }
    }

    let sniffResult = await sniffMediaURLs(
      from: embedPageURL, userAgent: Self.desktopUserAgent)
    let ranked = rankCandidates(sniffResult.urls, sourceURL: sourceURL)
    return resolvePlayableMedia(
      from: ranked,
      sourceURL: sourceURL,
      userAgent: Self.desktopUserAgent,
      cookies: sniffResult.cookies
    )
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

  private func instagramEmbedPageURL(from sourceURL: URL) -> URL? {
    guard
      SocialURLHeuristics.isInstagramReelURL(sourceURL)
        || SocialURLHeuristics.isInstagramVideoPostURL(sourceURL),
      let canonical = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL)
    else { return nil }

    return canonical.appendingPathComponent("embed")
  }

  private func instagramPageMediaSummary(from sourceURL: URL) async -> (
    videoURLs: [URL], mediaKind: SocialPostHTMLParser.InstagramMediaKind
  )? {
    guard let canonicalURL = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL)
    else { return nil }

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
    let patterns = [
      #"<meta[^>]+property=['"]og:video(?::secure_url|:url)?['"][^>]+content=['"]([^'"]+)['"][^>]*>"#,
      #"<meta[^>]+content=['"]([^'"]+)['"][^>]+property=['"]og:video(?::secure_url|:url)?['"][^>]*>"#
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
        let decoded = HTMLTextDecoder.decodeHTMLEntities(raw)
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
}
