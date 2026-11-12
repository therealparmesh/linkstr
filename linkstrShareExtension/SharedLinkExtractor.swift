import Foundation
import UniformTypeIdentifiers

struct ExtractedShare {
  let url: String
  let note: String?
}

enum SharedLinkExtractor {
  private struct ProviderCandidate {
    let provider: NSItemProvider
    let typeIdentifier: String
  }

  private static let preferredTypeIdentifiers = [
    UTType.url.identifier,
    UTType.plainText.identifier,
    UTType.text.identifier
  ]

  static func extract(
    from extensionContext: NSExtensionContext?,
    completion: @escaping (ExtractedShare?) -> Void
  ) {
    guard let extensionContext else {
      completion(nil)
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
    completion: @escaping (ExtractedShare?) -> Void
  ) {
    guard index < candidates.count else {
      completion(directTexts.lazy.compactMap(share(fromText:)).first)
      return
    }

    let candidate = candidates[index]
    candidate.provider.loadItem(
      forTypeIdentifier: candidate.typeIdentifier, options: nil
    ) { item, _ in
      DispatchQueue.main.async {
        if let item, let share = share(from: item) {
          completion(share)
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

  private static func share(from item: Any) -> ExtractedShare? {
    if let url = item as? URL {
      guard let normalizedURL = LinkstrDeepLinkCodec.webURL(fromInput: url.absoluteString) else { return nil }
      return ExtractedShare(url: normalizedURL, note: nil)
    }

    if let string = item as? String {
      return share(fromText: string)
    }

    if let attributedString = item as? NSAttributedString {
      return share(fromText: attributedString.string)
    }

    if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
      return share(fromText: string)
    }

    if let dictionary = item as? NSDictionary {
      return dictionary.allValues.lazy.compactMap(share(from:)).first
    }

    if let array = item as? NSArray {
      return array.lazy.compactMap(share(from:)).first
    }

    return nil
  }

  private static func share(fromText text: String) -> ExtractedShare? {
    guard let normalized = normalizedText(text) else { return nil }

    if !normalized.contains(where: \.isWhitespace), let directURL = LinkstrDeepLinkCodec.webURL(fromInput: normalized) {
      return ExtractedShare(url: directURL, note: nil)
    }

    guard let detector = linkDetector else { return nil }
    let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    for match in detector.matches(in: normalized, options: [], range: nsRange) {
      guard let matchedURL = match.url else { continue }
      guard let url = LinkstrDeepLinkCodec.webURL(fromInput: matchedURL.absoluteString) else {
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
    return LinkstrDeepLinkCodec.normalizedNote(note)
  }

  private static func normalizedText(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static let linkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )
}
