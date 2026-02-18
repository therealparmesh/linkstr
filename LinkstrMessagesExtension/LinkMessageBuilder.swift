import LinkPresentation
import Messages
import UIKit

enum LinkMessageBuilder {
  private static let metadataProviderTimeout: TimeInterval = 10

  @MainActor
  static func createMessage(normalizedURL: String) async -> MSMessage? {
    guard let sourceURL = URL(string: normalizedURL) else { return nil }

    let strategy = URLClassifier.mediaStrategy(for: sourceURL)
    guard strategy != .link else { return nil }

    let payload = LinkstrDeepLinkPayload(
      url: normalizedURL,
      timestamp: Int64(Date.now.timeIntervalSince1970),
      messageGUID: UUID().uuidString
    )

    guard let messageURL = LinkstrMessagePayloadCodec.makeMessageURL(payload: payload) else {
      return nil
    }

    guard let preview = await loadPreview(for: sourceURL) else {
      // Block send when preview metadata cannot be fetched in time.
      return nil
    }

    let layout = MSMessageTemplateLayout()
    let fallbackHost = cleanHost(for: sourceURL)
    if let title = preview.title, !title.isEmpty {
      layout.caption = title
      layout.subcaption = fallbackHost
    } else {
      layout.caption = fallbackHost
    }
    layout.image = preview.image

    let message = MSMessage()
    message.url = messageURL
    message.layout = layout
    message.summaryText = layout.caption ?? fallbackHost
    message.accessibilityLabel = "Linkstr video link"
    return message
  }

  private struct PreviewData {
    let title: String?
    let image: UIImage?
  }

  private static func loadPreview(for sourceURL: URL) async -> PreviewData? {
    await fetchPreview(for: sourceURL)
  }

  private static func fetchPreview(for sourceURL: URL) async -> PreviewData? {
    let provider = LPMetadataProvider()
    provider.timeout = metadataProviderTimeout

    return await withTaskCancellationHandler(
      operation: {
        do {
          let metadata = try await provider.startFetchingMetadata(for: sourceURL)
          let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
          let image = await loadUIImage(from: metadata.imageProvider)
          let icon = await loadUIImage(from: metadata.iconProvider)
          let previewImage = image ?? icon
          return PreviewData(title: title, image: previewImage)
        } catch {
          return nil
        }
      },
      onCancel: {
        provider.cancel()
      })
  }

  private static func loadUIImage(from itemProvider: NSItemProvider?) async -> UIImage? {
    guard let itemProvider else { return nil }
    guard itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }

    return await withCheckedContinuation { continuation in
      itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
        continuation.resume(returning: object as? UIImage)
      }
    }
  }

  private static func cleanHost(for sourceURL: URL) -> String {
    (sourceURL.host ?? "linkstr.app").replacingOccurrences(of: "www.", with: "")
  }
}
