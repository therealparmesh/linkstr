import Foundation

struct PlayableMedia: Sendable {
  let playbackURL: URL
  let headers: [String: String]
  let isLocalFile: Bool
}

enum ExtractionState: Sendable {
  case ready([PlayableMedia])
  case cannotExtract(String)
}

enum SocialVideoTimingDefaults {
  static let localDiscoveryBudget: Duration = .seconds(60)
  static let requestTimeout: TimeInterval = 6
  static let webViewProbeTimeout: TimeInterval = 12
  static let candidateCollectionGracePeriod: TimeInterval = 1.5
}

enum HTMLTextDecoder {
  static func decodeHTMLEntities(_ text: String) -> String {
    var result =
      text
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
    result = replaceNumericHTMLEntities(result)
    return result
  }

  private static func replaceNumericHTMLEntities(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);|&#(\d+);"#) else {
      return text
    }
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    var result = text
    for match in regex.matches(in: text, range: fullRange).reversed() {
      guard let matchRange = Range(match.range, in: result) else { continue }
      let scalar: UInt32?
      if let hexRange = Range(match.range(at: 1), in: result) {
        scalar = UInt32(result[hexRange], radix: 16)
      } else if let decRange = Range(match.range(at: 2), in: result) {
        scalar = UInt32(result[decRange], radix: 10)
      } else {
        scalar = nil
      }
      guard let scalar, let unicode = Unicode.Scalar(scalar) else { continue }
      result.replaceSubrange(matchRange, with: String(unicode))
    }
    return result
  }
}

final class SocialVideoExtractionService: NSObject {
  static let shared = SocialVideoExtractionService()

  private override init() {
    super.init()
  }

  // MARK: - Shared resolution

  func resolvePlayableMedia(
    from candidates: [URL],
    sourceURL: URL,
    userAgent: String,
    cookies: [HTTPCookie]
  ) -> ExtractionState? {
    let viable = candidates.filter { url in
      guard url.scheme?.lowercased() == "https" else { return false }
      guard !isKnownBadCandidate(url) else { return false }
      return matchesSourceIdentity(url, sourceURL: sourceURL)
    }
    guard !viable.isEmpty else { return nil }

    let mediaList = viable.map { url in
      let headers = buildHeaders(
        for: url, sourcePageURL: sourceURL, cookies: cookies, userAgent: userAgent)
      return PlayableMedia(playbackURL: url, headers: headers, isLocalFile: false)
    }
    return .ready(mediaList)
  }

  private func matchesSourceIdentity(_ candidateURL: URL, sourceURL: URL) -> Bool {
    switch URLClassifier.classify(sourceURL) {
    case .tiktok:
      return candidateMatches(
        expectedID: SocialURLHeuristics.tikTokPostID(from: sourceURL),
        candidateID: SocialURLHeuristics.tikTokPostID(fromCandidateURL: candidateURL)
      )
    case .instagram:
      return candidateMatches(
        expectedID: SocialURLHeuristics.instagramPostID(from: sourceURL),
        candidateID: SocialURLHeuristics.instagramPostID(fromCandidateURL: candidateURL)
      )
    case .facebook:
      return candidateMatches(
        expectedID: SocialURLHeuristics.facebookVideoID(from: sourceURL),
        candidateID: SocialURLHeuristics.facebookVideoID(fromCandidateURL: candidateURL)
      )
    case .twitter:
      guard SocialURLHeuristics.isTwitterStatusURL(sourceURL) else { return true }
      let host = candidateURL.host?.lowercased() ?? ""
      return
        host == "twimg.com"
        || host.hasSuffix(".twimg.com")
        || SocialURLHeuristics.isTwitterHost(candidateURL)
    case .youtube, .rumble, .generic:
      return true
    }
  }

  private func candidateMatches(expectedID: String?, candidateID: String?) -> Bool {
    guard let expectedID, let candidateID else { return true }
    return expectedID == candidateID
  }

  // MARK: - Candidate ranking

