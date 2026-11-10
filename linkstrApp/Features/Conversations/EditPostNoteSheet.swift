import SwiftUI

struct EditPostNoteSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let post: SessionMessageEntity
  @State private var draft: String
  @State private var isSaving = false
  @FocusState private var isNoteFocused: Bool
  @State private var feedback = LinkstrSheetMutationFeedback()

  init(post: SessionMessageEntity) {
    self.post = post
    _draft = State(initialValue: post.note ?? "")
  }

  private var normalizedDraft: String? { LinkstrPostPreview.text(draft) }

  private var status: LinkstrSheetFooterStatus? {
    feedback.footerStatus(isRunning: isSaving, progressMessage: "waiting for a relay connection")
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("your note")
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
          ZStack(alignment: .topLeading) {
            if draft.isEmpty {
              Text("say something about this link")
                .foregroundStyle(LinkstrTheme.textSecondary)
                .padding(.top, 8)
                .padding(.leading, 5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            TextEditor(text: $draft)
              .scrollContentBackground(.hidden)
              .frame(minHeight: 100, maxHeight: 180)
              .disabled(isSaving)
              .focused($isNoteFocused)
              .accessibilityLabel("your note")
          }
          .font(LinkstrTheme.font(.body))
          .padding(9)
          .linkstrFieldChrome()

          Text("leave it blank to remove your note.")
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .padding(LinkstrTheme.screenHorizontalPadding)
        .linkstrReadableContent()
      }
      .background(LinkstrBackgroundView())
      .navigationTitle(post.note == nil ? "add a note" : "edit note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("cancel") { dismiss() }.disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "saving…" : "save", action: save)
            .disabled(isSaving || normalizedDraft == LinkstrPostPreview.text(post.note))
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let status {
          LinkstrSheetStatusFooter(message: status.message, messageColor: status.color)
        }
      }
      .onAppear { isNoteFocused = true }
      .linkstrKeyboardDismissal()
      .interactiveDismissDisabled(isSaving)
      .onChange(of: draft) { _, _ in feedback.clear() }
    }
  }

  private func save() {
    let note = normalizedDraft
    isSaving = true
    isNoteFocused = false
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
