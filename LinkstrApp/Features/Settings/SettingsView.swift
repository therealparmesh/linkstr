import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\RelayEntity.url)])
  private var relays: [RelayEntity]

  @State private var relayURL = ""
  @State private var revealedNsec = ""
  @State private var isNsecVisible = false
  @State private var isPresentingLogoutOptions = false
  @State private var isPresentingDeleteAccountConfirm = false
  @State private var isPresentingDeleteAccountFinalConfirm = false
  @State private var isDeletingAccount = false
  @State private var clearableStorageBytes: Int64?
  @State private var isRefreshingStorageUsage = false

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
        "choose whether to keep this account's local sessions, posts, and contacts on this device or remove them before logging out."
      )
    }
    .alert("delete account", isPresented: $isPresentingDeleteAccountConfirm) {
      Button("continue", role: .destructive) {
        isPresentingDeleteAccountFinalConfirm = true
      }
      Button("cancel", role: .cancel) {}
    } message: {
      Text(
        "this asks your active relays to delete this account, clears this account's local data on this device, and logs you out. if you keep the secret key, you can still sign in again."
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
        "this removes contacts, sessions, posts, reactions, cached media, and local encryption keys for this account after the relay deletion request succeeds."
      )
    }
  }

  private var relaysSection: some View {
    LinkstrInsetSection(
      title: "relays",
      accessory: "\(connectedRelayCount)/\(relays.count)",
      footer:
        "enable at least one writable relay to create sessions, send posts, or publish account changes."
    ) {
      if sortedRelays.isEmpty {
        Text("no relays configured yet.")
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(sortedRelays.enumerated()), id: \.element.id) { index, relay in
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
        .linkstrInputField()

      HStack(spacing: LinkstrTheme.buttonRowSpacing) {
        Button {
          if session.addRelay(url: relayURL) {
            relayURL = ""
          }
        } label: {
          Text("add relay")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.accent)

        Button {
          session.resetDefaultRelays()
        } label: {
          Text("reset defaults")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.textSecondary)
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

  private var storageSection: some View {
    LinkstrInsetSection(
      title: "storage",
      footer:
        "downloaded videos and hydrated previews are device-local only and can be rebuilt later if needed."
    ) {
      if isRefreshingStorageUsage && clearableStorageBytes == nil {
        Text("measuring local storage...")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textSecondary)
      } else if let clearableStorageBytes {
        Text(
          "this will save about \(ByteCountFormatter.string(fromByteCount: clearableStorageBytes, countStyle: .file).lowercased())."
        )
        .font(LinkstrTheme.body(13))
        .foregroundStyle(LinkstrTheme.textSecondary)
      }

      Button(role: .destructive) {
        session.clearCachedMediaAndPreviews()
        refreshStorageUsage()
      } label: {
        Text("clear cached media and previews")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
      .tint(LinkstrTheme.destructive)
    }
  }

  private var identitySection: some View {
    LinkstrInsetSection(title: "identity") {
      if session.identityService.keypair != nil {
        HStack(spacing: LinkstrTheme.buttonRowSpacing) {
          Button {
            if isNsecVisible {
              hideSensitiveIdentityContent()
            } else {
              revealedNsec = (try? session.identityService.revealNsec()) ?? ""
              isNsecVisible = true
            }
          } label: {
            Label(
              isNsecVisible ? "hide secret key" : "reveal secret key",
              systemImage: "key.fill"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
          .tint(LinkstrTheme.textSecondary)

          if isNsecVisible {
            Button {
              guard !revealedNsec.isEmpty else { return }
              UIPasteboard.general.string = revealedNsec
            } label: {
              Label("copy", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
            .tint(LinkstrTheme.amber)
            .disabled(revealedNsec.isEmpty)
          }
        }

        if isNsecVisible {
          Text(revealedNsec.isEmpty ? "unable to reveal secret key (nsec)." : revealedNsec)
            .font(LinkstrTheme.body(13))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .textSelection(.enabled)
            .privacySensitive()
            .linkstrInputField()
        }

        Button(role: .destructive) {
          isPresentingLogoutOptions = true
        } label: {
          Label("log out", systemImage: "rectangle.portrait.and.arrow.right")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.destructive)

        Button(role: .destructive) {
          isPresentingDeleteAccountConfirm = true
        } label: {
          Label(
            isDeletingAccount ? "deleting account..." : "delete account",
            systemImage: "person.crop.circle.badge.xmark"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.destructive)
        .disabled(isDeletingAccount)
      } else {
        Text("no account found. sign in with a secret key (nsec) or create one.")
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
  }

  private var connectedRelayCount: Int {
    session.connectedRelayCount(for: relays)
  }

  private func statusDotColor(for relay: RelayEntity) -> Color {
    if relay.isEnabled == false {
      return LinkstrTheme.textSecondary.opacity(0.45)
    }

    let status = session.relayStatus(for: relay)
    switch status {
    case .connected:
      return LinkstrTheme.statusSuccess
    case .connecting:
      return LinkstrTheme.accent
    case .failed:
      return LinkstrTheme.destructive
    case .readOnly:
      return LinkstrTheme.amber
    case .disconnected:
      return LinkstrTheme.textSecondary
    }
  }

  private var sortedRelays: [RelayEntity] {
    relays.sorted {
      $0.url.localizedCaseInsensitiveCompare($1.url) == .orderedAscending
    }
  }

  @MainActor
  private func refreshStorageUsage() {
    isRefreshingStorageUsage = true
    clearableStorageBytes = session.clearableStorageBytes()
    isRefreshingStorageUsage = false
  }

  private func hideSensitiveIdentityContent() {
    isNsecVisible = false
    revealedNsec = ""
  }
}
