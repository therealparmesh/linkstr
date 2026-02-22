import Foundation

enum SocialURLHeuristics {
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
    hostMatches(url, domain: "youtube.com") || hostMatches(url, domain: "youtu.be")
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

  static func isTikTokVideoLikeURL(_ url: URL) -> Bool {
    let host = normalizedHost(for: url) ?? ""
    if hostMatches(host, domain: "vm.tiktok.com") || hostMatches(host, domain: "vt.tiktok.com") {
      return true
    }

    let parts = url.pathComponents.map { $0.lowercased() }
    if parts.contains("video") {
      return true
    }

    guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else {
      return false
    }
    return queryItems.contains { item in
      let key = item.name.lowercased()
      return key == "aweme_id" || key == "video_id" || key == "item_id"
    }
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

  static func tikTokVideoID(from sourceURL: URL) -> String? {
    let parts = sourceURL.pathComponents
    if let videoIndex = parts.firstIndex(of: "video"), videoIndex + 1 < parts.count {
      let candidate = parts[videoIndex + 1]
      let digits = candidate.filter(\.isNumber)
      if digits.count >= 8 { return digits }
    }
    return nil
  }

  static func tikTokVideoID(fromCandidateURL url: URL) -> String? {
    let queryKeys = ["aweme_id", "item_id", "group_id", "video_id"]
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    {
      for item in queryItems where queryKeys.contains(item.name.lowercased()) {
        let digits = (item.value ?? "").filter(\.isNumber)
        if digits.count >= 8 { return digits }
      }
    }

    let raw = url.absoluteString
    let patterns = [
      #"/video/(\d{8,})"#,
      #"(?:aweme_id|item_id|group_id|video_id)=(\d{8,})"#,
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
      guard let match = regex.firstMatch(in: raw, range: nsRange), match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: raw)
      else { continue }
      return String(raw[range])
    }

    return nil
  }

  static func instagramPostID(from sourceURL: URL) -> String? {
    if let token = pathToken(
      in: sourceURL,
      markers: ["reel", "reels", "p", "tv"],
      minLength: 5,
      allowDigitsOnly: false
    ) {
      return token
    }

    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else { return nil }

    for key in ["shortcode", "media_id", "igshid"] {
      if let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
        let token = normalizedToken(value, minLength: 5, allowDigitsOnly: false)
      {
        return token
      }
    }

    return nil
  }

  static func instagramPostID(fromCandidateURL url: URL) -> String? {
    if let token = pathToken(
      in: url,
      markers: ["reel", "reels", "p", "tv"],
      minLength: 5,
      allowDigitsOnly: false
    ) {
      return token
    }

    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    {
      for key in ["shortcode", "media_id", "ig_cache_key", "item_id"] {
        guard let raw = queryItems.first(where: { $0.name.lowercased() == key })?.value else {
          continue
        }

        if key == "ig_cache_key" {
          if let token = tokenFromRegex(#"([A-Za-z0-9_-]{5,})"#, in: raw) {
            return token.lowercased()
          }
          continue
        }

        if let token = normalizedToken(raw, minLength: 5, allowDigitsOnly: false) {
          return token
        }
      }
    }

    if let token = tokenFromRegex(
      #"/(?:reel|reels|p|tv)/([A-Za-z0-9_-]{5,})"#,
      in: url.absoluteString
    ) {
      return token.lowercased()
    }

    return nil
  }

  static func facebookVideoID(from sourceURL: URL) -> String? {
    if let id = pathToken(
      in: sourceURL,
      markers: ["reel", "reels", "videos", "v", "r"],
      minLength: 6,
      allowDigitsOnly: true
    ) {
      return id
    }

    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else { return nil }

    for key in ["v", "video_id", "story_fbid"] {
      if let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
        let id = normalizedToken(value, minLength: 6, allowDigitsOnly: true)
      {
        return id
      }
    }

    return nil
  }

  static func facebookVideoID(fromCandidateURL url: URL) -> String? {
    if let id = pathToken(
      in: url,
      markers: ["reel", "reels", "videos", "v", "r"],
      minLength: 6,
      allowDigitsOnly: true
    ) {
      return id
    }

    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    {
      for key in ["video_id", "v", "story_fbid", "item_id", "group_id"] {
        if let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
          let id = normalizedToken(value, minLength: 6, allowDigitsOnly: true)
        {
          return id
        }
      }
    }

    if let id = tokenFromRegex(#"/(?:reel|videos)/(\d{6,})"#, in: url.absoluteString) {
      return id
    }

    return nil
  }

  private static func normalizedPathComponents(for url: URL) -> [String] {
    url.pathComponents
      .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }
  }

  private static func normalizedHost(for url: URL) -> String? {
    guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
      !host.isEmpty
    else {
      return nil
    }
    return host
  }

  private static func hostMatches(_ url: URL, domain: String) -> Bool {
    guard let host = normalizedHost(for: url) else { return false }
    return hostMatches(host, domain: domain)
  }

  private static func hostMatches(_ host: String, domain: String) -> Bool {
    host == domain || host.hasSuffix(".\(domain)")
  }

  private static func hasPathSequence(_ parts: [String], first: String, second: String) -> Bool {
    guard let index = parts.firstIndex(of: first), index + 1 < parts.count else { return false }
    return parts[index + 1] == second
  }

  private static func pathToken(
    in url: URL,
    markers: [String],
    minLength: Int,
    allowDigitsOnly: Bool
  ) -> String? {
    let parts = url.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }

    for (index, part) in parts.enumerated() {
      guard markers.contains(part.lowercased()), index + 1 < parts.count else { continue }
      if let token = normalizedToken(
        parts[index + 1], minLength: minLength, allowDigitsOnly: allowDigitsOnly)
      {
        return token
      }
    }

    return nil
  }

  private static func normalizedToken(
    _ raw: String,
    minLength: Int,
    allowDigitsOnly: Bool
  ) -> String? {
    let cleaned =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/?&=#"))
      .lowercased()
    guard cleaned.count >= minLength else { return nil }
    if allowDigitsOnly, !cleaned.allSatisfy(\.isNumber) {
      return nil
    }
    return cleaned
  }

  private static func tokenFromRegex(_ pattern: String, in value: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: nsRange), match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }
}
