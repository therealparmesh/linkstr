import SwiftUI
import UIKit

extension SettingsView {
  var storageSection: some View {
    LinkstrInsetSection(
      title: "storage",
      footer: storageUsageHint
    ) {
      Button(role: .destructive) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        session.clearCachedMedia()
        refreshStorageUsage()
      } label: {
        LinkstrActionButtonLabel(title: "clear downloaded videos")
      }
      .linkstrDestructiveButton()

      Button(role: .destructive) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        session.clearCachedMetadata()
        refreshStorageUsage()
      } label: {
        LinkstrActionButtonLabel(title: "clear metadata")
      }
      .linkstrDestructiveButton()
    }
  }

  var storageUsageHint: String? {
    if isRefreshingStorageUsage
      && clearableStorageBytes == nil
      && clearableMetadataBytes == nil {
      return "measuring local storage..."
    }
    let segments = [
      storageUsageHintSegment(
        label: "downloaded videos",
        clearableBytes: clearableStorageBytes
      ),
      storageUsageHintSegment(
        label: "metadata previews",
        clearableBytes: clearableMetadataBytes
      )
    ]
    .compactMap { $0 }
    guard !segments.isEmpty else { return "nothing to clear right now." }
    return segments.joined(separator: ". ") + "."
  }

  func storageUsageHintSegment(label: String, clearableBytes: Int64?) -> String? {
    guard let clearableBytes else { return nil }
    guard clearableBytes > 0 else { return nil }
    let size = ByteCountFormatter.string(
      fromByteCount: clearableBytes,
      countStyle: .file
    ).lowercased()
    return "clearing \(label) would free ~\(size)"
  }

  var identitySection: some View {
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
            LinkstrActionButtonLabel(
              title: isNsecVisible ? "hide secret key" : "reveal secret key",
              systemImage: "key.fill"
            )
          }
          .linkstrCautionButton()

          if isNsecVisible {
            Button {
              guard !revealedNsec.isEmpty else { return }
              UIPasteboard.general.string = revealedNsec
              LinkstrToast.showSuccess("copied to clipboard")
            } label: {
              LinkstrActionButtonLabel(title: "copy", systemImage: "doc.on.doc")
            }
            .linkstrCautionButton()
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
          LinkstrActionButtonLabel(
            title: "log out",
            systemImage: "rectangle.portrait.and.arrow.right"
          )
        }
        .linkstrSecondaryButton()

        Button(role: .destructive) {
          isPresentingDeleteAccountConfirm = true
        } label: {
          LinkstrActionButtonLabel(
            title: isDeletingAccount ? "deleting account..." : "delete account",
            systemImage: "person.crop.circle.badge.xmark"
          )
        }
        .linkstrDestructiveButton(prominent: true)
        .disabled(isDeletingAccount)
      } else {
        Text("no account found. sign in with a secret key (nsec) or create one.")
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
  }

  var connectedRelayCount: Int {
    session.connectedRelayCount(for: session.configuredRelays)
  }

  func statusDotColor(for relay: RelayEntity) -> Color {
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

  var sortedRelays: [RelayEntity] {
    session.configuredRelays.sorted {
      $0.url.localizedCaseInsensitiveCompare($1.url) == .orderedAscending
    }
  }

  @MainActor
  func refreshStorageUsage() {
    isRefreshingStorageUsage = true
    Task { @MainActor in
      let usage = session.clearableStorageUsage()
      clearableStorageBytes = usage.cachedMediaBytes
      clearableMetadataBytes = usage.previewBytes
      isRefreshingStorageUsage = false
    }
  }

  func hideSensitiveIdentityContent() {
    isNsecVisible = false
    revealedNsec = ""
  }
}
