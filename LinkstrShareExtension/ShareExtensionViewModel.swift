import Foundation
import UIKit
import UniformTypeIdentifiers

protocol ShareExtensionStore {
  func appendPendingShare(_ item: PendingShareItem) throws
  func loadContactsSnapshot() throws -> [ContactSnapshot]
}

extension AppGroupStore: ShareExtensionStore {}

@MainActor
final class ShareExtensionViewModel: ObservableObject {
  @Published var incomingURL: String = ""
  @Published var contacts: [ContactSnapshot] = []
  @Published var selectedContact: ContactSnapshot?
  @Published var note: String = ""
  @Published var errorMessage: String?

  private let store: ShareExtensionStore

  init(store: ShareExtensionStore = AppGroupStore.shared) {
    self.store = store
  }

  func load(context: NSExtensionContext?) {
    loadContacts()
    loadURL(context: context)
  }

  func send() {
    guard URL(string: incomingURL) != nil else {
      errorMessage = "Invalid URL"
      return
    }
    guard let selectedContact else {
      errorMessage = "Select a contact"
      return
    }

    let item = PendingShareItem(
      url: incomingURL, contactNPub: selectedContact.npub, note: note.isEmpty ? nil : note)
    do {
      try store.appendPendingShare(item)
    } catch {
      errorMessage = "Unable to queue share: \(error.localizedDescription)"
    }
  }

  private func loadContacts() {
    contacts = (try? store.loadContactsSnapshot()) ?? []
  }

  private func loadURL(context: NSExtensionContext?) {
    guard let item = context?.inputItems.first as? NSExtensionItem,
      let providers = item.attachments
    else {
      return
    }

    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
        [weak self] data, _ in
        guard let self else { return }
        if let url = data as? URL {
          Task { @MainActor in
            self.incomingURL = url.absoluteString
          }
        }
      }
      return
    }
  }
}
