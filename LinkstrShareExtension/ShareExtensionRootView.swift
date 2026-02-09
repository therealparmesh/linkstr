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

        Section("Contact") {
          Picker("Recipient", selection: $viewModel.selectedContact) {
            Text("Select").tag(ContactSnapshot?.none)
            ForEach(viewModel.contacts) { contact in
              Text(contact.displayName).tag(ContactSnapshot?.some(contact))
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
      .navigationTitle("Share to linkstr")
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
