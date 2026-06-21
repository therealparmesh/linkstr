import SwiftUI
import UIKit

struct SettingsView: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject var session: AppSession

  @State private var relayURL = ""
  @State var revealedNsec = ""
  @State var isNsecVisible = false
  @State var isPresentingLogoutOptions = false
  @State var isPresentingDeleteAccountConfirm = false
  @State var isPresentingDeleteAccountFinalConfirm = false
  @State var isDeletingAccount = false
  @State var clearableStorageBytes: Int64?
  @State var clearableMetadataBytes: Int64?
  @State var isRefreshingStorageUsage = false

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear(perform: refreshStorageUsage)
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
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
        LinkstrScreenTitle(title: "settings")
        relaysSection
        storageSection
        identitySection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
    }
    .linkstrTabBarContentInset()
    .alert("log out", isPresented: $isPresentingLogoutOptions) {
      Button("log out (keep local data)") {
        session.logOut(clearLocalData: false)
      }
      Button("log out and clear local data", role: .destructive) {
        session.logOut(clearLocalData: true)
      }
      Button("cancel", role: .cancel) {}
    } message: {
      Text(
        "choose whether to keep this account's local sessions, posts, and "
          + "contacts on this device or remove them before logging out."
      )
    }
    .alert("delete account", isPresented: $isPresentingDeleteAccountConfirm) {
      Button("continue", role: .destructive) {
        isPresentingDeleteAccountFinalConfirm = true
      }
      Button("cancel", role: .cancel) {}
    } message: {
      Text(
        "this asks your active relays to delete this account, clears this "
          + "account's local data on this device, and logs you out. if you keep "
          + "the secret key, you can still sign in again."
      )
    }
    .alert("are you absolutely sure?", isPresented: $isPresentingDeleteAccountFinalConfirm) {
      Button("delete account permanently", role: .destructive) {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        Task {
          let didDelete = await session.deleteAccountAwaitingRelay()
          await MainActor.run {
            isDeletingAccount = false
            if didDelete == false {
              isPresentingDeleteAccountFinalConfirm = false
            }
          }
        }
      }
      Button("cancel", role: .cancel) {}
    } message: {
      Text(
        "this removes contacts, sessions, posts, reactions, cached media, "
          + "and local encryption keys for this account after the relay "
          + "deletion request succeeds."
      )
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
          .font(LinkstrTheme.body(13))
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

      TextField("wss://relay.example.com", text: $relayURL)
        .font(LinkstrTheme.body(15))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .lineLimit(1)
        .submitLabel(.done)
        .onSubmit(addRelayFromDraft)
        .linkstrInputField()

      HStack(spacing: LinkstrTheme.buttonRowSpacing) {
        Button {
          addRelayFromDraft()
        } label: {
          LinkstrActionButtonLabel(title: "add relay")
        }
        .linkstrPrimaryButton()

        Button {
          session.resetDefaultRelays()
        } label: {
          LinkstrActionButtonLabel(title: "reset defaults")
        }
        .linkstrSecondaryButton()
      }
    }
  }

  private func relayRow(_ relay: RelayEntity) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.buttonRowSpacing) {
      HStack(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing) {
        Circle()
          .fill(statusDotColor(for: relay))
          .frame(width: 10, height: 10)
          .padding(.top, 4)

        VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
          Text(relay.url)
            .font(LinkstrTheme.body(14, weight: .medium))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(2)

          let relayErrorText =
            session.relayErrorMessage(for: relay)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
          if !relayErrorText.isEmpty {
            Text(relayErrorText)
              .font(LinkstrTheme.body(12))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Spacer(minLength: 8)
      }

      HStack(alignment: .center, spacing: LinkstrTheme.rowSpacing) {
        Toggle(
          "",
          isOn: Binding(
            get: { relay.isEnabled },
            set: { _ in session.toggleRelay(relay) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(LinkstrTheme.accent)
        .scaleEffect(0.82)
        .accessibilityLabel(relay.isEnabled ? "disable relay" : "enable relay")

        Spacer()

        Button {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          session.removeRelay(relay)
        } label: {
          Label("remove", systemImage: "trash")
            .font(LinkstrTheme.body(12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(LinkstrTheme.destructive)
      }
    }
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
  }

  private func addRelayFromDraft() {
    if session.addRelay(url: relayURL) {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      relayURL = ""
    }
  }

}
