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
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: incomingURL) else {
      errorMessage = "Enter a valid URL."
      return
    }
    guard let selectedContact else {
      errorMessage = "Choose a contact."
      return
    }

    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let item = PendingShareItem(
      url: normalizedURL,
      contactNPub: selectedContact.npub,
      note: trimmedNote.isEmpty ? nil : trimmedNote
    )
    do {
      try store.appendPendingShare(item)
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't queue this share. Please try again."
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
