import Foundation
import NostrSDK

enum NostrProfileMetadata {
  static let maxChosenNameLength = 80

  static func normalizedChosenName(_ candidate: String?) -> String? {
    let rawValue = candidate ?? ""
    let filteredScalars = rawValue.unicodeScalars.filter { scalar in
      !CharacterSet.controlCharacters.contains(scalar)
    }
    let cleaned = String(String.UnicodeScalarView(filteredScalars))
    let collapsed =
      cleaned
      .components(separatedBy: CharacterSet.whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  static func validatedOwnChosenName(_ candidate: String?) throws -> String? {
    guard let normalized = normalizedChosenName(candidate) else { return nil }
    guard normalized.count <= maxChosenNameLength else {
      throw NostrProfileMetadataError.nameTooLong(maxLength: maxChosenNameLength)
    }
    return normalized
  }

  static func chosenName(from metadataEvent: MetadataEvent) -> String? {
    normalizedChosenName(metadataEvent.displayName) ?? normalizedChosenName(metadataEvent.name)
  }

  static func mergedContent(existingContent: String?, chosenName: String?) throws -> String {
    var metadata = decodedJSONObject(from: existingContent)
    let normalizedChosenName = normalizedChosenName(chosenName)

    if let normalizedChosenName {
      metadata["name"] = normalizedChosenName
      metadata["display_name"] = normalizedChosenName
    } else {
      metadata.removeValue(forKey: "name")
      metadata.removeValue(forKey: "display_name")
    }

    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    guard let content = String(data: data, encoding: .utf8) else {
      throw NostrProfileMetadataError.invalidContentEncoding
    }
    return content
  }

  private static func decodedJSONObject(from rawContent: String?) -> [String: Any] {
    guard let rawContent else { return [:] }
    let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
      return [:]
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }
}

enum NostrProfileMetadataError: LocalizedError {
  case invalidContentEncoding
  case nameTooLong(maxLength: Int)

  var errorDescription: String? {
    switch self {
    case .invalidContentEncoding:
      return "couldn't prepare your profile metadata. try again."
    case .nameTooLong(let maxLength):
      return "profile name must be \(maxLength) characters or fewer."
    }
  }
}
