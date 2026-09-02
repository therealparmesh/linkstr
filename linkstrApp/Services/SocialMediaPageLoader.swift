import Foundation

struct LoadedSocialMediaPage: Sendable {
  let html: String?
  let finalURL: URL
}

enum SocialMediaPageLoader {
  static func load(
    _ url: URL,
    userAgent: String,
    stoppingAtRedirectThat shouldStopAtRedirect: (@Sendable (URL) -> Bool)? = nil
  ) async -> LoadedSocialMediaPage? {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout

    do {
      let redirectDelegate = shouldStopAtRedirect.map(RedirectCaptureDelegate.init)
      let data: Data
      let response: URLResponse
      if let redirectDelegate {
        (data, response) = try await URLSession.shared.data(
          for: request,
          delegate: redirectDelegate
        )
      } else {
        (data, response) = try await URLSession.shared.data(for: request)
      }
      if let redirectURL = redirectDelegate?.redirectURL {
        return LoadedSocialMediaPage(html: nil, finalURL: redirectURL)
      }
      if let httpResponse = response as? HTTPURLResponse,
        !(200..<400).contains(httpResponse.statusCode) {
        return nil
      }
      let html = String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
      return LoadedSocialMediaPage(html: html, finalURL: response.url ?? url)
    } catch {
      return nil
    }
  }
}

private final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let shouldStop: @Sendable (URL) -> Bool
  private let lock = NSLock()
  private var capturedRedirectURL: URL?

  init(shouldStop: @escaping @Sendable (URL) -> Bool) {
    self.shouldStop = shouldStop
  }

  var redirectURL: URL? {
    lock.lock()
    defer { lock.unlock() }
    return capturedRedirectURL
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, shouldStop(url) else {
      completionHandler(request)
      return
    }
    lock.lock()
    capturedRedirectURL = url
    lock.unlock()
    completionHandler(nil)
  }
}
