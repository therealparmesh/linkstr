import Foundation
import NostrSDK
import SwiftData

extension AppSession {
  func savePrivatePreference(_ preference: PrivatePreference) throws {
    guard let keypair = identityService.keypair else { throw NostrServiceError.missingIdentity }
    try privatePreferenceStore.save(preference, keypair: keypair)
    defer { schedulePrivatePreferenceSync() }
    try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex)
  }

  func receivePrivatePreference(_ event: NostrEvent) {
    guard let keypair = identityService.keypair else { return }
    do {
      guard let preference = try privatePreferenceStore.receive(event, keypair: keypair) else { return }
      try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex)
    } catch PrivatePreferenceError.invalidEvent {
      // Untrusted or undecryptable relay events must not change local preferences.
    } catch {
      reportPrivatePreferenceError()
    }
  }

  func restorePrivatePreferences() throws {
    guard let keypair = identityService.keypair else { return }
    for record in try privatePreferenceStore.records(ownerPubkey: keypair.publicKey.hex) {
      let preference = try PrivatePreferenceCodec().preference(from: record.event(), keypair: keypair)
      try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex)
    }
  }

  func preparePrivatePreferenceBackup() {
    guard let keypair = identityService.keypair else { return }
    let owner = keypair.publicKey.hex
    do {
      try restorePrivatePreferences()
      let contacts = try modelContext.fetch(FetchDescriptor<ContactEntity>(predicate: #Predicate {
        $0.ownerPubkey == owner && $0.encryptedAlias != ""
      }))
      for contact in contacts {
        // Historical dates keep an initial backup from replacing a newer edit on another device.
        guard let alias = contact.localAlias else { throw PrivatePreferenceError.invalidEvent }
        try privatePreferenceStore.save(
          .alias(pubkey: contact.targetPubkey, name: alias), keypair: keypair, initialDate: contact.createdAt
        )
      }
      let sessions = try modelContext.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate {
        $0.ownerPubkey == owner && $0.isArchived
      }))
      for session in sessions {
        try privatePreferenceStore.save(
          .archive(sessionID: session.sessionID, archived: true), keypair: keypair, initialDate: session.createdAt
        )
      }
      schedulePushStateSync()
      schedulePrivatePreferenceSync()
    } catch {
      reportPrivatePreferenceError()
    }
  }

  func restorePrivateArchive(sessionID: String) throws {
    guard let keypair = identityService.keypair,
      let record = try privatePreferenceStore.record(
        for: .archive(sessionID: sessionID, archived: false), keypair: keypair
      ) else { return }
    let preference = try PrivatePreferenceCodec().preference(from: record.event(), keypair: keypair)
    try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex)
  }

  func applyPrivatePreference(_ preference: PrivatePreference, ownerPubkey: String) throws {
    switch preference {
    case .alias(let pubkey, let name):
      let contacts = try modelContext.fetch(FetchDescriptor<ContactEntity>(predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey && $0.targetPubkey == pubkey
      }))
      for contact in contacts where contact.localAlias != name || (name == nil && !contact.encryptedAlias.isEmpty) {
        try contactStore.updateAlias(contact, ownerPubkey: ownerPubkey, alias: name)
      }
    case .archive(let sessionID, let archived):
      try messageStore.setSessionArchived(sessionID: sessionID, ownerPubkey: ownerPubkey, archived: archived)
      schedulePushStateSync()
    }
  }

  func schedulePrivatePreferenceSync() {
    guard privatePreferenceSyncTask == nil, isForeground,
      isRelayPublicationEnabledForCurrentProcess(),
      let keypair = identityService.keypair else { return }
    guard case .ready = relaySendWaitState() else { return }
    let sourceService = nostrService
    privatePreferenceSyncTask = Task { @MainActor [weak self, weak sourceService] in
      guard let self, let sourceService else { return }
      defer {
        if self.nostrService === sourceService { self.privatePreferenceSyncTask = nil }
      }
      do {
        while !Task.isCancelled, self.nostrService === sourceService,
          self.identityService.pubkeyHex == keypair.publicKey.hex {
          guard let record = try self.privatePreferenceStore.records(
            ownerPubkey: keypair.publicKey.hex, pendingOnly: true
          ).first else { break }
          let event = try record.event()
          _ = try await self.publishEventAwaitingRelayAcceptance(event)
          guard !Task.isCancelled, self.nostrService === sourceService,
            self.identityService.pubkeyHex == keypair.publicKey.hex else { return }
          try self.privatePreferenceStore.markPublished(event, keypair: keypair)
        }
      } catch {
        if !Task.isCancelled, self.nostrService === sourceService { self.reportPrivatePreferenceError() }
      }
    }
  }

  private func reportPrivatePreferenceError() {
    composeError = "couldn't sync private preferences. local data is kept; linkstr will retry when you reconnect."
  }
}
