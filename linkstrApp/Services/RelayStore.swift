import Foundation
import SwiftData

@MainActor
final class RelayStore {
  private enum RelayConfigurationKey {
    static let hasCustomizedRelays = "linkstr.hasCustomizedRelays"
  }

  private let modelContext: ModelContext
  private let userDefaults: UserDefaults

  init(modelContext: ModelContext, userDefaults: UserDefaults = .standard) {
    self.modelContext = modelContext
    self.userDefaults = userDefaults
  }

  func fetchRelays() throws -> [RelayEntity] {
    let persistedRelays = try fetchPersistedRelays()
    if try shouldUseCustomizedRelays(persistedRelays) {
      return persistedRelays
    }
    return makeVirtualDefaultRelays()
  }

  func addRelay(url: URL) throws {
    let relayURL = canonicalRelayURLString(from: url)
    let existingRelayURLs = try fetchRelays().map(\.url)
    if existingRelayURLs.contains(where: { canonicalRelayURLString(from: $0) == relayURL }) {
      throw RelayStoreError.duplicateRelay
    }

    try materializeDefaultsForCustomizationIfNeeded()
    modelContext.insert(RelayEntity(url: relayURL))
    try modelContext.save()
  }

  func removeRelay(url rawValue: String) throws {
    try materializeDefaultsForCustomizationIfNeeded()
    guard let relay = try persistedRelay(matching: rawValue) else { return }
    modelContext.delete(relay)
    try modelContext.save()
  }

  func toggleRelay(url rawValue: String) throws {
    try materializeDefaultsForCustomizationIfNeeded()
    guard let relay = try persistedRelay(matching: rawValue) else { return }
    relay.isEnabled.toggle()
    try modelContext.save()
  }

  func restoreDefaultRelays() throws {
    try deletePersistedRelays()
    clearCustomizedRelays()
  }

  private func fetchPersistedRelays() throws -> [RelayEntity] {
    let descriptor = FetchDescriptor<RelayEntity>(sortBy: [SortDescriptor(\.createdAt)])
    return try modelContext.fetch(descriptor)
  }

  private func materializeDefaultsForCustomizationIfNeeded() throws {
    let persistedRelays = try fetchPersistedRelays()
    guard try !shouldUseCustomizedRelays(persistedRelays) else {
      return
    }

    RelayDefaults.urls.forEach { modelContext.insert(RelayEntity(url: $0)) }
    try modelContext.save()
    markCustomizedRelays()
  }

  private func persistedRelay(matching rawValue: String) throws -> RelayEntity? {
    let canonicalURL = canonicalRelayURLString(from: rawValue)
    return try fetchPersistedRelays().first(where: {
      canonicalRelayURLString(from: $0.url) == canonicalURL
    })
  }

  private func shouldUseCustomizedRelays(_ persistedRelays: [RelayEntity]) throws -> Bool {
    if hasCustomizedRelays {
      return true
    }
    guard !persistedRelays.isEmpty else { return false }
    markCustomizedRelays()
    return true
  }

  private func deletePersistedRelays() throws {
    let relaysToDelete = try fetchPersistedRelays()
    guard !relaysToDelete.isEmpty else { return }
    relaysToDelete.forEach(modelContext.delete)
    try modelContext.save()
  }

  private func makeVirtualDefaultRelays() -> [RelayEntity] {
    RelayDefaults.urls.enumerated().map { offset, url in
      RelayEntity(
        url: url,
        createdAt: Date(timeIntervalSince1970: TimeInterval(offset))
      )
    }
  }

  private var hasCustomizedRelays: Bool {
    userDefaults.bool(forKey: RelayConfigurationKey.hasCustomizedRelays)
  }

  private func markCustomizedRelays() {
    userDefaults.set(true, forKey: RelayConfigurationKey.hasCustomizedRelays)
  }

  private func clearCustomizedRelays() {
    userDefaults.removeObject(forKey: RelayConfigurationKey.hasCustomizedRelays)
  }

  private func canonicalRelayURLString(from url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    if components.path == "/" {
      components.path = ""
    }
    return components.url?.absoluteString ?? url.absoluteString
  }

  private func canonicalRelayURLString(from rawValue: String) -> String {
    guard let url = URL(string: rawValue) else { return rawValue.lowercased() }
    return canonicalRelayURLString(from: url)
  }
}

private enum RelayStoreError: LocalizedError {
  case duplicateRelay

