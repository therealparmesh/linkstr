import Foundation
import NostrSDK
import SwiftData

@MainActor
final class AppSession: ObservableObject {
  enum RelayConnectivityState: Equatable {
    case noEnabledRelays
    case online
    case readOnly
    case reconnecting
    case offline
  }

  private struct RelayRuntimeStatus {
    var status: RelayHealthStatus
    var message: String?
  }

  private struct RootPostDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let sessionID: String
    let rootID: String
    let recipientPubkeys: [String]
    let normalizedURL: String
    let normalizedNote: String?
  }

  private struct ReactionDraft {
    let payload: LinkstrPayload
    let ownerPubkey: String
    let senderPubkey: String
    let sessionID: String
    let postID: String
    let emoji: String
    let isActive: Bool
    let recipientPubkeys: [String]
  }

  let identityService: IdentityService
  let nostrService: NostrDMService
  let modelContext: ModelContext
  private let contactStore: ContactStore
  private let relayStore: RelayStore
  private let messageStore: SessionMessageStore
  private let testHasConnectedRelaysOverride: (() -> Bool)?
  private let testDisableNostrStartupOverride: Bool?
  private let testRelaySendOverride: ((LinkstrPayload, String) async throws -> String)?
  private let noEnabledRelaysMessage =
    "No relays are enabled. Enable at least one relay in Settings."
  private let relayOfflineMessage = "You're offline. Waiting for a relay connection."
  private let relayReadOnlyMessage =
    "Connected relays are read-only. Add a writable relay to send."
  private let relaySendTimeoutMessage = "Couldn't reconnect to relays in time. Try again."
  private var hasShownOfflineToastForCurrentOutage = false
  private var isForeground = false
  private var pendingMetadataStorageIDs: [String] = []
  private var enqueuedMetadataStorageIDs = Set<String>()
  private var isProcessingMetadataQueue = false
  private var relayRuntimeStatusByURL: [String: RelayRuntimeStatus] = [:]

  @Published var composeError: String?
  @Published private(set) var hasIdentity = false
  @Published private(set) var didFinishBoot = false
  @Published private(set) var bootStatusMessage = "Loading account…"

  init(
    modelContext: ModelContext,
    testDisableNostrStartupOverride: Bool? = nil,
    testHasConnectedRelaysOverride: (() -> Bool)? = nil,
    testRelaySendOverride: ((LinkstrPayload, String) async throws -> String)? = nil
  ) {
    self.modelContext = modelContext
    self.testDisableNostrStartupOverride = testDisableNostrStartupOverride
    self.testHasConnectedRelaysOverride = testHasConnectedRelaysOverride
    self.testRelaySendOverride = testRelaySendOverride
    self.identityService = IdentityService()
    self.nostrService = NostrDMService()
    self.contactStore = ContactStore(modelContext: modelContext)
    self.relayStore = RelayStore(modelContext: modelContext)
    self.messageStore = SessionMessageStore(modelContext: modelContext)
  }

  func boot() {
    didFinishBoot = false
    bootStatusMessage = "Loading account…"
    defer { didFinishBoot = true }

    identityService.loadIdentity()
    refreshIdentityState()
    LocalNotificationService.shared.configure()
    if !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      LocalNotificationService.shared.requestAuthorizationIfNeeded()
    }

    #if targetEnvironment(simulator)
      if isEnvironmentFlagEnabled("LINKSTR_SIM_BOOTSTRAP") {
        bootStatusMessage = "Preparing simulator account…"
        bootstrapSimulatorIfNeeded()
        refreshIdentityState()
      }
    #endif

    do {
      bootStatusMessage = "Preparing local data…"
      purgeLegacyNonRootMessagesIfNeeded()
      bootStatusMessage = "Connecting relays…"
      try relayStore.ensureDefaultRelays()
      pruneRuntimeRelayStatusCache()
    } catch {
      composeError = error.localizedDescription
    }
    bootStatusMessage = "Starting session…"
    handleAppDidBecomeActive()
    hydrateMissingMetadata()
  }

  func handleAppDidBecomeActive() {
    isForeground = true
    startNostrIfPossible(forceRestart: true)
  }

  func handleAppDidLeaveForeground() {
    isForeground = false
  }

  private func report(error: Error) {
    composeError = error.localizedDescription
  }

  func relayConnectivityState(for enabledRelays: [RelayEntity]) -> RelayConnectivityState {
    guard !enabledRelays.isEmpty else { return .noEnabledRelays }

    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .connected }) {
      return .online
    }
    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .readOnly }) {
      return .readOnly
    }
    if enabledRelays.contains(where: { effectiveRelayStatus(for: $0) == .reconnecting }) {
      return .reconnecting
    }
    return .offline
  }

  private func clearOfflineToastIfPresent() {
    hasShownOfflineToastForCurrentOutage = false
    if composeError == relayOfflineMessage {
      composeError = nil
    }
  }

  private func showOfflineToastForCurrentOutageIfNeeded() {
    guard !hasShownOfflineToastForCurrentOutage else { return }
    composeError = relayOfflineMessage
    hasShownOfflineToastForCurrentOutage = true
  }

  private func clearRelaySendBlockingErrorIfPresent() {
    if composeError == relayOfflineMessage
      || composeError == noEnabledRelaysMessage
      || composeError == relayReadOnlyMessage
    {
      composeError = nil
    }
  }

  private func hasConnectedRelays() -> Bool {
    if let testHasConnectedRelaysOverride {
      return testHasConnectedRelaysOverride()
    }
    return nostrService.hasConnectedRelays()
  }

  func relayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    if relay.isEnabled == false {
      return .disconnected
    }
    return effectiveRelayStatus(for: relay)
  }

  func relayErrorMessage(for relay: RelayEntity) -> String? {
    guard relay.isEnabled else { return nil }
    let runtime = relayRuntimeStatusByURL[relay.url]?.message
    let trimmedRuntime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedRuntime.isEmpty {
      return trimmedRuntime
    }
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
      return nil
    }
    let persisted = relay.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return persisted.isEmpty ? nil : persisted
  }

  func connectedRelayCount(for relays: [RelayEntity]) -> Int {
    relays.count { relay in
      relay.isEnabled
        && (relayStatus(for: relay) == .connected || relayStatus(for: relay) == .readOnly)
    }
  }

  func scopedContacts(from contacts: [ContactEntity]) -> [ContactEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return
      contacts
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  func scopedMessages(from messages: [SessionMessageEntity]) -> [SessionMessageEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return messages.filter { $0.ownerPubkey == ownerPubkey }
  }

  func scopedSessions(from sessions: [SessionEntity]) -> [SessionEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return
      sessions
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func scopedSessionMembers(from members: [SessionMemberEntity]) -> [SessionMemberEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return members.filter { $0.ownerPubkey == ownerPubkey }
  }

  func scopedReactions(from reactions: [SessionReactionEntity]) -> [SessionReactionEntity] {
    guard let ownerPubkey = identityService.pubkeyHex else { return [] }
    return reactions.filter { $0.ownerPubkey == ownerPubkey }
  }

  private func effectiveRelayStatus(for relay: RelayEntity) -> RelayHealthStatus {
    if let runtimeStatus = relayRuntimeStatusByURL[relay.url]?.status {
      return runtimeStatus
    }
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return relay.status
    }
    return .disconnected
  }

  private func updateRuntimeRelayStatus(
    relayURL: String,
    status: RelayHealthStatus,
    message: String?
  ) {
    let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    relayRuntimeStatusByURL[relayURL] = RelayRuntimeStatus(
      status: status,
      message: (trimmedMessage?.isEmpty == false) ? trimmedMessage : nil
    )
  }

  private func pruneRuntimeRelayStatusCache() {
    let relays = (try? relayStore.fetchRelays()) ?? []
    let enabledURLs = Set(relays.filter(\.isEnabled).map(\.url))
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { enabledURLs.contains($0.key) }
  }

  private func refreshRelayConnectivityAlert() throws {
    let enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    switch relayConnectivityState(for: enabledRelays) {
    case .online, .readOnly:
      clearOfflineToastIfPresent()
    case .reconnecting:
      // Keep outage state while sockets are still flapping between reconnecting/offline.
      // Clearing here can create repeated toast show/hide loops during relay churn.
      return
    case .offline:
      showOfflineToastForCurrentOutageIfNeeded()
    case .noEnabledRelays:
      return
    }
  }

  private enum RelaySendWaitState {
    case ready
    case blocked(message: String)
    case waitingForConnection
  }

  private func relaySendWaitState() -> RelaySendWaitState {
    if shouldDisableNostrStartupForCurrentProcess() {
      return .ready
    }

    if hasConnectedRelays() {
      return .ready
    }

    let enabledRelays: [RelayEntity]
    do {
      enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    } catch {
      return .blocked(message: error.localizedDescription)
    }

    switch relayConnectivityState(for: enabledRelays) {
    case .noEnabledRelays:
      return .blocked(message: noEnabledRelaysMessage)
    case .readOnly:
      return .blocked(message: relayReadOnlyMessage)
    case .online, .offline, .reconnecting:
      return .waitingForConnection
    }
  }

  private func awaitRelayReadyForSend(
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async -> Bool {
    let timeout = max(0, timeoutSeconds)
    let pollInterval = max(0.05, pollIntervalSeconds)
    let deadline = Date.now.addingTimeInterval(timeout)

    while true {
      switch relaySendWaitState() {
      case .ready:
        clearRelaySendBlockingErrorIfPresent()
        return true
      case .blocked(let message):
        composeError = message
        hasShownOfflineToastForCurrentOutage = false
        return false
      case .waitingForConnection:
        if Date.now >= deadline {
          composeError = relaySendTimeoutMessage
          hasShownOfflineToastForCurrentOutage = false
          return false
        }

        if composeError == relayOfflineMessage {
          composeError = nil
        }
        startNostrIfPossible()

        let sleepNanoseconds = UInt64(pollInterval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: sleepNanoseconds)
      }
    }
  }

  private func makeLocalEventID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private func isEnvironmentFlagEnabled(_ key: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env[key] == "1"
  }

  private func shouldDisableNostrStartupForCurrentProcess() -> Bool {
    if let testDisableNostrStartupOverride {
      return testDisableNostrStartupOverride
    }

    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return false }
    return !isEnvironmentFlagEnabled("LINKSTR_ENABLE_NOSTR_IN_TESTS")
  }

  private func shouldFetchMetadataForCurrentProcess() -> Bool {
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return true }
    return isEnvironmentFlagEnabled("LINKSTR_ENABLE_METADATA_IN_TESTS")
  }

  func ensureIdentity() {
    if identityService.keypair == nil {
      do {
        try identityService.createNewIdentity()
        refreshIdentityState()
        composeError = nil
        startNostrIfPossible()
      } catch {
        composeError = error.localizedDescription
      }
    } else {
      refreshIdentityState()
    }
  }

  func importNsec(_ nsec: String) {
    do {
      try identityService.importNsec(nsec)
      refreshIdentityState()
      composeError = nil
      startNostrIfPossible()
    } catch {
      composeError = error.localizedDescription
    }
  }

  func logout(clearLocalData: Bool) {
    let ownerPubkey = identityService.pubkeyHex
    nostrService.stop()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return
    }
    refreshIdentityState()
    pendingMetadataStorageIDs.removeAll()
    enqueuedMetadataStorageIDs.removeAll()
    isProcessingMetadataQueue = false
    relayRuntimeStatusByURL.removeAll()

    if let ownerPubkey, clearLocalData {
      clearCachedVideos(ownerPubkey: ownerPubkey)
      clearMessageCache(ownerPubkey: ownerPubkey)
      clearAllContacts(ownerPubkey: ownerPubkey)
      try? LocalDataCrypto.shared.clearKey(ownerPubkey: ownerPubkey)
    }

    composeError = nil
  }

  private func refreshIdentityState() {
    hasIdentity = identityService.keypair != nil
  }

  private func purgeLegacyNonRootMessagesIfNeeded() {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.purgeLegacyNonRootMessages(ownerPubkey: ownerPubkey)
    } catch {
      report(error: error)
    }
  }

  func startNostrIfPossible(forceRestart: Bool = false) {
    guard let keypair = identityService.keypair else { return }

    if forceRestart {
      // iOS may suspend sockets while backgrounded; on foreground always rebuild the relay
      // session so send-gating reflects fresh connection state instead of stale sockets.
      nostrService.stop()
    }

    if shouldDisableNostrStartupForCurrentProcess() {
      // Keep local send paths available in tests without opening relay connections.
      relayRuntimeStatusByURL.removeAll()
      nostrService.start(
        keypair: keypair,
        relayURLs: [],
        onIncoming: { _ in },
        onRelayStatus: { _, _, _ in }
      )
      return
    }

    let relayURLs: [String]
    do {
      relayURLs = try relayStore.fetchRelays().filter(\.isEnabled).map(\.url)
    } catch {
      report(error: error)
      return
    }
    if relayURLs.isEmpty {
      nostrService.stop()
      relayRuntimeStatusByURL.removeAll()
      composeError = noEnabledRelaysMessage
      hasShownOfflineToastForCurrentOutage = false
      return
    }
    if composeError == noEnabledRelaysMessage {
      composeError = nil
    }
    relayRuntimeStatusByURL = relayRuntimeStatusByURL.filter { relayURLs.contains($0.key) }

    nostrService.start(
      keypair: keypair,
      relayURLs: relayURLs,
      onIncoming: { [weak self] incoming in
        Task { @MainActor in
          self?.persistIncoming(incoming)
        }
      },
      onRelayStatus: { [weak self] relayURL, status, message in
        Task { @MainActor in
          guard let self else { return }
          guard self.isForeground else { return }
          self.updateRuntimeRelayStatus(
            relayURL: relayURL,
            status: status,
            message: message
          )
          try? self.refreshRelayConnectivityAlert()
        }
      }
    )
  }

  @discardableResult
  func createSessionAwaitingRelay(
    name: String,
    memberNPubs: [String],
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      composeError = "Enter a session name."
      return false
    }

    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to create sessions."
      return false
    }

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    let sessionID = makeLocalEventID()
    let timestamp = Int64(Date.now.timeIntervalSince1970)
    let payload = LinkstrPayload(
      conversationID: sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionCreate,
      url: nil,
      note: nil,
      timestamp: timestamp,
      sessionName: normalizedName,
      memberPubkeys: members
    )

    do {
      if shouldDisableNostrStartupForCurrentProcess() == false {
        _ = try await sendPayloadAwaitingRelayAcceptance(
          payload: payload,
          recipientPubkeyHexes: members
        )
      }

      let updatedAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: normalizedName,
        createdByPubkey: keypair.publicKey.hex,
        updatedAt: updatedAt
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkeys: members,
        updatedAt: updatedAt
      )
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func updateSessionMembersAwaitingRelay(
    session: SessionEntity,
    memberNPubs: [String],
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to manage session members."
      return false
    }

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    let timestamp = Int64(Date.now.timeIntervalSince1970)
    let payload = LinkstrPayload(
      conversationID: session.sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionMembers,
      url: nil,
      note: nil,
      timestamp: timestamp,
      memberPubkeys: members
    )

    do {
      if shouldDisableNostrStartupForCurrentProcess() == false {
        _ = try await sendPayloadAwaitingRelayAcceptance(
          payload: payload,
          recipientPubkeyHexes: members
        )
      }

      let updatedAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID,
        name: session.name,
        createdByPubkey: session.createdByPubkey,
        updatedAt: updatedAt,
        isArchived: session.isArchived
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID,
        memberPubkeys: members,
        updatedAt: updatedAt
      )
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func createSessionPostAwaitingRelay(
    url: String,
    note: String?,
    session: SessionEntity,
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    if shouldDisableNostrStartupForCurrentProcess() {
      return createPostInSession(url: url, note: note, sessionID: session.sessionID)
    }
    return await createPostAwaitingRelayDelivery(url: url, note: note, sessionID: session.sessionID)
  }

  @discardableResult
  private func createPostInSession(url: String, note: String?, sessionID: String) -> Bool {
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: sessionID) else {
      return false
    }

    do {
      // Test-only local send path when relay startup is disabled in-process.
      let eventID = makeLocalEventID()
      try persistSentRootPost(draft, eventID: eventID)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func toggleReactionAwaitingRelay(
    emoji: String,
    post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = 12,
    pollIntervalSeconds: TimeInterval = 0.35
  ) async -> Bool {
    guard
      await awaitRelayReadyForSend(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    else {
      return false
    }
    startNostrIfPossible()

    guard let draft = makeReactionDraft(emoji: emoji, post: post) else {
      return false
    }

    do {
      if shouldDisableNostrStartupForCurrentProcess() == false {
        _ = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        )
      }
      try persistReactionState(draft)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func createPostAwaitingRelayDelivery(
    url: String,
    note: String?,
    sessionID: String
  ) async -> Bool {
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: sessionID) else {
      return false
    }

    do {
      let eventID = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      )
      try persistSentRootPost(draft, eventID: eventID)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func makeReactionDraft(emoji: String, post: SessionMessageEntity) -> ReactionDraft? {
    let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else {
      composeError = "Pick an emoji reaction."
      return nil
    }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to react."
      return nil
    }

    let recipientPubkeys: [String]
    do {
      let fallbackPeer =
        post.senderPubkey == keypair.publicKey.hex ? post.receiverPubkey : post.senderPubkey
      recipientPubkeys = try activeMemberPubkeys(
        sessionID: post.conversationID,
        ownerPubkey: ownerPubkey,
        fallbackPeerPubkey: fallbackPeer
      )
    } catch {
      composeError = error.localizedDescription
      return nil
    }

    let existingReactions =
      (try? messageStore.reactions(
        ownerPubkey: ownerPubkey,
        sessionID: post.conversationID
      )) ?? []
    let currentlyActive = existingReactions.contains { reaction in
      reaction.postID == post.rootID
        && reaction.emoji == normalizedEmoji
        && reaction.senderMatches(keypair.publicKey.hex)
        && reaction.isActive
    }
    let nextState = !currentlyActive
    let timestamp = Int64(Date.now.timeIntervalSince1970)

    return ReactionDraft(
      payload: LinkstrPayload(
        conversationID: post.conversationID,
        rootID: post.rootID,
        kind: .reaction,
        url: nil,
        note: nil,
        timestamp: timestamp,
        emoji: normalizedEmoji,
        reactionActive: nextState
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      sessionID: post.conversationID,
      postID: post.rootID,
      emoji: normalizedEmoji,
      isActive: nextState,
      recipientPubkeys: recipientPubkeys
    )
  }

  private func makeRootPostDraft(
    url: String,
    note: String?,
    sessionID: String
  ) -> RootPostDraft? {
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      composeError = "Enter a valid URL."
      return nil
    }

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to send posts."
      return nil
    }

    let recipientPubkeys: [String]
    do {
      recipientPubkeys = try activeMemberPubkeys(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        fallbackPeerPubkey: nil
      )
    } catch {
      composeError = error.localizedDescription
      return nil
    }
    guard !recipientPubkeys.isEmpty else {
      composeError = "Session has no members. Add members before sending."
      return nil
    }

    let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
    let rootID = makeLocalEventID()
    let timestamp = Int64(Date.now.timeIntervalSince1970)

    return RootPostDraft(
      payload: LinkstrPayload(
        conversationID: sessionID,
        rootID: rootID,
        kind: .root,
        url: normalizedURL,
        note: normalizedNote,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      sessionID: sessionID,
      rootID: rootID,
      recipientPubkeys: recipientPubkeys,
      normalizedURL: normalizedURL,
      normalizedNote: normalizedNote
    )
  }

  private func persistSentRootPost(_ draft: RootPostDraft, eventID: String) throws {
    _ = try messageStore.upsertSession(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.sessionID,
      name: existingSessionName(for: draft.sessionID, ownerPubkey: draft.ownerPubkey),
      createdByPubkey: draft.senderPubkey,
      updatedAt: .now
    )
    let message = try SessionMessageEntity(
      eventID: eventID,
      ownerPubkey: draft.ownerPubkey,
      conversationID: draft.sessionID,
      rootID: draft.rootID,
      kind: .root,
      senderPubkey: draft.senderPubkey,
      receiverPubkey: draft.ownerPubkey,
      url: draft.normalizedURL,
      note: draft.normalizedNote,
      timestamp: .now,
      readAt: .now,
      linkType: URLClassifier.classify(draft.normalizedURL)
    )
    try messageStore.insert(message)
    enqueueMetadataRefresh(for: message)
  }

  private func persistReactionState(_ draft: ReactionDraft) throws {
    try messageStore.upsertReaction(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.sessionID,
      postID: draft.postID,
      emoji: draft.emoji,
      senderPubkey: draft.senderPubkey,
      isActive: draft.isActive,
      updatedAt: .now
    )
  }

  private func sendPayloadAwaitingRelayAcceptance(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) async throws -> String {
    if let testRelaySendOverride {
      guard let firstRecipient = recipientPubkeyHexes.first else {
        throw NostrServiceError.invalidPubkey
      }
      return try await testRelaySendOverride(payload, firstRecipient)
    }
    return try await nostrService.sendAwaitingRelayAcceptance(
      payload: payload,
      toMany: recipientPubkeyHexes
    )
  }

  private func normalizedMemberPubkeys(fromNPubs memberNPubs: [String], myPubkey: String)
    -> [String]
  {
    var members: [String] = []
    var seen = Set<String>()

    func appendMember(_ pubkeyHex: String) {
      guard PublicKey(hex: pubkeyHex) != nil else { return }
      guard !seen.contains(pubkeyHex) else { return }
      seen.insert(pubkeyHex)
      members.append(pubkeyHex)
    }

    appendMember(myPubkey)
    for npub in memberNPubs {
      guard let member = PublicKey(npub: npub.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        continue
      }
      appendMember(member.hex)
    }

    return members
  }

  private func activeMemberPubkeys(
    sessionID: String,
    ownerPubkey: String,
    fallbackPeerPubkey: String?
  ) throws -> [String] {
    guard let myPubkey = identityService.pubkeyHex else {
      return []
    }

    var members = try messageStore.members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: true
    ).map(\.memberPubkey)

    if members.isEmpty, let fallbackPeerPubkey, PublicKey(hex: fallbackPeerPubkey) != nil {
      members = [fallbackPeerPubkey]
    }

    var deduped: [String] = []
    var seen = Set<String>()

    func appendIfValid(_ pubkeyHex: String) {
      guard PublicKey(hex: pubkeyHex) != nil else { return }
      guard !seen.contains(pubkeyHex) else { return }
      seen.insert(pubkeyHex)
      deduped.append(pubkeyHex)
    }

    appendIfValid(myPubkey)
    members.forEach { appendIfValid($0) }
    return deduped
  }

  private func existingSessionName(for sessionID: String, ownerPubkey: String) -> String {
    do {
      if let session = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    } catch {
      // Ignore fetch failures and fall back to a generic title.
    }
    return "Session"
  }

  @discardableResult
  func addContact(npub: String, displayName: String) -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to manage contacts."
      return false
    }
    do {
      try contactStore.addContact(ownerPubkey: ownerPubkey, npub: npub, displayName: displayName)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func updateContact(_ contact: ContactEntity, npub: String, displayName: String) -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to manage contacts."
      return false
    }
    do {
      try contactStore.updateContact(
        contact, ownerPubkey: ownerPubkey, npub: npub, displayName: displayName)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  func removeContact(_ contact: ContactEntity) {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to manage contacts."
      return
    }
    do {
      try contactStore.removeContact(contact, ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  private func clearAllContacts(ownerPubkey: String) {
    do {
      try contactStore.clearAllContacts(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func setSessionArchived(sessionID: String, archived: Bool) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.setSessionArchived(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        archived: archived
      )
    } catch {
      report(error: error)
    }
  }

  func markRootPostRead(postID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markRootPostRead(postID: postID, ownerPubkey: myPubkey, myPubkey: myPubkey)
    } catch {
      report(error: error)
    }
  }

  func addRelay(url: String) {
    guard let parsedURL = normalizedRelayURL(from: url)
    else {
      composeError = "Enter a valid relay URL (ws:// or wss://)."
      return
    }
    performRelayMutation {
      try relayStore.addRelay(url: parsedURL)
    }
  }

  func removeRelay(_ relay: RelayEntity) {
    performRelayMutation {
      try relayStore.removeRelay(relay)
    }
  }

  func toggleRelay(_ relay: RelayEntity) {
    performRelayMutation {
      try relayStore.toggleRelay(relay)
    }
  }

  func resetDefaultRelays() {
    performRelayMutation {
      try relayStore.resetDefaultRelays()
    }
  }

  private func performRelayMutation(_ mutation: () throws -> Void) {
    do {
      try mutation()
      composeError = nil
    } catch {
      report(error: error)
      return
    }
    pruneRuntimeRelayStatusCache()
    startNostrIfPossible()
  }

  private func clearMessageCache(ownerPubkey: String) {
    do {
      try messageStore.clearAllSessionData(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func clearCachedVideos() {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to manage local storage."
      return
    }
    clearCachedVideos(ownerPubkey: ownerPubkey)
  }

  private func clearCachedVideos(ownerPubkey: String) {
    do {
      try messageStore.clearCachedVideos(ownerPubkey: ownerPubkey)
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func contactName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    contactStore.contactName(for: pubkeyHex, contacts: contacts)
  }

  private func persistIncoming(_ incoming: ReceivedDirectMessage) {
    switch incoming.payload.kind {
    case .sessionCreate:
      persistIncomingSessionCreate(incoming)
    case .sessionMembers:
      persistIncomingSessionMembers(incoming)
    case .reaction:
      persistIncomingReaction(incoming)
    case .root:
      persistIncomingRootPost(incoming)
    }
  }

  private func persistIncomingSessionCreate(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return
    }

    let incomingName = incoming.payload.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionName =
      (incomingName?.isEmpty == false)
      ? incomingName!
      : existingSessionName(for: sessionID, ownerPubkey: ownerPubkey)

    do {
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: sessionName,
        createdByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkeys: members,
        updatedAt: incoming.createdAt
      )
    } catch {
      report(error: error)
    }
  }

  private func persistIncomingSessionMembers(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return
    }

    let sessionName = existingSessionName(for: sessionID, ownerPubkey: ownerPubkey)
    do {
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: sessionName,
        createdByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt
      )
      try messageStore.applyMemberSnapshot(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        memberPubkeys: members,
        updatedAt: incoming.createdAt
      )
    } catch {
      report(error: error)
    }
  }

  private func persistIncomingReaction(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    guard let isActive = incoming.payload.reactionActive else { return }
    let emoji = incoming.payload.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !emoji.isEmpty else { return }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    let postID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !postID.isEmpty else { return }

    do {
      try messageStore.upsertReaction(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        postID: postID,
        emoji: emoji,
        senderPubkey: incoming.senderPubkey,
        isActive: isActive,
        updatedAt: incoming.createdAt
      )
    } catch {
      report(error: error)
      return
    }
  }

  private func persistIncomingRootPost(_ incoming: ReceivedDirectMessage) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    do {
      if let existing = try messageStore.message(
        eventID: incoming.eventID, ownerPubkey: ownerPubkey)
      {
        if existing.kind == .root {
          enqueueMetadataRefresh(for: existing)
        }
        return
      }
    } catch {
      report(error: error)
      return
    }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    let payloadRootID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonicalPostID = payloadRootID.isEmpty ? incoming.eventID : payloadRootID
    guard let payloadURL = incoming.payload.url,
      let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: payloadURL)
    else {
      return
    }

    let isEchoedOutgoing = identityService.pubkeyHex == incoming.senderPubkey

    let contacts = (try? contactStore.fetchContacts(ownerPubkey: ownerPubkey)) ?? []
    let fallbackName = contactName(for: incoming.senderPubkey, contacts: contacts)
    let sessionName = existingSessionName(for: sessionID, ownerPubkey: ownerPubkey)
    let resolvedSessionName = sessionName == "Session" ? fallbackName : sessionName

    do {
      _ = try messageStore.upsertSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        name: resolvedSessionName,
        createdByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt
      )
    } catch {
      report(error: error)
      return
    }

    let message: SessionMessageEntity
    do {
      message = try SessionMessageEntity(
        eventID: incoming.eventID,
        ownerPubkey: ownerPubkey,
        conversationID: sessionID,
        rootID: canonicalPostID,
        kind: .root,
        senderPubkey: incoming.senderPubkey,
        receiverPubkey: incoming.receiverPubkey,
        url: normalizedURL,
        note: incoming.payload.note,
        timestamp: incoming.createdAt,
        readAt: isEchoedOutgoing ? incoming.createdAt : nil,
        linkType: URLClassifier.classify(normalizedURL)
      )
    } catch {
      report(error: error)
      return
    }

    do {
      try messageStore.insert(message)
    } catch {
      report(error: error)
      return
    }

    notifyForIncomingMessage(message)
    enqueueMetadataRefresh(for: message)
  }

  private func notifyForIncomingMessage(_ message: SessionMessageEntity) {
    guard let myPubkey = identityService.pubkeyHex, message.senderPubkey != myPubkey else {
      return
    }

    let contacts = (try? contactStore.fetchContacts(ownerPubkey: myPubkey)) ?? []
    let senderName = contactName(for: message.senderPubkey, contacts: contacts)
    LocalNotificationService.shared.postIncomingPostNotification(
      senderName: senderName,
      url: message.url,
      note: message.note,
      eventID: message.eventID,
      conversationID: message.conversationID
    )
  }

  private func hydrateMissingMetadata() {
    guard shouldFetchMetadataForCurrentProcess() else { return }
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    do {
      let roots = try messageStore.rootMessages(ownerPubkey: ownerPubkey)
      let sortedRoots = roots.sorted { $0.timestamp > $1.timestamp }
      for message in sortedRoots where needsMetadataRefresh(message) {
        enqueueMetadataRefresh(for: message)
      }
    } catch {
      report(error: error)
    }
  }

  private func enqueueMetadataRefresh(for message: SessionMessageEntity) {
    guard shouldFetchMetadataForCurrentProcess() else { return }
    guard message.kind == .root else { return }
    guard message.url != nil else { return }
    guard needsMetadataRefresh(message) else { return }

    let storageID = message.storageID
    guard !enqueuedMetadataStorageIDs.contains(storageID) else { return }
    enqueuedMetadataStorageIDs.insert(storageID)
    pendingMetadataStorageIDs.append(storageID)
    processMetadataQueueIfNeeded()
  }

  private func processMetadataQueueIfNeeded() {
    guard !isProcessingMetadataQueue else { return }
    isProcessingMetadataQueue = true

    Task { @MainActor in
      while !pendingMetadataStorageIDs.isEmpty {
        let storageID = pendingMetadataStorageIDs.removeFirst()
        defer {
          enqueuedMetadataStorageIDs.remove(storageID)
        }

        do {
          guard let message = try messageStore.message(storageID: storageID) else { continue }
          try await refreshMetadata(for: message)
        } catch {
          report(error: error)
        }
      }

      isProcessingMetadataQueue = false
      if !pendingMetadataStorageIDs.isEmpty {
        processMetadataQueueIfNeeded()
      }
    }
  }

  private func refreshMetadata(for message: SessionMessageEntity) async throws {
    guard let url = message.url else { return }
    guard needsMetadataRefresh(message) else { return }

    let preview = await URLMetadataService.shared.fetchPreview(for: url)
    guard let preview else { return }

    let currentTitle = normalizedMetadataTitle(message.metadataTitle)
    let previewTitle = normalizedMetadataTitle(preview.title)
    let resolvedTitle = previewTitle ?? currentTitle

    let currentThumbnail = normalizedThumbnailPath(message.thumbnailURL)
    let previewThumbnail = normalizedThumbnailPath(preview.thumbnailPath)
    let resolvedThumbnail: String?
    if let previewThumbnail {
      resolvedThumbnail = previewThumbnail
    } else if let currentThumbnail, FileManager.default.fileExists(atPath: currentThumbnail) {
      resolvedThumbnail = currentThumbnail
    } else {
      resolvedThumbnail = nil
    }

    guard resolvedTitle != currentTitle || resolvedThumbnail != currentThumbnail else {
      return
    }

    try message.setMetadata(title: resolvedTitle, thumbnailURL: resolvedThumbnail)
    try modelContext.save()
  }

  private func needsMetadataRefresh(_ message: SessionMessageEntity) -> Bool {
    guard message.kind == .root else { return false }
    guard message.url != nil else { return false }

    let hasTitle = normalizedMetadataTitle(message.metadataTitle) != nil
    if !hasTitle {
      return true
    }

    guard let thumbnailPath = normalizedThumbnailPath(message.thumbnailURL) else {
      return false
    }
    return !FileManager.default.fileExists(atPath: thumbnailPath)
  }

  private func normalizedMetadataTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizedThumbnailPath(_ path: String?) -> String? {
    guard let path else { return nil }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizedRelayURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "ws" || scheme == "wss",
      let host = components.host,
      !host.isEmpty
    else {
      return nil
    }
    return components.url
  }

  #if targetEnvironment(simulator)
    private func bootstrapSimulatorIfNeeded() {
      if identityService.keypair == nil {
        try? identityService.createNewIdentity()
      }

      guard let ownerPubkey = identityService.pubkeyHex else { return }

      let contactsDescriptor = FetchDescriptor<ContactEntity>()
      let contacts = ((try? modelContext.fetch(contactsDescriptor)) ?? []).filter {
        $0.ownerPubkey == ownerPubkey
      }
      let posts = ((try? modelContext.fetch(FetchDescriptor<SessionMessageEntity>())) ?? []).filter
      {
        $0.kind == .root && $0.ownerPubkey == ownerPubkey
      }

      var secondaryContact: ContactEntity
      if let firstContact = contacts.first {
        secondaryContact = firstContact
      } else {
        let secondaryKeypair = Keypair()
        let npub =
          secondaryKeypair?.publicKey.npub
          ?? "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk3el7l"
        let contact = try? ContactEntity(
          ownerPubkey: ownerPubkey,
          npub: npub,
          displayName: "Secondary Test Contact"
        )
        guard let contact else { return }
        modelContext.insert(contact)
        secondaryContact = contact
      }

      if posts.isEmpty, let myPubkey = identityService.pubkeyHex,
        let peerPubkey = PublicKey(npub: secondaryContact.npub)?.hex
      {
        let sessionID = "sim-\(ownerPubkey.prefix(12))"
        let sessionName = "Simulator Session"
        let seededAt = Date.now
        _ = try? messageStore.upsertSession(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          name: sessionName,
          createdByPubkey: myPubkey,
          updatedAt: seededAt
        )
        try? messageStore.applyMemberSnapshot(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          memberPubkeys: [myPubkey, peerPubkey],
          updatedAt: seededAt
        )
        let sampleURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let sampleEventID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let post = try? SessionMessageEntity(
          eventID: sampleEventID,
          ownerPubkey: ownerPubkey,
          conversationID: sessionID,
          rootID: sampleEventID,
          kind: .root,
          senderPubkey: myPubkey,
          receiverPubkey: peerPubkey,
          url: sampleURL,
          note: "Seeded simulator post",
          timestamp: .now,
          readAt: .now,
          linkType: URLClassifier.classify(sampleURL),
          metadataTitle: "Sample Link"
        )
        if let post {
          modelContext.insert(post)
        }
      }

      try? modelContext.save()
    }
  #endif
}
