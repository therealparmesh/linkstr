import Foundation
import NostrSDK

// MARK: - Post Creation & Deletion

extension AppSession {
  @discardableResult
  func createSessionPostAwaitingRelay(
    url: String,
    note: String?,
    session: SessionEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard session.ownerPubkey == identityService.pubkeyHex else {
      composeError = "this session belongs to a different account."
      return false
    }
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: session.sessionID) else {
      return false
    }
    let sourceService = nostrService

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      reportMutationError(error, ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      return false
    }

    guard let readyDraft = makeRootPostDraft(
      url: draft.normalizedURL, note: draft.payload.note, sessionID: draft.payload.conversationID
    ) else { return false }
    if !isRelayPublicationEnabledForCurrentProcess() {
      return createPostLocally(readyDraft)
    }
    return await createPostAwaitingRelayDelivery(readyDraft)
  }

  @discardableResult
  private func createPostLocally(_ draft: RootPostDraft) -> Bool {
    do {
      let eventID = makeLocalEventID()
      guard try persistSentRootPost(draft, receipt: localSendReceipt(withRumorEventID: eventID)) else { return false }
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func deletePostAwaitingRelay(
    _ post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard !Task.isCancelled else { return false }
    guard let draft = makeRootDeletionDraft(post: post) else {
      return false
    }
    let sourceService = nostrService

    if !isRelayPublicationEnabledForCurrentProcess() {
      do {
        try persistRootDeletion(draft, eventID: makeLocalEventID())
        composeError = nil
        return true
      } catch {
        report(error: error)
        return false
      }
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      reportMutationError(error, ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      return false
    }

    guard let keypair = identityService.keypair else {
      composeError = "you're signed out. sign in to manage this post."
      return false
    }

    return await performRelayPostDeletion(draft: draft, keypair: keypair)
  }

  private func performRelayPostDeletion(draft: RootDeletionDraft, keypair: Keypair) async -> Bool {
    let sourceService = nostrService
    do {
      let deletionRequestEventID: String?
      if draft.publishedTransportEventIDs.isEmpty {
        deletionRequestEventID = nil
      } else {
        deletionRequestEventID = try await publishEventAwaitingRelayAcceptance(
          makeRelayDeletionEvent(
            publishedTransportEventIDs: draft.publishedTransportEventIDs,
            reason: "linkstr post deletion request",
            signedBy: keypair
          )
        )
      }
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)

      let deletionWatermarkEventID: String
      do {
        deletionWatermarkEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        ).rumorEventID
      } catch {
        try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
        if let deletionRequestEventID {
          try persistRootDeletion(draft, eventID: deletionRequestEventID)
          composeError = "post deleted, but other members may keep seeing it until sync catches up."
          return true
        }
        throw error
      }

      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      try persistRootDeletion(draft, eventID: deletionWatermarkEventID)
      if deletionRequestEventID == nil {
        composeError =
          "post deleted, but relay deletion is unavailable for older copies of this post."
      } else {
        composeError = nil
      }
      return true
    } catch {
      reportMutationError(error, ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      return false
    }
  }

  private func createPostAwaitingRelayDelivery(_ draft: RootPostDraft) async -> Bool {
    let sourceService = nostrService
    do {
      let receipt = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      )
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      guard try persistSentRootPost(draft, receipt: receipt) else { return false }
      schedulePushEnqueue(
        PushEnqueueRequest(
          notificationType: "new_post",
          eventID: receipt.rumorEventID,
          conversationID: draft.payload.conversationID,
          recipientPubkeys: draft.recipientPubkeys,
          emoji: nil
        )
      )
      composeError = nil
      return true
    } catch {
      reportMutationError(error, ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      return false
    }
  }
}

// MARK: - Post Draft Construction & Persistence

extension AppSession {
  func makeRootDeletionDraft(post: SessionMessageEntity) -> RootDeletionDraft? {
    guard post.kind == .root else {
      composeError = "only root posts can be deleted."
      return nil
    }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this post."
      return nil
    }
    guard post.ownerPubkey == ownerPubkey else {
      composeError = "this post belongs to a different account."
      return nil
    }
    let senderHash = LocalDataCrypto.shared.digestHex(keypair.publicKey.hex)
    guard post.senderMatchesHash(senderHash) else {
      composeError = "you can only delete posts you sent."
      return nil
    }

    guard
      let recipientPubkeys = resolveDeletionRecipients(
        sessionID: post.conversationID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else {
      return nil
    }

    let timestamp = Int64(Date.now.timeIntervalSince1970)
    return RootDeletionDraft(
      payload: LinkstrPayload(
        conversationID: post.conversationID,
        rootID: post.rootID,
        kind: .rootDelete,
        url: nil,
        note: nil,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys,
      rootID: post.rootID,
      publishedTransportEventIDs: post.publishedTransportEventIDs
    )
  }

  func makeRootPostDraft(
    url: String,
    note: String?,
    sessionID: String
  ) -> RootPostDraft? {
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: url) else {
      composeError = "enter a valid url."
      return nil
    }

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to send posts."
      return nil
    }

    guard
      let recipientPubkeys = resolveOutboundRecipients(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else { return nil }
    guard !recipientPubkeys.isEmpty else {
      composeError = "this session has no active members."
      return nil
    }

    let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
    let timestamp = Int64(Date.now.timeIntervalSince1970)

    return RootPostDraft(
      payload: LinkstrPayload(
        conversationID: sessionID,
        rootID: "",
        kind: .root,
        url: normalizedURL,
        note: normalizedNote,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys,
      normalizedURL: normalizedURL
    )
  }

  private func persistSentRootPost(_ draft: RootPostDraft, receipt: SentPayloadReceipt) throws -> Bool {
    let sessionID = draft.payload.conversationID
    guard try !hasDeletedSession(ownerPubkey: draft.ownerPubkey, sessionID: sessionID),
      let session = try messageStore.session(sessionID: sessionID, ownerPubkey: draft.ownerPubkey) else {
      composeError = "this session is no longer available."
      return false
    }
    guard try !messageStore.hasRootDeletion(
      ownerPubkey: draft.ownerPubkey, sessionID: sessionID,
      rootID: receipt.rumorEventID, deletedByPubkey: draft.senderPubkey
    ) else {
      composeError = "this post is no longer available."
      return false
    }
    let timestamp = Date(timeIntervalSince1970: TimeInterval(draft.payload.timestamp))
    session.updatedAt = max(session.updatedAt, timestamp)
    if let existing = try messageStore.rootPost(
      ownerPubkey: draft.ownerPubkey, sessionID: sessionID, rootID: receipt.rumorEventID
    ) {
      existing.appendPublishedTransportEventIDs(receipt.publishedEventIDs)
      try modelContext.save()
      return true
    }
    let message = try SessionMessageEntity(
      eventID: receipt.rumorEventID,
      ownerPubkey: draft.ownerPubkey,
      conversationID: sessionID,
      rootID: receipt.rumorEventID,
      kind: .root,
      senderPubkey: draft.senderPubkey,
      url: draft.normalizedURL,
      note: draft.payload.note,
      timestamp: timestamp,
      readAt: .now,
      linkType: URLClassifier.classify(draft.normalizedURL),
      publishedTransportEventIDs: receipt.publishedEventIDs
    )
    try messageStore.insert(message)
    return true
  }

  func persistRootDeletion(_ draft: RootDeletionDraft, eventID: String) throws {
    try messageStore.applyRootDeletion(
      ApplyRootDeletionParams(
        ownerPubkey: draft.ownerPubkey,
        sessionID: draft.payload.conversationID,
        rootID: draft.rootID,
        deletedByPubkey: draft.senderPubkey,
        updatedAt: Date(timeIntervalSince1970: TimeInterval(draft.payload.timestamp)),
        eventID: eventID
      ))
    discardPendingPostUpdates(
      sessionID: draft.payload.conversationID,
      rootID: draft.rootID
    )
  }

  func makeRelayDeletionEvent(
    publishedTransportEventIDs: [String],
    reason: String,
    signedBy keypair: Keypair
  ) throws -> NostrEvent {
    let normalizedEventIDs =
      publishedTransportEventIDs.compactMap(NostrValueNormalizer.normalizedEventID)
    guard !normalizedEventIDs.isEmpty else {
      throw LinkstrPayloadError.invalidRootID
    }

    let eventTags = try normalizedEventIDs.map { try customTag(name: "e", value: $0) }

    return try NostrEvent.Builder<NostrEvent>(kind: .deletion)
      .content(reason)
      .appendTags(contentsOf: eventTags)
      .appendTags(try customTag(name: "k", value: String(EventKind.giftWrap.rawValue)))
      .build(signedBy: keypair)
  }
}
