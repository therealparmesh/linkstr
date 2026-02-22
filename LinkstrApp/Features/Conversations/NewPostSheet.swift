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

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
              sectionLabel("Session")
              Text(sessionEntity.name)
                .font(.custom(LinkstrTheme.bodyFont, size: 15))
                .foregroundStyle(LinkstrTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )
            }

            VStack(alignment: .leading, spacing: 10) {
              sectionLabel("Link")

              TextField("https://...", text: $url)
                .font(.custom(LinkstrTheme.bodyFont, size: 14))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .disabled(isSending)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )

              LinkstrInputAssistRow(
                showClear: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showScan: false,
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

            VStack(alignment: .leading, spacing: 10) {
              sectionLabel("Note")

              ZStack(alignment: .topLeading) {
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("Optional context for this session")
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

            Text("Send requires a valid link. Note is optional.")
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
      .navigationTitle("New Post")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSending)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 8) {
          Button(action: sendPost) {
            Label(isSending ? "Sending…" : "Send Post", systemImage: "paperplane.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrPrimaryButtonStyle())
          .disabled(!canSend)

          Text(isSending ? "Waiting for relay reconnect before sending…" : " ")
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
    return normalizedURL == nil ? "Enter a valid http(s) URL." : nil
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
        url = clipboardText
      }
    #endif
  }
}

struct LinkstrInputAssistRow: View {
  let showClear: Bool
  var showScan = true
  let onPaste: () -> Void
  var onScan: (() -> Void)? = nil
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      actionButton("Paste", systemImage: "doc.on.clipboard", action: onPaste)
      if showScan, let onScan {
        actionButton("Scan", systemImage: "qrcode.viewfinder", action: onScan)
      }
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
      .foregroundStyle(LinkstrTheme.textPrimary)
    }
    .buttonStyle(.plain)
  }
}
