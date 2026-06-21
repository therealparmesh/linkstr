import Foundation
import LinkPresentation
import UIKit

struct LinkPreviewData {
  let title: String?
  let thumbnailPath: String?
}

private enum URLMetadataTimingDefaults {
  static let providerTimeout: TimeInterval = 6
}

enum LinkMetadataRefreshPolicy {
  static func needsRefresh(
    linkType: LinkType,
    title: String?,
    thumbnailPath: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> Bool {
    guard normalizedTitle(title) != nil else { return true }
    guard let thumbnailPath else {
      return expectsThumbnail(linkType)
    }
    return !fileExists(thumbnailPath)
  }

  static func normalizedTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func expectsThumbnail(_ linkType: LinkType) -> Bool {
    switch linkType {
    case .tiktok, .instagram, .facebook, .youtube, .rumble, .twitter:
      return true
    case .generic:
      return false
    }
  }
}

final class URLMetadataService {
  static let shared = URLMetadataService()
  private init() {}

  func fetchPreview(for urlString: String) async -> LinkPreviewData? {
    guard let url = URL(string: urlString) else { return nil }

    if let twitterPreview = await twitterPreview(for: url) {
      return twitterPreview
    }

    if let socialPreview = await socialPostPreview(for: url) {
      return socialPreview
    }

    if let rumblePreview = await rumblePreview(for: url) {
      return rumblePreview
    }

    return await genericPreview(for: url)
  }

  private func twitterPreview(for url: URL) async -> LinkPreviewData? {
    guard SocialURLHeuristics.isTwitterStatusURL(url),
      let preview = await TwitterStatusResolutionService.shared.preview(for: url)
    else {
      return nil
    }

    let thumbnailPath = try? await thumbnailPath(for: url, remoteImageURL: preview.imageURL)
    guard preview.title != nil || thumbnailPath != nil else { return nil }
    return LinkPreviewData(title: preview.title, thumbnailPath: thumbnailPath)
  }

  private func socialPostPreview(for url: URL) async -> LinkPreviewData? {
    let linkType = URLClassifier.classify(url)
    guard linkType == .instagram || linkType == .tiktok || linkType == .facebook else { return nil }

    guard let social = await SocialPostResolutionService.shared.preview(for: url) else {
      return nil
    }

    let thumbnailPath = try? await thumbnailPath(for: url, remoteImageURL: social.imageURL)
    let title = social.authorName

    guard title != nil || thumbnailPath != nil else { return nil }
    return LinkPreviewData(title: title, thumbnailPath: thumbnailPath)
  }

  private func rumblePreview(for url: URL) async -> LinkPreviewData? {
    guard SocialURLHeuristics.isRumbleHost(url),
      SocialURLHeuristics.isRumbleVideoURL(url)
    else { return nil }

    var components = URLComponents(string: "https://rumble.com/api/Media/oembed.json")
    components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
    guard let requestURL = components?.url else { return nil }

    do {
      var request = URLRequest(url: requestURL)
      request.timeoutInterval = URLMetadataTimingDefaults.providerTimeout
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }

      let title = json["title"] as? String
      let authorName = json["author_name"] as? String
      let displayTitle = title ?? authorName

      var thumbnailPath: String?
      if let raw = json["thumbnail_url"] as? String, let imageURL = URL(string: raw) {
        thumbnailPath = try? await self.thumbnailPath(for: url, remoteImageURL: imageURL)
      }

      guard displayTitle != nil || thumbnailPath != nil else { return nil }
      return LinkPreviewData(title: displayTitle, thumbnailPath: thumbnailPath)
    } catch {
      return nil
    }
  }

  private func genericPreview(for url: URL) async -> LinkPreviewData? {
    let provider = LPMetadataProvider()
    provider.timeout = URLMetadataTimingDefaults.providerTimeout
    do {
      let metadata = try await provider.startFetchingMetadata(for: url)
      let title = metadata.title
      let thumbnailPath = try await thumbnailPath(for: url, provider: metadata.imageProvider)
      return LinkPreviewData(title: title, thumbnailPath: thumbnailPath)
    } catch {
      return nil
    }
  }

  private func thumbnailPath(for url: URL, provider: NSItemProvider?) async throws
    -> String? {
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

    return try writeThumbnailImage(image, sourceURL: url)
  }

  private func thumbnailPath(for url: URL, remoteImageURL: URL?) async throws -> String? {
    guard let remoteImageURL else { return nil }

    var request = URLRequest(url: remoteImageURL)
    request.timeoutInterval = URLMetadataTimingDefaults.providerTimeout
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      return nil
    }

    guard let image = UIImage(data: data) else { return nil }
    return try writeThumbnailImage(image, sourceURL: url)
  }

  private func writeThumbnailImage(_ image: UIImage, sourceURL: URL) throws -> String? {
    guard image.size != .zero else { return nil }
    guard let normalizedPNGData = image.pngData() else { return nil }
    let fileURL = ManagedLocalFileScope.shared.thumbnailFileURL(
      for: sourceURL.absoluteString.sha256Hex,
      fileExtension: "png"
    )
    try normalizedPNGData.write(to: fileURL, options: .atomic)
    ThumbnailImageCache.shared.removeImage(at: fileURL.path)
    return fileURL.path
  }
}
