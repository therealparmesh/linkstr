import NostrSDK
import SwiftUI
import UniformTypeIdentifiers

struct BackupSection: View {
  @EnvironmentObject private var session: AppSession
  @State private var isPreparing = false
  @State private var isExporting = false
  @State private var document: BackupDocument?
  @State private var exportError: Error?

  var body: some View {
    LinkstrInsetSection(
      title: "backup",
      footer: "your backup contains your secret key. anyone with the file can access your account."
    ) {
      Button {
        exportError = nil
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
            exportError = error
          }
        }
      } label: {
        LinkstrActionButtonLabel(
          title: isPreparing ? "preparing backup…" : "create backup", systemImage: "square.and.arrow.up")
      }
      .linkstrSecondaryButton()
      .disabled(isPreparing || session.isUsingRecoveryStore)

      if let exportError {
        BackupFailureView(error: exportError, message: "couldn’t save the backup. try again.")
      }
    }
    .fileExporter(
      isPresented: $isExporting, document: document, contentType: .linkstrBackup,
      defaultFilename: "linkstr-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
    ) { result in
      document = nil
      switch result {
      case .success: LinkstrToast.showSuccess("backup saved")
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled { exportError = error }
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
  @State private var importError: Error?

  var body: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      importButton
      if let importError {
        BackupFailureView(error: importError, message: "couldn’t open this backup. choose the file again.")
      }
    }
  }

  private var importButton: some View {
    Button {
      importError = nil
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
            importError = error
          }
        }
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled { importError = error }
      }
    }
    .sheet(item: $selection) { RestoreBackupSheet(backup: $0.backup) }
  }
}

private struct RestoreBackupSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession
  let backup: LinkstrBackup
  @State private var restoreError: Error?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrSheetTitle(title: "restore backup")
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
            if let restoreError {
              BackupFailureView(error: restoreError, message: "couldn’t restore this backup. try again.")
            }
            Button {
              restoreError = nil
              Task {
                do { try await session.restoreBackup(backup) } catch { restoreError = error }
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
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "cancel", icon: "xmark") { dismiss() }
            .disabled(session.isRestoringBackup)
        }
        .linkstrFlatToolbarItem()
      }
      .interactiveDismissDisabled(session.isRestoringBackup)
    }
  }
}

private struct BackupFailureView: View {
  let error: Error
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      Text((error as? BackupError)?.errorDescription ?? message)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.destructive)
      if !(error is BackupError) {
        LinkstrDiagnosticDisclosure(details: error.localizedDescription)
      }
    }
  }
}
