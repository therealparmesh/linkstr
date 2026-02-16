import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareExtensionViewModel: ObservableObject {
  @Published var incomingURL: String = ""
  @Published var contacts: [ContactSnapshot] = []
  @Published var recipientQuery: String = "" {
    didSet {
      syncSelectedContactWithQuery()
    }
  }
  @Published var selectedContact: ContactSnapshot?
  @Published var note: String = ""
  @Published var errorMessage: String?

  private let store: AppGroupStoreProtocol

  init(store: AppGroupStoreProtocol = AppGroupStore.shared) {
    self.store = store
  }

  func load(context: NSExtensionContext?) {
    loadContacts()
    loadURL(context: context)
  }

  var filteredContacts: [ContactSnapshot] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: recipientQuery,
      displayName: { displayName(for: $0) },
      npub: { $0.npub }
    )
  }

  var recipientInputHasValue: Bool {
    selectedContact != nil
      || !recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func selectContact(_ contact: ContactSnapshot) {
    selectedContact = contact
    recipientQuery = displayName(for: contact)
    errorMessage = nil
  }

  func clearRecipient() {
    selectedContact = nil
    recipientQuery = ""
    errorMessage = nil
  }

  func displayName(for contact: ContactSnapshot) -> String {
    RecipientSearchLogic.displayNameOrNPub(displayName: contact.displayName, npub: contact.npub)
  }

  func pasteRecipientFromClipboard() {
    if let clipboardText = UIPasteboard.general.string {
      recipientQuery = clipboardText
    }
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
      ownerPubkey: selectedContact.ownerPubkey,
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
    let loadedContacts = (try? store.loadContactsSnapshot()) ?? []
    contacts = loadedContacts.sorted {
      displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1))
        == .orderedAscending
    }
    if let selectedContact,
      !contacts.contains(where: { $0.id == selectedContact.id })
    {
      self.selectedContact = nil
    }
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

  private func syncSelectedContactWithQuery() {
    let trimmedQuery = recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      selectedContact = nil
      return
    }

    guard let selectedContact else { return }

    let normalizedQuery = trimmedQuery.lowercased()
    let normalizedDisplayName = displayName(for: selectedContact).lowercased()
    if normalizedDisplayName != normalizedQuery
      && selectedContact.npub.lowercased() != normalizedQuery
    {
      self.selectedContact = nil
    }
  }
}
