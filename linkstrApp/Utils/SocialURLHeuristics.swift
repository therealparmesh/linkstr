import Foundation

enum SocialURLHeuristics {
  // MARK: - Cached regex patterns

  private static func regex(_ pattern: String) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern)
    } catch {
      fatalError("Invalid regex: \(error)")
    }
  }

  static let tikTokVideoPatterns: [NSRegularExpression] = [
    regex(#"/video/(\d{8,})"#),
    regex(#"(?:aweme_id|item_id|group_id|video_id)=(\d{8,})"#)
  ]

  static let tikTokVideoIDQueryKeys = ["aweme_id", "item_id", "group_id", "video_id"]

  static let igCacheKeyPattern = regex(#"([A-Za-z0-9_-]{5,})"#)

  static let instagramPostPattern = regex(#"/(?:reel|reels|p|tv)/([A-Za-z0-9_-]{5,})"#)

  static let facebookVideoPattern = regex(#"/(?:reel|videos)/(\d{6,})"#)
  static func isTikTokHost(_ url: URL) -> Bool {
    hostMatches(url, domain: "tiktok.com")
  }

  static func isInstagramHost(_ url: URL) -> Bool {
    hostMatches(url, domain: "instagram.com") || hostMatches(url, domain: "instagr.am")
  }

  static func isFacebookHost(_ url: URL) -> Bool {
    hostMatches(url, domain: "facebook.com")
      || hostMatches(url, domain: "fb.com")
      || hostMatches(url, domain: "fb.watch")
  }

  static func isYouTubeHost(_ url: URL) -> Bool {
    hostMatches(url, domain: "youtube.com")
      || hostMatches(url, domain: "youtu.be")
      || hostMatches(url, domain: "youtube-nocookie.com")
  }

  static func isRumbleHost(_ url: URL) -> Bool {
    hostMatches(url, domain: "rumble.com") || hostMatches(url, domain: "rumble.video")
  }

  static func isTwitterHost(_ url: URL) -> Bool {
    hostMatches(url, domain: "x.com")
      || hostMatches(url, domain: "twitter.com")
      || hostMatches(url, domain: "fixupx.com")
      || hostMatches(url, domain: "fxtwitter.com")
      || hostMatches(url, domain: "vxtwitter.com")
  }

  static func isFacebookShareURL(_ url: URL) -> Bool {
    guard isFacebookHost(url) else { return false }

    let parts = normalizedPathComponents(for: url)
    guard let first = parts.first else { return false }
    return first == "share"
  }

  static func isTikTokShortURL(_ url: URL) -> Bool {
    guard isTikTokHost(url) else { return false }
    let host = normalizedHost(for: url) ?? ""
    if hostMatches(host, domain: "vm.tiktok.com") || hostMatches(host, domain: "vt.tiktok.com") {
      return true
    }

    let parts = normalizedPathComponents(for: url)
    return parts.first == "t" && parts.count >= 2
  }

  static func isTikTokVideoLikeURL(_ url: URL) -> Bool {
    guard isTikTokHost(url) else { return false }
    return isTikTokShortURL(url) || tikTokVideoID(from: url) != nil
  }

  static func isInstagramReelURL(_ url: URL) -> Bool {
    pathToken(
      in: url,
      markers: ["reel", "reels"],
      minLength: 5,
      allowDigitsOnly: false
    ) != nil
  }

  static func isInstagramVideoPostURL(_ url: URL) -> Bool {
    pathToken(
      in: url,
      markers: ["p", "tv"],
      minLength: 5,
      allowDigitsOnly: false
    ) != nil
  }

  static func isFacebookReelURL(_ url: URL) -> Bool {
    if pathToken(
      in: url,
      markers: ["reel", "reels", "r"],
      minLength: 4,
      allowDigitsOnly: false
    ) != nil {
      return true
    }

    let parts = normalizedPathComponents(for: url)
    return hasPathSequence(parts, first: "share", second: "r")
  }

  static func isFacebookVideoURL(_ url: URL) -> Bool {
    if hostMatches(url, domain: "fb.watch") {
      return true
    }

    let parts = normalizedPathComponents(for: url)
    if parts.contains("videos") {
      return true
    }
    if hasPathSequence(parts, first: "share", second: "v") {
      return true
    }
    if hasPathSequence(parts, first: "watch", second: "v") {
      return true
    }

    guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else {
      return false
    }
    return queryItems.contains { item in
      let key = item.name.lowercased()
      return key == "v" || key == "video_id" || key == "story_fbid"
    }
  }

  static func isTwitterStatusURL(_ url: URL) -> Bool {
    twitterStatusID(from: url) != nil
  }

  static func isTwitterVideoURL(_ url: URL) -> Bool {
    let parts = normalizedPathComponents(for: url)
    guard let statusIndex = parts.firstIndex(of: "status"), statusIndex + 2 < parts.count else {
      return false
    }
    return parts[(statusIndex + 2)...].contains("video")
  }

  static func isYouTubeVideoURL(_ url: URL) -> Bool {
    youtubeVideoID(from: url) != nil
  }

  static func isRumbleVideoURL(_ url: URL) -> Bool {
    guard isRumbleHost(url) else { return false }
    let parts = url.pathComponents
      .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }
    guard let first = parts.first else { return false }

    // /embed/xxx/ or /vXXXXX-title.html
    if first == "embed", parts.count >= 2 { return true }
    if first.hasPrefix("v"), first.contains("-") || first.hasSuffix(".html") { return true }
    return false
  }

  static func twitterStatusID(from sourceURL: URL) -> String? {
    let parts = normalizedPathComponents(for: sourceURL)
    guard let statusIndex = parts.firstIndex(of: "status"), statusIndex + 1 < parts.count else {
      return nil
    }
    let candidate = parts[statusIndex + 1]
    guard candidate.allSatisfy(\.isNumber) else {
      return nil
    }
    return candidate
  }

  static func twitterCanonicalStatusURL(from sourceURL: URL) -> URL? {
    guard let statusID = twitterStatusID(from: sourceURL) else {
      return nil
    }
    return URL(string: "https://x.com/i/status/\(statusID)")
  }

  static func normalizedPathComponents(for url: URL) -> [String] {
    url.pathComponents
      .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }
  }

  static func normalizedHost(for url: URL) -> String? {
    guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
      !host.isEmpty
    else {
      return nil
    }
    return host
  }

  static func hostMatches(_ url: URL, domain: String) -> Bool {
    guard let host = normalizedHost(for: url) else { return false }
    return hostMatches(host, domain: domain)
  }

  static func hostMatches(_ host: String, domain: String) -> Bool {
    host == domain || host.hasSuffix(".\(domain)")
  }

  static func hasPathSequence(_ parts: [String], first: String, second: String) -> Bool {
    guard let index = parts.firstIndex(of: first), index + 1 < parts.count else { return false }
    return parts[index + 1] == second
  }

  static func pathToken(
    in url: URL,
    markers: [String],
    minLength: Int,
    allowDigitsOnly: Bool,
    preservesCase: Bool = false
  ) -> String? {
    let parts = url.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }

    for (index, part) in parts.enumerated() {
      guard markers.contains(part.lowercased()), index + 1 < parts.count else { continue }
      if let token = normalizedToken(
        parts[index + 1],
        minLength: minLength,
        allowDigitsOnly: allowDigitsOnly,
        preservesCase: preservesCase
      ) {
        return token
      }
    }

    return nil
  }

  static func normalizedToken(
    _ raw: String,
    minLength: Int,
    allowDigitsOnly: Bool,
    preservesCase: Bool = false
  ) -> String? {
    let trimmed =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/?&=#"))
    let cleaned = preservesCase ? trimmed : trimmed.lowercased()
    guard cleaned.count >= minLength else { return nil }
    if allowDigitsOnly, !cleaned.allSatisfy(\.isNumber) {
      return nil
    }
    return cleaned
  }

  static func tokenFromRegex(_ regex: NSRegularExpression, in value: String) -> String? {
    let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: nsRange), match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }
}
