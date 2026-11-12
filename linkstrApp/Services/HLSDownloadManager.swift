import AVFoundation
import Foundation

protocol HLSDownloadTask: AnyObject {
  var taskIdentifier: Int { get }
  func resume()
  func cancel()
}

extension URLSessionTask: HLSDownloadTask {}

final class HLSDownloadManager: NSObject {
  static let shared = HLSDownloadManager()

  private var session: AVAssetDownloadURLSession!
  private struct Download {
    let sourceURL: URL
    let continuation: CheckedContinuation<URL, Error>
    var location: URL?
  }
  private var downloads: [Int: Download] = [:]
  private let lock = NSLock()

  private override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: "com.parmscript.linkstr.hls")
    let delegateQueue = OperationQueue()
    delegateQueue.name = "com.parmscript.linkstr.hls-delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    session = AVAssetDownloadURLSession(
      configuration: config, assetDownloadDelegate: self, delegateQueue: delegateQueue)
  }

  func download(assetURL: URL, headers: [String: String]) async throws -> URL {
    if let destinationURL = ManagedLocalFileScope.shared.cachedHLSPackageURL(for: assetURL) {
      await VideoCacheService.shared.registerCachedMedia(at: destinationURL)
      return destinationURL
    }

    let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: assetURL, options: options)
    let isProtected = try await asset.load(.hasProtectedContent)
    try Task.checkCancellation()
    if isProtected {
      throw HLSDownloadError.drmProtected
    }

    guard
      let task = session.makeAssetDownloadTask(
        asset: asset, assetTitle: assetURL.lastPathComponent, assetArtworkData: nil, options: nil)
    else {
      throw HLSDownloadError.taskCreationFailed
    }

    return try await waitForDownload(task, sourceURL: assetURL)
  }

  func waitForDownload(_ task: any HLSDownloadTask, sourceURL: URL) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        guard !Task.isCancelled else {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        downloads[task.taskIdentifier] = Download(sourceURL: sourceURL, continuation: continuation)
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
      self.completeDownload(task.taskIdentifier, error: CancellationError())
    }
  }

  func recordLocation(_ location: URL, for taskID: Int) {
    let retained = lock.withLock {
      guard downloads[taskID] != nil else { return false }
      downloads[taskID]?.location = location
      return true
    }
    if !retained { try? FileManager.default.removeItem(at: location) }
  }

  func completeDownload(_ taskID: Int, error: Error?) {
    guard let download = lock.withLock({ downloads.removeValue(forKey: taskID) }) else { return }
    if let error {
      if let location = download.location { try? FileManager.default.removeItem(at: location) }
      download.continuation.resume(throwing: error)
      return
    }
    guard let location = download.location else {
      download.continuation.resume(throwing: URLError(.fileDoesNotExist))
      return
    }
    Task {
      do {
        let saved = try ManagedLocalFileScope.shared.hlsRegistry.register(location, for: download.sourceURL)
        await VideoCacheService.shared.registerCachedMedia(at: saved)
        download.continuation.resume(returning: saved)
      } catch {
        try? FileManager.default.removeItem(at: location)
        download.continuation.resume(throwing: error)
      }
    }
  }
}

extension HLSDownloadManager: AVAssetDownloadDelegate {
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    recordLocation(location, for: assetDownloadTask.taskIdentifier)
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    willDownloadTo location: URL
  ) {
    recordLocation(location, for: assetDownloadTask.taskIdentifier)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    completeDownload(task.taskIdentifier, error: error)
  }
}

enum HLSDownloadError: Error {
  case drmProtected
  case taskCreationFailed
}
