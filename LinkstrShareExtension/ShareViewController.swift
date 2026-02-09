import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
  private let viewModel = ShareExtensionViewModel()

  override func viewDidLoad() {
    super.viewDidLoad()

    let rootView = ShareExtensionRootView(viewModel: viewModel) {
      self.extensionContext?.completeRequest(returningItems: nil)
    } onCancel: {
      self.extensionContext?.cancelRequest(withError: NSError(domain: "linkstrShare", code: 0))
    }

    let hosting = UIHostingController(rootView: rootView)
    addChild(hosting)
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    hosting.didMove(toParent: self)

    viewModel.load(context: extensionContext)
  }
}
