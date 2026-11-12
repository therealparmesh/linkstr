import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct NewPostSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let sessionEntity: SessionEntity
  let memberAvatars: [SessionMemberAvatar]

  @State private var url = ""
  @State private var note = ""
  @State private var isSending = false
  @State private var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState private var focusedField: LinkstrShareDraftFields.Field?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrSheetTitle(title: "share a link")

            LinkstrInsetSection(title: "to") {
              ShareSelectedSessionRow(session: sessionEntity, memberAvatars: memberAvatars)
            }

            if !canCreatePostInSession {
              LinkstrReadOnlyBanner()
            }

            LinkstrShareDraftFields(
              link: $url, note: $note, normalizedURL: normalizedURL,
              isSending: isSending, focusedField: $focusedField
            )
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
        .linkstrKeyboardDismissal()
        .modifier(LinkstrFocusedFieldScrolling(focusedField: focusedField))
      }

      .linkstrBarChrome()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "cancel", icon: "xmark") { dismiss() }
            .disabled(isSending)
        }
        .linkstrFlatToolbarItem()
      }
      .interactiveDismissDisabled(isSending)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if focusedField == nil {
          LinkstrShareFooter(status: footerStatus, canSend: canSend, isSending: isSending, send: sendPost)
        }
      }
      .onChange(of: focusedField) { previousField, focusedField in
        guard previousField == .link, focusedField != .link else { return }
        guard let normalizedURL else { return }
        url = normalizedURL
      }
      .onChange(of: url) { _, _ in
        mutationFeedback.clear()
      }
      .onChange(of: note) { _, _ in
        mutationFeedback.clear()
      }
    }
  }

  private var normalizedURL: String? {
    LinkstrDeepLinkCodec.webURL(fromInput: url)
  }

  private var canCreatePostInSession: Bool {
    session.isCurrentUserActiveMember(of: sessionEntity)
  }

  private var canSend: Bool {
    !isSending && canCreatePostInSession && normalizedURL != nil
  }

  private var urlValidationHint: String? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return normalizedURL == nil ? "enter a valid link." : nil
  }

  private var validationMessage: String? {
    if !canCreatePostInSession {
      return "you're no longer a member of this session."
    }
    return urlValidationHint
  }

  private var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isSending,
      progressMessage: "connecting to share your link",
      validationMessage: validationMessage,
      validationColor: LinkstrTheme.destructive.opacity(0.9)
    )
  }

  private func sendPost() {
    guard canCreatePostInSession else { return }
    guard let normalizedURL else { return }
    guard !isSending else { return }
    url = normalizedURL
    focusedField = nil
    mutationFeedback.clear()

    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    isSending = true

    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.createSessionPostAwaitingRelay(
          url: normalizedURL,
          note: trimmedNote.isEmpty ? nil : trimmedNote,
          session: sessionEntity
        )
      }
      isSending = false
      if result.didSucceed {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }
}
