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
            LinkstrSheetTitle(title: "add contact")

            LinkstrInsetSection(title: "public key (npub)") {
              TextField("public key (npub)", text: $npub)
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
                  LinkstrContactAvatar(name: previewIdentity.displayName, size: LinkstrTheme.contactAvatarSize)
                  LinkstrContactIdentityView(
                    identity: previewIdentity,
                    primaryFont: LinkstrTheme.font(.subheadline, weight: .medium),
                    nameLineLimit: 2,
                    keyLineLimit: nil
                  )
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }

            LinkstrInsetSection(title: "alias", footer: "only you see this alias.") {
              TextField("optional alias", text: $alias)
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
          LinkstrHeaderButton(title: "cancel", icon: "xmark") { dismiss() }
            .disabled(isSubmitting)
        }
        .linkstrFlatToolbarItem()

        ToolbarItem(placement: .topBarTrailing) {
          if isSubmitting {
            ProgressView()
              .tint(LinkstrTheme.accent)
              .frame(width: LinkstrTheme.minimumInteractiveDimension, height: LinkstrTheme.minimumInteractiveDimension)
              .accessibilityLabel("saving contact")
          } else {
            LinkstrHeaderButton(
              title: actionTitle,
              icon: existingContact == nil ? "person.crop.circle.badge.plus" : "checkmark",
              action: confirmFollow
            )
            .disabled(!canSubmit)
          }
        }
        .linkstrFlatToolbarItem()
      }
      .sheet(isPresented: $isPresentingConfirmation) {
        LinkstrConfirmationSheet(
          title: actionTitle,
          message: confirmationMessage(for: existingContact),
          isDestructive: false,
          onConfirm: submitFollow
        )
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
      progressMessage: "connecting to add your contact",
      validationMessage: validationMessage,
      validationColor: LinkstrTheme.destructive.opacity(0.9)
    )
  }

  private func pasteFromClipboard() {
    if let clipboardText = UIPasteboard.general.string {
      npub = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func confirmationMessage(for existingContact: ContactEntity?) -> String {
    if let existingContact {
      let name = session.resolvedIdentity(for: existingContact).displayName
      return normalizedAliasPreview == nil
        ? "clear your private alias for \(name)?"
        : "save this private alias for \(name)?"
    }
    return "add \(previewIdentity?.displayName ?? npub) to your contacts and public follow list?"
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
