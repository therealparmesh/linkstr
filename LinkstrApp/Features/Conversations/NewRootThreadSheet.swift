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

  @State private var selectedContactNPub: String?
  @State private var url = ""
  @State private var note = ""

  init(
    contacts: [ContactEntity],
    preselectedContactNPub: String? = nil,
    lockedRecipient: LockedRecipientContext? = nil
  ) {
    self.contacts = contacts
    self.lockedRecipient = lockedRecipient
    _selectedContactNPub = State(initialValue: preselectedContactNPub)
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
              Picker("Recipient", selection: $selectedContactNPub) {
                Text("Select Contact").tag(String?.none)
                ForEach(contacts) { contact in
                  Text(contact.displayName).tag(String?.some(contact.npub))
                }
              }
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
            Text("Text-only sending is disabled here. Posts require a valid URL.")
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
            session.createPost(
              url: url, note: note.isEmpty ? nil : note, recipientNPub: recipientNPub)
            dismiss()
          }
          .disabled(activeRecipientNPub == nil || URL(string: url) == nil)
          .tint(LinkstrTheme.neonCyan)
        }
      }
    }
  }

  private var activeRecipientNPub: String? {
    if let lockedRecipient {
      return lockedRecipient.npub
    }
    return selectedContactNPub
  }
}
