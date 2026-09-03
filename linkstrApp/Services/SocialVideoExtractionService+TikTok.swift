import Foundation

extension SocialVideoExtractionService {
  func extractFromTikTok(
    sourceURL: URL,
    budget: MediaDiscoveryBudget
  ) async -> ExtractionState? {
    guard SocialURLHeuristics.isTikTokHost(sourceURL),
      SocialURLHeuristics.isTikTokVideoURL(sourceURL)
    else {
      return nil
    }

    guard let videoID = SocialURLHeuristics.tikTokPostID(from: sourceURL) else {
      return nil
    }

    if budget.permitsAttempt {
      let pageCandidates = await loadTikTokPagePlayURLs(
        from: sourceURL,
        expectedVideoID: videoID
      )
      if let resolved = resolvePlayableMedia(
        from: pageCandidates,
        sourceURL: sourceURL,
        userAgent: Self.mobileUserAgent,
        cookies: []
      ) {
        return resolved
      }
    }

    let directTikTokCandidates = await loadTikTokAPIPlayURLs(
      from: sourceURL,
      budget: budget
    )
    if let resolved = resolvePlayableMedia(
      from: directTikTokCandidates,
      sourceURL: sourceURL,
      userAgent: Self.tikTokAPIUserAgent,
      cookies: []
    ) {
      return resolved
    }

    if budget.permitsAttempt,
      let embedURL = URL(string: "https://www.tiktok.com/player/v1/\(videoID)") {
      let embedResult = await extractViaGenericSniff(
        sourceURL: embedURL,
        budget: budget
      )
      if case .ready = embedResult {
        return embedResult
      }
    }
    return .cannotExtract("could not find a usable video stream for this post.")
  }

  func tiktokIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    mediaIdentityScore(
      expectedID: SocialURLHeuristics.tikTokPostID(from: sourceURL),
      candidateID: SocialURLHeuristics.tikTokPostID(fromCandidateURL: url),
      value: value,
      host: host,
      allowedHostTokens: ["tiktok", "byte", "akamaized"]
    )
  }

  private func loadTikTokPagePlayURLs(
    from sourceURL: URL,
    expectedVideoID: String
  ) async -> [URL] {
    guard let page = await SocialMediaPageLoader.load(sourceURL, userAgent: Self.mobileUserAgent),
      let html = page.html
    else {
      return []
    }
    return Self.extractTikTokPageVideoURLs(
      fromHTML: html,
      expectedVideoID: expectedVideoID
    )
  }

  static func extractTikTokPageVideoURLs(
    fromHTML html: String,
    expectedVideoID: String
  ) -> [URL] {
    var seen = Set<String>()
    var urls: [URL] = []

    for script in HTMLScriptContentScanner.contents(in: html) {
      guard let data = script.data(using: .utf8),
        let payload = try? JSONDecoder().decode(TikTokPagePayload.self, from: data)
      else {
        continue
      }
      let items = [
        payload.defaultScope.reflowVideoDetail,
        payload.defaultScope.legacyVideoDetail
      ].compactMap { $0?.itemInfo.itemStruct }
      guard let item = items.first(where: { $0.id == expectedVideoID }) else {
        continue
      }

      for rawURL in [item.video.playAddr, item.video.downloadAddr].compactMap({ $0 }) {
        let normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized.lowercased()
        guard key.hasPrefix("https://"),
          isLikelyMediaURLString(key),
          seen.insert(key).inserted,
          let url = URL(string: normalized)
        else {
          continue
        }
        urls.append(url)
      }
    }
    return urls
  }

  private func loadTikTokAPIPlayURLs(
    from sourceURL: URL,
    budget: MediaDiscoveryBudget
  ) async -> [URL] {
    guard let awemeID = SocialURLHeuristics.tikTokPostID(from: sourceURL) else {
      return []
    }

    // Try endpoints sequentially — concurrent requests to TikTok's API
    // servers get rate-limited or blocked.
    for feedEndpoint in Self.tikTokFeedEndpoints {
      guard budget.permitsAttempt else { return [] }
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
    request.httpMethod = "GET"
    request.setValue(Self.tikTokAPIUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout

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
}

private struct TikTokPagePayload: Decodable {
  let defaultScope: TikTokPageScope

  enum CodingKeys: String, CodingKey {
    case defaultScope = "__DEFAULT_SCOPE__"
  }
}

private struct TikTokPageScope: Decodable {
  let reflowVideoDetail: TikTokPageVideoDetail?
  let legacyVideoDetail: TikTokPageVideoDetail?

  enum CodingKeys: String, CodingKey {
    case reflowVideoDetail = "webapp.reflow.video.detail"
    case legacyVideoDetail = "webapp.video-detail"
  }
}

private struct TikTokPageVideoDetail: Decodable {
  let itemInfo: TikTokPageItemInfo
}

private struct TikTokPageItemInfo: Decodable {
  let itemStruct: TikTokPageItem
}

private struct TikTokPageItem: Decodable {
  let id: String
  let video: TikTokPageVideo
}

private struct TikTokPageVideo: Decodable {
  let playAddr: String?
  let downloadAddr: String?
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
