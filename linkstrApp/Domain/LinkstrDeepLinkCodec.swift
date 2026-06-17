import Foundation

enum LinkstrDeepLinkCodec {
  private static let urlQueryKey = "url"
  private static let appDeepLinkScheme = "linkstr"
  private static let appDeepLinkHost = "open"

  static func makeAppDeepLink(url: String?) -> URL? {
    guard let url, let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      return nil
    }

    var components = URLComponents()
    components.scheme = appDeepLinkScheme
    components.host = appDeepLinkHost
    components.queryItems = [
      URLQueryItem(name: urlQueryKey, value: normalizedURL)
    ]
    return components.url
  }

  static func parseURL(fromAppDeepLink url: URL) -> String? {
    guard url.scheme?.lowercased() == appDeepLinkScheme else {
      return nil
    }

    guard url.host?.lowercased() == appDeepLinkHost else {
      return nil
    }

    guard url.path.isEmpty || url.path == "/" else {
      return nil
    }

    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let encodedURL = components.queryItems?.first(where: { $0.name == urlQueryKey })?.value
    else {
      return nil
    }

    return LinkstrURLValidator.normalizedWebURL(from: encodedURL)
  }
}
