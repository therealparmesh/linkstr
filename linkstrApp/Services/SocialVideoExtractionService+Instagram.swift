import Foundation

private struct InstagramPageMediaSummary {
  let videoURLs: [URL]
  let mediaKind: SocialPostHTMLParser.InstagramMediaKind
  let confirmsNoVideo: Bool
}

extension SocialVideoExtractionService {
  func extractFromInstagram(
    sourceURL: URL,
    budget: MediaDiscoveryBudget
  ) async -> ExtractionState? {
    guard SocialURLHeuristics.isInstagramHost(sourceURL),
      SocialURLHeuristics.isInstagramReelURL(sourceURL)
        || SocialURLHeuristics.isInstagramVideoPostURL(sourceURL),
      let postID = SocialURLHeuristics.instagramPostID(from: sourceURL)
    else {
      return nil
    }

    var sawNonVideoPage = false
    if budget.permitsAttempt {
      let pageSummary = await instagramPageMediaSummary(
        from: sourceURL,
        expectedPostID: postID
      )
      let ranked = rankCandidates(pageSummary.videoURLs, sourceURL: sourceURL)
      if let resolved = resolvePlayableMedia(
        from: ranked,
        sourceURL: sourceURL,
        userAgent: Self.mobileUserAgent,
        cookies: []
      ) {
        return resolved
      }

      if pageSummary.confirmsNoVideo {
        return .cannotExtract("this Instagram post does not include a playable video.")
      }
      sawNonVideoPage = pageSummary.mediaKind == .nonVideo
    }

    if budget.permitsAttempt {
      let state = await extractViaGenericSniff(
        sourceURL: sourceURL,
        budget: budget
      )
      if case .ready = state {
        return state
      }
    }

    if sawNonVideoPage {
      return .cannotExtract("this Instagram post does not include a playable video.")
    }
    return .cannotExtract("could not find a usable video stream for this post.")
  }

