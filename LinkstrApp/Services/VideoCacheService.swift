import CryptoKit
import Foundation

final class VideoCacheService {
  static let shared = VideoCacheService()

  private let fileManager = FileManager.default
  private let cacheDirectory: URL

  private init() {
    let base =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    cacheDirectory = base.appendingPathComponent("linkstr_videos", isDirectory: true)

    if !fileManager.fileExists(atPath: cacheDirectory.path) {
      try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
  }

  func clearAll() {
    try? fileManager.removeItem(at: cacheDirectory)
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
  }

  func cachedFileURL(for remoteURL: URL, preferredExtension: String) -> URL {
    let fileName = remoteURL.absoluteString.sha256Hex
    return cacheDirectory.appendingPathComponent(fileName).appendingPathExtension(
      preferredExtension)
  }

  func downloadMP4(from remoteURL: URL, headers: [String: String]) async throws -> URL {
    let destination = cachedFileURL(for: remoteURL, preferredExtension: "mp4")
    if fileManager.fileExists(atPath: destination.path) {
      return destination
    }

    var request = URLRequest(url: remoteURL)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

    let (tmpURL, response) = try await URLSession.shared.download(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }

    if fileManager.fileExists(atPath: destination.path) {
      try? fileManager.removeItem(at: destination)
    }

    try fileManager.moveItem(at: tmpURL, to: destination)
    return destination
  }
}

extension String {
  fileprivate var sha256Hex: String {
    let digest = SHA256.hash(data: Data(self.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
