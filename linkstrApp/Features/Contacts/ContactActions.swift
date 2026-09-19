import SwiftUI
import UIKit

private struct ContactAdditionModifier: ViewModifier {
  @EnvironmentObject private var session: AppSession
  @Binding var pending: ContactPresentation?
  @State private var isAdding = false
  @State private var errorMessage: String?

  func body(content: Content) -> some View {
    content
      .disabled(isAdding)
      .alert(
        "add contact",
        isPresented: Binding(
          get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending
      ) { person in
        Button("cancel", role: .cancel) {}
        Button("add contact") { add(person) }
      } message: { person in
        Text("add \(person.identity.displayName) to your contacts and public follow list?")
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if isAdding || errorMessage != nil {
          LinkstrSheetStatusFooter(
            message: isAdding ? "adding contact..." : (errorMessage ?? ""),
            messageColor: isAdding ? LinkstrTheme.textSecondary : LinkstrTheme.destructive
          )
        }
      }
  }

  private func add(_ person: ContactPresentation) {
    guard !isAdding else { return }
    isAdding = true
    errorMessage = nil
    Task { @MainActor in
      let result = await session.performFormMutation { await session.ensureContact(pubkey: person.pubkey) }
      isAdding = false
      errorMessage = result.errorMessage
    }
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
  func contactAddition(pending: Binding<ContactPresentation?>) -> some View {
    modifier(ContactAdditionModifier(pending: pending))
  }

  func contactRemoval(pending: Binding<ContactEntity?>, didRemove: @escaping () -> Void = {})
    -> some View {
    modifier(ContactRemovalModifier(pending: pending, didRemove: didRemove))
  }
}
