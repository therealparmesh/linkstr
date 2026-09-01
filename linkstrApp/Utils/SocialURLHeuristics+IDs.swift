import Foundation

extension SocialURLHeuristics {
  static func youtubeVideoID(from sourceURL: URL) -> String? {
    guard isYouTubeHost(sourceURL) else { return nil }

    let parts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }
    let host = normalizedHost(for: sourceURL) ?? ""

    let rawID: String?
    if hostMatches(host, domain: "youtu.be") {
      rawID = parts.first
    } else if let first = parts.first?.lowercased(),
      ["shorts", "embed", "live", "v"].contains(first), parts.count >= 2 {
      rawID = parts[1]
    } else if parts.first?.lowercased() == "watch" {
      rawID = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name.caseInsensitiveCompare("v") == .orderedSame })?.value
    } else {
      rawID = nil
    }

    guard let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
      return nil
    }
    return id
  }

  static func tikTokVideoID(from sourceURL: URL) -> String? {
    let parts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }

    if parts.count >= 3,
      parts[0].caseInsensitiveCompare("player") == .orderedSame,
      parts[1].caseInsensitiveCompare("v1") == .orderedSame,
      let id = normalizedTikTokVideoID(parts[2]) {
      return id
    }

    if let videoIndex = parts.firstIndex(where: {
      $0.caseInsensitiveCompare("video") == .orderedSame
    }), videoIndex + 1 < parts.count,
      let id = normalizedTikTokVideoID(parts[videoIndex + 1]) {
      return id
    }
    return tikTokVideoIDFromQuery(sourceURL)
  }

  private static func normalizedTikTokVideoID(_ rawValue: String) -> String? {
    let digits = rawValue.filter(\.isNumber)
    return digits.count >= 8 ? digits : nil
  }

  private static func tikTokVideoIDFromQuery(_ url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else { return nil }

    for item in queryItems where tikTokVideoIDQueryKeys.contains(item.name.lowercased()) {
      if let id = normalizedTikTokVideoID(item.value ?? "") {
        return id
      }
    }
    return nil
  }

  static func tikTokVideoID(fromCandidateURL url: URL) -> String? {
    if let id = tikTokVideoID(from: url) { return id }

    let raw = url.absoluteString

    for regex in tikTokVideoPatterns {
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
      allowDigitsOnly: false,
      preservesCase: true
    ) {
      return token
    }

    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else { return nil }

    for key in ["shortcode", "media_id"] {
      if let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
        let token = normalizedToken(
          value,
          minLength: 5,
          allowDigitsOnly: false,
          preservesCase: true
        ) {
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
      allowDigitsOnly: false,
      preservesCase: true
    ) {
      return token
    }

    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems {
      for key in ["shortcode", "media_id", "ig_cache_key", "item_id"] {
        guard let raw = queryItems.first(where: { $0.name.lowercased() == key })?.value else {
          continue
        }

        if key == "ig_cache_key" {
          if let token = tokenFromRegex(igCacheKeyPattern, in: raw) {
            return token
          }
          continue
        }

        if let token = normalizedToken(
          raw,
          minLength: 5,
          allowDigitsOnly: false,
          preservesCase: true
        ) {
          return token
        }
      }
    }

    if let token = tokenFromRegex(
      instagramPostPattern,
      in: url.absoluteString
    ) {
      return token
    }

    return nil
  }

  static func instagramCanonicalURL(for sourceURL: URL) -> URL? {
    guard isInstagramHost(sourceURL) else { return nil }

    let rawParts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }

    for (index, part) in rawParts.enumerated() {
      let lower = part.lowercased()
      guard ["reel", "reels", "p", "tv"].contains(lower), index + 1 < rawParts.count else {
        continue
      }
      let shortcode = rawParts[index + 1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/?&=#"))
      guard shortcode.count >= 5 else { continue }
      let marker = (lower == "reels") ? "reel" : lower
      return URL(string: "https://www.instagram.com/\(marker)/\(shortcode)/")
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

    let parts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }
    if let videosIndex = parts.firstIndex(where: {
      $0.caseInsensitiveCompare("videos") == .orderedSame
    }) {
      for part in parts.dropFirst(videosIndex + 1).reversed() {
        if let id = normalizedToken(part, minLength: 6, allowDigitsOnly: true) {
          return id
        }
      }
    }

    guard let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else { return nil }

    for key in ["v", "video_id", "story_fbid"] {
      if let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
        let id = normalizedToken(value, minLength: 6, allowDigitsOnly: true) {
        return id
      }
    }

    return nil
  }

  static func facebookVideoID(fromCandidateURL url: URL) -> String? {
    if let id = facebookVideoID(from: url) { return id }

    if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
      for key in ["item_id", "group_id"] {
        if let value = queryItems.first(where: { $0.name.lowercased() == key })?.value,
          let id = normalizedToken(value, minLength: 6, allowDigitsOnly: true) {
          return id
        }
      }
    }

    if let id = tokenFromRegex(facebookVideoPattern, in: url.absoluteString) {
      return id
    }

    return nil
  }
}
