import Foundation

final class VideoCacheService {
  static let shared = VideoCacheService()

  private let fileManager = FileManager.default

  private init() {}

  func cachedFileURL(for remoteURL: URL, preferredExtension: String) -> URL {
    ManagedLocalFileScope.shared.cachedVideoFileURL(
      for: remoteURL,
      preferredExtension: preferredExtension
    )
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
