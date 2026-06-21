import Foundation
import NostrSDK
import SwiftData

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
    guard let draft = makeRootPostDraft(url: url, note: note, sessionID: session.sessionID) else {
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    if !isRelayPublicationEnabledForCurrentProcess() {
      return createPostLocally(draft)
    }
    return await createPostAwaitingRelayDelivery(draft)
  }

  @discardableResult
  private func createPostLocally(_ draft: RootPostDraft) -> Bool {
    do {
      let eventID = makeLocalEventID()
      try persistSentRootPost(draft, receipt: localSendReceipt(withRumorEventID: eventID))
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
    guard let draft = makeRootDeletionDraft(post: post) else {
      return false
    }

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
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    guard let keypair = identityService.keypair else {
      composeError = "you're signed out. sign in to manage this post."
      return false
    }

    return await performRelayPostDeletion(draft: draft, keypair: keypair)
  }

  private func performRelayPostDeletion(draft: RootDeletionDraft, keypair: Keypair) async -> Bool {
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

      let deletionWatermarkEventID: String
      do {
        deletionWatermarkEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        ).rumorEventID
      } catch {
        if let deletionRequestEventID {
          try persistRootDeletion(draft, eventID: deletionRequestEventID)
          composeError = "post deleted, but other members may keep seeing it until sync catches up."
          return true
        }
        throw error
      }

      try persistRootDeletion(draft, eventID: deletionWatermarkEventID)
      if deletionRequestEventID == nil {
        composeError =
          "post deleted, but relay deletion is unavailable for older copies of this post."
      } else {
        composeError = nil
      }
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func createPostAwaitingRelayDelivery(_ draft: RootPostDraft) async -> Bool {
    do {
      let receipt = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      )
      try persistSentRootPost(draft, receipt: receipt)
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
      report(error: error)
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

  func persistSentRootPost(_ draft: RootPostDraft, receipt: SentPayloadReceipt) throws {
    let sessionID = draft.payload.conversationID
    _ = try messageStore.upsertSession(
      ownerPubkey: draft.ownerPubkey,
      sessionID: sessionID,
      name: existingSessionName(for: sessionID, ownerPubkey: draft.ownerPubkey),
      createdByPubkey: draft.senderPubkey,
      updatedAt: .now
    )
    let message = try SessionMessageEntity(
      eventID: receipt.rumorEventID,
      ownerPubkey: draft.ownerPubkey,
      conversationID: sessionID,
      rootID: receipt.rumorEventID,
      kind: .root,
      senderPubkey: draft.senderPubkey,
      url: draft.normalizedURL,
      note: draft.payload.note,
      timestamp: .now,
      readAt: .now,
      linkType: URLClassifier.classify(draft.normalizedURL),
      publishedTransportEventIDs: receipt.publishedEventIDs
    )
    try messageStore.insert(message)
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
    discardPendingIncomingReactions(
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
