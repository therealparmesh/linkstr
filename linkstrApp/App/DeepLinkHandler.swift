import Foundation
import UIKit

extension Notification.Name {
  static let linkstrWillPresentIncomingLink = Notification.Name("linkstrWillPresentIncomingLink")
}

@MainActor
final class DeepLinkHandler: ObservableObject {
  @Published private(set) var pendingSharedURL: URL?
  @Published var pendingShareDraft: LinkstrDeepLinkCodec.ShareDraft?
  @Published var pendingMediaSaveDraft: LinkstrDeepLinkCodec.MediaSaveDraft?
  private(set) var latestRequestID: UUID?

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

    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?.rootViewController
    if let sharePresentation = activityPresentation(from: root) {
      // The share controller may be embedded in a SwiftUI sheet.
      if sharePresentation.isBeingDismissed, let transition = sharePresentation.transitionCoordinator {
        transition.animate(alongsideTransition: nil) { _ in presentRoute() }
      } else {
        (sharePresentation.presentingViewController ?? sharePresentation)
          .dismiss(animated: true, completion: presentRoute)
      }
      return true
    }
    presentRoute()
    return true
  }

  private func activityPresentation(from root: UIViewController?) -> UIViewController? {
    var presentation = root?.presentedViewController
    while let current = presentation {
      if containsActivityController(current) { return current }
      presentation = current.presentedViewController
    }
    return nil
  }

  private func containsActivityController(_ controller: UIViewController) -> Bool {
    controller is UIActivityViewController || controller.children.contains(where: containsActivityController)
  }

  private func present(_ route: LinkstrDeepLinkCodec.Route) {
    NotificationCenter.default.post(name: .linkstrWillPresentIncomingLink, object: self)
    switch route {
    case .openURL(let webURL):
      pendingShareDraft = nil
      pendingMediaSaveDraft = nil
      pendingSharedURL = webURL
    case .share(let draft):
      pendingSharedURL = nil
      pendingMediaSaveDraft = nil
      pendingShareDraft = draft
    case .mediaSave(let draft):
      pendingSharedURL = nil
      pendingShareDraft = nil
      pendingMediaSaveDraft = draft
    }
  }

  func clearSharedLinkDetail() {
    pendingSharedURL = nil
  }

  func clearPendingRoutes() {
    latestRequestID = nil
    clearSharedLinkDetail()
    clearShareDraft()
    clearMediaSaveDraft()
  }

  func clearShareDraft(matching draft: LinkstrDeepLinkCodec.ShareDraft? = nil) {
    guard draft == nil || pendingShareDraft == draft else { return }
    pendingShareDraft = nil
  }

  func clearMediaSaveDraft(matching draft: LinkstrDeepLinkCodec.MediaSaveDraft? = nil) {
    guard draft == nil || pendingMediaSaveDraft == draft else { return }
    pendingMediaSaveDraft = nil
  }
}
