import Foundation

@MainActor
final class DeepLinkHandler: ObservableObject {
  @Published var pendingURLString: String?

  @discardableResult
  func handle(url: URL) -> Bool {
    guard let pendingURLString = LinkstrDeepLinkCodec.parseURL(fromAppDeepLink: url) else {
      return false
    }

    self.pendingURLString = pendingURLString
    return true
  }

  func clear() {
    pendingURLString = nil
  }
}
