import SwiftUI
import UIKit

struct YouView: View {
  @EnvironmentObject private var session: AppSession
  let openSettings: () -> Void
  @State private var qrImage: UIImage?
  @State private var isEditingProfile = false
  @State private var profileNameDraft = ""
  @State private var isSavingProfileName = false
  @State private var profileFeedback = LinkstrSheetMutationFeedback()
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
      profileFeedback.clear()
    }
  }

  @ViewBuilder
  private var content: some View {
    if let npub = session.identityService.npub {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          LinkstrPageHeader(title: "you") { EmptyView() }
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            profileHeader(npub: npub)
            identitySection(npub: npub)
            LinkstrPageShortcut(title: "settings", icon: "gearshape", action: openSettings)
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.pageHeaderTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .task(id: npub) {
        qrImage = QRCodeGenerator.image(for: npub)
      }
      .sheet(isPresented: $isEditingProfile, onDismiss: syncProfileNameDraft) {
        NavigationStack {
          ScrollView {
            VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
              LinkstrSheetTitle(title: "edit profile")
              profileNameSection
            }
            .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
            .padding(.top, LinkstrTheme.screenTopPadding)
            .padding(.bottom, LinkstrTheme.screenBottomPadding)
            .linkstrReadableContent()
          }
          .background(LinkstrBackgroundView())
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              LinkstrHeaderButton(title: "cancel", icon: "xmark") { isEditingProfile = false }
                .disabled(isSavingProfileName)
            }
            .linkstrFlatToolbarItem()
            ToolbarItem(placement: .confirmationAction) {
              LinkstrHeaderButton(
                title: profileNameButtonTitle,
                icon: isClearingProfileName ? "trash" : "checkmark",
                foreground: isClearingProfileName ? LinkstrTheme.destructive : LinkstrTheme.accent,
                action: submitProfileName
              )
              .disabled(!canSaveProfileName || isSavingProfileName)
            }
            .linkstrFlatToolbarItem()
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if let status = profileNameStatus {
              LinkstrSheetStatusFooter(message: status.message, messageColor: status.color)
            }
          }
          .interactiveDismissDisabled(isSavingProfileName)
          .linkstrKeyboardDismissal()
          .linkstrBarChrome()
        }
      }
    } else {
      VStack(spacing: LinkstrTheme.listBlockSpacing) {
        LinkstrPageHeader(title: "you") { EmptyView() }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.pageHeaderTopPadding)
        LinkstrCenteredEmptyStateView(
          title: "no identity",
          systemImage: "person.crop.circle.badge.exclamationmark",
          description: "sign in or create an account in settings.",
          actionTitle: "open settings",
          actionSystemImage: "gearshape",
          action: openSettings
        )
      }
      .linkstrReadableContent()
    }
  }

  private var profileNameSection: some View {
    LinkstrInsetSection(
      title: "profile name",
      footer: isClearingProfileName
        ? "confirm to remove your profile name." : "optional. others can see this name."
    ) {
      TextField("name others see", text: $profileNameDraft)
        .font(LinkstrTheme.font(.subheadline))
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled(true)
        .submitLabel(.done)
        .focused($isProfileNameFieldFocused)
        .onSubmit(submitProfileName)
        .linkstrInputField()
        .disabled(isSavingProfileName)

      if !profileNameDraft.isEmpty {
        Button {
          profileNameDraft = ""
        } label: {
          LinkstrActionButtonLabel(title: "clear text", systemImage: "xmark.circle")
        }
        .linkstrSecondaryButton()
        .disabled(isSavingProfileName)
      }
    }
  }

  private func profileHeader(npub: String) -> some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrContactAvatar(name: session.currentProfileName ?? "you", size: 68, seed: npub)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        Text(session.currentProfileName ?? "your profile")
          .font(LinkstrTheme.font(.title2, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Button { isEditingProfile = true } label: {
          Text("edit profile")
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.accent)
            .frame(minHeight: LinkstrTheme.minimumInteractiveDimension, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func identitySection(npub: String) -> some View {
    VStack(spacing: LinkstrTheme.compactSpacing) {
      if let qrImage {
        Image(uiImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 174)
          .padding(10)
          .background(LinkstrTheme.textPrimary, in: .rect(cornerRadius: 16))
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
  }
}

private extension YouView {
  var profileNameStatus: LinkstrSheetFooterStatus? {
    profileFeedback.footerStatus(isRunning: isSavingProfileName, progressMessage: "saving profile name…")
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
    return "save profile name"
  }

  private func saveProfileName() {
    guard canSaveProfileName, !isSavingProfileName else { return }
    isSavingProfileName = true
    profileFeedback.clear()

    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.updateOwnProfileName(profileNameDraft)
      }
      isSavingProfileName = false
      if result.didSucceed {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        syncProfileNameDraft()
        isEditingProfile = false
      } else {
        profileFeedback.record(errorMessage: result.errorMessage)
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
