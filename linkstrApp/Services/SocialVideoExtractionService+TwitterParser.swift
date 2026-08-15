import Foundation

enum TwitterStatusResponseParser {
  static func mediaSummary(from json: [String: Any]) -> TwitterStatusMediaSummary {
    let mediaContainer = ((json["tweet"] as? [String: Any])?["media"] as? [String: Any]) ?? [:]
    let mediaEntries = mediaEntries(from: mediaContainer, fallbackJSON: json)
    let videoTypes = ["video", "animated_gif", "gif"]
    let hasTypedVideo = mediaEntries.contains { entry in
      guard let type = (entry["type"] as? String)?.lowercased() else { return false }
      return videoTypes.contains(type)
    }

    var candidateURLs: [URL] = []
    var seen = Set<String>()

    collectNestedMediaURLs(from: mediaContainer, into: &candidateURLs, seen: &seen)
    collectRootMediaURLs(from: json, into: &candidateURLs, seen: &seen)

    return TwitterStatusMediaSummary(
      candidateURLs: candidateURLs,
      hasVideo: hasTypedVideo || !candidateURLs.isEmpty,
      preview: preview(from: json)
    )
  }

  private static func mediaEntries(
    from container: [String: Any],
    fallbackJSON: [String: Any]
  ) -> [[String: Any]] {
    let keys = ["videos", "all", "media", "items", "photos"]
    for key in keys {
      if let entries = container[key] as? [[String: Any]], !entries.isEmpty {
        return entries
      }
    }

    if let entry = container["video"] as? [String: Any] {
      return [entry]
    }

    if let entries = fallbackJSON["media_extended"] as? [[String: Any]], !entries.isEmpty {
      return entries
    }

    if let entries = fallbackJSON["mediaDetails"] as? [[String: Any]], !entries.isEmpty {
      return entries
    }

    return []
  }

  private static func preview(from json: [String: Any]) -> TwitterStatusPreview? {
    let title = previewTitle(from: json)
    let bodyText = previewBodyText(from: json)
    let imageURL = previewImageURL(from: json)
    guard title != nil || bodyText != nil || imageURL != nil else { return nil }
    return TwitterStatusPreview(title: title, bodyText: bodyText, imageURL: imageURL)
  }

  private static func previewTitle(from json: [String: Any]) -> String? {
    if let tweet = json["tweet"] as? [String: Any],
      let author = tweet["author"] as? [String: Any] {
      return formattedPreviewTitle(
        name: author["name"] as? String,
        screenName: author["screen_name"] as? String
      )
    }

    if let user = json["user"] as? [String: Any] {
      return formattedPreviewTitle(
        name: user["name"] as? String,
        screenName: user["screen_name"] as? String
      )
    }

    return formattedPreviewTitle(
      name: json["user_name"] as? String,
      screenName: json["user_screen_name"] as? String
    )
  }

  private static func formattedPreviewTitle(name: String?, screenName: String?) -> String? {
    let trimmedName = normalizedText(name)
    let trimmedScreenName = normalizedText(screenName)

    switch (trimmedName, trimmedScreenName) {
    case (let name?, let screenName?):
      return "\(name) (@\(screenName))"
    case (let name?, nil):
      return name
    case (nil, let screenName?):
      return "@\(screenName)"
    case (nil, nil):
      return nil
    }
  }

  private static func previewImageURL(from json: [String: Any]) -> URL? {
    if let tweet = json["tweet"] as? [String: Any],
      let media = tweet["media"] as? [String: Any] {
      let preferredKeys = ["photos", "all", "videos", "media", "items"]
      for key in preferredKeys {
        if let entries = media[key] as? [[String: Any]],
          let url = firstPreviewURL(in: entries) {
          return url
        }
      }
    }

    if let entries = json["media_extended"] as? [[String: Any]],
      let url = firstPreviewURL(in: entries) {
      return url
    }

    if let rawURLs = json["mediaURLs"] as? [String] {
      for rawURL in rawURLs {
        if let url = validatedPreviewURL(from: rawURL) {
          return url
        }
      }
    }

    return nil
  }

  private static func previewBodyText(from json: [String: Any]) -> String? {
    if let tweet = json["tweet"] as? [String: Any] {
      for key in ["text", "full_text", "content"] {
        if let value = normalizedText(tweet[key] as? String) {
          return value
        }
      }
    }

    for key in ["text", "full_text", "tweetText"] {
      if let value = normalizedText(json[key] as? String) {
        return value
      }
    }

    return nil
  }

  private static func firstPreviewURL(in entries: [[String: Any]]) -> URL? {
    for entry in entries {
      let type = (entry["type"] as? String)?.lowercased()
      if type == "photo" || type == "image" {
        if let url = validatedPreviewURL(from: entry["url"] as? String) {
          return url
        }
        if let url = validatedPreviewURL(from: entry["thumbnail_url"] as? String) {
          return url
        }
      }
    }

    for entry in entries {
      if let url = validatedPreviewURL(from: entry["thumbnail_url"] as? String) {
        return url
      }
      if let url = validatedPreviewURL(from: entry["url"] as? String) {
        return url
      }
    }

    return nil
  }

  private static func collectMediaURL(
    _ rawValue: Any?,
    into urls: inout [URL],
    seen: inout Set<String>
  ) {
    guard let raw = rawValue as? String else { return }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = normalized.lowercased()
    guard lower.hasPrefix("https://"), SocialVideoExtractionService.isLikelyMediaURLString(lower),
      let url = URL(string: normalized),
      seen.insert(lower).inserted
    else {
      return
    }
    urls.append(url)
  }

  private static func collectNestedMediaURLs(
    from value: Any,
    into urls: inout [URL],
    seen: inout Set<String>
  ) {
    if let dictionary = value as? [String: Any] {
      for nestedValue in dictionary.values {
        collectNestedMediaURLs(from: nestedValue, into: &urls, seen: &seen)
      }
      return
    }

    if let array = value as? [Any] {
      for nestedValue in array {
        collectNestedMediaURLs(from: nestedValue, into: &urls, seen: &seen)
      }
      return
    }

    collectMediaURL(value, into: &urls, seen: &seen)
  }

  private static func collectRootMediaURLs(
    from json: [String: Any],
    into urls: inout [URL],
    seen: inout Set<String>
  ) {
    for key in ["media_extended", "mediaDetails", "media", "mediaURLs"] {
      guard let rootMediaValue = json[key] else { continue }
      collectNestedMediaURLs(from: rootMediaValue, into: &urls, seen: &seen)
    }
  }

  private static func validatedPreviewURL(from rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.lowercased().hasPrefix("https://") else { return nil }
    return URL(string: normalized)
  }

  private static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
