import NostrSDK
import SwiftUI
import UniformTypeIdentifiers

struct BackupSection: View {
  @EnvironmentObject private var session: AppSession
  @State private var isPreparing = false
  @State private var isExporting = false
  @State private var document: BackupDocument?

  var body: some View {
    LinkstrInsetSection(
      title: "backup",
      footer: "this file includes your secret key. anyone with the file can access your account."
    ) {
      Button {
        isPreparing = true
        Task {
          defer { isPreparing = false }
          do {
            let owner = session.identityService.pubkeyHex
            let data = try await session.prepareBackup()
            guard session.identityService.pubkeyHex == owner else { return }
            document = BackupDocument(data: data)
            isExporting = true
          } catch is CancellationError {
            return
          } catch {
            session.report(error: error)
          }
        }
      } label: {
        LinkstrActionButtonLabel(
          title: isPreparing ? "preparing backup…" : "backup", systemImage: "square.and.arrow.up")
      }
      .linkstrSecondaryButton()
      .disabled(isPreparing || session.isUsingRecoveryStore)
    }
    .fileExporter(
      isPresented: $isExporting, document: document, contentType: .linkstrBackup,
      defaultFilename: "linkstr-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
    ) { result in
      document = nil
      switch result {
      case .success: LinkstrToast.showSuccess("backup saved")
      case .failure(let error): session.report(error: error)
      }
    }
    .onChange(of: isExporting) { _, presented in
      if !presented { document = nil }
    }
  }
}

struct RestoreBackupButton: View {
  private struct Selection: Identifiable {
    let id = UUID()
    let backup: LinkstrBackup
  }

  @EnvironmentObject private var session: AppSession
  @State private var isImporting = false
  @State private var isReading = false
  @State private var selection: Selection?

  var body: some View {
    Button {
      isImporting = true
    } label: {
      LinkstrActionButtonLabel(
        title: isReading ? "reading backup…" : "restore backup", systemImage: "square.and.arrow.down")
    }
    .linkstrSecondaryButton()
    .disabled(isReading || session.isRestoringBackup || session.isUsingRecoveryStore)
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.linkstrBackup, .json]) { result in
      switch result {
      case .success(let url):
        isReading = true
        Task {
          defer { isReading = false }
          do {
            let backup = try await session.backupWorker.read(url)
            guard session.identityService.keypair == nil else { return }
            selection = Selection(backup: backup)
          } catch {
            session.report(error: error)
          }
        }
      case .failure(let error): session.report(error: error)
      }
    }
    .sheet(item: $selection) { RestoreBackupSheet(backup: $0.backup) }
  }
}

private struct RestoreBackupSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession
  let backup: LinkstrBackup
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: "restore backup")
            LinkstrInsetSection(title: "account") {
              Text(PublicKey(hex: backup.owner)?.npub ?? backup.owner)
                .typesettingLanguage(.init(languageCode: .unavailable))
                .font(LinkstrTheme.font(.footnote))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(LinkstrTheme.font(.subheadline))
                .foregroundStyle(LinkstrTheme.textSecondary)
            }
            LinkstrInsetSection(title: "saved data") {
              LabeledContent("sessions", value: backup.sessions.count.formatted())
              LabeledContent("posts", value: backup.posts.count.formatted())
              LabeledContent("contacts", value: backup.contacts.count.formatted())
            }
            Text("restores this account and app settings. newer saved changes are kept.")
              .font(LinkstrTheme.font(.footnote))
              .foregroundStyle(LinkstrTheme.textSecondary)
            if let errorMessage {
              Text(errorMessage)
                .font(LinkstrTheme.font(.footnote))
                .foregroundStyle(LinkstrTheme.destructive)
            }
            Button {
              errorMessage = nil
              Task {
                do { try await session.restoreBackup(backup) } catch { errorMessage = error.localizedDescription }
              }
            } label: {
              LinkstrActionButtonLabel(
                title: session.isRestoringBackup ? "restoring backup…" : "restore backup",
                systemImage: "square.and.arrow.down")
            }
            .linkstrPrimaryButton()
            .disabled(session.isRestoringBackup)
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.vertical, LinkstrTheme.screenTopPadding)
          .linkstrReadableContent()
        }
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button { dismiss() } label: { Image(systemName: "xmark").linkstrToolbarIconLabel() }
            .accessibilityLabel("cancel")
            .disabled(session.isRestoringBackup)
        }
      }
      .interactiveDismissDisabled(session.isRestoringBackup)
    }
  }
}
