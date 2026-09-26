import Foundation
import NostrSDK
import SwiftData

@MainActor
final class PrivatePreferenceStore {
  private let context: ModelContext
  private let codec = PrivatePreferenceCodec()

  init(modelContext: ModelContext) {
    self.context = modelContext
  }

  func records(ownerPubkey: String, pendingOnly: Bool = false) throws -> [PrivatePreferenceEntity] {
    try context.fetch(FetchDescriptor<PrivatePreferenceEntity>(predicate: #Predicate {
      $0.ownerPubkey == ownerPubkey && (!pendingOnly || $0.needsPublish)
    }))
  }

  func record(for preference: PrivatePreference, keypair: Keypair) throws -> PrivatePreferenceEntity? {
    let storageID = "\(keypair.publicKey.hex):\(codec.identifier(for: preference, keypair: keypair))"
    return try context.fetch(FetchDescriptor<PrivatePreferenceEntity>(predicate: #Predicate {
      $0.storageID == storageID
    })).first
  }

  func save(
    _ preference: PrivatePreference, keypair: Keypair, saveImmediately: Bool = true
  ) throws {
    let existing = try record(for: preference, keypair: keypair)
    let previous = try existing?.event()
    if let previous, try codec.preference(from: previous, keypair: keypair) == preference { return }
    let timestamp = max(
      Int64(Date.now.timeIntervalSince1970), (previous?.createdAt ?? 0) + 1
    )
    let event = try codec.event(for: preference, keypair: keypair, createdAt: timestamp)
    try persist(event, existing: existing, needsPublish: true, saveImmediately: saveImmediately)
  }

  @discardableResult
  func receiveVerified(
    _ event: NostrEvent, preference: PrivatePreference, keypair: Keypair
  ) throws -> PrivatePreference? {
    let existing = try record(for: preference, keypair: keypair)
    if let previous = try existing?.event() {
      if previous.id == event.id, existing?.needsPublish == false { return preference }
      // NIP-01 keeps the lowest event ID when addressable events have equal timestamps.
      guard event.createdAt > previous.createdAt
        || (event.createdAt == previous.createdAt && event.id <= previous.id)
      else { return nil }
    }
    try persist(event, existing: existing, needsPublish: false)
    return preference
  }

  func seed(_ event: NostrEvent, preference: PrivatePreference, keypair: Keypair) throws {
    // A local edit made while the backup was being encrypted must not be replaced.
    guard try record(for: preference, keypair: keypair) == nil else { return }
    try persist(event, existing: nil, needsPublish: true)
  }

  func markPublished(_ event: NostrEvent, keypair: Keypair) throws {
    let preference = try codec.preference(from: event, keypair: keypair)
    guard let record = try record(for: preference, keypair: keypair),
      try record.event().id == event.id else { return }
    record.needsPublish = false
    do {
      try context.save()
    } catch {
      record.needsPublish = true
      throw error
    }
  }

  func delete(ownerPubkey: String) throws {
    for record in try records(ownerPubkey: ownerPubkey) { context.delete(record) }
    try context.save()
  }

  private func persist(
    _ event: NostrEvent, existing: PrivatePreferenceEntity?, needsPublish: Bool, saveImmediately: Bool = true
  ) throws {
    guard let identifier = event.firstValueForRawTagName("d") else {
      throw PrivatePreferenceError.invalidEvent
    }
    if let existing {
      let oldData = existing.eventData
      let oldPending = existing.needsPublish
      existing.eventData = try JSONEncoder().encode(event)
      existing.needsPublish = needsPublish
      guard saveImmediately else { return }
      do {
        try context.save()
      } catch {
        existing.eventData = oldData
        existing.needsPublish = oldPending
        throw error
      }
    } else {
      let record = try PrivatePreferenceEntity(event: event, identifier: identifier, needsPublish: needsPublish)
      context.insert(record)
      guard saveImmediately else { return }
      do {
        try context.save()
      } catch {
        context.delete(record)
        throw error
      }
    }
  }
}
