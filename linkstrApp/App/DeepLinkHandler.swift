import Foundation
import UIKit

@MainActor
final class DeepLinkHandler: ObservableObject {
  @Published var pendingURLString: String?
  @Published var pendingShareDraft: LinkstrDeepLinkCodec.ShareDraft?
  @Published var pendingMediaSaveDraft: LinkstrDeepLinkCodec.MediaSaveDraft?
  private var latestRequestID: UUID?

  @discardableResult
  func handle(url: URL) -> Bool {
    guard let route = LinkstrDeepLinkCodec.parseRoute(fromAppDeepLink: url) else {
      return false
    }

    let requestID = UUID()
    latestRequestID = requestID
    let presentRoute = { [weak self] in
      guard let self, self.latestRequestID == requestID else { return }
      self.present(route)
    }

    var controller = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?.rootViewController
    while let current = controller {
      if let shareSheet = current as? UIActivityViewController {
        // Sharing back can open a URL before the system share sheet has closed.
        if shareSheet.isBeingDismissed, let transition = shareSheet.transitionCoordinator {
          transition.animate(alongsideTransition: nil) { _ in presentRoute() }
        } else {
          (shareSheet.presentingViewController ?? shareSheet).dismiss(animated: true, completion: presentRoute)
        }
        return true
      }
      controller = current.presentedViewController
    }
    presentRoute()
    return true
  }

  private func present(_ route: LinkstrDeepLinkCodec.Route) {
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
