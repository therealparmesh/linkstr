import SwiftUI
import UIKit

struct YouView: View {
  @EnvironmentObject private var session: AppSession
  let openSettings: (SettingsSection?) -> Void
  @State private var qrImage: UIImage?
  @State private var isEditingProfile = false
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
          heading
          identitySection(npub: npub)
          settingsShortcuts
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .task(id: npub) {
        qrImage = QRCodeGenerator.image(for: npub)
      }
      .sheet(isPresented: $isEditingProfile, onDismiss: syncProfileNameDraft) {
        NavigationStack {
          ScrollView {
            profileNameSection
              .padding(LinkstrTheme.screenHorizontalPadding)
              .linkstrReadableContent()
          }
          .background(LinkstrBackgroundView())
          .navigationTitle("edit profile")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("close") { isEditingProfile = false }
                .disabled(isSavingProfileName)
            }
          }
          .interactiveDismissDisabled(isSavingProfileName)
          .linkstrKeyboardDismissal()
          .linkstrBarChrome()
        }
      }
    } else {
      VStack(spacing: 0) {
        heading
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
        LinkstrCenteredEmptyStateView(
          title: "no identity",
          systemImage: "person.crop.circle.badge.exclamationmark",
          description: "sign in or create an account in settings.",
          actionTitle: "open settings",
          actionSystemImage: "gearshape",
          action: { openSettings(nil) }
        )
      }
      .linkstrReadableContent()
    }
  }

  private var heading: some View {
    LinkstrTabHeader(title: "you") {
      LinkstrHeaderButton(title: "settings", icon: "gearshape") { openSettings(nil) }
    }
  }

  private var profileNameSection: some View {
    LinkstrInsetSection(
      title: "profile name",
      footer: "optional. others can see this name."
    ) {
      TextField("name others see", text: $profileNameDraft)
        .font(LinkstrTheme.font(.subheadline))
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled(true)
        .submitLabel(.done)
        .focused($isProfileNameFieldFocused)
        .onSubmit(submitProfileName)
        .linkstrInputField()

      if let profileNameErrorMessage = session.profileNameErrorMessage {
        Text(profileNameErrorMessage)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.destructive.opacity(0.92))
      }

      profileNameButton
    }
  }

  private func identitySection(npub: String) -> some View {
    VStack(spacing: 14) {
      LinkstrContactAvatar(name: session.currentProfileName ?? "you", size: 68, seed: npub)

      Text(session.currentProfileName ?? "your profile")
        .font(LinkstrTheme.font(.title2, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .multilineTextAlignment(.center)

      Button("edit profile") { isEditingProfile = true }
        .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        .frame(minHeight: 44)

      if let qrImage {
        Image(uiImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 174)
          .padding(10)
          .background(.white, in: .rect(cornerRadius: 16))
          .accessibilityLabel("QR code for your public key")
      }

      Text(npub)
        .font(LinkstrTheme.font(.caption).monospaced())
        .foregroundStyle(LinkstrTheme.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 260)
        .textSelection(.enabled)
        .accessibilityLabel("public key: \(npub)")

      LinkstrAdaptiveButtonRow {
        Button {
          UIPasteboard.general.string = npub
          LinkstrToast.showSuccess("public key copied")
        } label: {
          LinkstrActionButtonLabel(title: "copy", systemImage: "doc.on.doc")
        }
        .linkstrSecondaryButton()
        .accessibilityLabel("copy public key")

        ShareLink(item: npub) {
          LinkstrActionButtonLabel(title: "share", systemImage: "square.and.arrow.up")
        }
        .linkstrSecondaryButton()
        .accessibilityLabel("share public key")
      }
      .frame(maxWidth: 300)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }

  private var settingsShortcuts: some View {
    VStack(spacing: 0) {
      ForEach([SettingsSection.playback, .storage, .backup], id: \.self) { section in
        settingsRow(section.rawValue, icon: section.icon) { openSettings(section) }
      }
      settingsRow("all settings", icon: "gearshape") { openSettings(nil) }
    }
  }

  private func settingsRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .frame(width: 24)
          .foregroundStyle(LinkstrTheme.accent)
        Text(title)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
      .font(LinkstrTheme.font(.subheadline, weight: .medium))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .padding(.vertical, 12)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .top) { LinkstrListRowDivider(leadingInset: 0) }
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        syncProfileNameDraft()
        isEditingProfile = false
      }
    }
  }

  private func submitProfileName() {
    isProfileNameFieldFocused = false
    saveProfileName()
  }

  private func syncProfileNameDraft() {
    profileNameDraft = session.currentProfileName ?? ""
  }
}
