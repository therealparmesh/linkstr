import Foundation

extension SocialVideoExtractionService {
  func extractFromTikTok(sourceURL: URL) async -> ExtractionState? {
    guard SocialURLHeuristics.isTikTokHost(sourceURL),
      SocialURLHeuristics.tikTokVideoID(from: sourceURL) != nil
    else {
      return nil
    }
    let directTikTokCandidates = await loadTikTokAPIPlayURLs(from: sourceURL)
    return resolvePlayableMedia(
      from: directTikTokCandidates,
      sourceURL: sourceURL,
      userAgent: Self.tikTokAPIUserAgent,
      cookies: []
    )
  }

  func tiktokIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    guard let expectedID = SocialURLHeuristics.tikTokVideoID(from: sourceURL) else { return 0 }
    var score = 0
    if value.contains(expectedID) { score += 50 }
    if let candidateID = SocialURLHeuristics.tikTokVideoID(fromCandidateURL: url) {
      score += candidateID == expectedID ? 100 : -100
    }
    if !(host.contains("tiktok") || host.contains("byte") || host.contains("akamaized")) {
      score -= 25
    }
    return score
  }

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
