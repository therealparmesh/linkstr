import AVFoundation
import Foundation

final class HLSDownloadManager: NSObject {
  static let shared = HLSDownloadManager()

  private var session: AVAssetDownloadURLSession!
  private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]

  private override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: "com.parmscript.linkstr.hls")
    session = AVAssetDownloadURLSession(
      configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
  }

  func download(assetURL: URL, headers: [String: String]) async throws -> URL {
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
      task.resume()
    }
  }
}

extension HLSDownloadManager: AVAssetDownloadDelegate {
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    if let continuation = continuations.removeValue(forKey: assetDownloadTask.taskIdentifier) {
      continuation.resume(returning: location)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