  func rankCandidates(_ urls: [URL], sourceURL: URL) -> [URL] {
    urls
      .map { (url: $0, score: score(for: $0, sourceURL: sourceURL)) }
      .filter { $0.score > -30 }
      .sorted { lhs, rhs in
        if lhs.score == rhs.score {
          return lhs.url.absoluteString.count < rhs.url.absoluteString.count
        }
        return lhs.score > rhs.score
      }
      .map(\.url)
  }

  private func score(for url: URL, sourceURL: URL) -> Int {
    let value = url.absoluteString.lowercased()
    let host = url.host?.lowercased() ?? ""

    var score = 0
    score += formatScore(value: value)
    score += cdnHostScore(value: value, host: host)
    score += sourceHostBonus(host: host, sourceURL: sourceURL)
    score += providerIDScore(url: url, value: value, host: host, sourceURL: sourceURL)
    score += negativeSignalScore(value: value, host: host)
    return score
  }

  private func formatScore(value: String) -> Int {
    var score = 0
    if value.contains(".m3u8") { score += 35 }
    if value.contains(".mp4") { score += 30 }
    if value.contains("mime_type=video_mp4") { score += 15 }
    if value.contains("video") { score += 15 }
    if value.contains("play") { score += 10 }
    if value.contains("download") { score += 8 }
    return score
  }

  private func cdnHostScore(value: String, host: String) -> Int {
    var score = 0
    if host.contains("video") && host.contains("fbcdn") { score += 25 }
    if Self.isLikelyInstagramSignedVideoURLString(value) { score += 30 }
    if host.contains("cdninstagram") && value.contains(".mp4") { score += 25 }
    if host.contains("fbcdn") && value.contains(".mp4") { score += 20 }
    if host.hasSuffix("twimg.com") && host.contains("video") { score += 25 }
    if value.contains("/aweme/v1/play/") { score += 25 }
    if value.contains("/video/tos/") { score += 25 }
    if host.contains("tiktokcdn") || host.contains("byteoversea") || host.contains("akamaized") {
      score += 15
    }
    return score
  }

  private func sourceHostBonus(host: String, sourceURL: URL) -> Int {
    host == sourceURL.host?.lowercased() ? 5 : 0
  }

  private func providerIDScore(
    url: URL, value: String, host: String, sourceURL: URL
  ) -> Int {
    switch URLClassifier.classify(sourceURL) {
    case .tiktok:
      return tiktokIDScore(url: url, value: value, host: host, sourceURL: sourceURL)
    case .instagram:
      return instagramIDScore(url: url, value: value, host: host, sourceURL: sourceURL)
    case .facebook:
      return facebookIDScore(url: url, value: value, host: host, sourceURL: sourceURL)
    case .twitter, .youtube, .rumble, .generic:
      return 0
    }
  }
}

extension SocialVideoExtractionService {
  func mediaIdentityScore(
    expectedID: String?,
    candidateID: String?,
    value: String,
    host: String,
    allowedHostTokens: [String]
  ) -> Int {
    guard let expectedID else { return 0 }

    var score = value.contains(expectedID.lowercased()) ? 50 : 0
    if let candidateID {
      score += candidateID == expectedID ? 100 : -100
    }
    if !allowedHostTokens.contains(where: host.contains) {
      score -= 25
    }
    return score
  }

  private func negativeSignalScore(value: String, host: String) -> Int {
    var score = 0
    if Self.blockedPlaybackCandidateTokens.contains(where: value.contains) {
      score -= 40
    }
    if host.contains("cdninstagram")
      && !value.contains(".mp4")
      && !value.contains(".m3u8")
      && !Self.isLikelyInstagramSignedVideoURLString(value) {
      score -= 40
    }
    return score
  }

  private func isKnownBadCandidate(_ url: URL) -> Bool {
    let value = url.absoluteString.lowercased()
    return Self.blockedVisualAssetTokens.contains(where: value.contains)
  }

  // MARK: - Header construction

