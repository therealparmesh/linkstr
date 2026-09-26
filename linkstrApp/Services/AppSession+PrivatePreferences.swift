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

  func receivePrivatePreference(_ event: NostrEvent) async {
    guard let keypair = identityService.keypair else { return }
    let sourceService = nostrService
    let generation = sourceService.receiveGeneration
    do {
      let decoded = try await sourceService.eventDecoder.preference(from: event, keypair: keypair)
      guard !Task.isCancelled, nostrService === sourceService,
        sourceService.receiveGeneration == generation,
        identityService.pubkeyHex == keypair.publicKey.hex else { return }
      guard let preference = try privatePreferenceStore.receiveVerified(
        event, preference: decoded, keypair: keypair
      ) else { return }
      try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex)
    } catch PrivatePreferenceError.invalidEvent {
      // Untrusted or undecryptable relay events must not change local preferences.
    } catch {
      reportPrivatePreferenceError()
    }
  }

  func restorePrivatePreferences() async throws {
    guard let keypair = identityService.keypair else { return }
    let sourceService = nostrService
    let generation = sourceService.receiveGeneration
    for record in try privatePreferenceStore.records(ownerPubkey: keypair.publicKey.hex) {
      let event = try record.event()
      let preference = try await sourceService.eventDecoder.preference(from: event, keypair: keypair)
      try Task.checkCancellation()
      guard nostrService === sourceService, sourceService.receiveGeneration == generation,
        identityService.pubkeyHex == keypair.publicKey.hex else { throw CancellationError() }
      // A local edit made during validation takes precedence over this snapshot.
      guard try record.event().id == event.id else { continue }
      try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex, syncPush: false)
    }
  }

  func preparePrivatePreferenceBackup() async {
    guard let keypair = identityService.keypair else { return }
    let owner = keypair.publicKey.hex
    guard preparedPrivatePreferenceOwner != owner else {
      schedulePrivatePreferenceSync()
      return
    }
    do {
      try await restorePrivatePreferences()
      let contacts = try modelContext.fetch(FetchDescriptor<ContactEntity>(predicate: #Predicate {
        $0.ownerPubkey == owner && $0.encryptedAlias != ""
      })).map { (pubkey: $0.targetPubkey, alias: $0.localAlias, createdAt: $0.createdAt) }
      for contact in contacts {
        // Historical dates keep an initial backup from replacing a newer edit on another device.
        guard let alias = contact.alias else { throw PrivatePreferenceError.invalidEvent }
        try await seedPrivatePreferenceBackup(
          .alias(pubkey: contact.pubkey, name: alias), keypair: keypair, createdAt: contact.createdAt
        )
      }
      let sessions = try modelContext.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate {
        $0.ownerPubkey == owner && $0.isArchived
      })).map { (sessionID: $0.sessionID, createdAt: $0.createdAt) }
      for session in sessions {
        try await seedPrivatePreferenceBackup(
          .archive(sessionID: session.sessionID, archived: true), keypair: keypair, createdAt: session.createdAt
        )
      }
      preparedPrivatePreferenceOwner = owner
      schedulePushStateSync()
      schedulePrivatePreferenceSync()
    } catch is CancellationError {
      return
    } catch {
      reportPrivatePreferenceError()
    }
  }

  private func seedPrivatePreferenceBackup(
    _ preference: PrivatePreference, keypair: Keypair, createdAt: Date
  ) async throws {
    guard try privatePreferenceStore.record(for: preference, keypair: keypair) == nil else { return }
    let sourceService = nostrService
    let generation = sourceService.receiveGeneration
    let event = try await sourceService.eventDecoder.preferenceEvent(
      for: preference, keypair: keypair, createdAt: max(1, Int64(createdAt.timeIntervalSince1970)))
    try Task.checkCancellation()
    guard nostrService === sourceService, sourceService.receiveGeneration == generation,
      identityService.pubkeyHex == keypair.publicKey.hex else { throw CancellationError() }
    try privatePreferenceStore.seed(event, preference: preference, keypair: keypair)
  }

  func restorePrivateArchive(sessionID: String) throws {
    guard let keypair = identityService.keypair,
      let record = try privatePreferenceStore.record(
        for: .archive(sessionID: sessionID, archived: false), keypair: keypair
      ) else { return }
    let preference = try PrivatePreferenceCodec().preference(from: record.event(), keypair: keypair)
    try applyPrivatePreference(preference, ownerPubkey: keypair.publicKey.hex)
  }

  func applyPrivatePreference(
    _ preference: PrivatePreference, ownerPubkey: String, syncPush: Bool = true
  ) throws {
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
      if syncPush { schedulePushStateSync() }
    }
  }

  func schedulePrivatePreferenceSync() {
    guard privatePreferenceSyncTask == nil, isForeground,
      isRelayPublicationEnabledForCurrentProcess(),
      let keypair = identityService.keypair else { return }
    guard case .ready = relaySendWaitState() else { return }
    let sourceService = nostrService
    let generation = sourceService.receiveGeneration
    privatePreferenceSyncTask = Task { @MainActor [weak self, weak sourceService] in
      guard let self, let sourceService else { return }
      defer {
        if self.nostrService === sourceService, sourceService.receiveGeneration == generation {
          self.privatePreferenceSyncTask = nil
        }
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
    preparedPrivatePreferenceOwner = nil
    composeError = "couldn't sync private preferences. local data is kept; linkstr will retry when you reconnect."
  }
}
