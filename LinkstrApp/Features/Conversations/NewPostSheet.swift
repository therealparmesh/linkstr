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
          VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
              sectionLabel("session")
              Text(sessionEntity.name)
                .font(.custom(LinkstrTheme.bodyFont, size: 15))
                .foregroundStyle(LinkstrTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .frame(minHeight: LinkstrTheme.inputControlMinHeight)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
              sectionLabel("link")

              TextField("https://...", text: $url)
                .font(.custom(LinkstrTheme.bodyFont, size: 14))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .disabled(isSending)
                .focused($isURLFieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .lineLimit(1)
                .frame(minHeight: LinkstrTheme.inputControlMinHeight)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )

              LinkstrInputAssistRow(
                showClear: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showScan: false,
                isDisabled: isSending,
                onPaste: pasteURLFromClipboard,
                onClear: { url = "" }
              )

              Text(urlValidationHint ?? " ")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(Color.red.opacity(0.92))
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                .opacity(urlValidationHint == nil ? 0 : 1)
                .accessibilityHidden(urlValidationHint == nil)
            }

            VStack(alignment: .leading, spacing: 8) {
              sectionLabel("note")

              ZStack(alignment: .topLeading) {
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("optional context for this session")
                    .font(.custom(LinkstrTheme.bodyFont, size: 14))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $note)
                  .font(.custom(LinkstrTheme.bodyFont, size: 14))
                  .foregroundStyle(LinkstrTheme.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 112, maxHeight: 180)
                  .padding(4)
                  .disabled(isSending)
              }
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )
            }

            Text("send requires a valid link. note is optional.")
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .padding(.horizontal, 2)
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 120)
        .scrollBounceBehavior(.basedOnSize)
      }
      .navigationTitle("new post")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("cancel") { dismiss() }
            .disabled(isSending)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 8) {
          Button(action: sendPost) {
            Label(isSending ? "sending…" : "send post", systemImage: "paperplane.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrPrimaryButtonStyle())
          .disabled(!canSend)

          Text(isSending ? "waiting for relay reconnect before sending…" : " ")
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
            .opacity(isSending ? 1 : 0)
            .accessibilityHidden(!isSending)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
          Rectangle()
            .fill(LinkstrTheme.bgBottom.opacity(0.95))
            .overlay(alignment: .top) {
              Rectangle()
                .fill(LinkstrTheme.textSecondary.opacity(0.18))
                .frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
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
    return normalizedURL == nil ? "enter a valid http(s) url." : nil
  }

  private func sectionLabel(_ text: String) -> some View {
    Text(text)
      .font(.custom(LinkstrTheme.titleFont, size: 12))
      .foregroundStyle(LinkstrTheme.textSecondary)
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

struct LinkstrInputAssistRow: View {
  let showClear: Bool
  var showScan = true
  var isDisabled = false
  let onPaste: () -> Void
  var onScan: (() -> Void)? = nil
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      assistButton("paste", systemImage: "doc.on.clipboard", action: onPaste)
      if showScan, let onScan {
        assistButton("scan", systemImage: "qrcode.viewfinder", action: onScan)
      }
      if showClear {
        assistButton(
          "clear",
          systemImage: "xmark.circle",
          tint: Color.red.opacity(0.9),
          action: onClear
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.65 : 1)
  }

  private func assistButton(
    _ title: String,
    systemImage: String,
    tint: Color = LinkstrTheme.textPrimary,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 14, height: 14)
        Text(title)
          .font(.custom(LinkstrTheme.bodyFont, size: 12))
      }
      .foregroundStyle(tint)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minHeight: 30)
      .background(
        Capsule(style: .continuous)
          .fill(LinkstrTheme.panelSoft)
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(LinkstrTheme.textSecondary.opacity(0.24), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}
