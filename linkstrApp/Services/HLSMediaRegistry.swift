import Foundation

/// Remember system-owned HLS locations without moving the downloaded packages.
final class HLSMediaRegistry {
  private let root: URL
  private let defaults: UserDefaults
  private let lock = NSLock()
  private let key = "downloadedHLSPackages"

  init(root: URL = URL(fileURLWithPath: NSHomeDirectory()), defaults: UserDefaults = .standard) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.defaults = defaults
  }

  func cachedURL(for sourceURL: URL) -> URL? {
    lock.withLock {
      let paths = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
      return paths[sourceURL.absoluteString.sha256Hex].flatMap(packageURL)
    }
  }

  func register(_ location: URL, for sourceURL: URL) throws -> URL {
    try lock.withLock {
      guard let relativePath = relativePath(for: location) else { throw URLError(.badURL) }
      guard let package = packageURL(relativePath) else { throw URLError(.fileDoesNotExist) }
      var paths = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
      let sourceKey = sourceURL.absoluteString.sha256Hex
      if let existing = paths[sourceKey].flatMap(packageURL) {
        if existing.path != package.path { try? FileManager.default.removeItem(at: package) }
        return existing
      }
      paths[sourceKey] = relativePath
      defaults.set(paths, forKey: key)
      return package
    }
  }

  var registeredURLs: [URL] {
    lock.withLock {
      let paths = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
      let retained = paths.filter { packageURL($0.value) != nil }
      if retained.count != paths.count { defaults.set(retained, forKey: key) }
      return Array(Set(retained.values.compactMap(packageURL)))
    }
  }

  private func packageURL(_ relativePath: String) -> URL? {
    let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.path + "/"),
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { return nil }
    return url
  }

  private func relativePath(for location: URL) -> String? {
    guard location.isFileURL else { return nil }
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
    guard let rootValues = try? root.resourceValues(forKeys: keys),
      let rootFile = rootValues.fileResourceIdentifier as? NSObject,
      let rootVolume = rootValues.volumeIdentifier as? NSObject else { return nil }
    var cursor = location.standardizedFileURL.resolvingSymlinksInPath()
    var components: [String] = []
    // AVFoundation can return a filesystem alias of the app container.
    while cursor.path != "/" {
      if let values = try? cursor.resourceValues(forKeys: keys),
        rootFile.isEqual(values.fileResourceIdentifier), rootVolume.isEqual(values.volumeIdentifier) {
        return components.isEmpty ? nil : components.reversed().joined(separator: "/")
      }
      components.append(cursor.lastPathComponent)
      cursor.deleteLastPathComponent()
    }
    return nil
  }
}
