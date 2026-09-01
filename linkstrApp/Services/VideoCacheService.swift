import Foundation

struct ManagedStorageUsage: Equatable {
  let previewBytes: Int64
  let cachedMediaBytes: Int64

  static let zero = ManagedStorageUsage(previewBytes: 0, cachedMediaBytes: 0)
}

struct DeviceCacheUsage: Equatable {
  let thumbnailBytes: Int64
  let videoBytes: Int64
  let videoCacheLimitBytes: Int64
}

enum LocalFileMetrics {
  private static let fileResourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey,
    .fileSizeKey,
    .contentModificationDateKey
  ]

  static func allocatedSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
    let normalizedURL = normalized(url)
    guard fileManager.fileExists(atPath: normalizedURL.path) else { return 0 }

    guard let values = try? normalizedURL.resourceValues(forKeys: fileResourceKeys) else {
      return 0
    }

    if values.isDirectory == true {
      return directoryAllocatedSize(at: normalizedURL, fileManager: fileManager)
    }

    return fileAllocatedSize(values: values)
  }

  static func contentModificationDate(at url: URL) -> Date? {
    try? normalized(url).resourceValues(forKeys: fileResourceKeys).contentModificationDate
  }

  static func touch(_ url: URL, date: Date = .now, fileManager: FileManager = .default) {
    let normalizedURL = normalized(url)
    guard fileManager.fileExists(atPath: normalizedURL.path) else { return }
    try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: normalizedURL.path)
  }

  private static func directoryAllocatedSize(at url: URL, fileManager: FileManager) -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: Array(fileResourceKeys),
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: fileResourceKeys) else { continue }
      guard values.isDirectory != true else { continue }
      total += fileAllocatedSize(values: values)
    }
    return total
  }

  private static func fileAllocatedSize(values: URLResourceValues) -> Int64 {
    if let fileSize = values.fileSize {
      return Int64(fileSize)
    }
    return 0
  }

  private static func normalized(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}

actor VideoCacheService {
  private struct CachedVideoEntry {
    let url: URL
    let bytes: Int64
    let lastAccessedAt: Date
  }

  static let defaultMaxVideoCacheBytes: Int64 = 1_000_000_000
  static let shared = VideoCacheService(
    thumbnailDirectory: ManagedLocalFileScope.shared.thumbnailDirectory,
    videoDirectory: ManagedLocalFileScope.shared.videoDirectory
  )

  private let fileManager: FileManager
  private let thumbnailDirectory: URL
  private let videoDirectory: URL
  private let maxVideoCacheBytes: Int64
  private var runningVideoBytes: Int64?

  init(
    thumbnailDirectory: URL,
    videoDirectory: URL,
    fileManager: FileManager = .default,
    maxVideoCacheBytes: Int64 = defaultMaxVideoCacheBytes
  ) {
    self.fileManager = fileManager
    self.thumbnailDirectory = Self.normalized(url: thumbnailDirectory)
    self.videoDirectory = Self.normalized(url: videoDirectory)
    self.maxVideoCacheBytes = maxVideoCacheBytes
  }

  func currentUsage() -> DeviceCacheUsage {
    DeviceCacheUsage(
      thumbnailBytes: LocalFileMetrics.allocatedSize(
        at: thumbnailDirectory, fileManager: fileManager),
      videoBytes: LocalFileMetrics.allocatedSize(at: videoDirectory, fileManager: fileManager),
      videoCacheLimitBytes: maxVideoCacheBytes
    )
  }

  func registerCachedMedia(at fileURL: URL) {
    guard let normalizedURL = normalizedVideoCacheURL(fileURL) else { return }
    LocalFileMetrics.touch(normalizedURL, fileManager: fileManager)
    runningVideoBytes = nil
    enforceVideoCacheLimitIfNeeded(preserving: normalizedURL)
  }

  func touchCachedMedia(at fileURL: URL) {
    guard let normalizedURL = normalizedVideoCacheURL(fileURL) else { return }
    LocalFileMetrics.touch(normalizedURL, fileManager: fileManager)
  }

  private func cachedFileURL(for remoteURL: URL, preferredExtension: String) -> URL {
    ManagedLocalFileScope.shared.cachedVideoFileURL(
      for: remoteURL,
      preferredExtension: preferredExtension
    )
  }

  func downloadMP4(from remoteURL: URL, headers: [String: String]) async throws -> URL {
    let destination = cachedFileURL(for: remoteURL, preferredExtension: "mp4")
    if fileManager.fileExists(atPath: destination.path) {
      registerCachedMedia(at: destination)
      return destination
    }

    var request = URLRequest(url: remoteURL)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

    let (tmpURL, response) = try await URLSession.shared.download(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }

    if fileManager.fileExists(atPath: destination.path) {
      try? fileManager.removeItem(at: destination)
    }

    try fileManager.moveItem(at: tmpURL, to: destination)
    registerCachedMedia(at: destination)
    return destination
  }

  private func enforceVideoCacheLimitIfNeeded(preserving preservedURL: URL?) {
    if let cached = runningVideoBytes, cached <= maxVideoCacheBytes {
      return
    }

    let entries = cachedVideoEntriesSortedByLastAccess()
    guard !entries.isEmpty else { return }

    var totalBytes = entries.reduce(into: Int64(0)) { $0 += $1.bytes }
    runningVideoBytes = totalBytes
    guard totalBytes > maxVideoCacheBytes else { return }

    let preservedPath = preservedURL.map { Self.normalized(url: $0).path }

    for entry in entries {
      if entry.url.path == preservedPath {
        continue
      }

      try? fileManager.removeItem(at: entry.url)
      totalBytes -= entry.bytes
      if totalBytes <= maxVideoCacheBytes {
        break
      }
    }
    runningVideoBytes = totalBytes
  }

  private func cachedVideoEntriesSortedByLastAccess() -> [CachedVideoEntry] {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: videoDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return
      contents
      .map { url in
        CachedVideoEntry(
          url: Self.normalized(url: url),
          bytes: LocalFileMetrics.allocatedSize(at: url, fileManager: fileManager),
          lastAccessedAt: LocalFileMetrics.contentModificationDate(at: url) ?? .distantPast
        )
      }
      .sorted { lhs, rhs in
        if lhs.lastAccessedAt == rhs.lastAccessedAt {
          return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return lhs.lastAccessedAt < rhs.lastAccessedAt
      }
  }

  private func normalizedVideoCacheURL(_ url: URL) -> URL? {
    let normalizedURL = Self.normalized(url: url)
    let candidatePath = normalizedURL.path
    let rootPath = videoDirectory.path
    guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
      return nil
    }
    return normalizedURL
  }

  private static func normalized(url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}
