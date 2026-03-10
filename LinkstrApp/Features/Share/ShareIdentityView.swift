import SwiftUI
import UIKit

struct ShareIdentityView: View {
  @EnvironmentObject private var session: AppSession
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
      GeometryReader { _ in
        ViewThatFits(in: .vertical) {
          VStack(spacing: 0) {
            identityContent(npub: npub)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.top, 14)
          .padding(.bottom, LinkstrTheme.tabBarContentBottomInset + 28)

          ScrollView {
            identityContent(npub: npub)
              .padding(.horizontal, 12)
              .padding(.top, 14)
              .padding(.bottom, 28)
          }
          .linkstrTabBarContentInset()
        }
      }
    } else {
      LinkstrCenteredEmptyStateView(
        title: "no identity",
        systemImage: "person.crop.circle.badge.exclamationmark",
        description: "create an account or sign in with a secret key (nsec) in settings."
      )
    }
  }

  @ViewBuilder
  private func identityContent(npub: String) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
      VStack(alignment: .leading, spacing: 10) {
        Text("your profile name")
          .linkstrPrimarySectionTitleTextStyle()
          .padding(.horizontal, 2)
        Text("optional. this publishes the name other Nostr clients can show instead of your npub.")
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)

        TextField("name others see", text: $profileNameDraft)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled(true)
          .submitLabel(.done)
          .focused($isProfileNameFieldFocused)
          .onSubmit {
            submitProfileName()
          }
          .padding(12)
          .frame(minHeight: LinkstrTheme.inputControlMinHeight)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(LinkstrTheme.panelSoft)
          )

        Button {
          submitProfileName()
        } label: {
          Label(
            profileNameButtonTitle,
            systemImage: isClearingProfileName ? "trash" : "checkmark"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isClearingProfileName ? LinkstrTheme.neonAmber : LinkstrTheme.neonCyan)
        .disabled(!canSaveProfileName || isSavingProfileName)

        if let profileNameErrorMessage = session.profileNameErrorMessage {
          Text(profileNameErrorMessage)
            .font(LinkstrTheme.body(12))
            .foregroundStyle(LinkstrTheme.destructive.opacity(0.92))
        }
      }

      if let qrImage = QRCodeGenerator.image(for: npub) {
        VStack(alignment: .leading, spacing: 10) {
          Text("qr code")
            .linkstrPrimarySectionTitleTextStyle()
            .padding(.horizontal, 2)
          if let currentProfileName = session.currentProfileName {
            Text(currentProfileName)
              .font(LinkstrTheme.title(18))
              .foregroundStyle(LinkstrTheme.neonPink)
              .frame(maxWidth: .infinity, alignment: .center)
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .minimumScaleFactor(0.8)
              .padding(.horizontal, 16)
          }
          Image(uiImage: qrImage)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity, alignment: .center)
          Text("scan to add this contact key (npub)")
            .font(LinkstrTheme.body(12))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("your contact key (npub)")
          .linkstrPrimarySectionTitleTextStyle()
          .padding(.horizontal, 2)
        Text("others use this key to send links to you or add you as a contact.")
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
        Text(npub)
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(LinkstrTheme.panelSoft)
          )

        Button {
          UIPasteboard.general.string = npub
        } label: {
          Label("copy contact key (npub)", systemImage: "doc.on.doc")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(LinkstrTheme.neonCyan)
      }
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
      return "saving profile name…"
    }
    if isClearingProfileName {
      return "clear profile name"
    }
    if normalizedProfileNameDraft == nil {
      return "save profile name"
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
