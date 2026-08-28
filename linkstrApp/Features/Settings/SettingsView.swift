import SwiftUI
import UIKit

struct LinkstrAdaptiveButtonRow<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: LinkstrTheme.buttonRowSpacing))
      : AnyLayout(HStackLayout(spacing: LinkstrTheme.buttonRowSpacing))

    layout { content }
  }
}

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
      .linkstrReadableContent()
    }
    .linkstrKeyboardDismissal()
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

      TextField("wss://relay.example.com", text: $relayURL)
        .font(LinkstrTheme.font(.subheadline))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .keyboardType(.URL)
        .lineLimit(1)
        .submitLabel(.done)
        .onSubmit(addRelayFromDraft)
        .linkstrInputField()

      LinkstrAdaptiveButtonRow {
        Button {
          addRelayFromDraft()
        } label: {
          LinkstrActionButtonLabel(title: "add relay")
        }
        .linkstrPrimaryButton()

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
    VStack(alignment: .leading, spacing: LinkstrTheme.buttonRowSpacing) {
      HStack(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing) {
        relayDetails(relay)

        Spacer(minLength: 8)

        Toggle(
          "relay enabled",
          isOn: Binding(
            get: { relay.isEnabled },
            set: { _ in session.toggleRelay(relay) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(LinkstrTheme.accent)
        .accessibilityLabel("\(relay.url) enabled")
      }

      HStack(alignment: .center, spacing: LinkstrTheme.rowSpacing) {
        Spacer()

        Button {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          session.removeRelay(relay)
        } label: {
          Label("remove", systemImage: "trash")
            .font(LinkstrTheme.font(.caption, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(LinkstrTheme.destructive)
        .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
      }
    }
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
  }

  private func relayDetails(_ relay: RelayEntity) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
      Text(relay.url)
        .font(LinkstrTheme.font(.footnote, weight: .medium))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .lineLimit(2)

      HStack(spacing: 6) {
        Circle()
          .fill(statusDotColor(for: relay))
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)

        Text(relayStatusLabel(for: relay))
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      let relayErrorText =
        session.relayErrorMessage(for: relay)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
      if !relayErrorText.isEmpty {
        Text(relayErrorText)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func addRelayFromDraft() {
    if session.addRelay(url: relayURL) {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      relayURL = ""
    }
  }

}
