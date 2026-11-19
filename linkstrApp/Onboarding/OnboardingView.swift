import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct OnboardingView: View {
  @EnvironmentObject private var session: AppSession
  @FocusState private var isEditingField: Bool
  @State private var secretKey = ""
  @State private var isSecretKeyVisible = false
  @State private var createdProfileName = ""
  @State private var isSavingCreatedProfileName = false
  @State private var accountFeedback = LinkstrSheetMutationFeedback()

  var body: some View {
    ZStack {
      LinkstrBackgroundView()

      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          Text(
            session.pendingCreatedAccountNsec == nil
              ? "share and watch links with people you trust."
              : "keep a copy so you can sign in on another device."
          )
          .font(LinkstrTheme.font(.subheadline))
          .foregroundStyle(LinkstrTheme.textSecondary)

          if let pendingCreatedAccountNsec = session.pendingCreatedAccountNsec {
            createdAccountStep(nsec: pendingCreatedAccountNsec)
          } else {
            signInAndCreateStep
          }
        }
        .linkstrPageContentLayout(topPadding: LinkstrTheme.pinnedPageContentTopPadding)
      }
      .linkstrPinnedPageHeader { header }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if session.pendingCreatedAccountNsec != nil, let status = footerStatus {
        LinkstrSheetStatusFooter(message: status.message, messageColor: status.color)
      }
    }
    .linkstrKeyboardDismissal($isEditingField)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: createdProfileName) { _, _ in
      session.clearProfileNameError()
      accountFeedback.clear()
    }
  }

  private var footerStatus: LinkstrSheetFooterStatus? {
    accountFeedback.footerStatus(isRunning: isSavingCreatedProfileName, progressMessage: "saving profile name…")
  }

  private var header: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrAppIconBadge(size: 44)
        .accessibilityHidden(true)
      LinkstrScreenTitle(title: session.pendingCreatedAccountNsec == nil ? "welcome to linkstr" : "save your key")
        .lineLimit(3)
    }
  }

  private var signInAndCreateStep: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
      LinkstrInsetSection(title: "sign in") {
        HStack(spacing: LinkstrTheme.metaSpacing) {
          Group {
            if isSecretKeyVisible {
              TextField("secret key (nsec)", text: $secretKey, prompt: LinkstrTheme.placeholder("secret key (nsec)"))
            } else {
              SecureField("secret key (nsec)", text: $secretKey, prompt: LinkstrTheme.placeholder("secret key (nsec)"))
            }
          }
          .font(LinkstrTheme.font(.subheadline))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .submitLabel(.go)
          .onSubmit(submitSecretKey)
          .focused($isEditingField)
          .privacySensitive()

          Button {
            isSecretKeyVisible.toggle()
          } label: {
            Image(systemName: isSecretKeyVisible ? "eye.slash" : "eye")
              .frame(
                width: LinkstrTheme.minimumInteractiveDimension,
                height: LinkstrTheme.minimumInteractiveDimension
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(LinkstrTheme.textSecondary)
          .accessibilityLabel(isSecretKeyVisible ? "hide secret key" : "show secret key")
        }
        .padding(.leading, LinkstrTheme.fieldHorizontalPadding)
        .padding(.trailing, LinkstrTheme.metaSpacing)
        .frame(maxWidth: .infinity, minHeight: LinkstrTheme.minimumInteractiveDimension)
        .linkstrFieldChrome()

        LinkstrInputAssistRow(text: $secretKey)

        Button {
          session.importNsec(secretKey)
        } label: {
          LinkstrActionButtonLabel(title: "sign in", systemImage: "arrow.right.circle.fill")
        }
        .linkstrPrimaryButton()
        .disabled(secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        RestoreBackupButton()
      }

      HStack(spacing: LinkstrTheme.rowSpacing) {
        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)

        Text("or")
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .foregroundStyle(LinkstrTheme.textTertiary)

        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)
      }
      .padding(.horizontal, 2)

      LinkstrInsetSection {
        Button {
          session.createAccount()
        } label: {
          LinkstrActionButtonLabel(title: "create account", systemImage: "plus.circle.fill")
        }
        .linkstrSecondaryButton()
      }
    }
  }

  private func createdAccountStep(nsec: String) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
      LinkstrInsetSection(
        title: "secret key (nsec)",
        footer: "keep this key private. anyone with it can sign in as you."
      ) {
        Text(nsec)
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
          .privacySensitive()
          .linkstrInputField()

        Button {
          UIPasteboard.general.string = nsec
          LinkstrToast.showSuccess("secret key copied")
        } label: {
          LinkstrActionButtonLabel(title: "copy secret key", systemImage: "doc.on.doc")
        }
        .linkstrCautionButton(prominent: true)
      }

      LinkstrInsetSection(
        title: "profile name",
        footer: "optional. others can see this name."
      ) {
        TextField("name others see", text: $createdProfileName, prompt: LinkstrTheme.placeholder("name others see"))
          .font(LinkstrTheme.font(.subheadline))
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled(true)
          .submitLabel(.done)
          .focused($isEditingField)
          .onSubmit(completePendingAccountCreation)
          .linkstrInputField()
          .disabled(isSavingCreatedProfileName)

        Button {
          completePendingAccountCreation()
        } label: {
          LinkstrActionButtonLabel(
            title: createdAccountContinueButtonTitle,
            systemImage: "checkmark.circle.fill"
          )
        }
        .linkstrPrimaryButton()
        .disabled(isSavingCreatedProfileName)
      }
    }
  }

  private func submitSecretKey() {
    guard !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    session.importNsec(secretKey)
  }

  private var normalizedCreatedProfileName: String? {
    NostrProfileMetadata.normalizedChosenName(createdProfileName)
  }

  private var createdAccountContinueButtonTitle: String {
    if isSavingCreatedProfileName {
      return "saving profile name…"
    }
    if normalizedCreatedProfileName == nil {
      return "continue"
    }
    return "save name and continue"
  }

  private func completePendingAccountCreation() {
    guard !isSavingCreatedProfileName else { return }
    session.clearProfileNameError()
    accountFeedback.clear()
    guard normalizedCreatedProfileName != nil else {
      session.completePendingAccountCreation()
      return
    }

    isSavingCreatedProfileName = true
    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.completePendingAccountCreation(profileName: createdProfileName)
      }
      isSavingCreatedProfileName = false
      if result.didSucceed {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        createdProfileName = ""
      } else {
        accountFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }
}
