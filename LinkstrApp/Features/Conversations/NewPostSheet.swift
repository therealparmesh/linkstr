import NostrSDK
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct NewPostSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let sessionEntity: SessionEntity

  @State private var url = ""
  @State private var note = ""
  @State private var isSending = false
  @FocusState private var isURLFieldFocused: Bool

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrInsetSection(title: "session") {
              Text(sessionEntity.name)
                .font(LinkstrTheme.body(15, weight: .medium))
                .foregroundStyle(LinkstrTheme.textPrimary)
                .linkstrInputField()
            }

            LinkstrInsetSection(title: "link") {
              TextField("https://...", text: $url)
                .font(LinkstrTheme.body(14))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .disabled(isSending)
                .focused($isURLFieldFocused)
                .lineLimit(1)
                .linkstrInputField()

              LinkstrInputAssistRow(
                showClear: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showScan: false,
                isDisabled: isSending,
                onPaste: pasteURLFromClipboard,
                onClear: { url = "" }
              )

              Text(urlValidationHint ?? " ")
                .font(LinkstrTheme.body(12))
                .foregroundStyle(LinkstrTheme.destructive.opacity(0.92))
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                .opacity(urlValidationHint == nil ? 0 : 1)
                .accessibilityHidden(urlValidationHint == nil)
            }

            LinkstrInsetSection(title: "note") {
              ZStack(alignment: .topLeading) {
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("note")
                    .font(LinkstrTheme.body(14))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .padding(.top, LinkstrTheme.fieldVerticalPadding)
                    .padding(.leading, LinkstrTheme.fieldHorizontalPadding)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $note)
                  .font(LinkstrTheme.body(14))
                  .foregroundStyle(LinkstrTheme.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 112, maxHeight: 180)
                  .padding(4)
                  .disabled(isSending)
              }
              .linkstrFieldChrome()
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.sheetBottomPadding)
      }
      .navigationTitle("new post")
      .navigationBarTitleDisplayMode(.inline)
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("cancel")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isSending)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        LinkstrSheetActionFooter(
          title: isSending ? "sending..." : "send post",
          systemImage: "paperplane.fill",
          isDisabled: !canSend,
          message: isSending
            ? "waiting for relay reconnect before sending..."
            : (urlValidationHint ?? ""),
          action: sendPost
        )
      }
      .onChange(of: isURLFieldFocused) { _, isFocused in
        guard isFocused else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          url = "https://"
        }
      }
    }
  }

  private var normalizedURL: String? {
    LinkstrURLValidator.normalizedWebURL(from: url)
  }

  private var canSend: Bool {
    !isSending && normalizedURL != nil
  }

  private var urlValidationHint: String? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return normalizedURL == nil ? "enter a valid link." : nil
  }

  private func sendPost() {
    guard let normalizedURL else { return }
    guard !isSending else { return }

    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    isSending = true

    Task { @MainActor in
      let didCreate = await session.createSessionPostAwaitingRelay(
        url: normalizedURL,
        note: trimmedNote.isEmpty ? nil : trimmedNote,
        session: sessionEntity
      )
      isSending = false
      if didCreate {
        dismiss()
      }
    }
  }

  private func pasteURLFromClipboard() {
    #if canImport(UIKit)
      if let clipboardText = UIPasteboard.general.string {
        url = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    #endif
  }
}
