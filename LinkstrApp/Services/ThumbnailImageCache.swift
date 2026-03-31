import UIKit

final class ThumbnailImageCache: @unchecked Sendable {
  static let shared = ThumbnailImageCache()
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
      guard let image = UIImage(contentsOfFile: path) else { return nil as UIImage? }
      let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
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
