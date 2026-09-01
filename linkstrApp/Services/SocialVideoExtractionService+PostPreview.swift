import Foundation

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
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout
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
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout
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
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout
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
