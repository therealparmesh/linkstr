import Foundation
import UIKit

private enum ShareViewControllerTimingDefaults {
  static let appHandoffCompletionDelay: TimeInterval = 0.5
  static let extractionTimeout: TimeInterval = 15
}

// MARK: - ShareViewController Action Helpers

extension ShareViewController {
  func beginShareHandoff() {
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, !self.isClosed else { return }
      self.extractionTimeout = nil
      self.presentUnavailable("the source app hasn’t provided a link. close this sheet and try sharing again.")
    }
    extractionTimeout = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + ShareViewControllerTimingDefaults.extractionTimeout, execute: timeout
    )
    SharedLinkExtractor.extract(from: extensionContext) { [weak self] share in
      DispatchQueue.main.async {
        guard let self, !self.isClosed else { return }
        self.extractionTimeout?.cancel()
        self.extractionTimeout = nil
        if let share {
          self.presentActions(for: share)
        } else {
          self.presentUnavailable("share a web link from the original app and try again.")
        }
      }
    }
  }

  func openContainingApp(for action: ShareAction) {
    guard !isOpening, !isClosed, let share = extractedShare else { return }

    let deepLink: URL?
    switch action {
    case .shareLink:
      deepLink = LinkstrDeepLinkCodec.makeShareAppDeepLink(url: share.url, note: share.note)
    case .saveMedia:
      deepLink = LinkstrDeepLinkCodec.makeMediaSaveAppDeepLink(url: share.url)
    }

    guard let deepLink, let extensionContext else {
      presentUnavailable("this link couldn’t be opened. try sharing it again from the original app.")
      return
    }

    isOpening = true
    setLoading(message: "opening linkstr…")

    extensionContext.open(deepLink) { [weak self, weak extensionContext] didOpen in
      DispatchQueue.main.async {
        guard let self, let extensionContext, !self.isClosed else { return }
        if didOpen {
          self.finishOpening(success: true, share: share, context: extensionContext)
        } else {
          self.openURLUsingResponderChain(deepLink) { [weak self, weak extensionContext] success in
            guard let extensionContext else { return }
            self?.finishOpening(success: success, share: share, context: extensionContext)
          }
        }
      }
    }
  }

  private func finishOpening(success: Bool, share: ExtractedShare, context: NSExtensionContext) {
    guard !isClosed else { return }
    if success {
      DispatchQueue.main.asyncAfter(
        deadline: .now() + ShareViewControllerTimingDefaults.appHandoffCompletionDelay
      ) { [weak self] in
        guard let self, !self.isClosed else { return }
        self.isClosed = true
        context.completeRequest(returningItems: nil)
      }
    } else {
      isOpening = false
      presentActions(for: share, error: "try again, or copy the link from the original app and paste it in linkstr.")
    }
  }

  private func openURLUsingResponderChain(_ url: URL, completion: @escaping (Bool) -> Void) {
    guard let applicationClass = NSClassFromString("UIApplication") else {
      completion(false)
      return
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
      let completionBlock: @convention(block) (Bool) -> Void = completion
      unsafeBitCast(method, to: OpenURLFunction.self)(
        currentResponder,
        openURLSelector,
        url as NSURL,
        NSDictionary(),
        completionBlock as AnyObject
      )
      return
    }
    completion(false)
  }

  func cancelShare() {
    guard !isClosed else { return }
    isClosed = true
    extractionTimeout?.cancel()
    extractionTimeout = nil
    let error = NSError(
      domain: "com.parmscript.linkstr.share-extension",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "share cancelled."]
    )
    extensionContext?.cancelRequest(withError: error)
  }
}