  private func buildHeaders(
    for mediaURL: URL,
    sourcePageURL: URL,
    cookies: [HTTPCookie],
    userAgent: String
  ) -> [String: String] {
    var headers: [String: String] = [
      "User-Agent": userAgent,
      "Accept": "*/*"
    ]

    headers["Referer"] = sourcePageURL.absoluteString
    if let scheme = sourcePageURL.scheme, let host = sourcePageURL.host {
      headers["Origin"] = "\(scheme)://\(host)"
    }

    guard let mediaHost = mediaURL.host?.lowercased() else {
      return headers
    }

    let cookieHeader =
      cookies
      .filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
          .lowercased()
        return mediaHost == domain || mediaHost.hasSuffix("." + domain)
      }
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")

    if !cookieHeader.isEmpty {
      headers["Cookie"] = cookieHeader
    }

    return headers
  }

  // MARK: - URL classification

  static func isLikelyMediaURLString(_ lower: String) -> Bool {
    // Generic video markers
    lower.contains(".m3u8")
      || lower.contains(".mp4")
      || lower.contains("mime_type=video_mp4")
      // TikTok
      || lower.contains("/aweme/v1/play/")
      || lower.contains("/video/tos/")
      || lower.contains("playaddr")
      || lower.contains("play_addr")
      // Facebook / Instagram CDN (host-level, not path-version-specific)
      || lower.contains("video.xx.fbcdn.net")
      || lower.contains("scontent.cdninstagram.com")
      || (lower.contains("cdninstagram.com") && lower.contains(".mp4"))
      || (lower.contains("fbcdn.net") && lower.contains("/video"))
      || isLikelyInstagramSignedVideoURLString(lower)
      // Twitter / X
      || lower.contains("video.twimg.com")
  }

  private static func isLikelyInstagramSignedVideoURLString(_ lower: String) -> Bool {
    guard lower.contains("cdninstagram.com") || lower.contains("fbcdn.net") else { return false }
    guard lower.contains("/o1/v/") else { return false }
    return !hasStaticImageExtension(lower)
  }

  private static func hasStaticImageExtension(_ lower: String) -> Bool {
    [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".heif"].contains {
      lower.contains($0)
    }
  }

  // MARK: - Static configuration

  static let desktopUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
  static let mobileUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  static let tikTokAPIUserAgent =
    "com.zhiliaoapp.musically/300904 "
    + "(2018111632; U; Android 10; en_US; Pixel 4; Build/QQ3A.200805.001; Cronet/58.0.2991.0)"
  static let tikTokFeedEndpoints = [
    "https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/feed/",
    "https://api16-normal-useast5.tiktokv.us/aweme/v1/feed/",
    "https://api19-normal-c-useast1a.tiktokv.com/aweme/v1/feed/",
    "https://api16-core-c-useast1a.tiktokv.com/aweme/v1/feed/",
    "https://api21-normal-c-useast2a.tiktokv.com/aweme/v1/feed/"
  ]
  static let blockedVisualAssetTokens = [
    "logo", "watermark", "avatar", "icon", "poster", "thumb", "sprite", "preview", "init"
  ]
  static let blockedPlaybackCandidateTokens =
    blockedVisualAssetTokens + ["audio", "mute", "sticker", "ads", "track"]
}

// MARK: - Local caching

extension SocialVideoExtractionService {
  func cachePlayableMediaLocally(_ media: PlayableMedia) async -> PlayableMedia? {
    guard !media.isLocalFile else {
      return media
    }
    guard media.playbackURL.scheme?.lowercased() == "https" else {
      return nil
    }

    do {
      if media.playbackURL.absoluteString.lowercased().contains(".m3u8") {
        let localURL = try await HLSDownloadManager.shared.download(
          assetURL: media.playbackURL,
          headers: media.headers
        )
        return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
      }

      let localURL = try await VideoCacheService.shared.downloadMP4(
        from: media.playbackURL,
        headers: media.headers
      )
      return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
    } catch {
      return nil
    }
  }
}
