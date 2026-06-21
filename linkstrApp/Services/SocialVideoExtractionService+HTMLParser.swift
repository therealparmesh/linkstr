import Foundation

enum SocialPostHTMLParser {
  enum InstagramMediaKind: Equatable {
    case video
    case nonVideo
    case unknown
  }

  static func instagramPreview(from html: String) -> SocialPostPreview? {
    let bodyText = instagramBodyText(from: html)
    let authorName = instagramAuthorName(from: html)
    let imageURL = instagramImageURL(from: html)
    guard bodyText != nil || authorName != nil || imageURL != nil else { return nil }
    return SocialPostPreview(bodyText: bodyText, authorName: authorName, imageURL: imageURL)
  }

  static func instagramMediaKind(from html: String) -> InstagramMediaKind {
    let ogType = extractMetaContent(from: html, property: "og:type")?.lowercased()
    let medium = extractMetaContent(from: html, name: "medium")?.lowercased()
    let twitterTitle = extractMetaContent(from: html, name: "twitter:title")?.lowercased()

    let videoSignals = [
      extractMetaContent(from: html, property: "og:video"),
      extractMetaContent(from: html, property: "og:video:url"),
      extractMetaContent(from: html, property: "og:video:secure_url")
    ].contains { value in
      guard let value else { return false }
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    if videoSignals
      || ogType?.contains("video") == true
      || medium?.contains("video") == true
      || twitterTitle?.contains("instagram video") == true
      || twitterTitle?.contains("instagram reel") == true {
      return .video
    }

    if ogType?.contains("photo") == true
      || ogType?.contains("image") == true
      || medium?.contains("photo") == true
      || medium?.contains("image") == true
      || twitterTitle?.contains("instagram photo") == true {
      return .nonVideo
    }

    return .unknown
  }

  static func tikTokPreview(from json: [String: Any]) -> SocialPostPreview? {
    let title = normalizedText(json["title"] as? String)
    let authorName = normalizedText(json["author_name"] as? String)
    let imageURL: URL?
    if let raw = normalizedText(json["thumbnail_url"] as? String),
      raw.lowercased().hasPrefix("https://") {
      imageURL = URL(string: raw)
    } else {
      imageURL = nil
    }
    guard title != nil || authorName != nil || imageURL != nil else { return nil }
    return SocialPostPreview(bodyText: title, authorName: authorName, imageURL: imageURL)
  }

  static func facebookPreview(from html: String) -> SocialPostPreview? {
    let bodyText = facebookBodyText(from: html)
    let authorName = facebookAuthorName(from: html)
    let imageURL = facebookImageURL(from: html)
    guard bodyText != nil || authorName != nil || imageURL != nil else { return nil }
    return SocialPostPreview(bodyText: bodyText, authorName: authorName, imageURL: imageURL)
  }

  // MARK: - Facebook HTML parsing

  private static func facebookBodyText(from html: String) -> String? {
    if let ogDescription = extractMetaContent(from: html, property: "og:description") {
      return normalizedText(ogDescription)
    }
    return nil
  }

  private static func facebookAuthorName(from html: String) -> String? {
    guard let ogTitle = extractMetaContent(from: html, property: "og:title") else { return nil }
    let parts = ogTitle.components(separatedBy: " | ")
    guard parts.count >= 3 else { return nil }
    let candidate = parts[parts.count - 2]
    return normalizedText(candidate)
  }

  private static func facebookImageURL(from html: String) -> URL? {
    guard let raw = extractMetaContent(from: html, property: "og:image") else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("https://") else { return nil }
    return URL(string: trimmed)
  }

  // MARK: - Instagram HTML parsing

  private static func instagramBodyText(from html: String) -> String? {
    if let ogDescription = extractMetaContent(from: html, property: "og:description") {
      let cleaned = stripInstagramDescriptionPrefix(ogDescription)
      if let normalized = normalizedText(cleaned) {
        return normalized
      }
    }

    if let ogTitle = extractMetaContent(from: html, property: "og:title") {
      let cleaned = stripInstagramTitlePrefix(ogTitle)
      if let normalized = normalizedText(cleaned) {
        return normalized
      }
    }

    return nil
  }

  private static func instagramImageURL(from html: String) -> URL? {
    guard let raw = extractMetaContent(from: html, property: "og:image") else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("https://") else { return nil }
    return URL(string: trimmed)
  }

  private static func instagramAuthorName(from html: String) -> String? {
    if let twitterTitle = extractMetaContent(from: html, name: "twitter:title") {
      let cleaned =
        twitterTitle
        .replacingOccurrences(of: " \u{2022} Instagram reel", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram photo", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram video", with: "")
        .replacingOccurrences(of: " \u{2022} Instagram", with: "")
        .replacingOccurrences(of: " • Instagram reel", with: "")
        .replacingOccurrences(of: " • Instagram photo", with: "")
        .replacingOccurrences(of: " • Instagram video", with: "")
        .replacingOccurrences(of: " • Instagram", with: "")
      return normalizedText(cleaned)
    }
    return nil
  }

  private static func stripInstagramDescriptionPrefix(_ text: String) -> String {
    let quoteColonPatterns = ["\": \"", "\": \u{201c}", ":\u{00a0}\u{201c}", ": \""]
    for pattern in quoteColonPatterns {
      if let range = text.range(of: pattern) {
        var caption = String(text[range.upperBound...])
        caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["\". ", "\".", "\u{201d}. ", "\u{201d}.", "\"", "\u{201d}"]
        where caption.hasSuffix(suffix) {
          caption = String(caption.dropLast(suffix.count))
          break
        }
        caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { return caption }
      }
    }
    return text
  }

  private static func stripInstagramTitlePrefix(_ text: String) -> String {
    let pattern = " on Instagram: "
    if let range = text.range(of: pattern, options: .caseInsensitive) {
      var caption = String(text[range.upperBound...])
      caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
      for (open, close) in [("\"", "\""), ("\u{201c}", "\u{201d}")] {
        if caption.hasPrefix(open), caption.hasSuffix(close), caption.count > 2 {
          caption = String(caption.dropFirst(open.count).dropLast(close.count))
          break
        }
      }
      caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
      if !caption.isEmpty { return caption }
    }
    return text
  }

  // MARK: - HTML meta tag extraction

  static func extractMetaContent(from html: String, property: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: property)
    let forwardPattern =
      #"<meta\s+property="\#(escaped)"[^>]*?\s+content="([^"]*)"#
    if let result = firstRegexCapture(in: html, pattern: forwardPattern) {
      return HTMLTextDecoder.decodeHTMLEntities(result)
    }
    let reversePattern =
      #"<meta\s+content="([^"]*)"[^>]*?\s+property="\#(escaped)""#
    return firstRegexCapture(in: html, pattern: reversePattern)
      .map(HTMLTextDecoder.decodeHTMLEntities)
  }

  static func extractMetaContent(from html: String, name: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let forwardPattern =
      #"<meta\s+name="\#(escaped)"[^>]*?\s+content="([^"]*)"#
    if let result = firstRegexCapture(in: html, pattern: forwardPattern) {
      return HTMLTextDecoder.decodeHTMLEntities(result)
    }
    let reversePattern =
      #"<meta\s+content="([^"]*)"[^>]*?\s+name="\#(escaped)""#
    return firstRegexCapture(in: html, pattern: reversePattern)
      .map(HTMLTextDecoder.decodeHTMLEntities)
  }

  private static func firstRegexCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: nsRange),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[captureRange])
  }

  static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
