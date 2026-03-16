import NostrSDK
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct NewPostSheet: View {
  private enum Field: Hashable {
    case url
    case note
  }

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let sessionEntity: SessionEntity

  @State private var url = ""
  @State private var note = ""
  @State private var isSending = false
  @State private var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState private var focusedField: Field?

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

            if !canCreatePostInSession {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.xmark")
                  .font(LinkstrTheme.system(14, weight: .semibold))
                  .foregroundStyle(LinkstrTheme.textSecondary)

                Text("you're no longer a member. this session is read-only.")
                  .font(LinkstrTheme.body(12))
                  .foregroundStyle(LinkstrTheme.textSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
              .padding(.vertical, 10)
              .background(
                RoundedRectangle(
                  cornerRadius: LinkstrTheme.fieldCornerRadius,
                  style: .continuous
                )
                .fill(LinkstrTheme.panelMuted)
              )
              .overlay {
                RoundedRectangle(
                  cornerRadius: LinkstrTheme.fieldCornerRadius,
                  style: .continuous
                )
                .stroke(LinkstrTheme.separator.opacity(1.4), lineWidth: 1)
              }
            }

            LinkstrInsetSection(title: "link") {
              TextField("example.com", text: $url)
                .font(LinkstrTheme.body(14))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .disabled(isSending)
                .focused($focusedField, equals: .url)
                .lineLimit(1)
                .submitLabel(.next)
                .onSubmit {
                  focusedField = .note
                }
                .linkstrInputField()

              LinkstrInputAssistRow(
                showClear: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showScan: false,
                isDisabled: isSending,
                onPaste: pasteURLFromClipboard,
                onClear: { url = "" }
              )

              Text(urlFieldHint ?? " ")
                .font(LinkstrTheme.body(12))
                .foregroundStyle(urlFieldHintColor)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                .opacity(urlFieldHint == nil ? 0 : 1)
                .accessibilityHidden(urlFieldHint == nil)
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
                  .focused($focusedField, equals: .note)
                  .disabled(isSending)
              }
              .linkstrFieldChrome()
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .scrollDismissesKeyboard(.interactively)
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

        ToolbarItem(placement: .topBarTrailing) {
          Button {
            sendPost()
          } label: {
            if isSending {
              ProgressView()
                .frame(width: 30, height: 30, alignment: .center)
            } else {
              Image(systemName: "paperplane.fill")
                .linkstrToolbarIconLabel()
            }
          }
          .accessibilityLabel("send post")
          .tint(LinkstrTheme.accent)
          .disabled(!canSend)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let footerStatus {
          LinkstrSheetStatusFooter(
            message: footerStatus.message,
            messageColor: footerStatus.color
          )
        }
      }
      .onChange(of: focusedField) { previousField, focusedField in
        guard previousField == .url, focusedField != .url else { return }
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
    LinkstrURLValidator.normalizedWebURL(from: url)
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

  private var urlFieldHint: String? {
    if let urlValidationHint {
      return urlValidationHint
    }

    guard let normalizedURL else { return nil }
    return Self.composerAvailabilityHint(for: URLClassifier.mediaStrategy(for: normalizedURL))
  }

  private var urlFieldHintColor: Color {
    if urlValidationHint != nil {
      return LinkstrTheme.destructive.opacity(0.92)
    }
    return LinkstrTheme.accent.opacity(0.92)
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
      progressMessage: "waiting for relay reconnect before sending...",
      validationMessage: validationMessage,
      validationColor: LinkstrTheme.destructive.opacity(0.9)
    )
  }

  static func composerAvailabilityHint(for strategy: URLClassifier.MediaStrategy) -> String? {
    if strategy.allowsLocalPlaybackToggle {
      return "viewable in-app. may be saveable."
    }
    if case .embedOnly = strategy {
      return "viewable in-app."
    }
    return nil
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
        dismiss()
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
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
