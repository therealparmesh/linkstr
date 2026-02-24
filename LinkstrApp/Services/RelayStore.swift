import Foundation
import NostrSDK
import SwiftData

@MainActor
final class RelayStore {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func ensureDefaultRelays() throws {
    let relays = try fetchRelays()
    guard relays.isEmpty else { return }
    RelayDefaults.urls.forEach { modelContext.insert(RelayEntity(url: $0)) }
    try modelContext.save()
  }

  func fetchRelays() throws -> [RelayEntity] {
    let descriptor = FetchDescriptor<RelayEntity>(sortBy: [SortDescriptor(\.createdAt)])
    return try modelContext.fetch(descriptor)
  }

  func addRelay(url: URL) throws {
    let relayURL = canonicalRelayURLString(from: url)
    let existingRelayURLs = try fetchRelays().map(\.url)
    if existingRelayURLs.contains(where: { canonicalRelayURLString(from: $0) == relayURL }) {
      throw RelayStoreError.duplicateRelay
    }

    modelContext.insert(RelayEntity(url: relayURL))
    try modelContext.save()
  }

  func removeRelay(_ relay: RelayEntity) throws {
    modelContext.delete(relay)
    try modelContext.save()
  }

  func toggleRelay(_ relay: RelayEntity) throws {
    relay.isEnabled.toggle()
    if relay.isEnabled == false {
      relay.status = .disconnected
      relay.lastError = nil
    }
    try modelContext.save()
  }

  func resetDefaultRelays() throws {
    let descriptor = FetchDescriptor<RelayEntity>()
    let existingRelays = try modelContext.fetch(descriptor)
    existingRelays.forEach(modelContext.delete)

    RelayDefaults.urls.forEach { modelContext.insert(RelayEntity(url: $0)) }
    try modelContext.save()
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

  func fetchContacts(ownerPubkey: String, sortedByDisplayName: Bool = false) throws
    -> [ContactEntity]
  {
    let descriptor = FetchDescriptor<ContactEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    let contacts = try modelContext.fetch(descriptor)
    if sortedByDisplayName {
      return contacts.sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
    }
    return contacts
  }

  func clearAllContacts(ownerPubkey: String) throws {
    let contacts = try fetchContacts(ownerPubkey: ownerPubkey)
    contacts.forEach(modelContext.delete)
    try modelContext.save()
  }

  func normalizeFollowTarget(_ input: String) throws -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let parsedNPub = PublicKey(npub: trimmed) {
      return parsedNPub.hex
    }
    if let parsedHex = PublicKey(hex: trimmed.lowercased()) {
      return parsedHex.hex
    }
    throw ContactStoreError.invalidContactKey
  }

  func normalizeAlias(_ alias: String) -> String? {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func hasContact(ownerPubkey: String, withTargetPubkey targetPubkey: String) -> Bool {
    guard let contacts = try? fetchContacts(ownerPubkey: ownerPubkey) else { return false }
    return contacts.contains(where: { $0.targetPubkey == targetPubkey })
  }

  func followedPubkeys(ownerPubkey: String) throws -> [String] {
    let contacts = try fetchContacts(ownerPubkey: ownerPubkey)
    var seen = Set<String>()
    var output: [String] = []
    output.reserveCapacity(contacts.count)
    for contact in contacts {
      guard PublicKey(hex: contact.targetPubkey) != nil else { continue }
      guard seen.insert(contact.targetPubkey).inserted else { continue }
      output.append(contact.targetPubkey)
    }
    return output
  }

  func replaceFollowedPubkeys(ownerPubkey: String, pubkeyHexes: [String]) throws {
    var normalizedSet = Set<String>()
    for rawPubkey in pubkeyHexes {
      let trimmed = rawPubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard let parsed = PublicKey(hex: trimmed) else { continue }
      normalizedSet.insert(parsed.hex)
    }

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

    for pubkey in normalizedSet where existingByPubkey[pubkey] == nil {
      modelContext.insert(
        try ContactEntity(ownerPubkey: ownerPubkey, targetPubkey: pubkey, alias: nil)
      )
    }

    for (pubkey, contact) in existingByPubkey where normalizedSet.contains(pubkey) == false {
      modelContext.delete(contact)
    }

    try modelContext.save()
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
      contact.encryptedAlias = previousEncryptedAlias
      throw error
    }
  }

  func updateAlias(ownerPubkey: String, targetPubkey: String, alias: String?) throws {
    let descriptor = FetchDescriptor<ContactEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey && $0.targetPubkey == targetPubkey
      }
    )
    guard let contact = try modelContext.fetch(descriptor).first else {
      throw ContactStoreError.contactNotFound
    }
    try updateAlias(contact, ownerPubkey: ownerPubkey, alias: alias)
  }

  func contactName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    let canonicalPubkey = PublicKey(hex: pubkeyHex)?.hex ?? pubkeyHex
    for contact in contacts where contact.targetPubkey == canonicalPubkey {
      return contact.displayName
    }
    if let npub = PublicKey(hex: pubkeyHex)?.npub {
      return npub
    }
    return String(pubkeyHex.prefix(12))
  }
}

private enum ContactStoreError: LocalizedError {
  case invalidContactKey
  case contactOwnershipMismatch
  case contactNotFound

  var errorDescription: String? {
    switch self {
    case .invalidContactKey:
      return "invalid contact key (npub)."
    case .contactOwnershipMismatch:
      return "this contact belongs to a different account."
    case .contactNotFound:
      return "contact not found."
    }
  }
}
