import Foundation
import NostrSDK

// MARK: - Session Create / Update / Delete

extension AppSession {
  @discardableResult
  func createSessionAwaitingRelay(
    name: String,
    memberNPubs: [String],
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      composeError = "enter a session name."
      return false
    }

    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to create sessions."
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

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    return await publishAndPersistNewSession(
      ownerPubkey: ownerPubkey,
      keypair: keypair,
      name: normalizedName,
      members: members
    )
  }

  private func publishAndPersistNewSession(
    ownerPubkey: String,
    keypair: Keypair,
    name: String,
    members: [String]
  ) async -> Bool {
    let sessionID = makeLocalEventID()
    let now = Date.now
    let payload = makeSessionCreatePayload(
      sessionID: sessionID,
      name: name,
      members: members,
      timestamp: now
    )

    do {
      let membershipEventID = try await publishOrLocalEventID(
        payload: payload,
        recipientPubkeyHexes: members
      )
      _ = try applySessionSnapshotLocally(
        SessionSnapshotParams(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          createdByPubkey: keypair.publicKey.hex,
          sessionName: name,
          memberPubkeys: members,
          updatedAt: now,
          eventID: membershipEventID
        ))
      requestSessionNavigation(to: sessionID)
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func makeSessionCreatePayload(
    sessionID: String,
    name: String,
    members: [String],
    timestamp: Date
  ) -> LinkstrPayload {
    LinkstrPayload(
      conversationID: sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionCreate,
      url: nil,
      note: nil,
      timestamp: Int64(timestamp.timeIntervalSince1970),
      sessionName: name,
      memberPubkeys: members
    )
  }

  func publishOrLocalEventID(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) async throws -> String {
    if isRelayPublicationEnabledForCurrentProcess() {
      return try await sendPayloadAwaitingRelayAcceptance(
        payload: payload,
        recipientPubkeyHexes: recipientPubkeyHexes
      ).rumorEventID
    } else {
      return makeLocalEventID()
    }
  }

  @discardableResult
  func updateSessionMembersAwaitingRelay(
    session: SessionEntity,
    memberNPubs: [String],
    sessionName: String? = nil,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage this session."
      return false
    }

    guard canManageSession(for: session) else {
      composeError = "only the session creator can manage this session."
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

    let members = normalizedMemberPubkeys(
      fromNPubs: memberNPubs,
      myPubkey: keypair.publicKey.hex
    )
    return await publishAndPersistMemberUpdate(
      session: session,
      ownerPubkey: ownerPubkey,
      members: members,
      sessionName: sessionName
    )
  }

  private func publishAndPersistMemberUpdate(
    session: SessionEntity,
    ownerPubkey: String,
    members: [String],
    sessionName: String?
  ) async -> Bool {
    let now = Date.now
    let effectiveName = sessionName ?? session.name
    let payload = makeSessionMembersPayload(
      session: session,
      name: effectiveName,
      members: members,
      timestamp: now
    )

    do {
      let updateRecipients = try computeMemberUpdateRecipients(
        session: session,
        ownerPubkey: ownerPubkey,
        members: members
      )
      let membershipEventID = try await publishOrLocalEventID(
        payload: payload,
        recipientPubkeyHexes: updateRecipients
      )
      _ = try applySessionSnapshotLocally(
        SessionSnapshotParams(
          ownerPubkey: ownerPubkey,
          sessionID: session.sessionID,
          createdByPubkey: session.createdByPubkey,
          sessionName: effectiveName,
          memberPubkeys: members,
          updatedAt: now,
          eventID: membershipEventID,
          isArchived: session.isArchived
        ))
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func makeSessionMembersPayload(
    session: SessionEntity,
    name: String,
    members: [String],
    timestamp: Date
  ) -> LinkstrPayload {
    LinkstrPayload(
      conversationID: session.sessionID,
      rootID: makeLocalEventID(),
      kind: .sessionMembers,
      url: nil,
      note: nil,
      timestamp: Int64(timestamp.timeIntervalSince1970),
      sessionName: name,
      memberPubkeys: members
    )
  }

  private func computeMemberUpdateRecipients(
    session: SessionEntity,
    ownerPubkey: String,
    members: [String]
  ) throws -> [String] {
    let priorActiveMembers = try messageStore.members(
      sessionID: session.sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: true
    ).map(\.memberPubkey)
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(priorActiveMembers + members)
  }

  @discardableResult
  func deleteSessionAwaitingRelay(
    _ session: SessionEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let draft = makeSessionDeletionDraft(session: session) else {
      return false
    }

    if !isRelayPublicationEnabledForCurrentProcess() {
      return persistLocalSessionDeletion(draft)
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
    do {
      let deletionEventID = try await sendPayloadAwaitingRelayAcceptance(
        payload: draft.payload,
        recipientPubkeyHexes: draft.recipientPubkeys
      ).rumorEventID
      try persistSessionDeletion(draft, eventID: deletionEventID)

      guard !draft.publishedTransportEventIDs.isEmpty else {
        composeError =
          draft.hadStoredRootPosts
          ? "session deleted, but older relay copies of its posts may remain."
          : nil
        return true
      }

      await requestRelayDeletionForSession(draft: draft, keypair: keypair)
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func requestRelayDeletionForSession(draft: SessionDeletionDraft, keypair: Keypair) async {
    do {
      _ = try await publishEventAwaitingRelayAcceptance(
        makeRelayDeletionEvent(
          publishedTransportEventIDs: draft.publishedTransportEventIDs,
          reason: "linkstr session deletion request",
          signedBy: keypair
        )
      )
      composeError = nil
    } catch {
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