  func instagramIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    mediaIdentityScore(
      expectedID: SocialURLHeuristics.instagramPostID(from: sourceURL),
      candidateID: SocialURLHeuristics.instagramPostID(fromCandidateURL: url),
      value: value,
      host: host,
      allowedHostTokens: ["instagram", "cdninstagram", "fbcdn"]
    )
  }

  // MARK: - Instagram page

  private func instagramPageMediaSummary(
    from pageURL: URL,
    expectedPostID: String
  ) async -> InstagramPageMediaSummary {
    var mediaKind = SocialPostHTMLParser.InstagramMediaKind.unknown

    for userAgent in [Self.mobileUserAgent, Self.desktopUserAgent] {
      guard
        let summary = await loadInstagramPageSummary(
          from: pageURL,
          expectedPostID: expectedPostID,
          userAgent: userAgent
        )
      else { continue }
      if summary.mediaKind != .unknown {
        mediaKind = summary.mediaKind
      }
      if !summary.videoURLs.isEmpty {
        return summary
      }
    }

    if let embedSummary = await loadInstagramEmbedSummary(
      from: pageURL,
      expectedPostID: expectedPostID
    ) {
      if !embedSummary.videoURLs.isEmpty || embedSummary.confirmsNoVideo {
        return embedSummary
      }
      if embedSummary.mediaKind != .unknown {
        mediaKind = embedSummary.mediaKind
      }
    }

    return InstagramPageMediaSummary(
      videoURLs: [],
      mediaKind: mediaKind,
      confirmsNoVideo: false
    )
  }

  private func loadInstagramPageSummary(
    from pageURL: URL,
    expectedPostID: String,
    userAgent: String
  ) async -> InstagramPageMediaSummary? {
    guard let page = await SocialMediaPageLoader.load(pageURL, userAgent: userAgent),
      let html = page.html
    else { return nil }

    let matchesExpectedPost =
      SocialURLHeuristics.instagramPostID(from: page.finalURL) == expectedPostID
    let mediaKind = matchesExpectedPost
      ? SocialPostHTMLParser.instagramMediaKind(from: html)
      : .unknown
    var videoURLs = Self.extractInstagramPageVideoURLs(
      fromHTML: html,
      expectedPostID: expectedPostID
    )
    if matchesExpectedPost {
      var seen = Set(videoURLs.map { $0.absoluteString.lowercased() })
      for url in Self.extractOGVideoURLs(fromHTML: html)
      where seen.insert(url.absoluteString.lowercased()).inserted {
        videoURLs.append(url)
      }
    }
    return InstagramPageMediaSummary(
      videoURLs: videoURLs,
      mediaKind: mediaKind,
      confirmsNoVideo: false
    )
  }

  private func loadInstagramEmbedSummary(
    from pageURL: URL,
    expectedPostID: String
  ) async -> InstagramPageMediaSummary? {
    guard
      let embedURL = SocialURLHeuristics.instagramCanonicalURL(for: pageURL)?
        .appendingPathComponent("embed"),
      embedURL != pageURL,
      let page = await SocialMediaPageLoader.load(embedURL, userAgent: Self.mobileUserAgent),
      let html = page.html,
      let summary = Self.extractInstagramEmbedMediaSummary(
        fromHTML: html,
        expectedPostID: expectedPostID
      )
    else { return nil }

    return InstagramPageMediaSummary(
      videoURLs: summary.videoURLs,
      mediaKind: summary.mediaKind,
      confirmsNoVideo: summary.mediaKind == .nonVideo
    )
  }

  static func extractInstagramPageVideoURLs(
    fromHTML html: String,
    expectedPostID: String
  ) -> [URL] {
    var rawURLs: [String] = []

    for script in HTMLScriptContentScanner.contents(in: html) {
      guard let data = script.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
      else {
        continue
      }

      rawURLs.append(contentsOf: instagramVideoURLStrings(in: json, expectedPostID: expectedPostID))
    }
    return normalizedInstagramVideoURLs(from: rawURLs)
  }

  static func extractInstagramEmbedMediaSummary(
    fromHTML html: String,
    expectedPostID: String
  ) -> (
    videoURLs: [URL], mediaKind: SocialPostHTMLParser.InstagramMediaKind
  )? {
    guard
      let regex = try? NSRegularExpression(
        pattern: #""contextJSON"\s*:\s*("(?:\\.|[^"\\])*")"#
      )
    else { return nil }

    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    for match in regex.matches(in: html, range: range) {
      guard match.numberOfRanges > 1,
        let jsonStringRange = Range(match.range(at: 1), in: html),
        let jsonStringData = String(html[jsonStringRange]).data(using: .utf8),
        let context = try? JSONSerialization.jsonObject(
          with: jsonStringData,
          options: .fragmentsAllowed
        ) as? String,
        let contextData = context.data(using: .utf8),
        let payload = try? JSONSerialization.jsonObject(with: contextData) as? [String: Any],
        let graphData = payload["gql_data"] as? [String: Any],
        let media = graphData["shortcode_media"] as? [String: Any],
        let postID = (media["code"] as? String) ?? (media["shortcode"] as? String),
        postID == expectedPostID
      else {
        continue
      }

      let videoURLs = normalizedInstagramVideoURLs(
        from: instagramVideoURLStrings(inVerifiedMedia: media)
      )
      let type = media["__typename"] as? String
      let childVideoFlags = instagramSidecarVideoFlags(in: media)
      let mediaKind: SocialPostHTMLParser.InstagramMediaKind
      if type == "GraphVideo" || media["is_video"] as? Bool == true
        || childVideoFlags.contains(true) {
        mediaKind = .video
      } else if type == "GraphImage"
        || (type == "GraphSidecar" && !childVideoFlags.isEmpty) {
        mediaKind = .nonVideo
      } else {
        mediaKind = .unknown
      }
      return (videoURLs, mediaKind)
    }

    return nil
  }

  private static func normalizedInstagramVideoURLs(from rawURLs: [String]) -> [URL] {
    var seen = Set<String>()
    return rawURLs.compactMap { rawURL in
      let decoded = HTMLTextDecoder.decodeHTMLEntities(rawURL)
      let key = decoded.lowercased()
      guard key.hasPrefix("https://"),
        isLikelyMediaURLString(key),
        seen.insert(key).inserted
      else { return nil }
      return URL(string: decoded)
    }
  }

  private static func instagramSidecarVideoFlags(in media: [String: Any]) -> [Bool] {
    guard let sidecar = media["edge_sidecar_to_children"] as? [String: Any],
      let edges = sidecar["edges"] as? [[String: Any]],
      !edges.isEmpty
    else { return [] }
    let flags = edges.compactMap { edge in
      (edge["node"] as? [String: Any])?["is_video"] as? Bool
    }
    return flags.count == edges.count ? flags : []
  }

  private static func instagramVideoURLStrings(
    in value: Any,
    expectedPostID: String
  ) -> [String] {
    if let dictionary = value as? [String: Any] {
      let postID = (dictionary["code"] as? String) ?? (dictionary["shortcode"] as? String)
      if postID == expectedPostID {
        let urls = instagramVideoURLStrings(inVerifiedMedia: dictionary)
        if !urls.isEmpty {
          return urls
        }
      }
      return dictionary.values.flatMap {
        instagramVideoURLStrings(in: $0, expectedPostID: expectedPostID)
      }
    }

    if let array = value as? [Any] {
      return array.flatMap {
        instagramVideoURLStrings(in: $0, expectedPostID: expectedPostID)
      }
    }
    return []
  }

  private static func instagramVideoURLStrings(
    inVerifiedMedia media: [String: Any]
  ) -> [String] {
    var urls = (media["video_versions"] as? [[String: Any]])?
      .compactMap { $0["url"] as? String } ?? []
    if let videoURL = media["video_url"] as? String {
      urls.append(videoURL)
    }

    if let carousel = media["carousel_media"] as? [[String: Any]] {
      urls.append(contentsOf: carousel.flatMap { instagramVideoURLStrings(inVerifiedMedia: $0) })
    }

    if let sidecar = media["edge_sidecar_to_children"] as? [String: Any],
      let edges = sidecar["edges"] as? [[String: Any]] {
      urls.append(contentsOf: edges.compactMap { $0["node"] as? [String: Any] }
        .flatMap { instagramVideoURLStrings(inVerifiedMedia: $0) })
    }

    return urls
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
