import UIKit

final class ThumbnailImageCache: @unchecked Sendable {
  static let shared = ThumbnailImageCache()
  private let cache = NSCache<NSString, UIImage>()

  private init() {
    cache.countLimit = 120
  }

  func loadImage(at path: String) -> UIImage? {
    if let cached = cache.object(forKey: path as NSString) {
      return cached
    }
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    cache.setObject(image, forKey: path as NSString)
    return image
  }

  func clear() {
    cache.removeAllObjects()
  }
}
