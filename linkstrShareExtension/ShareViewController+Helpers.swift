import Foundation
import UIKit

// MARK: - ShareViewController Action Helpers

extension ShareViewController {
  func makeDivider() -> UIView {
    let divider = UIView()
    divider.backgroundColor = Self.separatorColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      divider.heightAnchor.constraint(equalToConstant: 1)
    ])
    return divider
  }

  func setLoading(message: String) {
    titleLabel.text = "share"
    statusLabel.text = message
    loadingStack.isHidden = false
    activityIndicator.isHidden = false
    activityIndicator.startAnimating()
    linkSectionLabel.isHidden = true
    linkFieldView.isHidden = true
    actionSectionLabel.isHidden = true
    actionListView.isHidden = true
  }

  func beginShareHandoff() {
    SharedLinkExtractor.extract(from: extensionContext) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let share):
          self.presentActions(for: share)
        case .failure:
          self.completeGracefully()
        }
      }
    }
  }

  func presentActions(for share: ExtractedShare) {
    extractedShare = share
    activityIndicator.stopAnimating()
    loadingStack.isHidden = true
    titleLabel.text = "choose action"
    linkSectionLabel.isHidden = false
    linkFieldView.isHidden = false
    actionSectionLabel.isHidden = false
    actionListView.isHidden = false
    linkLabel.text = share.url
  }

  func openContainingApp(for action: ShareAction) {
    guard let share = extractedShare else {
      completeGracefully()
      return
    }

    let deepLink: URL?
    switch action {
    case .shareLink:
      deepLink = LinkstrDeepLinkCodec.makeShareAppDeepLink(url: share.url, note: share.note)
    case .saveMedia:
      deepLink = LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: share.url)
    }

    guard let deepLink else {
      completeGracefully()
      return
    }

    guard let extensionContext else {
      completeGracefully()
      return
    }

    setLoading(message: "opening linkstr...")

    extensionContext.open(deepLink) { [weak self, weak extensionContext] didOpen in
      DispatchQueue.main.async {
        guard let self, let extensionContext else { return }
        guard didOpen || self.openURLUsingResponderChain(deepLink) else {
          self.completeGracefully()
          return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          extensionContext.completeRequest(returningItems: nil)
        }
      }
    }
  }

  func openURLUsingResponderChain(_ url: URL) -> Bool {
    guard let applicationClass = NSClassFromString("UIApplication") else {
      return false
    }

    let openURLSelector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let currentResponder = responder {
      defer { responder = currentResponder.next }
      guard currentResponder.isKind(of: applicationClass),
        currentResponder.responds(to: openURLSelector)
      else {
        continue
      }

      typealias OpenURLFunction =
        @convention(c) (
          AnyObject,
          Selector,
          NSURL,
          NSDictionary,
          AnyObject?
        ) -> Void
      let method = currentResponder.method(for: openURLSelector)
      unsafeBitCast(method, to: OpenURLFunction.self)(
        currentResponder,
        openURLSelector,
        url as NSURL,
        NSDictionary(),
        nil
      )
      return true
    }
    return false
  }

  func completeGracefully() {
    extensionContext?.completeRequest(returningItems: nil)
  }

  @objc func performShareLink() {
    openContainingApp(for: .shareLink)
  }

  @objc func performSaveMedia() {
    openContainingApp(for: .saveMedia)
  }

  @objc func cancelShare() {
    let error = NSError(
      domain: "com.parmscript.linkstr.share-extension",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "share cancelled."]
    )
    extensionContext?.cancelRequest(withError: error)
  }
}
