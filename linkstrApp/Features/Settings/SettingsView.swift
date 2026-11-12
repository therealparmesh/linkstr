import SwiftUI
import UIKit

struct LinkstrAdaptiveButtonRow<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    let layout = dynamicTypeSize >= .xLarge
      ? AnyLayout(VStackLayout(spacing: LinkstrTheme.buttonRowSpacing))
      : AnyLayout(HStackLayout(spacing: LinkstrTheme.buttonRowSpacing))

    layout { content }
  }
}

enum SettingsSection: String, Hashable {
  case playback
  case storage
  case backup
  case relays

  var icon: String {
    switch self {
    case .playback: "play.circle"
    case .storage: "internaldrive"
    case .backup: "externaldrive.badge.timemachine"
    case .relays: "antenna.radiowaves.left.and.right"
    }
  }
}

struct SettingsView: View {
  let initialSection: SettingsSection?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentObject var session: AppSession

  @AppStorage("loopLocalVideos") private var loopLocalVideos = true
  @AppStorage("watchMuted") private var watchMuted = false

  @State private var relayURL = ""
  @State private var showsRelayAddressError = false
  @State var revealedNsec = ""
  @State var isNsecVisible = false
  @State var isPresentingLogoutOptions = false
  @State var isPresentingDeleteAccountConfirm = false
  @State private var isConfirmingAccountDeletion = false
  @State var isDeletingAccount = false
  @State var clearableStorageBytes: Int64?
  @State var clearableMetadataBytes: Int64?
  @State var isRefreshingStorageUsage = false
  @State var storageUsageRefreshID = 0

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .task(id: storageUsageRefreshID) {
      await loadStorageUsage()
    }
    .onChange(of: scenePhase) { _, newValue in
      switch newValue {
      case .active:
        refreshStorageUsage()
      case .inactive, .background:
        hideSensitiveIdentityContent()
      @unknown default:
        hideSensitiveIdentityContent()
      }
    }
    .onDisappear(perform: hideSensitiveIdentityContent)
  }

  private var content: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          playbackSection.id(SettingsSection.playback)
          relaysSection.id(SettingsSection.relays)
          storageSection.id(SettingsSection.storage)
          BackupSection().id(SettingsSection.backup)
          identitySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.pinnedPageContentTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .onAppear {
        guard let initialSection else { return }
        // Resolve section frames after the first layout pass.
        DispatchQueue.main.async { proxy.scrollTo(initialSection, anchor: .top) }
      }
    }
    .linkstrPinnedPageHeader {
      LinkstrPageHeader(title: "settings", backLabel: "back to you") { EmptyView() }
    }
    .linkstrKeyboardDismissal()
    .alert("log out", isPresented: $isPresentingLogoutOptions) {
      Button("log out and keep local data") {
        session.logOut(clearLocalData: false)
      }
      Button("log out and clear local data", role: .destructive) {
        session.logOut(clearLocalData: true)
      }
      Button("cancel", role: .cancel) {}
    } message: {
      Text(
        "choose whether to keep this account’s sessions, posts, and contacts on this device."
      )
    }
    .sheet(
      isPresented: $isPresentingDeleteAccountConfirm,
      onDismiss: { isConfirmingAccountDeletion = false },
      content: {
        LinkstrConfirmationSheet(
          title: isConfirmingAccountDeletion ? "confirm account deletion" : "delete account",
          message: accountDeletionMessage,
          actionTitle: isConfirmingAccountDeletion ? "delete account" : "continue",
          isDestructive: isConfirmingAccountDeletion,
          dismissOnConfirm: isConfirmingAccountDeletion,
          onConfirm: confirmAccountDeletion
        )
        .id(isConfirmingAccountDeletion)
      }
    )
  }

  private var playbackSection: some View {
    LinkstrInsetSection(
      title: "playback",
      footer: "mute applies to the session viewer. official embeds use their own sound and loop controls."
    ) {
      Group {
        Toggle("loop local videos", isOn: $loopLocalVideos)
        Toggle("mute session videos", isOn: $watchMuted)
      }
      .font(LinkstrTheme.font(.subheadline))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .toggleStyle(.switch)
      .tint(LinkstrTheme.accent)
    }
  }

  private var relaysSection: some View {
    LinkstrInsetSection(
      title: "relays",
      accessory: "\(connectedRelayCount)/\(session.configuredRelays.count)",
      footer:
        "enable at least one writable relay to create sessions, send posts, or publish account changes."
    ) {
      if sortedRelays.isEmpty {
        Text("no relays configured yet.")
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textSecondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(sortedRelays.enumerated()), id: \.element.url) { index, relay in
            relayRow(relay)

            if index < sortedRelays.count - 1 {
              LinkstrListRowDivider(leadingInset: 0)
            }
          }
        }
      }

      TextField("relay address", text: $relayURL, prompt: Text("wss://relay.example.com"))
        .font(LinkstrTheme.font(.subheadline))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .keyboardType(.URL)
        .lineLimit(1)
        .submitLabel(.done)
        .onSubmit(addRelayFromDraft)
        .onChange(of: relayURL) { _, _ in showsRelayAddressError = false }
        .accessibilityLabel("relay address")
        .linkstrInputField()

      if showsRelayAddressError {
        Text("enter a relay address starting with wss:// or ws://.")
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.destructive)
      }

      LinkstrAdaptiveButtonRow {
        Button {
          addRelayFromDraft()
        } label: {
          LinkstrActionButtonLabel(title: "add relay", systemImage: "plus")
        }
        .linkstrPrimaryButton()
        .disabled(relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
          session.restoreDefaultRelays()
        } label: {
          LinkstrActionButtonLabel(title: "restore defaults")
        }
        .linkstrSecondaryButton()
      }
    }
  }

  private func relayRow(_ relay: RelayEntity) -> some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: LinkstrTheme.compactSpacing))
      : AnyLayout(HStackLayout(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing))

    return VStack(alignment: .leading, spacing: LinkstrTheme.buttonRowSpacing) {
      layout {
        relayDetails(relay)
          .frame(maxWidth: .infinity, alignment: .leading)

        Toggle(
          "enable relay",
          isOn: Binding(
            get: { relay.isEnabled },
            set: { _ in session.toggleRelay(relay) }
          )
        )
        .labelsVisibility(dynamicTypeSize.isAccessibilitySize ? .visible : .hidden)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .toggleStyle(.switch)
        .tint(LinkstrTheme.accent)
        .accessibilityLabel("relay \(relay.url)")
      }

      HStack(alignment: .center, spacing: LinkstrTheme.rowSpacing) {
        Spacer()

        Button {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          session.removeRelay(relay)
        } label: {
          Label("remove relay", systemImage: "minus.circle")
            .font(LinkstrTheme.font(.caption, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(LinkstrTheme.destructive)
        .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
        .accessibilityLabel("remove relay \(relay.url)")
      }
    }
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
  }

  private func relayDetails(_ relay: RelayEntity) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
      Text(relay.url)
        .font(LinkstrTheme.font(.footnote, weight: .medium))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        .textSelection(.enabled)

      HStack(spacing: LinkstrTheme.tightSpacing) {
        Circle()
          .fill(statusDotColor(for: relay))
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)

        Text(relayStatusLabel(for: relay))
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if let diagnostics = session.relayErrorMessage(for: relay) {
        LinkstrDiagnosticDisclosure(details: diagnostics)
      }
    }
  }

  private func addRelayFromDraft() {
    guard !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard session.normalizedRelayURL(from: relayURL) != nil else {
      showsRelayAddressError = true
      return
    }
    if session.addRelay(url: relayURL) {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      relayURL = ""
    }
  }

}

private extension SettingsView {
  var accountDeletionMessage: String {
    if isConfirmingAccountDeletion {
      return "this removes this account’s contacts, sessions, posts, reactions, cached media, "
        + "and local encryption keys from this device. you can still sign in with your secret key."
    }
    return "linkstr sends a deletion request to your relays. once a relay accepts it, "
      + "linkstr clears this account’s data on this device and logs you out."
  }

  func confirmAccountDeletion() {
    guard isConfirmingAccountDeletion else {
      isConfirmingAccountDeletion = true
      return
    }
    guard !isDeletingAccount else { return }
    isDeletingAccount = true
    Task { @MainActor in
      await session.deleteAccountAwaitingRelay()
      isDeletingAccount = false
    }
  }
}
