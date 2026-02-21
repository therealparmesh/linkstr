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

  let identityService: IdentityService
  let nostrService: NostrDMService
  let modelContext: ModelContext
  private let contactStore: ContactStore
  private let relayStore: RelayStore
  private let messageStore: SessionMessageStore
  private let testHasConnectedRelaysOverride: (() -> Bool)?
  private let testDisableNostrStartupOverride: Bool?
  private let noEnabledRelaysMessage =
    "No relays are enabled. Enable at least one relay in Settings."
  private let relayOfflineMessage = "You're offline. Waiting for a relay connection."
  private let relayReconnectingMessage = "Relays are reconnecting. Try again in a moment."
  private let relayReadOnlyMessage =
    "Connected relays are read-only. Add a writable relay to send."
  private let relaySendTimeoutMessage = "Couldn't reconnect to relays in time. Try again."
  private var hasShownOfflineToastForCurrentOutage = false
  private var isForeground = false

  @Published var composeError: String?
  @Published private(set) var hasIdentity = false
  @Published private(set) var didFinishBoot = false

  init(
    modelContext: ModelContext,
    testDisableNostrStartupOverride: Bool? = nil,
    testHasConnectedRelaysOverride: (() -> Bool)? = nil
  ) {
    self.modelContext = modelContext
    self.testDisableNostrStartupOverride = testDisableNostrStartupOverride
    self.testHasConnectedRelaysOverride = testHasConnectedRelaysOverride
    self.identityService = IdentityService()
    self.nostrService = NostrDMService()
    self.contactStore = ContactStore(modelContext: modelContext)
    self.relayStore = RelayStore(modelContext: modelContext)
    self.messageStore = SessionMessageStore(modelContext: modelContext)
  }

  func boot() {
    didFinishBoot = false
    defer { didFinishBoot = true }

    identityService.loadIdentity()
    refreshIdentityState()
    LocalNotificationService.shared.configure()
    if !isEnvironmentFlagEnabled("LINKSTR_SKIP_NOTIFICATION_PROMPT") {
      LocalNotificationService.shared.requestAuthorizationIfNeeded()
    }

    #if targetEnvironment(simulator)
      if isEnvironmentFlagEnabled("LINKSTR_SIM_BOOTSTRAP") {
        bootstrapSimulatorIfNeeded()
        refreshIdentityState()
      }
    #endif

    do {
      if let ownerPubkey = identityService.pubkeyHex {
        try messageStore.normalizeConversationIDs(ownerPubkey: ownerPubkey)
      }
      try relayStore.ensureDefaultRelays()
    } catch {
      composeError = error.localizedDescription
    }
    handleAppDidBecomeActive()
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

    if enabledRelays.contains(where: { $0.status == .connected }) {
      return .online
    }
    if enabledRelays.contains(where: { $0.status == .readOnly }) {
      return .readOnly
    }
    if enabledRelays.contains(where: { $0.status == .reconnecting }) {
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
      || composeError == relayReconnectingMessage
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

  private func ensureRelayReadyForSend() -> Bool {
    if shouldDisableNostrStartupForCurrentProcess() {
      return true
    }

    // Require a live relay socket for user-initiated sends to avoid stale persisted
    // connectivity causing "first send dropped, second send works" behavior.
    if hasConnectedRelays() {
      hasShownOfflineToastForCurrentOutage = false
      clearRelaySendBlockingErrorIfPresent()
      return true
    }

    let enabledRelays: [RelayEntity]
    do {
      enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    } catch {
      report(error: error)
      return false
    }

    switch relayConnectivityState(for: enabledRelays) {
    case .noEnabledRelays:
      composeError = noEnabledRelaysMessage
      hasShownOfflineToastForCurrentOutage = false
      return false
    case .readOnly:
      composeError = relayReadOnlyMessage
      hasShownOfflineToastForCurrentOutage = false
      return false
    case .reconnecting:
      composeError = relayReconnectingMessage
      hasShownOfflineToastForCurrentOutage = false
      return false
    case .online, .offline:
      composeError = relayOfflineMessage
      hasShownOfflineToastForCurrentOutage = true
      return false
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

        if composeError == relayOfflineMessage || composeError == relayReconnectingMessage {
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

  func startNostrIfPossible(forceRestart: Bool = false) {
    guard let keypair = identityService.keypair else { return }

    if forceRestart {
      // iOS may suspend sockets while backgrounded; on foreground always rebuild the relay
      // session so send-gating reflects fresh connection state instead of stale sockets.
      nostrService.stop()
    }

    if shouldDisableNostrStartupForCurrentProcess() {
      // Keep local send paths available in tests without opening relay connections.
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
      composeError = noEnabledRelaysMessage
      hasShownOfflineToastForCurrentOutage = false
      return
    }
    if composeError == noEnabledRelaysMessage {
      composeError = nil
    }

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
          do {
            let changed = try self.relayStore.updateRelayStatus(
              relayURL: relayURL,
              status: status,
              message: message
            )
            guard changed else { return }
            try self.refreshRelayConnectivityAlert()
          } catch {
            NSLog("Ignoring relay status persistence error: \(error.localizedDescription)")
          }
        }
      }
    )
  }

  @discardableResult
  func createPost(url: String, note: String?, recipientNPub: String) -> Bool {
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      composeError = "Enter a valid URL."
      return false
    }

    guard let keypair = identityService.keypair,
      let ownerPubkey = identityService.pubkeyHex,
      let recipientPublicKey = PublicKey(npub: recipientNPub)
    else {
      composeError = "Couldn't send. Check your account and recipient Contact Key (npub)."
      return false
    }

    let conversationID = ConversationID.deterministic(keypair.publicKey.hex, recipientPublicKey.hex)
    let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil

    let payload = LinkstrPayload(
      conversationID: conversationID,
      rootID: makeLocalEventID(),
      kind: .root,
      url: normalizedURL,
      note: normalizedNote,
      timestamp: Int64(Date.now.timeIntervalSince1970)
    )

    guard ensureRelayReadyForSend() else {
      return false
    }

    do {
      let eventID: String
      if shouldDisableNostrStartupForCurrentProcess() {
        eventID = makeLocalEventID()
      } else {
        eventID = try nostrService.send(payload: payload, to: recipientPublicKey.hex)
      }

      let message = try SessionMessageEntity(
        eventID: eventID,
        ownerPubkey: ownerPubkey,
        conversationID: conversationID,
        rootID: eventID,
        kind: .root,
        senderPubkey: keypair.publicKey.hex,
        receiverPubkey: recipientPublicKey.hex,
        url: normalizedURL,
        note: normalizedNote,
        timestamp: .now,
        readAt: .now,
        linkType: URLClassifier.classify(normalizedURL)
      )
      try messageStore.insert(message)

      updateMetadata(for: message)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func createPostAwaitingRelay(
    url: String,
    note: String?,
    recipientNPub: String,
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
    return createPost(url: url, note: note, recipientNPub: recipientNPub)
  }

  @discardableResult
  func sendReply(text: String, post: SessionMessageEntity) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "You're signed out. Sign in to send replies."
      return false
    }

    let recipientPubkey =
      post.senderPubkey == keypair.publicKey.hex ? post.receiverPubkey : post.senderPubkey

    let payload = LinkstrPayload(
      conversationID: post.conversationID,
      rootID: post.rootID,
      kind: .reply,
      url: nil,
      note: text,
      timestamp: Int64(Date.now.timeIntervalSince1970)
    )

    guard ensureRelayReadyForSend() else {
      return false
    }

    do {
      let eventID: String
      if shouldDisableNostrStartupForCurrentProcess() {
        eventID = makeLocalEventID()
      } else {
        eventID = try nostrService.send(payload: payload, to: recipientPubkey)
      }
      let reply = try SessionMessageEntity(
        eventID: eventID,
        ownerPubkey: ownerPubkey,
        conversationID: post.conversationID,
        rootID: post.rootID,
        kind: .reply,
        senderPubkey: keypair.publicKey.hex,
        receiverPubkey: recipientPubkey,
        url: nil,
        note: text,
        timestamp: .now,
        readAt: .now,
        linkType: .generic
      )
      try messageStore.insert(reply)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func sendReplyAwaitingRelay(
    text: String,
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
    return sendReply(text: text, post: post)
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

  func setConversationArchived(conversationID: String, archived: Bool) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.setConversationArchived(
        conversationID: conversationID,
        ownerPubkey: ownerPubkey,
        archived: archived
      )
    } catch {
      report(error: error)
    }
  }

  func markConversationPostsRead(conversationID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markConversationPostsRead(
        conversationID: conversationID,
        ownerPubkey: myPubkey,
        myPubkey: myPubkey
      )
    } catch {
      report(error: error)
    }
  }

  func markPostRepliesRead(postID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markPostRepliesRead(
        postID: postID, ownerPubkey: myPubkey, myPubkey: myPubkey)
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
    startNostrIfPossible()
  }

  private func clearMessageCache(ownerPubkey: String) {
    do {
      try messageStore.clearAllMessages(ownerPubkey: ownerPubkey)
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
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    do {
      if try messageStore.messageExists(eventID: incoming.eventID, ownerPubkey: ownerPubkey) {
        return
      }
    } catch {
      report(error: error)
      return
    }

    let canonicalPostID: String
    switch incoming.payload.kind {
    case .root:
      canonicalPostID = incoming.eventID
    case .reply:
      canonicalPostID = incoming.payload.rootID
    }

    let url: String?
    switch incoming.payload.kind {
    case .root:
      guard let payloadURL = incoming.payload.url,
        let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: payloadURL)
      else {
        return
      }
      url = normalizedURL
    case .reply:
      url = nil
    }

    let isEchoedOutgoing = identityService.pubkeyHex == incoming.senderPubkey

    let message: SessionMessageEntity
    do {
      message = try SessionMessageEntity(
        eventID: incoming.eventID,
        ownerPubkey: ownerPubkey,
        conversationID: ConversationID.deterministic(
          incoming.senderPubkey, incoming.receiverPubkey),
        rootID: canonicalPostID,
        kind: incoming.payload.kind == .root ? .root : .reply,
        senderPubkey: incoming.senderPubkey,
        receiverPubkey: incoming.receiverPubkey,
        url: url,
        note: incoming.payload.note,
        timestamp: incoming.createdAt,
        readAt: isEchoedOutgoing ? incoming.createdAt : nil,
        linkType: url.map(URLClassifier.classify) ?? .generic
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

    if message.kind == .root {
      updateMetadata(for: message)
    }
  }

  private func notifyForIncomingMessage(_ message: SessionMessageEntity) {
    guard let myPubkey = identityService.pubkeyHex, message.senderPubkey != myPubkey else {
      return
    }

    let contacts = (try? contactStore.fetchContacts(ownerPubkey: myPubkey)) ?? []
    let senderName = contactName(for: message.senderPubkey, contacts: contacts)

    switch message.kind {
    case .root:
      LocalNotificationService.shared.postIncomingPostNotification(
        senderName: senderName,
        url: message.url,
        note: message.note,
        eventID: message.eventID,
        conversationID: message.conversationID
      )
    case .reply:
      LocalNotificationService.shared.postIncomingReplyNotification(
        senderName: senderName,
        note: message.note,
        eventID: message.eventID,
        conversationID: message.conversationID
      )
    }
  }

  private func updateMetadata(for message: SessionMessageEntity) {
    guard shouldFetchMetadataForCurrentProcess() else { return }
    guard let url = message.url else { return }
    Task {
      let preview = await URLMetadataService.shared.fetchPreview(for: url)
      await MainActor.run {
        do {
          try message.setMetadata(title: preview?.title, thumbnailURL: preview?.thumbnailPath)
          try self.modelContext.save()
        } catch {
          self.report(error: error)
        }
      }
    }
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
        let conversationID = ConversationID.deterministic(myPubkey, peerPubkey)
        let sampleURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let sampleEventID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let post = try? SessionMessageEntity(
          eventID: sampleEventID,
          ownerPubkey: ownerPubkey,
          conversationID: conversationID,
          rootID: sampleEventID,
          kind: .root,
          senderPubkey: myPubkey,
          receiverPubkey: peerPubkey,
          url: sampleURL,
          note: "Seeded simulator thread",
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

@MainActor
private final class ContactStore {
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
  )
    throws
  {
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
