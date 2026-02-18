import Messages
import SwiftUI

final class MessagesViewController: MSMessagesAppViewController {
  private let viewModel = MessagesExtensionViewModel()
  private var lastAutoOpenedMessageGUID: String?

  override func viewDidLoad() {
    super.viewDidLoad()
    setupSwiftUIView()
  }

  override func willBecomeActive(with conversation: MSConversation) {
    super.willBecomeActive(with: conversation)
    viewModel.selectMessage(conversation.selectedMessage)
    autoOpenSelectedMessageIfPossible()
  }

  override func didSelect(_ message: MSMessage, conversation: MSConversation) {
    super.didSelect(message, conversation: conversation)
    viewModel.selectMessage(message)
    autoOpenSelectedMessageIfPossible()
  }

  override func didReceive(_ message: MSMessage, conversation: MSConversation) {
    super.didReceive(message, conversation: conversation)
    viewModel.selectMessage(message)
    autoOpenSelectedMessageIfPossible()
  }

  override func didResignActive(with conversation: MSConversation) {
    super.didResignActive(with: conversation)
    // Allow re-opening the same selected bubble on the next activation cycle.
    lastAutoOpenedMessageGUID = nil
  }

  private func setupSwiftUIView() {
    let rootView = MessagesExtensionView(
      viewModel: viewModel,
      onSend: { [weak self] message in
        self?.send(message)
      },
      onOpenInLinkstr: { [weak self] url in
        self?.openInLinkstr(url: url)
      },
      onCloseSelected: { [weak self] in
        self?.viewModel.clearSelection()
      }
    )

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
  }

  private func send(_ message: MSMessage) {
    guard let activeConversation else {
      viewModel.sendError = "No active conversation available."
      return
    }

    viewModel.sendError = nil
    activeConversation.send(message) { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          NSLog("LinkstrMessagesExtension send failed: %@", error.localizedDescription)
          self.viewModel.sendError = "Couldn't send message. Try again."
          return
        }

        // Only close after send success so we never silently drop the message.
        self.dismiss()
      }
    }
  }

  private func openInLinkstr(url: URL) {
    extensionContext?.open(url) { [weak self] success in
      guard !success else { return }
      Task { @MainActor in
        self?.lastAutoOpenedMessageGUID = nil
        self?.viewModel.selectionError = "Couldn't open Linkstr. Make sure the app is installed."
      }
    }
  }

  private func autoOpenSelectedMessageIfPossible() {
    guard let payload = viewModel.selectedPayload else { return }
    guard payload.messageGUID != lastAutoOpenedMessageGUID else { return }
    guard let url = viewModel.makeOpenInLinkstrURL() else { return }

    lastAutoOpenedMessageGUID = payload.messageGUID
    openInLinkstr(url: url)
  }
}
