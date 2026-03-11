import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct OnboardingView: View {
  @EnvironmentObject private var session: AppSession
  @State private var secretKey = ""
  @State private var createdProfileName = ""
  @State private var isSavingCreatedProfileName = false

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            header

            if let pendingCreatedAccountNsec = session.pendingCreatedAccountNsec {
              createdAccountStep(nsec: pendingCreatedAccountNsec)
            } else {
              signInAndCreateStep
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
        }
      }
      .navigationTitle("welcome")
      .navigationBarTitleDisplayMode(.inline)
      .linkstrBarChrome()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: createdProfileName) { _, _ in
      session.clearProfileNameError()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("welcome to linkstr.")
        .font(LinkstrTheme.title(30, weight: .bold))
        .foregroundStyle(LinkstrTheme.textPrimary)
    }
  }

  private var signInAndCreateStep: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
      LinkstrInsetSection(title: "sign in") {
        TextField("secret key (nsec)", text: $secretKey)
          .font(LinkstrTheme.body(15))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .linkstrInputField()

        LinkstrInputAssistRow(
          showClear: !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          showScan: false,
          onPaste: pasteSecretKeyFromClipboard,
          onClear: { secretKey = "" }
        )

        Button {
          session.importNsec(secretKey)
        } label: {
          LinkstrActionButtonLabel(title: "sign in", systemImage: "arrow.right.circle.fill")
        }
        .linkstrPrimaryButton()
        .disabled(secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      HStack(spacing: 12) {
        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)

        Text("or")
          .font(LinkstrTheme.body(12, weight: .medium))
          .foregroundStyle(LinkstrTheme.textTertiary)

        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)
      }
      .padding(.horizontal, 2)

      LinkstrInsetSection(title: "create account") {
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
        footer: "save this key. it works like your account password."
      ) {
        Text(nsec)
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
          .privacySensitive()
          .linkstrInputField()

        Button {
          UIPasteboard.general.string = nsec
        } label: {
          LinkstrActionButtonLabel(title: "copy key", systemImage: "doc.on.doc")
        }
        .linkstrCautionButton(prominent: true)
      }

      LinkstrInsetSection(
        title: "name",
        footer: "optional. others can see this name."
      ) {
        TextField("name others see", text: $createdProfileName)
          .font(LinkstrTheme.body(15))
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled(true)
          .linkstrInputField()

        if let profileNameErrorMessage = session.profileNameErrorMessage {
          Text(profileNameErrorMessage)
            .font(LinkstrTheme.body(12))
            .foregroundStyle(LinkstrTheme.destructive.opacity(0.92))
        }

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

  private func pasteSecretKeyFromClipboard() {
    #if canImport(UIKit)
      if let clipboardText = UIPasteboard.general.string {
        secretKey = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    #endif
  }

  private var normalizedCreatedProfileName: String? {
    NostrProfileMetadata.normalizedChosenName(createdProfileName)
  }

  private var createdAccountContinueButtonTitle: String {
    if isSavingCreatedProfileName {
      return "saving name..."
    }
    if normalizedCreatedProfileName == nil {
      return "enter app"
    }
    return "save name and enter app"
  }

  private func completePendingAccountCreation() {
    guard !isSavingCreatedProfileName else { return }
    session.clearProfileNameError()
    guard normalizedCreatedProfileName != nil else {
      session.completePendingAccountCreation()
      return
    }

    isSavingCreatedProfileName = true
    Task { @MainActor in
      let didComplete = await session.completePendingAccountCreation(
        profileName: createdProfileName
      )
      isSavingCreatedProfileName = false
      if didComplete {
        createdProfileName = ""
      }
    }
  }
}
