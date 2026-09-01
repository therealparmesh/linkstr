import Foundation

extension URLCanonicalizationService {
  static func facebookLoginNextURL(from url: URL) -> URL? {
    guard SocialURLHeuristics.isFacebookHost(url) else { return nil }

    let parts = url.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
      .filter { !$0.isEmpty }
    guard parts.first == "login" else { return nil }

    guard
      let rawNext = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name.lowercased() == "next" })?.value
    else {
      return nil
    }

    if let nextURL = URL(string: rawNext) {
      return nextURL
    }
    if let decoded = rawNext.removingPercentEncoding {
      return URL(string: decoded)
    }
    return nil
  }

  func fallbackCanonicalFacebookURL(from sourceURL: URL) -> URL? {
    let parts = sourceURL.pathComponents
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }

    guard parts.count >= 3, parts[0].lowercased() == "share" else {
      return nil
    }

    let marker = parts[1].lowercased()
    let token = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return nil }

    switch marker {
    case "r", "reel":
      guard token.allSatisfy(\.isNumber) else { return nil }
      return URL(string: "https://www.facebook.com/reel/\(token)/")
    case "v":
      guard token.allSatisfy(\.isNumber) else { return nil }
      var components = URLComponents(string: "https://www.facebook.com/watch/")
      components?.queryItems = [URLQueryItem(name: "v", value: token)]
      return components?.url
    default:
      return nil
    }
  }

  static func normalizedEmbeddedURL(_ raw: String) -> String {
    HTMLTextDecoder.decodeHTMLEntities(raw)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\/", with: "/")
  }
}
