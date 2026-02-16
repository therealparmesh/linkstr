import NostrSDK
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct LockedRecipientContext {
  let npub: String
  let displayName: String
}

struct NewPostSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contacts: [ContactEntity]
  let lockedRecipient: LockedRecipientContext?

  @State private var selectedRecipientNPub: String?
  @State private var url = ""
  @State private var note = ""
  @State private var isPresentingRecipientPicker = false

  init(
    contacts: [ContactEntity],
    preselectedContactNPub: String? = nil,
    lockedRecipient: LockedRecipientContext? = nil
  ) {
    self.contacts = contacts
    self.lockedRecipient = lockedRecipient
    _selectedRecipientNPub = State(initialValue: preselectedContactNPub)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        Form {
          Section("Recipient") {
            if let lockedRecipient {
              VStack(alignment: .leading, spacing: 4) {
                Text(lockedRecipient.displayName)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                Text(lockedRecipient.npub)
                  .font(.footnote)
                  .foregroundStyle(LinkstrTheme.textSecondary)
                  .lineLimit(1)
              }
            } else {
              Button {
                isPresentingRecipientPicker = true
              } label: {
                HStack(spacing: 10) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(recipientPrimaryLabel)
                      .foregroundStyle(LinkstrTheme.textPrimary)
                      .lineLimit(1)
                    if let recipientSecondaryLabel {
                      Text(recipientSecondaryLabel)
                        .font(.footnote)
                        .foregroundStyle(LinkstrTheme.textSecondary)
                        .lineLimit(1)
                    }
                  }
                  Spacer()
                  Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinkstrTheme.textSecondary.opacity(0.8))
                }
              }
              .buttonStyle(.plain)
            }
          }

          Section("Post Link") {
            TextField("https://...", text: $url)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              .autocorrectionDisabled(true)
            TextField("Optional note", text: $note, axis: .vertical)
          }

          Section {
            Text("Add a valid URL to send a post. Replies can be text-only.")
              .font(.footnote)
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        }
        .scrollContentBackground(.hidden)
      }
      .navigationTitle("New Post")
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            guard let recipientNPub = activeRecipientNPub else { return }
            guard let normalizedURL = normalizedURL else { return }
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            session.createPost(
              url: normalizedURL,
              note: trimmedNote.isEmpty ? nil : trimmedNote,
              recipientNPub: recipientNPub
            )
            if session.composeError == nil {
              dismiss()
            }
          }
          .disabled(activeRecipientNPub == nil || normalizedURL == nil)
          .tint(LinkstrTheme.neonCyan)
        }
      }
    }
    .sheet(isPresented: $isPresentingRecipientPicker) {
      RecipientSelectionSheet(
        contacts: contacts,
        selectedRecipientNPub: $selectedRecipientNPub,
        isPresented: $isPresentingRecipientPicker
      )
    }
  }

  private var activeRecipientNPub: String? {
    if let lockedRecipient {
      return lockedRecipient.npub
    }
    return selectedRecipientNPub
  }

  private var recipientPrimaryLabel: String {
    let displayName = contacts.first(where: { $0.npub == activeRecipientNPub })?.displayName
    return NewPostRecipientLabelLogic.primaryLabel(
      activeRecipientNPub: activeRecipientNPub,
      matchedContactDisplayName: displayName
    )
  }

  private var recipientSecondaryLabel: String? {
    let displayName = contacts.first(where: { $0.npub == activeRecipientNPub })?.displayName
    return NewPostRecipientLabelLogic.secondaryLabel(
      activeRecipientNPub: activeRecipientNPub,
      matchedContactDisplayName: displayName
    )
  }

  private var normalizedURL: String? {
    LinkstrURLValidator.normalizedWebURL(from: url)
  }
}

private struct RecipientSelectionSheet: View {
  let contacts: [ContactEntity]
  @Binding var selectedRecipientNPub: String?
  @Binding var isPresented: Bool
  @State private var recipientQuery: String
  @State private var isPresentingScanner = false

  init(
    contacts: [ContactEntity],
    selectedRecipientNPub: Binding<String?>,
    isPresented: Binding<Bool>
  ) {
    self.contacts = contacts
    _selectedRecipientNPub = selectedRecipientNPub
    _isPresented = isPresented
    let selectedDisplayName =
      contacts
      .first(where: { $0.npub == selectedRecipientNPub.wrappedValue })?
      .displayName
    _recipientQuery = State(
      initialValue: RecipientSelectionLogic.selectedQuery(
        selectedRecipientNPub: selectedRecipientNPub.wrappedValue,
        selectedDisplayName: selectedDisplayName
      ))
  }

