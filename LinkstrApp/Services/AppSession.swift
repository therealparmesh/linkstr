import Foundation
import NostrSDK
import SwiftData

@MainActor
final class AppSession: ObservableObject {
  let identityService: IdentityService
  let nostrService: NostrDMService
  let modelContext: ModelContext
  private let contactStore: ContactStore
  private let relayStore: RelayStore
  private let messageStore: SessionMessageStore
  private let noEnabledRelaysMessage =
    "No relays are enabled. Enable at least one relay in Settings."
  private let relayOfflineMessage = "You're offline. Waiting for a relay connection."
  private var hasShownOfflineToastForCurrentOutage = false

  @Published var composeError: String?
  @Published private(set) var hasIdentity = false
  @Published private(set) var didFinishBoot = false

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
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
      try messageStore.normalizeConversationIDs()
      try relayStore.ensureDefaultRelays()
      try contactStore.syncContactsSnapshot()
    } catch {
      composeError = error.localizedDescription
    }
    handleAppDidBecomeActive()
  }

  func handleAppDidBecomeActive() {
    startNostrIfPossible()
    processPendingShares()
  }

  private func report(error: Error) {
    composeError = error.localizedDescription
  }

  private func refreshRelayConnectivityAlert() throws {
    let enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    guard !enabledRelays.isEmpty else { return }

    let hasConnectedRelay = hasConnectedEnabledRelay(enabledRelays)

    if hasConnectedRelay {
      hasShownOfflineToastForCurrentOutage = false
      if composeError == relayOfflineMessage {
        composeError = nil
      }
      return
    }

    guard !hasShownOfflineToastForCurrentOutage else { return }
    composeError = relayOfflineMessage
    hasShownOfflineToastForCurrentOutage = true
  }

  private func hasConnectedEnabledRelay(_ enabledRelays: [RelayEntity]) -> Bool {
    enabledRelays.contains { $0.status == .connected || $0.status == .readOnly }
  }

  private func ensureRelayReadyForSend() -> Bool {
    if shouldDisableNostrStartupForCurrentProcess() {
      return true
    }

    let enabledRelays: [RelayEntity]
    do {
      enabledRelays = try relayStore.fetchRelays().filter(\.isEnabled)
    } catch {
      report(error: error)
      return false
    }

    guard !enabledRelays.isEmpty else {
      composeError = noEnabledRelaysMessage
      hasShownOfflineToastForCurrentOutage = false
      return false
    }

    guard hasConnectedEnabledRelay(enabledRelays) else {
      composeError = relayOfflineMessage
      hasShownOfflineToastForCurrentOutage = true
      return false
    }

    hasShownOfflineToastForCurrentOutage = false
    if composeError == relayOfflineMessage || composeError == noEnabledRelaysMessage {
      composeError = nil
    }
    return true
  }

  private func makeLocalEventID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private func isEnvironmentFlagEnabled(_ key: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env[key] == "1"
  }

  private func shouldDisableNostrStartupForCurrentProcess() -> Bool {
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    if !isRunningTests { return false }
    return !isEnvironmentFlagEnabled("LINKSTR_ENABLE_NOSTR_IN_TESTS")
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

  func logout(clearLocalData: Bool = true) {
    nostrService.stop()

    do {
      try identityService.clearIdentity()
    } catch {
      composeError = error.localizedDescription
      return
    }
    refreshIdentityState()

    if clearLocalData {
      clearCachedVideos()
      clearMessageCache()
      clearAllContacts()
    }

    composeError = nil
  }

  private func refreshIdentityState() {
    hasIdentity = identityService.keypair != nil
  }

  func startNostrIfPossible() {
    guard let keypair = identityService.keypair else { return }

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
          do {
            try self.relayStore.updateRelayStatus(
              relayURL: relayURL,
              status: status,
              message: message
            )
            try self.refreshRelayConnectivityAlert()
          } catch {
            self.report(error: error)
          }
        }
      }
    )
  }

  @discardableResult
  func createPost(url: String, note: String?, contact: ContactEntity) -> Bool {
    createPost(url: url, note: note, recipientNPub: contact.npub)
  }

  @discardableResult
  func createPost(url: String, note: String?, recipientNPub: String) -> Bool {
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      composeError = "Enter a valid URL."
      return false
    }

    guard let keypair = identityService.keypair,
      let recipientPublicKey = PublicKey(npub: recipientNPub)
    else {
      composeError = "Couldn't send. Check your account and recipient Contact key (npub)."
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

      let message = SessionMessageEntity(
        eventID: eventID,
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

  func sendReply(text: String, post: SessionMessageEntity) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard let keypair = identityService.keypair else {
      composeError = "You're signed out. Sign in to send replies."
      return
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
      return
    }

    do {
      let eventID: String
      if shouldDisableNostrStartupForCurrentProcess() {
        eventID = makeLocalEventID()
      } else {
        eventID = try nostrService.send(payload: payload, to: recipientPubkey)
      }
      let reply = SessionMessageEntity(
        eventID: eventID,
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
    } catch {
      report(error: error)
    }
  }

  @discardableResult
  func addContact(npub: String, displayName: String) -> Bool {
    do {
      try contactStore.addContact(npub: npub, displayName: displayName)
      try contactStore.syncContactsSnapshot()
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func updateContact(_ contact: ContactEntity, npub: String, displayName: String) -> Bool {
    do {
      try contactStore.updateContact(contact, npub: npub, displayName: displayName)
      try contactStore.syncContactsSnapshot()
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  func removeContact(_ contact: ContactEntity) {
    do {
      try contactStore.removeContact(contact)
      try contactStore.syncContactsSnapshot()
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  private func clearAllContacts() {
    do {
      try contactStore.clearAllContacts()
      try contactStore.syncContactsSnapshot()
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func setConversationArchived(conversationID: String, archived: Bool) {
    do {
      try messageStore.setConversationArchived(conversationID: conversationID, archived: archived)
    } catch {
      report(error: error)
    }
  }

  func markConversationPostsRead(conversationID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markConversationPostsRead(conversationID: conversationID, myPubkey: myPubkey)
    } catch {
      report(error: error)
    }
  }

  func markPostRepliesRead(postID: String) {
    guard let myPubkey = identityService.pubkeyHex else { return }
    do {
      try messageStore.markPostRepliesRead(postID: postID, myPubkey: myPubkey)
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

  func clearMessageCache() {
    do {
      try messageStore.clearAllMessages()
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func clearCachedVideos() {
    do {
      try messageStore.clearCachedVideos()
      composeError = nil
    } catch {
      report(error: error)
    }
  }

  func contactName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    contactStore.contactName(for: pubkeyHex, contacts: contacts)
  }

  private func persistIncoming(_ incoming: ReceivedDirectMessage) {
    do {
      if try messageStore.messageExists(eventID: incoming.eventID) {
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

    let message = SessionMessageEntity(
      eventID: incoming.eventID,
      conversationID: ConversationID.deterministic(incoming.senderPubkey, incoming.receiverPubkey),
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

    let contacts = (try? contactStore.fetchContacts()) ?? []
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
    guard let url = message.url else { return }
    Task {
      let preview = await URLMetadataService.shared.fetchPreview(for: url)
      await MainActor.run {
        message.metadataTitle = preview?.title
        message.thumbnailURL = preview?.thumbnailPath
        do {
          try self.modelContext.save()
        } catch {
          self.report(error: error)
        }
      }
    }
  }

  private func processPendingShares() {
    guard identityService.keypair != nil else { return }

    let pendingItems = (try? AppGroupStore.shared.loadPendingShares()) ?? []
    guard !pendingItems.isEmpty else { return }

    let contacts = (try? contactStore.fetchContacts()) ?? []
    let contactsByNPub = Dictionary(uniqueKeysWithValues: contacts.map { ($0.npub, $0) })
    var processedIDs = Set<String>()

    for item in pendingItems {
      guard let contact = contactsByNPub[item.contactNPub] else { continue }
      if createPost(url: item.url, note: item.note, contact: contact) {
        processedIDs.insert(item.id)
      }
    }

    do {
      try AppGroupStore.shared.removePendingShares(withIDs: processedIDs)
    } catch {
      report(error: error)
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

      let contactsDescriptor = FetchDescriptor<ContactEntity>()
      let contacts = (try? modelContext.fetch(contactsDescriptor)) ?? []
      let posts = ((try? modelContext.fetch(FetchDescriptor<SessionMessageEntity>())) ?? []).filter
      {
        $0.kind == .root
      }

      var secondaryContact: ContactEntity
      if let firstContact = contacts.first {
        secondaryContact = firstContact
      } else {
        let secondaryKeypair = Keypair()
        let npub =
          secondaryKeypair?.publicKey.npub
          ?? "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk3el7l"
        let contact = ContactEntity(npub: npub, displayName: "Secondary Test Contact")
        modelContext.insert(contact)
        secondaryContact = contact
      }

      if posts.isEmpty, let myPubkey = identityService.pubkeyHex,
        let peerPubkey = PublicKey(npub: secondaryContact.npub)?.hex
      {
        let conversationID = ConversationID.deterministic(myPubkey, peerPubkey)
        let sampleURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let sampleEventID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let post = SessionMessageEntity(
          eventID: sampleEventID,
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
        modelContext.insert(post)
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

  func fetchContacts(sortedByDisplayName: Bool = false) throws -> [ContactEntity] {
    let sortDescriptor: [SortDescriptor<ContactEntity>] =
      sortedByDisplayName ? [SortDescriptor(\.displayName)] : [SortDescriptor(\.createdAt)]
    let descriptor = FetchDescriptor<ContactEntity>(sortBy: sortDescriptor)
    return try modelContext.fetch(descriptor)
  }

  func addContact(npub: String, displayName: String) throws {
    let normalizedNPub = try normalize(npub: npub)
    let normalizedDisplayName = normalize(displayName: displayName)

    guard !normalizedDisplayName.isEmpty else {
      throw ContactStoreError.emptyDisplayName
    }
    guard !hasContact(withNPub: normalizedNPub) else {
      throw ContactStoreError.duplicateContact
    }

    modelContext.insert(ContactEntity(npub: normalizedNPub, displayName: normalizedDisplayName))
    try modelContext.save()
  }

  func updateContact(_ contact: ContactEntity, npub: String, displayName: String) throws {
    let normalizedNPub = try normalize(npub: npub)
    let normalizedDisplayName = normalize(displayName: displayName)

    guard !normalizedDisplayName.isEmpty else {
      throw ContactStoreError.emptyDisplayName
    }
    guard !hasContact(withNPub: normalizedNPub, excluding: contact.persistentModelID) else {
      throw ContactStoreError.duplicateContact
    }

    let previousNPub = contact.npub
    let previousDisplayName = contact.displayName
    contact.npub = normalizedNPub
    contact.displayName = normalizedDisplayName
    do {
      try modelContext.save()
    } catch {
      contact.npub = previousNPub
      contact.displayName = previousDisplayName
      throw error
    }
  }

  func removeContact(_ contact: ContactEntity) throws {
    modelContext.delete(contact)
    try modelContext.save()
  }

  func clearAllContacts() throws {
    let descriptor = FetchDescriptor<ContactEntity>()
    let contacts = try modelContext.fetch(descriptor)
    contacts.forEach(modelContext.delete)
    try modelContext.save()
  }

  func syncContactsSnapshot() throws {
    let contacts = try fetchContacts(sortedByDisplayName: true)
    let snapshots = contacts.map { ContactSnapshot(npub: $0.npub, displayName: $0.displayName) }
    try AppGroupStore.shared.saveContactsSnapshot(snapshots)
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

  func hasContact(withNPub npub: String, excluding contactID: PersistentIdentifier? = nil) -> Bool {
    guard let contacts = try? fetchContacts() else { return false }
    return contacts.contains { existing in
      guard existing.npub == npub else { return false }
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

  var errorDescription: String? {
    switch self {
    case .invalidNPub:
      return "Invalid Contact key (npub)."
    case .emptyDisplayName:
      return "Enter a display name."
    case .duplicateContact:
      return "This contact is already in your list."
    }
  }
}