  var errorDescription: String? {
    switch self {
    case .duplicateRelay:
      return "that relay is already in your list."
    }
  }
}

@MainActor
final class ContactStore {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  private func fetchContacts(ownerPubkey: String) throws
    -> [ContactEntity] {
    let descriptor = FetchDescriptor<ContactEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    return try modelContext.fetch(descriptor)
  }

  func clearAllContacts(ownerPubkey: String) throws {
    let contacts = try fetchContacts(ownerPubkey: ownerPubkey)
    contacts.forEach(modelContext.delete)
    try modelContext.save()
  }

  func normalizeFollowTarget(_ input: String) throws -> String {
    if let normalized = NostrValueNormalizer.normalizedPubkeyHex(fromAnyPublicKeyString: input) {
      return normalized
    }
    throw ContactStoreError.invalidContactKey
  }

  func normalizeAlias(_ alias: String) -> String? {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func contact(ownerPubkey: String, targetPubkey: String) throws -> ContactEntity? {
    var descriptor = FetchDescriptor<ContactEntity>(predicate: #Predicate {
      $0.ownerPubkey == ownerPubkey && $0.targetPubkey == targetPubkey
    })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  func followedPubkeys(ownerPubkey: String) throws -> [String] {
    let contacts = try fetchContacts(ownerPubkey: ownerPubkey)
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(contacts.map(\.targetPubkey))
  }

  @discardableResult
  func replaceFollowedPubkeys(
    ownerPubkey: String,
    pubkeyHexes: [String],
    knownProfiles: [String: KnownProfileSnapshot] = [:],
    save: Bool = true
  ) throws -> [ContactEntity] {
    let normalizedSet = Set(NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes))

    let existing = try fetchContacts(ownerPubkey: ownerPubkey)
    var existingByPubkey: [String: ContactEntity] = [:]
    existingByPubkey.reserveCapacity(existing.count)
    for contact in existing {
      // Retain the oldest row per pubkey and prune any duplicate rows for correctness.
      if existingByPubkey[contact.targetPubkey] == nil {
        existingByPubkey[contact.targetPubkey] = contact
      } else {
        modelContext.delete(contact)
      }
    }

    var added: [ContactEntity] = []
    for pubkey in normalizedSet where existingByPubkey[pubkey] == nil {
      let contact = try ContactEntity(ownerPubkey: ownerPubkey, targetPubkey: pubkey, alias: nil)
      contact.profileSnapshot = knownProfiles[pubkey]
      modelContext.insert(contact)
      added.append(contact)
    }

    for (pubkey, contact) in existingByPubkey where normalizedSet.contains(pubkey) == false {
      modelContext.delete(contact)
    }

    if save { try modelContext.save() }
    return added
  }

  func updateProfile(
    _ profile: KnownProfileSnapshot, ownerPubkey: String, targetPubkey: String
  ) throws -> KnownProfileSnapshot {
    guard let contact = try contact(ownerPubkey: ownerPubkey, targetPubkey: targetPubkey) else { return profile }
    let previousProfile = contact.profileSnapshot
    if let previousProfile,
      !NostrValueNormalizer.shouldApplyReplaceableEvent(
        currentUpdatedAt: previousProfile.updatedAt,
        currentEventID: previousProfile.eventID,
        incomingUpdatedAt: profile.updatedAt,
        incomingEventID: profile.eventID
      ) {
      return previousProfile
    }
    contact.profileSnapshot = profile
    do {
      try modelContext.save()
    } catch {
      contact.profileSnapshot = previousProfile
      throw error
    }
    return profile
  }

  func updateAlias(_ contact: ContactEntity, ownerPubkey: String, alias: String?) throws {
    guard contact.ownerPubkey == ownerPubkey else {
      throw ContactStoreError.contactOwnershipMismatch
    }

    let previousEncryptedAlias = contact.encryptedAlias
    try contact.updateAlias(alias)
    do {
      try modelContext.save()
    } catch {
      contact.restoreEncryptedAlias(previousEncryptedAlias)
      throw error
    }
  }

}

private enum ContactStoreError: LocalizedError {
  case invalidContactKey
  case contactOwnershipMismatch

  var errorDescription: String? {
    switch self {
    case .invalidContactKey:
      return "invalid public key (npub)."
    case .contactOwnershipMismatch:
      return "this contact belongs to a different account."
    }
  }
}
