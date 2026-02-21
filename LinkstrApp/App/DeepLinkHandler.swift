import Foundation

@MainActor
final class DeepLinkHandler: ObservableObject {
  @Published var pendingPayload: LinkstrDeepLinkPayload?

  @discardableResult
  func handle(url: URL) -> Bool {
    guard let payload = LinkstrDeepLinkCodec.parsePayload(fromAppDeepLink: url) else {
      return false
    }

    pendingPayload = payload
    return true
  }

  func clear() {
    pendingPayload = nil
  }
}
