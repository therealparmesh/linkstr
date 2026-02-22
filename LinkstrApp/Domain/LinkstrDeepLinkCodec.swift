import Foundation

enum LinkstrDeepLinkCodec {
  private static let payloadQueryKey = "p"
  private static let appDeepLinkScheme = "linkstr"
  private static let appDeepLinkHost = "open"

  static func makeAppDeepLink(payload: LinkstrDeepLinkPayload) -> URL? {
    guard let token = encode(payload) else {
      return nil
    }

    var components = URLComponents()
    components.scheme = appDeepLinkScheme
    components.host = appDeepLinkHost
    components.queryItems = [
      URLQueryItem(name: payloadQueryKey, value: token)
    ]
    return components.url
  }

  static func parsePayload(fromAppDeepLink url: URL) -> LinkstrDeepLinkPayload? {
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
      let token = components.queryItems?.first(where: { $0.name == payloadQueryKey })?.value
    else {
      return nil
    }

    guard let payload = decode(token) else {
      return nil
    }

    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: payload.url) else {
      return nil
    }

    return LinkstrDeepLinkPayload(
      url: normalizedURL,
      timestamp: payload.timestamp,
      messageGUID: payload.messageGUID
    )
  }

  private static func encode(_ payload: LinkstrDeepLinkPayload) -> String? {
    guard let data = try? JSONEncoder().encode(payload) else {
      return nil
    }

    return
      data
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decode(_ token: String) -> LinkstrDeepLinkPayload? {
    var base64 =
      token
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    let remainder = base64.count % 4
    if remainder != 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: base64) else {
      return nil
    }

    return try? JSONDecoder().decode(LinkstrDeepLinkPayload.self, from: data)
  }
}
