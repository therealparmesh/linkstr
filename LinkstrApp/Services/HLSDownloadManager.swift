import AVFoundation
import Foundation

final class HLSDownloadManager: NSObject {
  static let shared = HLSDownloadManager()

  private let fileManager = FileManager.default
  private var session: AVAssetDownloadURLSession!
  private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
  private var destinationURLByTaskID: [Int: URL] = [:]

  private override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: "com.parmscript.linkstr.hls")
    session = AVAssetDownloadURLSession(
      configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
  }

  func download(assetURL: URL, headers: [String: String]) async throws -> URL {
    let destinationURL = ManagedLocalFileScope.shared.cachedHLSPackageURL(for: assetURL)
    if fileManager.fileExists(atPath: destinationURL.path) {
      return destinationURL
    }

    let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: assetURL, options: options)
    let isProtected = try await asset.load(.hasProtectedContent)
    if isProtected {
      throw HLSDownloadError.drmProtected
    }

    guard
      let task = session.makeAssetDownloadTask(
        asset: asset, assetTitle: assetURL.lastPathComponent, assetArtworkData: nil, options: nil)
    else {
      throw HLSDownloadError.taskCreationFailed
    }

    return try await withCheckedThrowingContinuation { continuation in
      continuations[task.taskIdentifier] = continuation
      destinationURLByTaskID[task.taskIdentifier] = destinationURL
      task.resume()
    }
  }
}

extension HLSDownloadManager: AVAssetDownloadDelegate {
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let taskIdentifier = assetDownloadTask.taskIdentifier
    guard let continuation = continuations.removeValue(forKey: taskIdentifier) else { return }
    let destinationURL =
      destinationURLByTaskID.removeValue(forKey: taskIdentifier) ?? location

    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.removeItem(at: destinationURL)
      }
      try fileManager.moveItem(at: location, to: destinationURL)
      continuation.resume(returning: destinationURL)
    } catch {
      continuation.resume(throwing: error)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    destinationURLByTaskID.removeValue(forKey: task.taskIdentifier)
    guard let continuation = continuations.removeValue(forKey: task.taskIdentifier), let error
    else {
      return
    }
    continuation.resume(throwing: error)
  }
}

enum HLSDownloadError: Error {
  case drmProtected
  case taskCreationFailed
}
