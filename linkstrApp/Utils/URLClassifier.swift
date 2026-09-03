import Foundation

enum URLClassifier {
  enum MediaStrategy: Equatable {
    case extractionPreferred(embedURL: URL)
    case embedOnly(embedURL: URL)
    case link

    var allowsLocalPlaybackToggle: Bool {
      if case .extractionPreferred = self {
        return true
      }
      return false
    }
  }

  static func classify(_ urlString: String) -> LinkType {
    guard let parsedURL = URL(string: urlString) else {
      return .generic
    }
    return classify(parsedURL)
  }

  static func classify(_ url: URL) -> LinkType {
    if SocialURLHeuristics.isTikTokHost(url) { return .tiktok }
    if SocialURLHeuristics.isInstagramHost(url) { return .instagram }
    if SocialURLHeuristics.isFacebookHost(url) { return .facebook }
    if SocialURLHeuristics.isYouTubeHost(url) { return .youtube }
    if SocialURLHeuristics.isRumbleHost(url) { return .rumble }
    if SocialURLHeuristics.isTwitterHost(url) { return .twitter }
    return .generic
  }

  static func mediaStrategy(for urlString: String?) -> MediaStrategy {
    guard let urlString, let url = URL(string: urlString) else {
      return .link
    }
    return mediaStrategy(for: url)
  }

  static func mediaStrategy(for url: URL) -> MediaStrategy {
    let linkType = classify(url)
    switch linkType {
    case .tiktok:
      return tiktokMediaStrategy(for: url, linkType: linkType)
    case .instagram:
      return instagramMediaStrategy(for: url, linkType: linkType)
    case .facebook:
      return facebookMediaStrategy(for: url, linkType: linkType)
    case .twitter:
      guard SocialURLHeuristics.isTwitterStatusURL(url) else { return .link }
      return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
    case .youtube:
      guard SocialURLHeuristics.isYouTubeVideoURL(url) else { return .link }
      return .embedOnly(embedURL: embedURL(for: url, linkType: linkType) ?? url)
    case .rumble:
      guard SocialURLHeuristics.isRumbleVideoURL(url) else { return .link }
      return .embedOnly(embedURL: embedURL(for: url, linkType: linkType) ?? url)
    case .generic:
      return .link
    }
  }

  private static func tiktokMediaStrategy(for url: URL, linkType: LinkType) -> MediaStrategy {
    guard SocialURLHeuristics.isTikTokPostURL(url) else { return .link }
    if SocialURLHeuristics.isTikTokPhotoURL(url) {
      return .embedOnly(embedURL: embedURL(for: url, linkType: linkType) ?? url)
    }
    return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
  }

  private static func instagramMediaStrategy(for url: URL, linkType: LinkType) -> MediaStrategy {
    guard SocialURLHeuristics.isInstagramReelURL(url)
      || SocialURLHeuristics.isInstagramVideoPostURL(url)
    else { return .link }
    return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
  }

  private static func facebookMediaStrategy(for url: URL, linkType: LinkType) -> MediaStrategy {
    if isDedicatedEmbedURL(url) {
      return .embedOnly(embedURL: url)
    }
    guard SocialURLHeuristics.isFacebookReelURL(url)
      || SocialURLHeuristics.isFacebookVideoURL(url)
    else { return .link }
    return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
  }

  static func preferredMediaAspectRatio(for sourceURL: URL, strategy: MediaStrategy) -> CGFloat {
    switch strategy {
    case .extractionPreferred:
      let linkType = classify(sourceURL)
      switch linkType {
      case .tiktok, .instagram:
        return 9.0 / 16.0
      case .facebook:
        return SocialURLHeuristics.isFacebookReelURL(sourceURL) ? 9.0 / 16.0 : 16.0 / 9.0
      case .twitter, .youtube, .rumble, .generic:
        return 16.0 / 9.0
      }
    case .embedOnly:
      let linkType = classify(sourceURL)
      if linkType == .facebook {
        return SocialURLHeuristics.isFacebookReelURL(sourceURL) ? 9.0 / 16.0 : 16.0 / 9.0
      }
      if linkType == .twitter {
        return 4.0 / 5.0
      }
      if isShortFormMediaURL(sourceURL) {
        return 9.0 / 16.0
      }
      return 16.0 / 9.0
    case .link:
      return 16.0 / 9.0
    }
  }

  private static func embedURL(for sourceURL: URL, linkType: LinkType) -> URL? {
    switch linkType {
    case .tiktok:
      return tikTokEmbedURL(for: sourceURL)
    case .instagram:
      return instagramEmbedURL(for: sourceURL)
    case .facebook:
      return facebookEmbedURL(for: sourceURL)
    case .youtube:
      return youtubeEmbedURL(for: sourceURL)
    case .rumble:
      return rumbleEmbedURL(for: sourceURL)
    case .twitter:
      return twitterEmbedURL(for: sourceURL)
    case .generic:
      return nil
    }
  }

  private static func tikTokEmbedURL(for sourceURL: URL) -> URL? {
    if let id = SocialURLHeuristics.tikTokPostID(from: sourceURL) {
      return URL(string: "https://www.tiktok.com/player/v1/\(id)")
    }
    return sourceURL
  }

  private static func instagramEmbedURL(for sourceURL: URL) -> URL? {
    guard let canonicalURL = SocialURLHeuristics.instagramCanonicalURL(for: sourceURL) else {
      return sourceURL
    }
    return canonicalURL.appendingPathComponent("embed")
  }

