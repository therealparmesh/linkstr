import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\RelayEntity.url)])
  private var relays: [RelayEntity]

  @State private var relayURL = ""
  @State private var revealedNsec = ""
  @State private var isNsecVisible = false
  @State private var isRelaysExpanded = true
  @State private var isStorageExpanded = true
  @State private var isIdentityExpanded = true
  @State private var isPresentingLogoutOptions = false

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        relaysSection
        storageSection
        identitySection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.top, 14)
      .padding(.bottom, 28)
    }
    .scrollBounceBehavior(.basedOnSize)
    .alert("Log Out", isPresented: $isPresentingLogoutOptions) {
      Button("Log Out (Keep Local Data)") {
        session.logout(clearLocalData: false)
      }
      Button("Log Out and Clear Local Data", role: .destructive) {
        session.logout(clearLocalData: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Choose whether to keep this account's local contacts/messages on this device or remove them before signing out."
      )
    }
  }

  private var relaysSection: some View {
    DisclosureGroup(isExpanded: $isRelaysExpanded) {
      VStack(spacing: 0) {
        ForEach(Array(sortedRelays.enumerated()), id: \.element.id) { index, relay in
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
              Text(relay.url)
                .font(.custom(LinkstrTheme.bodyFont, size: 13))
                .foregroundStyle(LinkstrTheme.textPrimary)
                .lineLimit(2)
              Spacer(minLength: 8)
              Circle()
                .fill(statusDotColor(relay.status))
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            }

            HStack(spacing: 10) {
              Text("Enabled")
                .font(.custom(LinkstrTheme.bodyFont, size: 13))
                .foregroundStyle(LinkstrTheme.textSecondary)
              Spacer(minLength: 8)
              Toggle(
                "",
                isOn: Binding(
                  get: {
                    relay.isEnabled
                  },
                  set: { _ in
                    session.toggleRelay(relay)
                  })
              )
              .labelsHidden()
              .tint(LinkstrTheme.neonCyan)
            }
            .padding(.trailing, 4)

            if let error = relay.lastError, !error.isEmpty {
              Text(error)
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
              Spacer()
              Button(role: .destructive) {
                session.removeRelay(relay)
              } label: {
                Label("Remove", systemImage: "trash")
                  .font(.custom(LinkstrTheme.bodyFont, size: 13))
                  .foregroundStyle(Color.red.opacity(0.95))
                  .padding(.horizontal, 10)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color.red.opacity(0.14))
                  )
              }
              .buttonStyle(.plain)
            }
            .padding(.trailing, 4)

            if index < sortedRelays.count - 1 {
              Divider()
                .overlay(LinkstrTheme.textSecondary.opacity(0.24))
                .padding(.top, 4)
            }
          }
          .padding(.horizontal, 2)
          .padding(.vertical, 10)
        }

        VStack(alignment: .leading, spacing: 10) {
          Divider()
            .overlay(LinkstrTheme.textSecondary.opacity(0.3))
            .padding(.bottom, 10)

          TextField("wss://relay.example.com", text: $relayURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )

          Button {
            session.addRelay(url: relayURL)
            relayURL = ""
          } label: {
            Text("Add Relay")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrPrimaryButtonStyle())

          Button {
            session.resetDefaultRelays()
          } label: {
            Text("Reset Default Relays")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      sectionLabel(
        "Relays",
        systemImage: "antenna.radiowaves.left.and.right",
        badge: "\(relays.count)"
      )
    }
  }

  private var storageSection: some View {
    DisclosureGroup(isExpanded: $isStorageExpanded) {
      VStack(spacing: 10) {
        Button(role: .destructive) {
          session.clearCachedVideos()
        } label: {
          Text("Clear Cached Videos")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(LinkstrDangerButtonStyle())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      sectionLabel("Storage", systemImage: "externaldrive")
    }
  }

  private var identitySection: some View {
    DisclosureGroup(isExpanded: $isIdentityExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        if let npub = session.identityService.npub {
          LinkstrSectionHeader(title: "Contact Key (npub)")
          Text(npub)
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )

          HStack(spacing: 8) {
            Button {
              if isNsecVisible {
                isNsecVisible = false
              } else {
                revealedNsec = (try? session.identityService.revealNsec()) ?? ""
                isNsecVisible = true
              }
            } label: {
              Label(
                isNsecVisible ? "Hide Secret Key (nsec)" : "Reveal Secret Key (nsec)",
                systemImage: "key.fill"
              )
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(LinkstrSecondaryButtonStyle())

            if isNsecVisible {
              Button {
                guard !revealedNsec.isEmpty else { return }
                UIPasteboard.general.string = revealedNsec
              } label: {
                Label("Copy Secret Key (nsec)", systemImage: "doc.on.doc")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(LinkstrWarningButtonStyle())
              .disabled(revealedNsec.isEmpty)
            }
          }

          if isNsecVisible {
            LinkstrSectionHeader(title: "Secret Key (nsec)")
            Text(revealedNsec.isEmpty ? "Unable to reveal Secret Key (nsec)." : revealedNsec)
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .textSelection(.enabled)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )
          }

          Button(role: .destructive) {
            isPresentingLogoutOptions = true
          } label: {
            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrDangerButtonStyle())
        } else {
          Text("No account found. Sign in with a Secret Key (nsec) or create one.")
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      sectionLabel("Identity", systemImage: "person.crop.circle")
    }
  }

  private func sectionLabel(_ title: String, systemImage: String, badge: String? = nil) -> some View
  {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)

      Text(title)
        .font(.custom(LinkstrTheme.titleFont, size: 14))
        .foregroundStyle(LinkstrTheme.textPrimary)

      Spacer()

      if let badge {
        Text(badge)
          .font(.custom(LinkstrTheme.bodyFont, size: 11))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(LinkstrTheme.panelSoft, in: Capsule())
      }
    }
    .padding(.horizontal, 2)
  }

  private func statusDotColor(_ status: RelayHealthStatus) -> Color {
    switch status {
    case .connected:
      return .green
    case .reconnecting:
      return LinkstrTheme.neonCyan
    case .failed:
      return .red
    case .readOnly:
      return .orange
    case .disconnected:
      return LinkstrTheme.textSecondary
    }
  }

  private var sortedRelays: [RelayEntity] {
    relays.sorted {
      $0.url.localizedCaseInsensitiveCompare($1.url) == .orderedAscending
    }
  }
}
