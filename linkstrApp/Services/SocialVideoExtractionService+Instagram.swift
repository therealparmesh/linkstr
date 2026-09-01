import Foundation

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
    if budget.permitsAttempt,
      let pageSummary = await instagramPageMediaSummary(
        from: sourceURL,
        expectedPostID: postID
      ) {
      let ranked = rankCandidates(pageSummary.videoURLs, sourceURL: sourceURL)
      if let resolved = resolvePlayableMedia(
        from: ranked,
        sourceURL: sourceURL,
        userAgent: Self.mobileUserAgent,
        cookies: []
      ) {
        return resolved
      }

      if pageSummary.mediaKind == .nonVideo {
        sawNonVideoPage = true
      }
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
  ) async -> (
    videoURLs: [URL], mediaKind: SocialPostHTMLParser.InstagramMediaKind
  )? {
    var loadedPage = false
    var mediaKind = SocialPostHTMLParser.InstagramMediaKind.unknown

    for userAgent in [Self.mobileUserAgent, Self.desktopUserAgent] {
      guard let page = await SocialMediaPageLoader.load(pageURL, userAgent: userAgent),
        let html = page.html
      else {
        continue
      }
      loadedPage = true
      let detectedKind = SocialPostHTMLParser.instagramMediaKind(from: html)
      if detectedKind != .unknown {
        mediaKind = detectedKind
      }

      var videoURLs = Self.extractInstagramPageVideoURLs(
        fromHTML: html,
        expectedPostID: expectedPostID
      )
      if SocialURLHeuristics.instagramPostID(from: page.finalURL) == expectedPostID {
        var seen = Set(videoURLs.map { $0.absoluteString.lowercased() })
        for url in Self.extractOGVideoURLs(fromHTML: html)
        where seen.insert(url.absoluteString.lowercased()).inserted {
          videoURLs.append(url)
        }
      }
      if !videoURLs.isEmpty {
        return (videoURLs, detectedKind)
      }
    }

    return loadedPage ? ([], mediaKind) : nil
  }

  static func extractInstagramPageVideoURLs(
    fromHTML html: String,
    expectedPostID: String
  ) -> [URL] {
    var seen = Set<String>()
    var urls: [URL] = []

    for script in HTMLScriptContentScanner.contents(in: html) {
      guard let data = script.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
      else {
        continue
      }

      for rawURL in instagramVideoURLStrings(in: json, expectedPostID: expectedPostID) {
        let decoded = HTMLTextDecoder.decodeHTMLEntities(rawURL)
        let key = decoded.lowercased()
        guard key.hasPrefix("https://"),
          isLikelyMediaURLString(key),
          seen.insert(key).inserted,
          let url = URL(string: decoded)
        else {
          continue
        }
        urls.append(url)
      }
    }
    return urls
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
