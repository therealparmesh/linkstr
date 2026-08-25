import ImageIO
import UIKit

final class ThumbnailImageCache: @unchecked Sendable {
  static let shared = ThumbnailImageCache()
  private static let maximumPixelSize = 512
  private let cache = NSCache<NSString, UIImage>()

  private init() {
    cache.countLimit = 120
    cache.totalCostLimit = 50 * 1024 * 1024
  }

  func loadImageAsync(at path: String) async -> UIImage? {
    if let cached = cache.object(forKey: path as NSString) {
      return cached
    }
    return await Task.detached(priority: .userInitiated) {
      let fileURL = URL(fileURLWithPath: path)
      guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
      let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize
      ] as CFDictionary
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
        return nil
      }
      let image = UIImage(cgImage: thumbnail)
      let cost = thumbnail.bytesPerRow * thumbnail.height
      self.cache.setObject(image, forKey: path as NSString, cost: cost)
      return image
    }.value
  }

  func removeImage(at path: String) {
    cache.removeObject(forKey: path as NSString)
  }

  func clear() {
    cache.removeAllObjects()
  }
}
