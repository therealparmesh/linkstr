import SwiftUI
import UIKit

struct YouView: View {
  @EnvironmentObject private var session: AppSession
  @State private var qrImage: UIImage?
  @State private var profileNameDraft = ""
  @State private var isSavingProfileName = false
  @FocusState private var isProfileNameFieldFocused: Bool

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear {
      session.clearProfileNameError()
      syncProfileNameDraft()
    }
    .onChange(of: session.currentProfileName) { _, _ in
      if !isSavingProfileName {
        syncProfileNameDraft()
      }
    }
    .onChange(of: profileNameDraft) { _, _ in
      session.clearProfileNameError()
    }
  }

  @ViewBuilder
  private var content: some View {
    if let npub = session.identityService.npub {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          qrSection(npub: npub)
          npubSection(npub: npub)
          profileNameSection
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
      }
      .task(id: npub) {
        qrImage = QRCodeGenerator.image(for: npub)
      }
      .linkstrTabBarContentInset()
    } else {
      LinkstrCenteredEmptyStateView(
        title: "no identity",
        systemImage: "person.crop.circle.badge.exclamationmark",
        description: "sign in or create an account in settings."
      )
    }
  }

  private var profileNameSection: some View {
    LinkstrInsetSection(
      title: "profile name",
      footer: "optional. others can see this name."
    ) {
      TextField("name others see", text: $profileNameDraft)
        .font(LinkstrTheme.body(15))
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled(true)
        .submitLabel(.done)
        .focused($isProfileNameFieldFocused)
        .onSubmit(submitProfileName)
        .linkstrInputField()

      if let profileNameErrorMessage = session.profileNameErrorMessage {
        Text(profileNameErrorMessage)
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.destructive.opacity(0.92))
      }

      profileNameButton
    }
  }

  private func qrSection(npub: String) -> some View {
    LinkstrInsetSection(
      title: "qr code",
      footer: "scan to add this account."
    ) {
      if let profileName = session.currentProfileName, !profileName.isEmpty {
        Text(profileName)
          .font(LinkstrTheme.title(18, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .frame(maxWidth: .infinity, alignment: .center)
      }

      if let qrImage {
        Image(uiImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 280)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 8)
      }
    }
  }

  private func npubSection(npub: String) -> some View {
    LinkstrInsetSection(
      title: "public key (npub)",
      footer: "copy this public key to add this account elsewhere."
    ) {
      Text(npub)
        .font(LinkstrTheme.body(13))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .textSelection(.enabled)
        .linkstrInputField()

      Button {
        UIPasteboard.general.string = npub
      } label: {
        LinkstrActionButtonLabel(title: "copy public key", systemImage: "doc.on.doc")
      }
      .linkstrSecondaryButton()
    }
  }

  @ViewBuilder
  private var profileNameButton: some View {
    if isClearingProfileName {
      Button {
        submitProfileName()
      } label: {
        LinkstrActionButtonLabel(
          title: profileNameButtonTitle,
          systemImage: "minus.circle.fill"
        )
      }
      .linkstrSecondaryButton()
      .disabled(!canSaveProfileName || isSavingProfileName)
    } else {
      Button {
        submitProfileName()
      } label: {
        LinkstrActionButtonLabel(
          title: profileNameButtonTitle,
          systemImage: "checkmark.circle.fill"
        )
      }
      .linkstrPrimaryButton()
      .disabled(!canSaveProfileName || isSavingProfileName)
    }
  }

  private var normalizedProfileNameDraft: String? {
    NostrProfileMetadata.normalizedChosenName(profileNameDraft)
  }

  private var canSaveProfileName: Bool {
    normalizedProfileNameDraft
      != NostrProfileMetadata.normalizedChosenName(session.currentProfileName)
  }

  private var isClearingProfileName: Bool {
    normalizedProfileNameDraft == nil && session.currentProfileName != nil
  }

  private var profileNameButtonTitle: String {
    if isSavingProfileName {
      return "saving profile name..."
    }
    if isClearingProfileName {
      return "clear profile name"
    }
    return "save profile name"
  }

  private func saveProfileName() {
    guard canSaveProfileName else { return }
    isSavingProfileName = true

    Task { @MainActor in
      let didSave = await session.updateOwnProfileName(profileNameDraft)
      isSavingProfileName = false
      if didSave {
        syncProfileNameDraft()
      }
    }
  }

  private func submitProfileName() {
    dismissProfileNameKeyboard()
    saveProfileName()
  }

  private func dismissProfileNameKeyboard() {
    isProfileNameFieldFocused = false
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func syncProfileNameDraft() {
    profileNameDraft = session.currentProfileName ?? ""
  }
}
