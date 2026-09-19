import SwiftUI
import UIKit

struct AddContactButton: View {
  @EnvironmentObject private var session: AppSession
  let pubkey: String
  let displayName: String
  let isAdded: Bool
  var title = "add contact"
  @State private var isAdding = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      if isAdded {
        Label("added", systemImage: "checkmark")
          .foregroundStyle(LinkstrTheme.textSecondary)
          .accessibilityLabel("\(displayName) is in your contacts")
      } else {
        Button {
          guard !isAdding else { return }
          isAdding = true
          errorMessage = nil
          Task { @MainActor in
            let result = await session.performFormMutation {
              await session.ensureContact(pubkey: pubkey)
            }
            isAdding = false
            errorMessage = result.errorMessage
          }
        } label: {
          Group {
            if isAdding { ProgressView() } else { Text(title) }
          }
          .frame(
            minWidth: LinkstrTheme.minimumInteractiveDimension,
            minHeight: LinkstrTheme.minimumInteractiveDimension
          )
        }
        .disabled(isAdding)
        .tint(LinkstrTheme.accent)
        .accessibilityLabel(isAdding ? "adding \(displayName) to contacts" : "\(title), \(displayName)")
      }
      if !isAdded, let errorMessage {
        Text(errorMessage)
          .foregroundStyle(LinkstrTheme.destructive)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(LinkstrTheme.font(.caption, weight: .medium))
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
  }
}

private struct ContactRemovalModifier: ViewModifier {
  @EnvironmentObject private var session: AppSession
  @Binding var pending: ContactEntity?
  var didRemove: () -> Void
  @State private var isRemoving = false
  @State private var errorMessage: String?

  func body(content: Content) -> some View {
    content
      .disabled(isRemoving)
      .alert(
        "remove contact",
        isPresented: Binding(
          get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending
      ) { contact in
        Button("cancel", role: .cancel) {}
        Button("remove contact", role: .destructive) { remove(contact) }
      } message: { contact in
        let name = session.resolvedIdentity(for: contact).displayName
        Text(
          "this removes \(name) from your contacts and public follow list. "
            + "shared sessions and posts stay available."
        )
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if isRemoving || errorMessage != nil {
          LinkstrSheetStatusFooter(
            message: isRemoving ? "removing contact..." : (errorMessage ?? ""),
            messageColor: isRemoving ? LinkstrTheme.textSecondary : LinkstrTheme.destructive
          )
        }
      }
  }

  private func remove(_ contact: ContactEntity) {
    guard !isRemoving else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    isRemoving = true
    errorMessage = nil
    Task { @MainActor in
      let result = await session.performFormMutation { await session.removeContact(contact) }
      isRemoving = false
      if result.didSucceed { didRemove() } else { errorMessage = result.errorMessage }
    }
  }
}

extension View {
  func contactRemoval(pending: Binding<ContactEntity?>, didRemove: @escaping () -> Void = {})
    -> some View {
    modifier(ContactRemovalModifier(pending: pending, didRemove: didRemove))
  }
}
