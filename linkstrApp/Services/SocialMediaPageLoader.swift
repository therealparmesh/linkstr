import Foundation

struct LoadedSocialMediaPage: Sendable {
  let html: String?
  let finalURL: URL
}

enum SocialMediaPageLoader {
  static func load(_ url: URL, userAgent: String) async -> LoadedSocialMediaPage? {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    request.timeoutInterval = SocialVideoTimingDefaults.requestTimeout

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
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
