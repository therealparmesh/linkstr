import CoreGraphics
import Foundation

enum URLClassifier {
  enum MediaStrategy: Equatable {
    case extractionPreferred(embedURL: URL)
    case embedOnly(embedURL: URL)
    case link

    var showsVideoPill: Bool {
      if case .extractionPreferred = self {
        return true
      }
      return false
    }

    var contentKindLabel: String {
      showsVideoPill ? "Video" : "Link"
    }

    var allowsLocalPlaybackToggle: Bool {
      if case .extractionPreferred = self {
        return true
      }
      return false
    }

    var embedURL: URL? {
      switch self {
      case .extractionPreferred(let embedURL), .embedOnly(let embedURL):
        return embedURL
      case .link:
        return nil
      }
    }
  }

  static func classify(_ urlString: String) -> LinkType {
    guard let parsedURL = URL(string: urlString) else {
      return .generic
    }
    return classify(parsedURL)
  }

  static func classify(_ url: URL) -> LinkType {
    guard let host = url.host?.lowercased() else {
      return .generic
    }

    if host.contains("tiktok.com") { return .tiktok }
    if host.contains("instagram.com") { return .instagram }
    if host.contains("facebook.com") || host.contains("fb.watch") { return .facebook }
    if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
    if host.contains("rumble.com") || host.contains("rumble.video") { return .rumble }
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
      guard SocialURLHeuristics.isTikTokVideoLikeURL(url) else { return .link }
      return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
    case .instagram:
      if SocialURLHeuristics.isInstagramReelURL(url) {
        return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
      }
      if SocialURLHeuristics.isInstagramVideoPostURL(url) {
        return .embedOnly(embedURL: embedURL(for: url, linkType: linkType) ?? url)
      }
      return .link
    case .facebook:
      if SocialURLHeuristics.isFacebookReelURL(url) {
        return .extractionPreferred(embedURL: embedURL(for: url, linkType: linkType) ?? url)
      }
      if SocialURLHeuristics.isFacebookVideoURL(url) {
        return .embedOnly(embedURL: embedURL(for: url, linkType: linkType) ?? url)
      }
      return .link
    case .youtube, .rumble:
      return .embedOnly(embedURL: embedURL(for: url, linkType: linkType) ?? url)
    case .generic:
      return .link
    }
  }

  static func preferredMediaAspectRatio(for sourceURL: URL, strategy: MediaStrategy) -> CGFloat {
    switch strategy {
    case .extractionPreferred:
      // Reels/TikTok extraction targets are effectively portrait-first.
      return 9.0 / 16.0
    case .embedOnly:
      if isShortFormVideoURL(sourceURL) {
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
    case .generic:
      return nil
    }
  }

  private static func tikTokEmbedURL(for sourceURL: URL) -> URL? {
    if let id = SocialURLHeuristics.tikTokVideoID(from: sourceURL) {
      return URL(string: "https://www.tiktok.com/embed/v2/\(id)")
    }
    return sourceURL
  }

  private static func instagramEmbedURL(for sourceURL: URL) -> URL? {
    let parts = sourceURL.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2 else { return sourceURL }

    let first = parts[0].lowercased()
    let shortcode = parts[1]
    if ["reel", "reels", "p", "tv"].contains(first), !shortcode.isEmpty {
      return URL(string: "https://www.instagram.com/\(first)/\(shortcode)/embed")
    }
    return sourceURL
  }

  private static func facebookEmbedURL(for sourceURL: URL) -> URL? {
    var components = URLComponents(string: "https://www.facebook.com/plugins/video.php")
    components?.queryItems = [
      URLQueryItem(name: "href", value: sourceURL.absoluteString),
      URLQueryItem(name: "show_text", value: "false"),
    ]
    return components?.url ?? sourceURL
  }

  private static func youtubeEmbedURL(for sourceURL: URL) -> URL? {
    guard let host = sourceURL.host?.lowercased() else { return sourceURL }

    let parts = sourceURL.pathComponents.filter { $0 != "/" }

    let videoID: String?
    if host.contains("youtu.be") {
      videoID = parts.first
    } else if parts.first?.lowercased() == "shorts", parts.count >= 2 {
      videoID = parts[1]
    } else if parts.first?.lowercased() == "embed", parts.count >= 2 {
      videoID = parts[1]
    } else {
      let queryItems = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems
      videoID = queryItems?.first(where: { $0.name == "v" })?.value
    }

    guard let id = videoID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
      return sourceURL
    }
    return URL(string: "https://www.youtube.com/embed/\(id)")
  }

  private static func rumbleEmbedURL(for sourceURL: URL) -> URL? {
    let parts = sourceURL.pathComponents.filter { $0 != "/" }
    guard let first = parts.first, !first.isEmpty else { return sourceURL }

    if first.lowercased() == "embed", parts.count >= 2 {
      return sourceURL
    }

    let id =
      first
      .replacingOccurrences(of: ".html", with: "")
      .split(separator: "-")
      .first
      .map(String.init)
      ?? first
    return URL(string: "https://rumble.com/embed/\(id)")
  }

  private static func isShortFormVideoURL(_ sourceURL: URL) -> Bool {
    let linkType = classify(sourceURL)
    switch linkType {
    case .tiktok:
      return SocialURLHeuristics.isTikTokVideoLikeURL(sourceURL)
    case .instagram:
      return SocialURLHeuristics.isInstagramReelURL(sourceURL)
    case .facebook:
      return SocialURLHeuristics.isFacebookReelURL(sourceURL)
    case .youtube:
      let parts = sourceURL.pathComponents
        .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        .filter { !$0.isEmpty }
      return parts.first == "shorts"
    case .rumble, .generic:
      return false
    }
  }

}
