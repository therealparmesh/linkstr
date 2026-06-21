import Foundation

enum LinkstrDeepLinkCodec {
  struct ShareDraft: Identifiable, Equatable {
    let url: String
    let note: String?

    var id: String {
      "\(url.count):\(url)|\(note?.count ?? 0):\(note ?? "")"
    }
  }

  struct MediaSaveDraft: Identifiable, Equatable {
    let url: String

    var id: String {
      url
    }
  }

  enum Route: Equatable {
    case openURL(String)
    case share(ShareDraft)
    case mediaSave(MediaSaveDraft)
  }

  private static let urlQueryKey = "url"
  private static let noteQueryKey = "note"
  private static let appDeepLinkScheme = "linkstr"
  private static let appDeepLinkHost = "open"
  private static let shareDeepLinkHost = "share"
  private static let mediaSaveDeepLinkHost = "save"
  private static let maximumNoteLength = 4_000

  static func makeAppDeepLink(url: String?) -> URL? {
    makeDeepLink(host: appDeepLinkHost, url: url, note: nil)
  }

  static func makeShareAppDeepLink(url: String?, note: String? = nil) -> URL? {
    makeDeepLink(host: shareDeepLinkHost, url: url, note: normalizedNote(note))
  }

  static func makeMediaSaveAppDeepLink(url: String?) -> URL? {
    makeDeepLink(host: mediaSaveDeepLinkHost, url: url, note: nil)
  }

  static func parseRoute(fromAppDeepLink url: URL) -> Route? {
    guard url.scheme?.lowercased() == appDeepLinkScheme else {
      return nil
    }

    guard url.path.isEmpty || url.path == "/" else {
      return nil
    }

    guard
      let host = url.host?.lowercased(),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let encodedURL = components.queryItems?.first(where: { $0.name == urlQueryKey })?.value,
      let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: encodedURL)
    else {
      return nil
    }

    switch host {
    case appDeepLinkHost:
      return .openURL(normalizedURL)
    case shareDeepLinkHost:
      let note = normalizedNote(
        components.queryItems?.first(where: { $0.name == noteQueryKey })?.value
      )
      return .share(ShareDraft(url: normalizedURL, note: note))
    case mediaSaveDeepLinkHost:
      return .mediaSave(MediaSaveDraft(url: normalizedURL))
    default:
      return nil
    }
  }

  static func parseURL(fromAppDeepLink url: URL) -> String? {
    guard case .openURL(let urlString) = parseRoute(fromAppDeepLink: url) else {
      return nil
    }
    return urlString
  }

  static func parseShareDraft(fromAppDeepLink url: URL) -> ShareDraft? {
    guard case .share(let draft) = parseRoute(fromAppDeepLink: url) else {
      return nil
    }
    return draft
  }

  static func parseMediaSaveDraft(fromAppDeepLink url: URL) -> MediaSaveDraft? {
    guard case .mediaSave(let draft) = parseRoute(fromAppDeepLink: url) else {
      return nil
    }
    return draft
  }

  private static func makeDeepLink(host: String, url: String?, note: String?) -> URL? {
    guard let url, let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      return nil
    }

    var components = URLComponents()
    components.scheme = appDeepLinkScheme
    components.host = host

    var queryItems = [
      URLQueryItem(name: urlQueryKey, value: normalizedURL)
    ]

    if let note {
      queryItems.append(URLQueryItem(name: noteQueryKey, value: note))
    }

    components.queryItems = queryItems
    return components.url
  }

  private static func normalizedNote(_ note: String?) -> String? {
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maximumNoteLength))
  }
}
