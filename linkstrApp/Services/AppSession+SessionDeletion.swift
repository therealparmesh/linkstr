import Foundation
import NostrSDK

extension AppSession {
  @discardableResult
  func deleteSessionAwaitingRelay(
    _ session: SessionEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard !Task.isCancelled else { return false }
    guard let draft = makeSessionDeletionDraft(session: session) else {
      return false
    }
    let sourceService = nostrService

    if !isRelayPublicationEnabledForCurrentProcess() {
      return persistLocalSessionDeletion(draft)
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
      composeError = "you're signed out. sign in to manage this session."
      return false
    }

    return await publishSessionDeletion(draft: draft, keypair: keypair)
  }

  private func persistLocalSessionDeletion(_ draft: SessionDeletionDraft) -> Bool {
    do {
      try persistSessionDeletion(draft, eventID: makeLocalEventID())
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func publishSessionDeletion(draft: SessionDeletionDraft, keypair: Keypair) async -> Bool {
    let sourceService = nostrService
    do {
      let deletionEventID = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      ).rumorEventID
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      try persistSessionDeletion(draft, eventID: deletionEventID)

      guard !draft.publishedTransportEventIDs.isEmpty else {
        composeError =
          draft.hadStoredRootPosts
          ? "session deleted, but older relay copies of its posts may remain."
          : nil
        return true
      }

      await requestRelayDeletionForSession(draft: draft, keypair: keypair)
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      return true
    } catch {
      reportMutationError(error, ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      return false
    }
  }

  private func requestRelayDeletionForSession(draft: SessionDeletionDraft, keypair: Keypair) async {
    let sourceService = nostrService
    do {
      _ = try await publishEventAwaitingRelayAcceptance(
        makeRelayDeletionEvent(
          publishedTransportEventIDs: draft.publishedTransportEventIDs,
          reason: "linkstr session deletion request",
          signedBy: keypair
        )
      )
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      composeError = nil
    } catch {
      guard !Task.isCancelled, identityService.pubkeyHex == draft.ownerPubkey,
        nostrService === sourceService else { return }
      NSLog("Session relay deletion request failed: \(error.localizedDescription)")
      composeError = "session deleted, but older relay copies of its posts may remain."
    }
  }

  func makeSessionDeletionDraft(session: SessionEntity) -> SessionDeletionDraft? {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this session."
      return nil
    }
    guard canManageSession(for: session) else {
      composeError = "only the session creator can delete this session."
      return nil
    }

    guard
      let recipientPubkeys = resolveDeletionRecipients(
        sessionID: session.sessionID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else {
      return nil
    }

    let publishedTransportEventIDs: [String]
    let hadStoredRootPosts: Bool
    do {
      publishedTransportEventIDs = try messageStore.knownSessionTransportEventIDs(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID
      )
      hadStoredRootPosts = try messageStore.hasRootPosts(
        ownerPubkey: ownerPubkey,
        sessionID: session.sessionID
      )
    } catch {
      composeError = error.localizedDescription
      return nil
    }

    let timestamp = Int64(Date.now.timeIntervalSince1970)
    return SessionDeletionDraft(
      payload: LinkstrPayload(
        conversationID: session.sessionID,
        rootID: makeLocalEventID(),
        kind: .sessionDelete,
        url: nil,
        note: nil,
        timestamp: timestamp
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys,
      sessionID: session.sessionID,
      hadStoredRootPosts: hadStoredRootPosts,
      publishedTransportEventIDs: publishedTransportEventIDs
    )
  }

  func persistSessionDeletion(_ draft: SessionDeletionDraft, eventID: String) throws {
    _ = try messageStore.applySessionDeletion(
      ownerPubkey: draft.ownerPubkey,
      sessionID: draft.sessionID,
      deletedByPubkey: draft.senderPubkey,
      updatedAt: Date(timeIntervalSince1970: TimeInterval(draft.payload.timestamp)),
      eventID: eventID
    )
    discardPendingIncomingSessionData(sessionID: draft.sessionID)
    invalidateMemberIntervalCache(sessionID: draft.sessionID)
    if pendingSessionNavigationRequest?.sessionID == draft.sessionID {
      pendingSessionNavigationRequest = nil
    }
    schedulePushStateSync()
  }

}
