import SwiftUI

struct EditPostNoteSheet: View {
  private enum Field: Hashable {
    case note
  }

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let post: SessionMessageEntity
  @State private var draft: String
  @State private var isSaving = false
  @FocusState private var focusedField: Field?
  @State private var feedback = LinkstrSheetMutationFeedback()

  init(post: SessionMessageEntity) {
    self.post = post
    _draft = State(initialValue: post.note ?? "")
  }

  private var originalNote: String? { LinkstrPostPreview.text(post.note) }
  private var normalizedDraft: String? { LinkstrPostPreview.text(draft) }
  private var isRemovingNote: Bool { originalNote != nil && normalizedDraft == nil }
  private var canSave: Bool { !isSaving && normalizedDraft != originalNote }

  private var status: LinkstrSheetFooterStatus? {
    feedback.footerStatus(isRunning: isSaving, progressMessage: "saving note…")
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          LinkstrSheetTitle(title: originalNote == nil ? "add a note" : "edit note")

          LinkstrInsetSection(title: "note", footer: noteFooter) {
            LinkstrNoteEditor(note: $draft, isDisabled: isSaving, focusedField: $focusedField, field: .note)
              .id(Field.note)
            if !draft.isEmpty {
              Button {
                draft = ""
              } label: {
                LinkstrActionButtonLabel(title: "clear text", systemImage: "xmark.circle")
              }
              .linkstrSecondaryButton()
              .disabled(isSaving)
            }
          }
        }
        .linkstrPageContentLayout()
      }
      .background(LinkstrBackgroundView())
      .linkstrBarChrome()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "cancel", icon: "xmark") { dismiss() }
            .disabled(isSaving)
        }
        .linkstrFlatToolbarItem()
        ToolbarItem(placement: .confirmationAction) {
          LinkstrHeaderButton(
            title: isRemovingNote ? "remove note" : "save note",
            icon: isRemovingNote ? "trash" : "checkmark",
            foreground: isRemovingNote ? LinkstrTheme.destructive : LinkstrTheme.accent,
            action: save
          )
          .disabled(!canSave)
        }
        .linkstrFlatToolbarItem()
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let status {
          LinkstrSheetStatusFooter(message: status.message, messageColor: status.color)
        }
      }
      .onAppear { focusedField = .note }
      .linkstrKeyboardDismissal()
      .modifier(LinkstrFocusedFieldScrolling(focusedField: focusedField))
      .interactiveDismissDisabled(isSaving)
      .onChange(of: draft) { _, _ in feedback.clear() }
    }
  }

  private var noteFooter: String? {
    guard originalNote != nil else { return nil }
    return isRemovingNote
      ? "confirm to remove the note from this post."
      : "clear the text and confirm to remove your note."
  }

  private func save() {
    guard canSave else { return }
    let note = normalizedDraft
    isSaving = true
    focusedField = nil
    feedback.clear()
    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.editPostNoteAwaitingRelay(note, on: post)
      }
      isSaving = false
      if result.didSucceed {
        dismiss()
        LinkstrToast.showSuccess(note == nil ? "note removed" : "note saved")
      } else {
        feedback.record(errorMessage: result.errorMessage)
      }
    }
  }
}