  var body: some View {
    NavigationStack {
      List {
        Section("To") {
          TextField("Name or Contact Key (npub...)", text: $recipientQuery)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

          LinkstrInputAssistRow(
            showClear: selectedRecipientNPub != nil
              || !recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onPaste: pasteFromClipboard,
            onScan: { isPresentingScanner = true },
            onClear: {
              recipientQuery = ""
              selectedRecipientNPub = nil
            }
          )
        }

        if let customQueryNPub {
          Section("Use Contact Key") {
            Button {
              selectedRecipientNPub = customQueryNPub
              isPresented = false
            } label: {
              HStack(spacing: 10) {
                LinkstrPeerAvatar(name: customQueryNPub, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                  Text(customQueryNPub)
                    .foregroundStyle(LinkstrTheme.textPrimary)
                    .lineLimit(1)
                  Text(customQueryNPub)
                    .font(.footnote)
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .lineLimit(1)
                }
                Spacer()
                if selectedRecipientNPub == customQueryNPub {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LinkstrTheme.neonCyan)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }

        Section("Contacts") {
          if filteredContacts.isEmpty {
            Text("No contacts match. Enter, paste, or scan a Contact Key (npub).")
              .font(.footnote)
              .foregroundStyle(LinkstrTheme.textSecondary)
          } else {
            ForEach(filteredContacts) { contact in
              Button {
                selectedRecipientNPub = contact.npub
                isPresented = false
              } label: {
                HStack(spacing: 10) {
                  LinkstrPeerAvatar(name: displayName(for: contact), size: 32)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: contact))
                      .foregroundStyle(LinkstrTheme.textPrimary)
                      .lineLimit(1)
                    Text(contact.npub)
                      .font(.footnote)
                      .foregroundStyle(LinkstrTheme.textSecondary)
                      .lineLimit(1)
                  }
                  Spacer()
                  if selectedRecipientNPub == contact.npub {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(LinkstrTheme.neonCyan)
                  }
                }
              }
              .buttonStyle(.plain)
            }
          }
        }

        if selectedRecipientNPub != nil {
          Section {
            Button("Clear Recipient", role: .destructive) {
              selectedRecipientNPub = nil
            }
          }
        }
      }
      .navigationTitle("Select Recipient")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            isPresented = false
          }
        }
      }
      .sheet(isPresented: $isPresentingScanner) {
        LinkstrQRScannerSheet { scannedValue in
          if let scannedNPub = ContactKeyParser.extractNPub(from: scannedValue) {
            recipientQuery = scannedNPub
          }
        }
      }
    }
  }

  private var filteredContacts: [ContactEntity] {
    RecipientSelectionLogic.filteredContacts(contacts, query: recipientQuery)
  }

  private var customQueryNPub: String? {
    RecipientSelectionLogic.customRecipientNPub(
      from: recipientQuery,
      knownNPubs: contacts.map(\.npub)
    )
  }

  private func displayName(for contact: ContactEntity) -> String {
    RecipientSearchLogic.displayNameOrNPub(displayName: contact.displayName, npub: contact.npub)
  }

  private func pasteFromClipboard() {
    #if canImport(UIKit)
      if let clipboardText = UIPasteboard.general.string {
        recipientQuery = clipboardText
      }
    #endif
  }
}

enum RecipientSelectionLogic {
  static func selectedQuery(selectedRecipientNPub: String?, selectedDisplayName: String?) -> String
  {
    RecipientSearchLogic.selectedQuery(
      selectedRecipientNPub: selectedRecipientNPub,
      selectedDisplayName: selectedDisplayName
    )
  }

  static func filteredContacts(_ contacts: [ContactEntity], query: String) -> [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: query,
      displayName: \.displayName,
      npub: \.npub
    )
  }

  static func normalizedNPub(from query: String) -> String? {
    guard
      let extractedNPub = ContactKeyParser.extractNPub(from: query),
      let normalized = PublicKey(npub: extractedNPub)?.npub
    else {
      return nil
    }
    return normalized
  }

  static func customRecipientNPub(from query: String, knownNPubs: [String]) -> String? {
    guard let normalized = normalizedNPub(from: query) else { return nil }
    return knownNPubs.contains(normalized) ? nil : normalized
  }
}

struct LinkstrInputAssistRow: View {
  let showClear: Bool
  let onPaste: () -> Void
  let onScan: () -> Void
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      actionButton("Paste", systemImage: "doc.on.clipboard", action: onPaste)
      actionButton("Scan", systemImage: "qrcode.viewfinder", action: onScan)
      Spacer()

      if showClear {
        Button("Clear", action: onClear)
          .buttonStyle(.plain)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
  }

  private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 16, height: 16)
        Text(title)
          .font(.footnote)
      }
      .foregroundStyle(LinkstrTheme.textPrimary)
    }
    .buttonStyle(.plain)
  }
}

enum NewPostRecipientLabelLogic {
  static func primaryLabel(activeRecipientNPub: String?, matchedContactDisplayName: String?)
    -> String
  {
    guard let activeRecipientNPub else {
      return "Choose recipient"
    }
    let trimmedName =
      matchedContactDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedName.isEmpty ? activeRecipientNPub : trimmedName
  }

  static func secondaryLabel(
    activeRecipientNPub: String?,
    matchedContactDisplayName: String?
  ) -> String? {
    guard let activeRecipientNPub else {
      return "Choose a contact or enter a Contact Key (npub)."
    }
    let trimmedName =
      matchedContactDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedName.isEmpty ? nil : activeRecipientNPub
  }
}
