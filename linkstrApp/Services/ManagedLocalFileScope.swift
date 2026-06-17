import CryptoKit
import Foundation

final class ManagedLocalFileScope {
  static let shared = ManagedLocalFileScope()

  let thumbnailDirectory: URL
  let videoDirectory: URL

  private let fileManager = FileManager.default

  private init() {
    let cachesBase =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let supportBase =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? cachesBase

    thumbnailDirectory =
      supportBase
      .appendingPathComponent("linkstr", isDirectory: true)
      .appendingPathComponent("thumbnails", isDirectory: true)
    videoDirectory = cachesBase.appendingPathComponent("linkstr_videos", isDirectory: true)

    createDirectoryIfNeeded(thumbnailDirectory)
    createDirectoryIfNeeded(videoDirectory)
  }

  func thumbnailFileURL(for identifier: String, fileExtension: String) -> URL {
    thumbnailDirectory.appendingPathComponent(identifier).appendingPathExtension(fileExtension)
  }

  func cachedVideoFileURL(for remoteURL: URL, preferredExtension: String) -> URL {
    let fileName = remoteURL.absoluteString.sha256Hex
    return videoDirectory.appendingPathComponent(fileName).appendingPathExtension(
      preferredExtension)
  }

  func cachedHLSPackageURL(for remoteURL: URL) -> URL {
    let fileName = remoteURL.absoluteString.sha256Hex
    return videoDirectory.appendingPathComponent(fileName).appendingPathExtension("movpkg")
  }

  func managedFileURL(fromPath path: String?) -> URL? {
    guard let path else { return nil }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let candidate =
      URL(fileURLWithPath: trimmed, isDirectory: false)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    if isManagedFileURL(candidate) {
      return candidate
    }

    return rebasedManagedFileURL(forLegacyPath: candidate)
  }

  func normalizedManagedPath(_ path: String?) -> String? {
    managedFileURL(fromPath: path)?.path
  }

  func isManagedFileURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }

    let candidatePath =
      url
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    let roots = [thumbnailDirectory, videoDirectory].map {
      $0.standardizedFileURL.resolvingSymlinksInPath().path
    }

    return roots.contains { rootPath in
      candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
  }

  private func createDirectoryIfNeeded(_ directory: URL) {
    guard !fileManager.fileExists(atPath: directory.path) else { return }
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func rebasedManagedFileURL(forLegacyPath candidate: URL) -> URL? {
    guard looksLikeLegacyManagedPath(candidate) else { return nil }

    let fileName = candidate.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fileName.isEmpty else { return nil }

    for directory in rebasedSearchDirectories(forLegacyPath: candidate) {
      let rebased =
        directory
        .appendingPathComponent(fileName, isDirectory: candidate.hasDirectoryPath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      guard fileManager.fileExists(atPath: rebased.path), isManagedFileURL(rebased) else {
        continue
      }
      return rebased
    }

    return nil
  }

  private func looksLikeLegacyManagedPath(_ candidate: URL) -> Bool {
    let lowercasedPath = candidate.path.lowercased()
    return
      lowercasedPath.contains("/linkstr/")
      || lowercasedPath.contains("linkstr_videos")
      || lowercasedPath.contains("/thumbnails/")
      || lowercasedPath.contains("/videos/")
  }

  private func rebasedSearchDirectories(forLegacyPath candidate: URL) -> [URL] {
    let lowercasedPath = candidate.path.lowercased()
    if lowercasedPath.contains("/thumbnails/") {
      return [thumbnailDirectory, videoDirectory]
    }
    if lowercasedPath.contains("/videos/") || lowercasedPath.contains("linkstr_videos") {
      return [videoDirectory, thumbnailDirectory]
    }
    return [thumbnailDirectory, videoDirectory]
  }
}

extension String {
  var sha256Hex: String {
    let digest = SHA256.hash(data: Data(utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
