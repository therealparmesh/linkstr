import Foundation
import LinkPresentation
import UIKit

struct LinkPreviewData {
  let title: String?
  let thumbnailPath: String?
}

final class URLMetadataService {
  static let shared = URLMetadataService()
  private static let providerTimeout: TimeInterval = 6.0
  private init() {}

  func fetchPreview(for urlString: String) async -> LinkPreviewData? {
    guard let url = URL(string: urlString) else { return nil }
    let provider = LPMetadataProvider()
    provider.timeout = Self.providerTimeout
    do {
      let metadata = try await provider.startFetchingMetadata(for: url)
      let title = metadata.title
      let thumbnailPath = try await makeThumbnailPath(
        urlString: urlString, provider: metadata.imageProvider)
      return LinkPreviewData(title: title, thumbnailPath: thumbnailPath)
    } catch {
      return nil
    }
  }

  private func makeThumbnailPath(urlString: String, provider: NSItemProvider?) async throws
    -> String?
  {
    guard let provider else { return nil }
    guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }

    let image: UIImage = try await withCheckedThrowingContinuation { continuation in
      provider.loadObject(ofClass: UIImage.self) { object, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let image = object as? UIImage else {
          continuation.resume(throwing: URLError(.cannotDecodeContentData))
          return
        }
        continuation.resume(returning: image)
      }
    }

    guard image.size != .zero else { return nil }
    guard let data = image.pngData() else { return nil }

    let fileURL = ManagedLocalFileScope.shared.thumbnailFileURL(
      for: urlString.sha256Hex,
      fileExtension: "png"
    )
    try data.write(to: fileURL, options: .atomic)
    return fileURL.path
  }
}
