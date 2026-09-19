import SwiftUI
import UIKit

struct AddContactSheet: View {
  private enum Field: Hashable {
    case npub
    case alias
  }

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  @State private var npub = ""
  @State private var alias = ""
  @State private var isSubmitting = false
  @State private var isPresentingConfirmation = false
  @State private var isPresentingScanner = false
  @State private var scannerErrorMessage: String?
  @State private var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState private var focusedField: Field?

  var body: some View {
    let existingContact = contactForPreview
    let actionTitle = existingContact == nil ? "add contact" : "save contact"
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: "add contact")

            LinkstrInsetSection(title: "public key (npub)") {
              TextField("public key (npub...)", text: $npub)
                .font(LinkstrTheme.font(.subheadline))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .npub)
                .disabled(isSubmitting)
                .submitLabel(.next)
                .onSubmit {
                  focusedField = .alias
                }
                .linkstrInputField()

              LinkstrInputAssistRow(
                showClear: !npub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isDisabled: isSubmitting,
                onPaste: {
                  pasteFromClipboard()
                  scannerErrorMessage = nil
                },
                onScan: {
                  scannerErrorMessage = nil
                  isPresentingScanner = true
                },
                onClear: {
                  npub = ""
                  scannerErrorMessage = nil
                }
              )
            }

            if let previewIdentity {
              LinkstrInsetSection(title: "preview") {
                HStack(spacing: LinkstrTheme.rowSpacing) {
                  LinkstrContactAvatar(name: previewIdentity.displayName, size: 50)
                  LinkstrContactIdentityView(
                    identity: previewIdentity,
                    primaryFont: LinkstrTheme.font(.subheadline, weight: .medium),
                    lineLimit: 2
                  )
                  .frame(maxWidth: .infinity, alignment: .leading)
                }

                if previewIdentity.chosenName == nil && normalizedAliasPreview == nil {
                  Text("looking up published nostr name...")
                    .font(LinkstrTheme.font(.caption))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                }
              }
            }

            LinkstrInsetSection(title: "alias", footer: "optional. only you see this alias.") {
              TextField("alias", text: $alias)
                .font(LinkstrTheme.font(.subheadline))
                .textInputAutocapitalization(.words)
                .focused($focusedField, equals: .alias)
                .disabled(isSubmitting)
                .submitLabel(.done)
                .onSubmit(confirmFollow)
                .linkstrInputField()
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
        .linkstrKeyboardDismissal()
      }
      .task(id: previewPubkeyHex) {
        guard let previewPubkeyHex else { return }
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: [previewPubkeyHex])
      }
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
          .disabled(isSubmitting)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button {
            confirmFollow()
          } label: {
            if isSubmitting {
              ProgressView()
                .frame(width: 30, height: 30, alignment: .center)
            } else {
              Image(systemName: existingContact == nil ? "person.crop.circle.badge.plus" : "checkmark")
                .linkstrToolbarIconLabel()
            }
          }
          .accessibilityLabel(actionTitle)
          .tint(LinkstrTheme.accent)
          .disabled(!canSubmit)
        }
      }
      .alert(actionTitle, isPresented: $isPresentingConfirmation) {
        Button("cancel", role: .cancel) {}
        Button(actionTitle, action: submitFollow)
      } message: {
        if let existingContact {
          let name = session.resolvedIdentity(for: existingContact).displayName
          Text(normalizedAliasPreview == nil
            ? "clear your private alias for \(name)?"
            : "save this private alias for \(name)?")
        } else {
          Text("add \(previewIdentity?.displayName ?? npub) to your contacts and public follow list?")
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
      .sheet(isPresented: $isPresentingScanner) {
        LinkstrQRScannerSheet { scannedValue in
          if let scannedNPub = ContactKeyParser.extractNPub(from: scannedValue) {
            npub = scannedNPub
            scannerErrorMessage = nil
          } else {
            scannerErrorMessage = "no valid public key (npub) found in that qr code."
          }
        }
      }
      .onChange(of: npub) { _, _ in
        mutationFeedback.clear()
        guard normalizedScannerErrorMessage.isEmpty == false else { return }
        scannerErrorMessage = nil
      }
      .onChange(of: alias) { _, _ in
        mutationFeedback.clear()
      }
    }
  }

  private var canSubmit: Bool {
    !isSubmitting && previewPubkeyHex != nil
  }

  private var validationMessage: String? {
    if normalizedScannerErrorMessage.isEmpty == false {
      return normalizedScannerErrorMessage
    }
    let trimmedNPub = npub.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedNPub.isEmpty == false && previewPubkeyHex == nil {
      return "enter a valid public key."
    }
    return nil
  }

  private var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isSubmitting,
      progressMessage: "waiting for relay reconnect before adding...",
      validationMessage: validationMessage,
      validationColor: LinkstrTheme.destructive.opacity(0.9)
    )
  }

  private func pasteFromClipboard() {
    if let clipboardText = UIPasteboard.general.string {
      npub = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func confirmFollow() {
    guard canSubmit else { return }
    focusedField = nil
    isPresentingConfirmation = true
  }

  private func submitFollow() {
    guard canSubmit else { return }
    focusedField = nil
    mutationFeedback.clear()
    isSubmitting = true
    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.addContact(npub: npub, alias: alias)
      }
      isSubmitting = false
      if result.didSucceed {
        dismiss()
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }

  private var normalizedScannerErrorMessage: String {
    guard let scannerErrorMessage else { return "" }
    return scannerErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedAliasPreview: String? {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var previewPubkeyHex: String? {
    let candidate = ContactKeyParser.extractNPub(from: npub) ?? npub
    return NostrValueNormalizer.normalizedPubkeyHex(fromAnyPublicKeyString: candidate)
  }

  private var contactForPreview: ContactEntity? {
    guard let owner = session.identityService.pubkeyHex, let target = previewPubkeyHex else { return nil }
    return try? session.contactStore.contact(ownerPubkey: owner, targetPubkey: target)
  }

  private var previewIdentity: LinkstrResolvedIdentity? {
    guard let previewPubkeyHex else { return nil }
    let resolvedIdentity = session.resolvedIdentity(for: previewPubkeyHex, contacts: [])
    return LinkstrResolvedIdentity(
      localAlias: normalizedAliasPreview,
      chosenName: resolvedIdentity.chosenName,
      pubkeyHex: previewPubkeyHex
    )
  }
}
