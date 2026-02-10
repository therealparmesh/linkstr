import NostrSDK
import SwiftUI

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
    guard let activeRecipientNPub else {
      return "Choose recipient"
    }
    guard let contact = contacts.first(where: { $0.npub == activeRecipientNPub }) else {
      return activeRecipientNPub
    }
    let trimmedName = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? activeRecipientNPub : trimmedName
  }

  private var recipientSecondaryLabel: String? {
    guard let activeRecipientNPub else {
      return "Choose a contact or enter a Contact key (npub)."
    }
    guard let contact = contacts.first(where: { $0.npub == activeRecipientNPub }) else {
      return nil
    }
    let trimmedName = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? nil : activeRecipientNPub
  }

  private var normalizedURL: String? {
    LinkstrURLValidator.normalizedWebURL(from: url)
  }
}

private struct RecipientSelectionSheet: View {
  let contacts: [ContactEntity]
  @Binding var selectedRecipientNPub: String?
  @Binding var isPresented: Bool

  var body: some View {
    NavigationStack {
      List {
        Section("Contacts") {
          ForEach(contacts) { contact in
            Button {
              selectedRecipientNPub = contact.npub
              isPresented = false
            } label: {
              HStack(spacing: 10) {
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

        Section {
          NavigationLink {
            ManualRecipientEntryView(initialNPub: selectedRecipientNPub ?? "") { normalizedNPub in
              selectedRecipientNPub = normalizedNPub
              isPresented = false
            }
          } label: {
            Label("Enter Contact key (npub)", systemImage: "square.and.pencil")
          }
        }

        if selectedRecipientNPub != nil {
          Section {
            Button("Clear Recipient", role: .destructive) {
              selectedRecipientNPub = nil
              isPresented = false
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
    }
  }

  private func displayName(for contact: ContactEntity) -> String {
    let trimmed = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? contact.npub : trimmed
  }
}

private struct ManualRecipientEntryView: View {
  let onSelect: (String) -> Void

  @State private var npubInput: String
  @State private var errorMessage: String?
  @State private var isPresentingScanner = false

  init(initialNPub: String, onSelect: @escaping (String) -> Void) {
    self.onSelect = onSelect
    _npubInput = State(initialValue: initialNPub)
  }

  var body: some View {
    Form {
      Section("Contact key (npub)") {
        TextField("npub1...", text: $npubInput, axis: .vertical)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
      }

      Section {
        Button {
          errorMessage = nil
          isPresentingScanner = true
        } label: {
          Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LinkstrSecondaryButtonStyle())
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }

      Section {
        Button("Use Recipient") {
          guard let normalizedNPub else {
            errorMessage = "Invalid Contact key (npub)."
            return
          }
          errorMessage = nil
          onSelect(normalizedNPub)
        }
        .buttonStyle(LinkstrPrimaryButtonStyle())
        .frame(maxWidth: .infinity)
      }
    }
    .navigationTitle("Enter Contact key (npub)")
    .sheet(isPresented: $isPresentingScanner) {
      LinkstrQRScannerSheet { scannedValue in
        if let scannedNPub = ContactKeyParser.extractNPub(from: scannedValue) {
          npubInput = scannedNPub
          errorMessage = nil
        } else {
          errorMessage = "No valid Contact key (npub) found in that QR code."
        }
      }
    }
  }

  private var normalizedNPub: String? {
    guard
      let extractedNPub = ContactKeyParser.extractNPub(from: npubInput),
      let normalized = PublicKey(npub: extractedNPub)?.npub
    else {
      return nil
    }
    return normalized
  }
}
