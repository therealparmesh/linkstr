import Foundation
import UniformTypeIdentifiers

struct ExtractedShare {
  let url: String
  let note: String?
}

struct ProviderCandidate {
  let provider: NSItemProvider
  let typeIdentifier: String
}

enum ShareExtensionError: Error {
  case missingContext
  case noLinkFound
}

enum SharedLinkExtractor {
  private static let preferredTypeIdentifiers = [
    UTType.url.identifier,
    "public.url",
    UTType.plainText.identifier,
    UTType.text.identifier,
    "public.text"
  ].stableDeduplicated()

  static func extract(
    from extensionContext: NSExtensionContext?,
    completion: @escaping (Result<ExtractedShare, Error>) -> Void
  ) {
    guard let extensionContext else {
      completion(.failure(ShareExtensionError.missingContext))
      return
    }

    let extractionPlan = makeExtractionPlan(from: extensionContext.inputItems)
    loadFirstShare(
      from: extractionPlan.candidates,
      directTexts: extractionPlan.directTexts,
      at: 0,
      completion: completion
    )
  }

  private static func makeExtractionPlan(
    from inputItems: [Any]
  ) -> (candidates: [ProviderCandidate], directTexts: [String]) {
    var candidates: [ProviderCandidate] = []
    var directTexts: [String] = []

    for case let item as NSExtensionItem in inputItems {
      if let title = normalizedText(item.attributedTitle?.string) {
        directTexts.append(title)
      }
      if let contentText = normalizedText(item.attributedContentText?.string) {
        directTexts.append(contentText)
      }

      for provider in item.attachments ?? [] {
        for typeIdentifier in preferredTypeIdentifiers
        where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
          candidates.append(ProviderCandidate(provider: provider, typeIdentifier: typeIdentifier))
        }
      }
    }

    return (candidates, directTexts)
  }

  private static func loadFirstShare(
    from candidates: [ProviderCandidate],
    directTexts: [String],
    at index: Int,
    completion: @escaping (Result<ExtractedShare, Error>) -> Void
  ) {
    guard index < candidates.count else {
      if let directShare = directTexts.compactMap(share(fromText:)).first {
        completion(.success(directShare))
      } else {
        completion(.failure(ShareExtensionError.noLinkFound))
      }
      return
    }

    let candidate = candidates[index]
    candidate.provider.loadItem(
      forTypeIdentifier: candidate.typeIdentifier, options: nil
    ) { item, _ in
      DispatchQueue.main.async {
        if let item, let share = share(from: item) {
          completion(.success(share))
        } else {
          loadFirstShare(
            from: candidates,
            directTexts: directTexts,
            at: index + 1,
            completion: completion
          )
        }
      }
    }
  }

  private static func share(from item: NSSecureCoding) -> ExtractedShare? {
    if let url = item as? URL {
      return share(fromURLString: url.absoluteString, note: nil)
    }

    if let url = item as? NSURL {
      guard let absoluteString = url.absoluteString else { return nil }
      return share(fromURLString: absoluteString, note: nil)
    }

    if let string = item as? String {
      return share(fromText: string)
    }

    if let string = item as? NSString {
      return share(fromText: String(string))
    }

    if let attributedString = item as? NSAttributedString {
      return share(fromText: attributedString.string)
    }

    if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
      return share(fromText: string)
    }

    if let dictionary = item as? NSDictionary {
      return dictionary.allValues.compactMap {
        share(fromUnknownValue: $0)
      }.first
    }

    if let array = item as? NSArray {
      return array.compactMap {
        share(fromUnknownValue: $0)
      }.first
    }

    return nil
  }

  private static func share(fromUnknownValue value: Any) -> ExtractedShare? {
    if let value = value as? NSSecureCoding {
      return share(from: value)
    }
    if let string = value as? String {
      return share(fromText: string)
    }
    if let string = value as? NSString {
      return share(fromText: String(string))
    }
    return nil
  }

  private static func share(fromURLString urlString: String, note: String?) -> ExtractedShare? {
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: urlString) else {
      return nil
    }
    return ExtractedShare(url: normalizedURL, note: normalizedNote(note))
  }

  private static func share(fromText text: String) -> ExtractedShare? {
    guard let normalized = normalizedText(text) else { return nil }

    if let directURL = LinkstrURLValidator.normalizedWebURL(from: normalized) {
      return ExtractedShare(url: directURL, note: nil)
    }

    guard let detector = linkDetector else { return nil }
    let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    for match in detector.matches(in: normalized, options: [], range: nsRange) {
      guard let matchedURL = match.url else { continue }
      guard let url = LinkstrURLValidator.normalizedWebURL(from: matchedURL.absoluteString) else {
        continue
      }

      let note = noteByRemoving(range: match.range, from: normalized)
      return ExtractedShare(url: url, note: note)
    }

    return nil
  }

  private static func noteByRemoving(range: NSRange, from text: String) -> String? {
    guard let range = Range(range, in: text) else { return nil }
    var note = text
    note.removeSubrange(range)
    return normalizedNote(note)
  }

  private static func normalizedText(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedNote(_ note: String?) -> String? {
    let trimmed = normalizedText(note) ?? ""
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(4_000))
  }

  private static let linkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )
}

extension Array where Element: Hashable {
  func stableDeduplicated() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
