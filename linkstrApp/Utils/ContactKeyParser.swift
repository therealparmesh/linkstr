import Foundation
import NostrSDK

enum ContactKeyParser {
  private static let npubRegex: NSRegularExpression = {
    do {
      return try NSRegularExpression(pattern: #"npub1[023456789acdefghjklmnpqrstuvwxyz]{20,}"#)
    } catch {
      fatalError("Invalid regex: \(error)")
    }
  }()

  static func extractNPub(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if PublicKey(npub: trimmed) != nil {
      return trimmed
    }

    let withoutPrefix = trimmed.replacingOccurrences(
      of: "nostr:",
      with: "",
      options: [.caseInsensitive, .anchored]
    )
    if PublicKey(npub: withoutPrefix) != nil {
      return withoutPrefix
    }

    let nsRange = NSRange(withoutPrefix.startIndex..<withoutPrefix.endIndex, in: withoutPrefix)
    if let match = npubRegex.firstMatch(in: withoutPrefix, range: nsRange),
      let range = Range(match.range, in: withoutPrefix) {
      let token = String(withoutPrefix[range])
      if PublicKey(npub: token) != nil {
        return token
      }
    }

    if let components = URLComponents(string: trimmed) {
      for item in components.queryItems ?? [] where item.name.lowercased() == "npub" {
        if let value = item.value, PublicKey(npub: value) != nil {
          return value
        }
      }
    }

    return nil
  }
}
