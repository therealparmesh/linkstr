import Darwin
import Foundation

enum LinkstrURLValidator {
  static func normalizedWebURL(from rawValue: String) -> String? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = candidateWebURLString(from: trimmed)

    guard let components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let canonicalURL = components.url,
      let canonicalHost = canonicalURL.host?.lowercased(),
      isCredibleWebHost(canonicalHost)
    else {
      return nil
    }

    return canonicalURL.absoluteString
  }

  private static func candidateWebURLString(from value: String) -> String {
    let lowercased = value.lowercased()
    if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
      return value
    }

    if value.hasPrefix("//") {
      return "https:\(value)"
    }

    if value.contains("://") {
      return value
    }

    if value.hasPrefix("[") {
      return "https://\(value)"
    }

    let authorityLikeSegment = value.prefix { character in
      character != "/" && character != "?" && character != "#"
    }

    if let colonIndex = authorityLikeSegment.firstIndex(of: ":") {
      let prefix = String(authorityLikeSegment[..<colonIndex]).lowercased()
      if prefix == "localhost" || prefix.contains(".") || isIPv4Literal(prefix) {
        return "https://\(value)"
      }
      return value
    }

    return "https://\(value)"
  }

  private static func isCredibleWebHost(_ host: String) -> Bool {
    let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !normalizedHost.isEmpty else { return false }

    if normalizedHost == "localhost" {
      return true
    }

    if isIPv4Literal(normalizedHost) || isIPv6Literal(normalizedHost) {
      return true
    }

    let labels = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }

    return labels.allSatisfy { label in
      guard let first = label.first, let last = label.last else { return false }
      guard first != "-", last != "-" else { return false }
      return label.allSatisfy { character in
        character.isLetter || character.isNumber || character == "-"
      }
    }
  }

  private static func isIPv4Literal(_ value: String) -> Bool {
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
  }

  private static func isIPv6Literal(_ value: String) -> Bool {
    var address = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
  }
}
