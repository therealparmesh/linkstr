import AVFoundation
import Foundation

final class HLSDownloadManager: NSObject {
  static let shared = HLSDownloadManager()

  private var session: AVAssetDownloadURLSession!
  private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
  private var destinationURLByTaskID: [Int: URL] = [:]
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
    let destinationURL = ManagedLocalFileScope.shared.cachedHLSPackageURL(for: assetURL)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
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

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        continuations[task.taskIdentifier] = continuation
        destinationURLByTaskID[task.taskIdentifier] = destinationURL
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }
}

extension HLSDownloadManager: AVAssetDownloadDelegate {
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let taskIdentifier = assetDownloadTask.taskIdentifier
    lock.lock()
    guard let continuation = continuations.removeValue(forKey: taskIdentifier) else {
      lock.unlock()
      return
    }
    let destinationURL =
      destinationURLByTaskID.removeValue(forKey: taskIdentifier) ?? location
    lock.unlock()

    do {
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try? FileManager.default.removeItem(at: destinationURL)
      }
      try FileManager.default.moveItem(at: location, to: destinationURL)
      Task {
        await VideoCacheService.shared.registerCachedMedia(at: destinationURL)
        continuation.resume(returning: destinationURL)
      }
    } catch {
      continuation.resume(throwing: error)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    destinationURLByTaskID.removeValue(forKey: task.taskIdentifier)
    guard let continuation = continuations.removeValue(forKey: task.taskIdentifier), let error
    else {
      lock.unlock()
      return
    }
    lock.unlock()
    continuation.resume(throwing: error)
  }
}

enum HLSDownloadError: Error {
  case drmProtected
  case taskCreationFailed
}
