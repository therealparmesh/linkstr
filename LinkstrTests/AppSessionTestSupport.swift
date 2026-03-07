import NostrSDK
import SwiftData
import XCTest

@testable import Linkstr

@MainActor
class AppSessionTestCase: XCTestCase {
  override func setUpWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

  override func tearDownWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

  func insertSessionFixture(
    in context: ModelContext,
    ownerPubkey: String,
    createdByPubkey: String,
    memberPubkeys: [String],
    name: String = "Test Session",
    sessionID: String = "session-fixture"
  ) throws -> SessionEntity {
    let createdAt = Date.now
    let sessionEntity = try SessionEntity(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      name: name,
      createdByPubkey: createdByPubkey,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    context.insert(sessionEntity)

    for memberPubkey in Set(memberPubkeys) {
      let member = try SessionMemberEntity(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkey: memberPubkey,
        isActive: true,
        createdAt: createdAt,
        updatedAt: createdAt
      )
      context.insert(member)

      let interval = try SessionMemberIntervalEntity(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkey: memberPubkey,
        startAt: createdAt
      )
      context.insert(interval)
    }

    try context.save()
    return sessionEntity
  }

  func makeSession(
    testingOverrides: AppSession.TestingOverrides = {
      var overrides = AppSession.TestingOverrides()
      overrides.skipNostrNetworkStartup = true
      return overrides
    }()
  ) throws -> (AppSession, ModelContainer) {
    let schema = Schema([
      AccountStateEntity.self,
      ContactEntity.self,
      RelayEntity.self,
      SessionEntity.self,
      SessionMemberEntity.self,
      SessionMemberIntervalEntity.self,
      SessionReactionEntity.self,
      SessionPostDeletionEntity.self,
      SessionMessageEntity.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (
      AppSession(
        modelContext: container.mainContext,
        testingOverrides: testingOverrides
      ),
      container
    )
  }

  func makeSession(
    disableNostrStartup: Bool? = nil,
    hasConnectedRelays: (() -> Bool)? = nil,
    publishFollowList: (([String]) async throws -> String)? = nil,
    publishRelayEvent: ((NostrEvent) async throws -> String)? = nil,
    sendPayload: ((LinkstrPayload, [String]) async throws -> SentPayloadReceipt)? = nil,
    skipNostrNetworkStartup: Bool = true
  ) throws -> (AppSession, ModelContainer) {
    var testingOverrides = AppSession.TestingOverrides()
    testingOverrides.disableNostrStartup = disableNostrStartup
    testingOverrides.hasConnectedRelays = hasConnectedRelays
    testingOverrides.publishFollowList = publishFollowList
    testingOverrides.publishRelayEvent = publishRelayEvent
    testingOverrides.sendPayload = sendPayload
    testingOverrides.skipNostrNetworkStartup = skipNostrNetworkStartup
    return try makeSession(testingOverrides: testingOverrides)
  }

  func fetchContacts(in context: ModelContext) throws -> [ContactEntity] {
    try context.fetch(FetchDescriptor<ContactEntity>(sortBy: [SortDescriptor(\.createdAt)]))
  }

  func fetchRelays(in context: ModelContext) throws -> [RelayEntity] {
    try context.fetch(FetchDescriptor<RelayEntity>(sortBy: [SortDescriptor(\.createdAt)]))
  }

  func fetchMessages(in context: ModelContext) throws -> [SessionMessageEntity] {
    try context.fetch(
      FetchDescriptor<SessionMessageEntity>(sortBy: [SortDescriptor(\.timestamp)]))
  }

  func fetchReactions(in context: ModelContext) throws -> [SessionReactionEntity] {
    try context.fetch(
      FetchDescriptor<SessionReactionEntity>(sortBy: [SortDescriptor(\.updatedAt)]))
  }

  func fetchPostDeletions(in context: ModelContext) throws -> [SessionPostDeletionEntity] {
    try context.fetch(
      FetchDescriptor<SessionPostDeletionEntity>(sortBy: [SortDescriptor(\.updatedAt)]))
  }

  func fetchAccountStates(in context: ModelContext) throws -> [AccountStateEntity] {
    try context.fetch(FetchDescriptor<AccountStateEntity>())
  }

  func makeManagedThumbnailURL() -> URL {
    ManagedLocalFileScope.shared.thumbnailFileURL(
      for: "test-thumbnail-\(UUID().uuidString)",
      fileExtension: "png"
    )
  }

  func makeManagedVideoURL() -> URL {
    ManagedLocalFileScope.shared.cachedVideoFileURL(
      for: URL(string: "https://example.com/video-\(UUID().uuidString).mp4")!,
      preferredExtension: "mp4"
    )
  }

  func makeUnmanagedTempURL(prefix: String, fileExtension: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix)-\(UUID().uuidString).\(fileExtension)")
  }

  func makeIncomingMessage(
    eventID: String,
    transportEventID: String? = nil,
    senderPubkey: String,
    createdAt: Date,
    payload: LinkstrPayload,
    source: DirectMessageIngestSource = .live
  ) -> ReceivedDirectMessage {
    return ReceivedDirectMessage(
      eventID: eventID,
      transportEventID: transportEventID,
      senderPubkey: senderPubkey,
      payload: payload,
      createdAt: createdAt,
      source: source
    )
  }

  func makeMessage(
    eventID: String,
    conversationID: String,
    rootID: String,
    kind: SessionMessageKind,
    senderPubkey: String,
    receiverPubkey: String,
    ownerPubkey: String,
    publishedTransportEventIDs: [String] = []
  ) -> SessionMessageEntity {
    guard
      let message = try? SessionMessageEntity(
        eventID: eventID,
        ownerPubkey: ownerPubkey,
        conversationID: conversationID,
        rootID: rootID,
        kind: kind,
        senderPubkey: senderPubkey,
        receiverPubkey: receiverPubkey,
        url: "https://example.com/\(eventID)",
        note: "note-\(eventID)",
        timestamp: .now,
        readAt: nil,
        linkType: .generic,
        publishedTransportEventIDs: publishedTransportEventIDs
      )
    else {
      fatalError("Failed building test message for \(eventID)")
    }
    return message
  }
}

enum TestKeyMaterialFactory {
  static func makeKeypair() throws -> Keypair {
    guard let keypair = Keypair() else {
      throw TestKeyMaterialFactoryError.keypairGenerationFailed
    }
    return keypair
  }

  static func makeNPub() throws -> String {
    try makeKeypair().publicKey.npub
  }

  static func makePubkeyHex() throws -> String {
    try makeKeypair().publicKey.hex
  }
}

enum TestKeyMaterialFactoryError: Error {
  case keypairGenerationFailed
}
