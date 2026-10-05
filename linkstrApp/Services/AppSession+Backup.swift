import Foundation
import NostrSDK
import SwiftData

extension AppSession {
  func prepareBackup() async throws -> Data {
    guard !isUsingRecoveryStore, !isRestoringBackup, let owner = identityService.pubkeyHex else {
      throw BackupError.unavailable
    }
    let source = nostrService
    try modelContext.save()
    let snapshot = try BackupSnapshot(
      context: modelContext, nsec: identityService.revealNsec(), owner: owner, settings: relayStore.backupSettings())
    let data = try await backupWorker.export(snapshot)
    guard identityService.pubkeyHex == owner, nostrService === source, !Task.isCancelled else {
      throw CancellationError()
    }
    return data
  }

  func restoreBackup(_ backup: LinkstrBackup) async throws {
    guard !isUsingRecoveryStore, !isBooting, !isRestoringBackup, restoreRecoveryError == nil else {
      throw BackupError.unavailable
    }
    guard identityService.keypair == nil, try !identityService.hasStoredIdentity() else {
      throw BackupError.signedIn
    }
    guard Keypair(nsec: backup.nsec) != nil else { throw IdentityError.invalidNsec }
    isRestoringBackup = true
    defer { isRestoringBackup = false }
    cancelPendingNostrStartupIfNeeded()
    resetRuntimeSessionState()
    let files = try await backupWorker.restore(backup, in: modelContext.container)
    let cleanup = SessionMessageStore(modelContext: ModelContext(modelContext.container))
    cleanup.removeManagedFiles(at: files)
    do {
      guard try await finishBackupActivation() else { throw BackupError.invalidFile }
      didRestoreBackup = true
    } catch {
      didFinishBoot = false
      restoreRecoveryError = error.localizedDescription
      throw error
    }
  }

  func finishBackupActivation() async throws -> Bool {
    guard let activation = try await backupWorker.pendingActivation(in: modelContext.container) else { return false }
    try identityService.importNsec(activation.nsec)
    try relayStore.applyBackupSettings(activation.settings)
    try await backupWorker.finishActivation(owner: activation.owner, in: modelContext.container)
    return true
  }
}
