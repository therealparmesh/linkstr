import Foundation

@MainActor
final class DeepLinkHandler: ObservableObject {
  @Published var pendingURLString: String?
  @Published var pendingShareDraft: LinkstrDeepLinkCodec.ShareDraft?
  @Published var pendingMediaSaveDraft: LinkstrDeepLinkCodec.MediaSaveDraft?

  @discardableResult
  func handle(url: URL) -> Bool {
    guard let route = LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: url) else {
      return false
    }

    switch route {
    case .openURL(let pendingURLString):
      pendingShareDraft = nil
      pendingMediaSaveDraft = nil
      self.pendingURLString = pendingURLString
    case .share(let draft):
      pendingURLString = nil
      pendingMediaSaveDraft = nil
      pendingShareDraft = draft
    case .mediaSave(let draft):
      pendingURLString = nil
      pendingShareDraft = nil
      pendingMediaSaveDraft = draft
    }
    return true
  }

  func clearSharedLinkDetail() {
    pendingURLString = nil
  }

  func clearShareDraft() {
    pendingShareDraft = nil
  }

  func clearMediaSaveDraft() {
    pendingMediaSaveDraft = nil
  }
}
