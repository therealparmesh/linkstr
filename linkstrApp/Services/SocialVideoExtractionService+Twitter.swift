import Foundation

extension SocialVideoExtractionService {
  func extractFromTwitter(
    sourceURL: URL,
    budget: MediaDiscoveryBudget
  ) async -> ExtractionState? {
    guard SocialURLHeuristics.isTwitterStatusURL(sourceURL) else {
      return nil
    }
    let summary = await TwitterStatusResolutionService.shared.mediaSummary(
      for: sourceURL,
      budget: budget
    )
    if summary.hasVideo == false {
      return .cannotExtract("this post does not include a playable video.")
    }
    return resolvePlayableMedia(
      from: summary.candidateURLs,
      sourceURL: sourceURL,
      userAgent: Self.mobileUserAgent,
      cookies: []
    )
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

  func mediaSummary(
    for sourceURL: URL,
    budget: MediaDiscoveryBudget? = nil
  ) async -> TwitterStatusMediaSummary {
    guard let cacheKey = cacheKey(for: sourceURL) else {
      return .empty
    }
    if let cached = mediaSummaryCache[cacheKey] {
      return cached
    }

    let summary = await fetchMediaSummary(for: sourceURL, budget: budget)
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

  private func fetchMediaSummary(
    for sourceURL: URL,
    budget: MediaDiscoveryBudget?
  ) async -> TwitterStatusMediaSummary {
    guard let statusID = SocialURLHeuristics.twitterStatusID(from: sourceURL) else {
      return .empty
    }

    let endpoints = [
      "https://api.vxtwitter.com/Twitter/status/\(statusID)",
      "https://api.fxtwitter.com/status/\(statusID)",
      "https://cdn.syndication.twimg.com/tweet-result?id=\(statusID)&token=0"
    ]

    var fallbackSummary: TwitterStatusMediaSummary?
    for rawEndpoint in endpoints {
      guard !Task.isCancelled, budget?.permitsAttempt ?? true else {
        return fallbackSummary ?? .empty
      }
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
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout
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
      URLQueryItem(name: "align", value: "center")
    ]
    guard let endpoint = components.url else { return false }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout
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
