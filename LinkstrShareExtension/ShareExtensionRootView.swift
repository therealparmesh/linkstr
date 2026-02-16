import SwiftUI

struct ShareExtensionRootView: View {
  @ObservedObject var viewModel: ShareExtensionViewModel
  let onDone: () -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section("URL") {
          TextField("https://...", text: $viewModel.incomingURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        }

        Section("To") {
          TextField("Name or Contact Key (npub...)", text: $viewModel.recipientQuery)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

          ShareRecipientAssistRow(
            showClear: viewModel.recipientInputHasValue,
            onPaste: viewModel.pasteRecipientFromClipboard,
            onClear: viewModel.clearRecipient
          )
        }

        Section("Contacts") {
          if viewModel.filteredContacts.isEmpty {
            Text("No contacts match. Select an existing contact to continue.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            ForEach(viewModel.filteredContacts) { contact in
              Button {
                viewModel.selectContact(contact)
              } label: {
                ShareContactRow(
                  displayName: viewModel.displayName(for: contact),
                  npub: contact.npub,
                  isSelected: viewModel.selectedContact?.id == contact.id
                )
              }
              .buttonStyle(.plain)
            }
          }
        }

        Section("Note") {
          TextField("Optional note", text: $viewModel.note)
        }

        if let error = viewModel.errorMessage {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Send with linkstr")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { onCancel() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            viewModel.send()
            if viewModel.errorMessage == nil {
              onDone()
            }
          }
          .disabled(
            viewModel.selectedContact == nil
              || LinkstrURLValidator.normalizedWebURL(from: viewModel.incomingURL) == nil
          )
        }
      }
    }
  }
}

private struct ShareRecipientAssistRow: View {
  let showClear: Bool
  let onPaste: () -> Void
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      actionButton("Paste", systemImage: "doc.on.clipboard", action: onPaste)
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
    }
    .buttonStyle(.plain)
  }
}

private struct ShareContactRow: View {
  let displayName: String
  let npub: String
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      ShareContactAvatar(name: displayName, size: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .lineLimit(1)
        Text(npub)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
      }
    }
  }
}

private struct ShareContactAvatar: View {
  let name: String
  let size: CGFloat

  var body: some View {
    Circle()
      .fill(Color.accentColor.opacity(0.9))
      .frame(width: size, height: size)
      .overlay {
        Text(initials)
          .font(.system(size: max(12, size * 0.38), weight: .semibold))
          .foregroundStyle(.white)
      }
  }

  private var initials: String {
    let parts = name.split(separator: " ").prefix(2)
    let text = parts.compactMap { $0.first }.map(String.init).joined()
    return text.isEmpty ? "?" : text.uppercased()
  }
}
