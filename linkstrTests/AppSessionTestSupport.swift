import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
class AppSessionTestCase: XCTestCase {
  let shortRelayMutationTimeoutSeconds: TimeInterval = 0.05
  let shortRelayMutationPollIntervalSeconds: TimeInterval = 0.01
  let shortRemoteProfileLookupRetryNanoseconds: UInt64 = 50_000_000
  let asyncExpectationTimeoutSeconds: TimeInterval = 1.0
  private var relaySettingsSuiteNames: [String] = []

  override func setUpWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

  override func tearDownWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
    for suiteName in relaySettingsSuiteNames {
      UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
    relaySettingsSuiteNames.removeAll()
  }

  func makeRelaySettingsUserDefaults() -> UserDefaults {
    let suiteName = "linkstrTests.RelaySettings.\(UUID().uuidString)"
    relaySettingsSuiteNames.append(suiteName)
    let userDefaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
    userDefaults.removePersistentDomain(forName: suiteName)
    return userDefaults
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
    relaySettingsUserDefaults: UserDefaults? = nil,
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
      SessionDeletionTombstoneEntity.self,
      SessionPostDeletionEntity.self,
      SessionMessageEntity.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return (
      AppSession(
        modelContext: container.mainContext,
        relaySettingsUserDefaults: relaySettingsUserDefaults ?? makeRelaySettingsUserDefaults(),
        testingOverrides: testingOverrides
      ),
      container
    )
  }

  func makeSession(
    disableNostrStartup: Bool? = nil,
    hasConnectedRelays: (() -> Bool)? = nil,
    passiveOfflineToastGraceInterval: TimeInterval? = nil,
    loadIdentity: ((IdentityService) -> IdentityService.LoadResult)? = nil,
    identityRetryDelayNanoseconds: UInt64? = nil,
    skipPersistedFollowListStateLoad: Bool = false,
    publishFollowList: (([String]) async throws -> String)? = nil,
    publishRelayEvent: ((NostrEvent) async throws -> String)? = nil,
    sendPayload: ((LinkstrPayload, [String]) async throws -> SentPayloadReceipt)? = nil,
    skipNostrNetworkStartup: Bool = true,
    onNostrStart: (() -> Void)? = nil,
    requestProfileMetadata: (([String]) -> Bool)? = nil,
    remoteProfileLookupRetryNanoseconds: UInt64? = nil,
    clearLocalAccountData: ((String) throws -> Void)? = nil,
    registerPushDevice: ((PushDeviceRegistration) async throws -> Void)? = nil,
    unregisterPushDevice: ((String) async throws -> Void)? = nil,
    syncArchivedConversationIDs: (([String]) async throws -> Void)? = nil,
    enqueuePushNotification: ((PushEnqueueRequest) async throws -> Void)? = nil,
    fetchLinkPreview: ((String) async -> LinkPreviewData?)? = nil,
    relaySettingsUserDefaults: UserDefaults? = nil
  ) throws -> (AppSession, ModelContainer) {
    var testingOverrides = AppSession.TestingOverrides()
    testingOverrides.disableNostrStartup = disableNostrStartup
    testingOverrides.hasConnectedRelays = hasConnectedRelays
    testingOverrides.passiveOfflineToastGraceInterval = passiveOfflineToastGraceInterval
    testingOverrides.loadIdentity = loadIdentity
    testingOverrides.identityRetryDelayNanoseconds = identityRetryDelayNanoseconds
    testingOverrides.skipPersistedFollowListStateLoad = skipPersistedFollowListStateLoad
    testingOverrides.publishFollowList = publishFollowList
    testingOverrides.publishRelayEvent = publishRelayEvent
    testingOverrides.sendPayload = sendPayload
    testingOverrides.skipNostrNetworkStartup = skipNostrNetworkStartup
    testingOverrides.onNostrStart = onNostrStart
    testingOverrides.requestProfileMetadata = requestProfileMetadata
    testingOverrides.remoteProfileLookupRetryNanoseconds = remoteProfileLookupRetryNanoseconds
    testingOverrides.clearLocalAccountData = clearLocalAccountData
    testingOverrides.registerPushDevice = registerPushDevice
    testingOverrides.unregisterPushDevice = unregisterPushDevice
    testingOverrides.syncArchivedConversationIDs = syncArchivedConversationIDs
    testingOverrides.enqueuePushNotification = enqueuePushNotification
    testingOverrides.fetchLinkPreview = fetchLinkPreview
    return try makeSession(
      relaySettingsUserDefaults: relaySettingsUserDefaults,
      testingOverrides: testingOverrides
    )
  }

  func fetchContacts(in context: ModelContext) throws -> [ContactEntity] {
    try context.fetch(FetchDescriptor<ContactEntity>(sortBy: [SortDescriptor(\.createdAt)]))
  }

  func fetchPersistedRelays(in context: ModelContext) throws -> [RelayEntity] {
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

  func fetchSessionDeletionTombstones(
    in context: ModelContext
  ) throws -> [SessionDeletionTombstoneEntity] {
    try context.fetch(
      FetchDescriptor<SessionDeletionTombstoneEntity>(sortBy: [SortDescriptor(\.updatedAt)]))
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

  struct MessageSpec {
    var eventID: String
    var conversationID: String
    var rootID: String
    var kind: SessionMessageKind
    var senderPubkey: String
    var receiverPubkey: String?
    var ownerPubkey: String
    var publishedTransportEventIDs: [String] = []
  }

  func makeMessage(_ spec: MessageSpec) throws -> SessionMessageEntity {
    try SessionMessageEntity(
      eventID: spec.eventID,
      ownerPubkey: spec.ownerPubkey,
      conversationID: spec.conversationID,
      rootID: spec.rootID,
      kind: spec.kind,
      senderPubkey: spec.senderPubkey,
      receiverPubkey: spec.receiverPubkey,
      url: "https://example.com/\(spec.eventID)",
      note: "note-\(spec.eventID)",
      timestamp: .now,
      readAt: nil,
      linkType: .generic,
      publishedTransportEventIDs: spec.publishedTransportEventIDs
    )
  }

  func makeMessage(
    eventID: String,
    conversationID: String,
    rootID: String,
    kind: SessionMessageKind = .root,
    senderPubkey: String,
    receiverPubkey: String? = nil,
    ownerPubkey: String,
    publishedTransportEventIDs: [String] = []
  ) throws -> SessionMessageEntity {
    try makeMessage(
      MessageSpec(
        eventID: eventID,
        conversationID: conversationID,
        rootID: rootID,
        kind: kind,
        senderPubkey: senderPubkey,
        receiverPubkey: receiverPubkey,
        ownerPubkey: ownerPubkey,
        publishedTransportEventIDs: publishedTransportEventIDs
      ))
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
