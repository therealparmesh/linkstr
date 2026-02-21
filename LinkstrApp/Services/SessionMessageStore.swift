import Foundation
import NostrSDK
import SwiftData

@MainActor
final class SessionMessageStore {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func insert(_ message: SessionMessageEntity) throws {
    modelContext.insert(message)
    try modelContext.save()
  }

  func message(eventID: String, ownerPubkey: String) throws -> SessionMessageEntity? {
    let storageID = SessionMessageEntity.storageID(ownerPubkey: ownerPubkey, eventID: eventID)
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  func message(storageID: String) throws -> SessionMessageEntity? {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.storageID == storageID }
    )
    return try modelContext.fetch(descriptor).first
  }

  func rootMessages(ownerPubkey: String) throws -> [SessionMessageEntity] {
    let rootKindRaw = SessionMessageKind.root.rawValue
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate {
        $0.ownerPubkey == ownerPubkey && $0.kindRaw == rootKindRaw
      }
    )
    return try modelContext.fetch(descriptor)
  }

  func setConversationArchived(conversationID: String, ownerPubkey: String, archived: Bool) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.conversationID == conversationID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .root {
      guard message.isArchived != archived else { continue }
      message.isArchived = archived
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func markConversationPostsRead(conversationID: String, ownerPubkey: String, myPubkey: String)
    throws
  {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.conversationID == conversationID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .root {
      guard !message.senderMatches(myPubkey), message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func markRootPostRead(postID: String, ownerPubkey: String, myPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.rootID == postID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .root {
      guard !message.senderMatches(myPubkey), message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func markPostRepliesRead(postID: String, ownerPubkey: String, myPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.rootID == postID && $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .reply {
      guard !message.senderMatches(myPubkey), message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func clearAllMessages(ownerPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)
    messages.forEach(modelContext.delete)
    try modelContext.save()
  }

  func clearCachedVideos(ownerPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.cachedMediaPath != nil {
      if let path = message.cachedMediaPath {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
      }
      message.cachedMediaPath = nil
      message.cachedMediaSourceURL = nil
      didChange = true
    }
    if didChange {
      try modelContext.save()
    }
  }

  func normalizeConversationIDs(ownerPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.ownerPubkey == ownerPubkey }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages {
      let senderPubkey = message.senderPubkey
      let receiverPubkey = message.receiverPubkey
      guard PublicKey(hex: senderPubkey) != nil, PublicKey(hex: receiverPubkey) != nil else {
        continue
      }
      let canonicalID = ConversationID.deterministic(senderPubkey, receiverPubkey)
      guard message.conversationID != canonicalID else { continue }
      message.conversationID = canonicalID
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

}