  private static func facebookEmbedURL(for sourceURL: URL) -> URL? {
    let canonicalURL = canonicalFacebookWebURL(sourceURL)

    let path = canonicalURL.path.lowercased()
    if path.hasPrefix("/plugins/video.php") || path.hasPrefix("/plugins/post.php") {
      return canonicalURL
    }

    if !SocialURLHeuristics.isFacebookReelURL(canonicalURL),
      let videoID = SocialURLHeuristics.facebookVideoID(from: canonicalURL) {
      var components = URLComponents(string: "https://m.facebook.com/watch/")
      components?.queryItems = [URLQueryItem(name: "v", value: videoID)]
      return components?.url ?? canonicalURL
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.facebook.com"
    components.path = "/plugins/post.php"
    components.queryItems = [
      URLQueryItem(name: "href", value: canonicalURL.absoluteString),
      URLQueryItem(name: "show_text", value: "false"),
      URLQueryItem(name: "width", value: "540")
    ]
    return components.url ?? canonicalURL
  }

  private static func youtubeEmbedURL(for sourceURL: URL) -> URL? {
    guard let host = sourceURL.host?.lowercased() else { return sourceURL }

    let queryItems = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems
    guard let id = SocialURLHeuristics.youtubeVideoID(from: sourceURL) else {
      return sourceURL
    }

    var embedQueryItems = [
      URLQueryItem(name: "playsinline", value: "1"),
      URLQueryItem(name: "rel", value: "0")
    ]
    let rawStartTime = queryItems?.first(where: {
      let name = $0.name.lowercased()
      return name == "start" || name == "t"
    })?.value
    if let startSeconds = youtubeStartSeconds(from: rawStartTime) {
      embedQueryItems.append(URLQueryItem(name: "start", value: String(startSeconds)))
    }

    let embedHost = SocialURLHeuristics.hostMatches(host, domain: "youtube-nocookie.com")
      ? "www.youtube-nocookie.com"
      : "www.youtube.com"
    var components = URLComponents(string: "https://\(embedHost)/embed/\(id)")
    components?.queryItems = embedQueryItems
    return components?.url ?? sourceURL
  }

  private static func rumbleEmbedURL(for sourceURL: URL) -> URL? {
    let parts = sourceURL.pathComponents.filter { $0 != "/" }
    guard let first = parts.first, !first.isEmpty else { return sourceURL }

    // If already an embed URL, use it directly.
    if first.lowercased() == "embed", parts.count >= 2 {
      return sourceURL
    }

    // Rumble slug IDs (e.g. v6abcde in /v6abcde-title.html) differ from embed IDs.
    // Return the source URL as the fallback; the async oEmbed resolution in
    // URLCanonicalizationService provides the correct embed URL.
    return sourceURL
  }

  private static func twitterEmbedURL(for sourceURL: URL) -> URL? {
    guard SocialURLHeuristics.isTwitterStatusURL(sourceURL) else { return sourceURL }
    return twitterEmbedFallbackURL(for: sourceURL) ?? sourceURL
  }

  static func twitterEmbedFallbackURL(for sourceURL: URL) -> URL? {
    SocialURLHeuristics.twitterCanonicalStatusURL(from: sourceURL)
  }

  private static func isShortFormMediaURL(_ sourceURL: URL) -> Bool {
    let linkType = classify(sourceURL)
    switch linkType {
    case .tiktok:
      return SocialURLHeuristics.isTikTokPostURL(sourceURL)
    case .instagram:
      return SocialURLHeuristics.isInstagramReelURL(sourceURL)
    case .facebook:
      return SocialURLHeuristics.isFacebookReelURL(sourceURL)
    case .youtube:
      let parts = sourceURL.pathComponents
        .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        .filter { !$0.isEmpty }
      return parts.first == "shorts"
    case .twitter:
      return SocialURLHeuristics.isTwitterVideoURL(sourceURL)
    case .rumble, .generic:
      return false
    }
  }

  private static func canonicalFacebookWebURL(_ sourceURL: URL) -> URL {
    guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
      let host = components.host?.lowercased()
    else {
      return sourceURL
    }

    if host == "fb.watch" || host.hasSuffix(".fb.watch") {
      return sourceURL
    }

    guard SocialURLHeuristics.isFacebookHost(sourceURL) else {
      return sourceURL
    }

    components.scheme = "https"
    components.host = "www.facebook.com"
    components.port = nil
    components.user = nil
    components.password = nil
    return components.url ?? sourceURL
  }
}

extension URLClassifier {
  private static func youtubeStartSeconds(from rawValue: String?) -> Int? {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !value.isEmpty
    else { return nil }
    if let seconds = Int(value) {
      return seconds > 0 ? seconds : nil
    }

    guard let match = value.wholeMatch(of: /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?/)
    else { return nil }
    let hours = Double(match.1.map(String.init) ?? "") ?? 0
    let minutes = Double(match.2.map(String.init) ?? "") ?? 0
    let trailingSeconds = Double(match.3.map(String.init) ?? "") ?? 0
    let seconds = hours * 3_600 + minutes * 60 + trailingSeconds
    guard seconds.isFinite, seconds > 0, seconds <= Double(Int.max) else { return nil }
    return Int(seconds)
  }

  static func isDedicatedEmbedURL(_ url: URL) -> Bool {
    let parts = SocialURLHeuristics.normalizedPathComponents(for: url)
    switch classify(url) {
    case .tiktok:
      return parts.starts(with: ["player", "v1"]) && parts.count >= 3
    case .instagram:
      return parts.last == "embed"
    case .facebook:
      return parts.starts(with: ["plugins", "video.php"])
        || parts.starts(with: ["plugins", "post.php"])
    case .youtube:
      return parts.first == "embed" && parts.count >= 2
    case .rumble:
      return parts.first == "embed" && parts.count >= 2
    case .twitter, .generic:
      return false
    }
  }
}
