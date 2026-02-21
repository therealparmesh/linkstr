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
      return "That relay is already in your list."
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

  func addContact(ownerPubkey: String, npub: String, displayName: String) throws {
    let normalizedNPub = try normalize(npub: npub)
    let normalizedDisplayName = normalize(displayName: displayName)

    guard !normalizedDisplayName.isEmpty else {
      throw ContactStoreError.emptyDisplayName
    }
    guard !hasContact(ownerPubkey: ownerPubkey, withNPub: normalizedNPub) else {
      throw ContactStoreError.duplicateContact
    }

    modelContext.insert(
      try ContactEntity(
        ownerPubkey: ownerPubkey,
        npub: normalizedNPub,
        displayName: normalizedDisplayName
      ))
    try modelContext.save()
  }

  func updateContact(
    _ contact: ContactEntity, ownerPubkey: String, npub: String, displayName: String
  ) throws {
    guard contact.ownerPubkey == ownerPubkey else {
      throw ContactStoreError.contactOwnershipMismatch
    }
    let normalizedNPub = try normalize(npub: npub)
    let normalizedDisplayName = normalize(displayName: displayName)

    guard !normalizedDisplayName.isEmpty else {
      throw ContactStoreError.emptyDisplayName
    }
    guard
      !hasContact(
        ownerPubkey: ownerPubkey, withNPub: normalizedNPub, excluding: contact.persistentModelID)
    else {
      throw ContactStoreError.duplicateContact
    }

    let previousHash = contact.npubHash
    let previousEncryptedNPub = contact.encryptedNPub
    let previousEncryptedDisplayName = contact.encryptedDisplayName
    try contact.updateSecureFields(npub: normalizedNPub, displayName: normalizedDisplayName)
    do {
      try modelContext.save()
    } catch {
      contact.npubHash = previousHash
      contact.encryptedNPub = previousEncryptedNPub
      contact.encryptedDisplayName = previousEncryptedDisplayName
      throw error
    }
  }

  func removeContact(_ contact: ContactEntity, ownerPubkey: String) throws {
    guard contact.ownerPubkey == ownerPubkey else {
      throw ContactStoreError.contactOwnershipMismatch
    }
    modelContext.delete(contact)
    try modelContext.save()
  }

  func clearAllContacts(ownerPubkey: String) throws {
    let descriptor = FetchDescriptor<ContactEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    let contacts = try modelContext.fetch(descriptor)
    contacts.forEach(modelContext.delete)
    try modelContext.save()
  }

  func contactName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    for contact in contacts where PublicKey(npub: contact.npub)?.hex == pubkeyHex {
      return contact.displayName
    }
    if let npub = PublicKey(hex: pubkeyHex)?.npub {
      return npub
    }
    return String(pubkeyHex.prefix(12))
  }

  func hasContact(
    ownerPubkey: String, withNPub npub: String, excluding contactID: PersistentIdentifier? = nil
  ) -> Bool {
    guard let contacts = try? fetchContacts(ownerPubkey: ownerPubkey) else { return false }
    return contacts.contains { existing in
      guard existing.matchesNPub(npub) else { return false }
      if let contactID {
        return existing.persistentModelID != contactID
      }
      return true
    }
  }

  private func normalize(npub: String) throws -> String {
    let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsedPublicKey = PublicKey(npub: trimmed) else {
      throw ContactStoreError.invalidNPub
    }
    return parsedPublicKey.npub
  }

  private func normalize(displayName: String) -> String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private enum ContactStoreError: LocalizedError {
  case invalidNPub
  case emptyDisplayName
  case duplicateContact
  case contactOwnershipMismatch

  var errorDescription: String? {
    switch self {
    case .invalidNPub:
      return "Invalid Contact Key (npub)."
    case .emptyDisplayName:
      return "Enter a display name."
    case .duplicateContact:
      return "This contact is already in your list."
    case .contactOwnershipMismatch:
      return "This contact belongs to a different account."
    }
  }
}
