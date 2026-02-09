import Foundation
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

  func messageExists(eventID: String) throws -> Bool {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.eventID == eventID }
    )
    return try modelContext.fetch(descriptor).isEmpty == false
  }

  func setConversationArchived(conversationID: String, archived: Bool) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.conversationID == conversationID }
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

  func markConversationPostsRead(conversationID: String, myPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.conversationID == conversationID }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .root {
      guard message.senderPubkey != myPubkey, message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func markPostRepliesRead(postID: String, myPubkey: String) throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>(
      predicate: #Predicate { $0.rootID == postID }
    )
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages where message.kind == .reply {
      guard message.senderPubkey != myPubkey, message.readAt == nil else { continue }
      message.readAt = .now
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }

  func clearAllMessages() throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>()
    let messages = try modelContext.fetch(descriptor)
    messages.forEach(modelContext.delete)
    try modelContext.save()
  }

  func clearCachedVideos() throws {
    VideoCacheService.shared.clearAll()
    let descriptor = FetchDescriptor<SessionMessageEntity>()
    let messages = try modelContext.fetch(descriptor)

    for message in messages where message.cachedMediaPath != nil {
      if let path = message.cachedMediaPath {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
      }
      message.cachedMediaPath = nil
      message.cachedMediaSourceURL = nil
    }
    try modelContext.save()
  }

  func normalizeConversationIDs() throws {
    let descriptor = FetchDescriptor<SessionMessageEntity>()
    let messages = try modelContext.fetch(descriptor)

    var didChange = false
    for message in messages {
      let canonicalID = ConversationID.deterministic(message.senderPubkey, message.receiverPubkey)
      guard message.conversationID != canonicalID else { continue }
      message.conversationID = canonicalID
      didChange = true
    }

    if didChange {
      try modelContext.save()
    }
  }
}
