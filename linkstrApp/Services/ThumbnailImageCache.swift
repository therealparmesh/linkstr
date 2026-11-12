import ImageIO
import UIKit

final class ThumbnailImageCache: @unchecked Sendable {
  static let shared = ThumbnailImageCache()
  enum Size: Int, CaseIterable {
    case listRow = 256
    case preview = 512
  }

  private let cache = NSCache<NSString, UIImage>()
  private let lock = NSLock()
  private var inFlight: [String: Decode] = [:]

  private struct Decode {
    let id: UUID
    let task: Task<UIImage?, Never>
  }

  private init() {
    cache.countLimit = CacheLimits.maximumEntryCount
    cache.totalCostLimit = 50 * 1024 * 1024
  }

  func loadImageAsync(at path: String, size: Size = .preview) async -> UIImage? {
    let key = cacheKey(for: path, size: size)
    let (cached, task) = lock.withLock { () -> (UIImage?, Task<UIImage?, Never>?) in
      if let cached = cache.object(forKey: key as NSString) { return (cached, nil) }
      if let decode = inFlight[key] { return (nil, decode.task) }
      let id = UUID()
      let task = Task.detached(priority: .userInitiated) {
        self.finishDecode(Self.decode(path: path, size: size), for: key, id: id)
      }
      inFlight[key] = Decode(id: id, task: task)
      return (nil, task)
    }
    if let cached { return cached }
    return await task?.value
  }

  private static func decode(path: String, size: Size) -> CGImage? {
    let fileURL = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: size.rawValue
    ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }

  private func finishDecode(_ thumbnail: CGImage?, for key: String, id: UUID) -> UIImage? {
    lock.withLock {
      guard inFlight[key]?.id == id else { return nil }
      inFlight[key] = nil
      guard let thumbnail else { return nil }
      let image = UIImage(cgImage: thumbnail)
      let cost = thumbnail.bytesPerRow * thumbnail.height
      cache.setObject(image, forKey: key as NSString, cost: cost)
      return image
    }
  }

  func removeImage(at path: String) {
    lock.withLock {
      for size in Size.allCases {
        let key = cacheKey(for: path, size: size)
        inFlight.removeValue(forKey: key)?.task.cancel()
        cache.removeObject(forKey: key as NSString)
      }
    }
  }

  func clear() {
    lock.withLock {
      for decode in inFlight.values { decode.task.cancel() }
      inFlight.removeAll()
      cache.removeAllObjects()
    }
  }

  private func cacheKey(for path: String, size: Size) -> String {
    "\(size.rawValue):\(path)"
  }
}
