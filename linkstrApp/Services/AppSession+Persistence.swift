import Foundation

// MARK: - Incoming Message Persistence

extension AppSession {
  func persistIncoming(_ incoming: ReceivedDirectMessage) {
    evaluateInitialHistoricalUnreadPolicyIfNeeded(for: incoming)
    let pending = PendingIncomingMessage(incoming)
    switch reduceIncoming(pending) {
    case .applied:
      removePendingIncomingMessage(eventID: pending.eventID)
      drainTargetedPendingMessages(for: incoming)
      drainPendingIncomingMessagesIfNeeded()
    case .ignored:
      removePendingIncomingMessage(eventID: pending.eventID)
    case .pending:
      enqueuePendingIncomingMessage(pending)
    }
  }

  func drainTargetedPendingMessages(for incoming: ReceivedDirectMessage) {
    guard !pendingIncomingMessages.isEmpty else { return }
    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }

    switch incoming.payload.kind {
    case .root:
      let rootID = incoming.eventID
      drainPendingMessages { pending in
        pending.incoming.payload.kind == .reaction
          && pending.incoming.payload.conversationID.trimmingCharacters(
            in: .whitespacesAndNewlines) == sessionID
          && pending.incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
            == rootID
      }
    case .sessionCreate, .sessionMembers:
      drainPendingMessages { pending in
        let kind = pending.incoming.payload.kind
        guard
          kind == .root
            || kind == .reaction
            || kind == .rootDelete
            || kind == .sessionDelete
        else { return false }
        return pending.incoming.payload.conversationID.trimmingCharacters(
          in: .whitespacesAndNewlines) == sessionID
      }
    default:
      break
    }
  }

  func drainPendingMessages(matching predicate: (PendingIncomingMessage) -> Bool) {
    guard !isDrainingPendingIncomingMessages else { return }
    var candidates: [(Int, PendingIncomingMessage)] = []
    for (index, pending) in pendingIncomingMessages.enumerated() where predicate(pending) {
      candidates.append((index, pending))
    }
    guard !candidates.isEmpty else { return }

    isDrainingPendingIncomingMessages = true
    defer { isDrainingPendingIncomingMessages = false }

    var indicesToRemove = IndexSet()
    var madeProgress = true
    while madeProgress {
      madeProgress = false
      var stillPending: [(Int, PendingIncomingMessage)] = []
      for (originalIndex, pending) in candidates {
        guard !indicesToRemove.contains(originalIndex) else { continue }
        switch reduceIncoming(pending) {
        case .applied:
          indicesToRemove.insert(originalIndex)
          madeProgress = true
        case .ignored:
          indicesToRemove.insert(originalIndex)
        case .pending:
          stillPending.append((originalIndex, pending))
        }
      }
      candidates = stillPending
    }

    if !indicesToRemove.isEmpty {
      pendingIncomingMessages = pendingIncomingMessages.enumerated().compactMap { index, msg in
        indicesToRemove.contains(index) ? nil : msg
      }
    }
  }

  func reduceIncoming(_ pending: PendingIncomingMessage) -> IncomingPersistenceOutcome {
    switch pending.incoming.payload.kind {
    case .sessionCreate:
      return persistIncomingSessionCreate(pending.incoming)
    case .sessionDelete:
      return persistIncomingSessionDelete(pending.incoming)
    case .sessionMembers:
      return persistIncomingSessionMembers(pending.incoming)
    case .reaction:
      return persistIncomingReaction(pending.incoming)
    case .root:
      return persistIncomingRootPost(
        pending.incoming,
        transportEventIDs: pending.transportEventIDs
      )
    case .rootDelete:
      return persistIncomingRootDeletion(pending.incoming)
    }
  }

  func enqueuePendingIncomingMessage(_ pending: PendingIncomingMessage) {
    if let index = pendingIncomingMessages.firstIndex(where: { $0.eventID == pending.eventID }) {
      pendingIncomingMessages[index].mergeDuplicate(pending.incoming)
      return
    }
    pendingIncomingMessages.append(pending)
  }

  func removePendingIncomingMessage(eventID: String) {
    pendingIncomingMessages.removeAll { $0.eventID == eventID }
  }

  func discardPendingIncomingReactions(sessionID: String, rootID: String) {
    pendingIncomingMessages.removeAll { pending in
      pending.incoming.payload.kind == .reaction
        && pending.incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
          == sessionID
        && pending.incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines) == rootID
    }
  }

  func discardPendingIncomingSessionData(sessionID: String) {
    pendingIncomingMessages.removeAll { pending in
      pending.incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        == sessionID
    }
  }

  func discardPendingIncomingSessionDependents(sessionID: String) {
    pendingIncomingMessages.removeAll { pending in
      let payload = pending.incoming.payload
      guard payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID
      else {
        return false
      }
      return payload.kind != .sessionDelete
    }
  }

  func drainPendingIncomingMessagesIfNeeded() {
    guard !isDrainingPendingIncomingMessages else { return }
    guard !pendingIncomingMessages.isEmpty else { return }

    isDrainingPendingIncomingMessages = true
    defer { isDrainingPendingIncomingMessages = false }

    var madeProgress = true
    while madeProgress {
      madeProgress = false
      var nextPending: [PendingIncomingMessage] = []

      for pending in pendingIncomingMessages {
        switch reduceIncoming(pending) {
        case .applied:
          madeProgress = true
        case .ignored:
          continue
        case .pending:
          nextPending.append(pending)
        }
      }

      pendingIncomingMessages = nextPending
    }
  }

  func resetInitialHistoricalUnreadPolicy() {
    suppressUnreadDuringHistoricalRestore = false
    didEvalHistoricalUnreadPolicy = false
  }

  func finishInitialHistoricalRestore() {
    suppressUnreadDuringHistoricalRestore = false
    didEvalHistoricalUnreadPolicy = true
    drainPendingIncomingMessagesIfNeeded()
  }

  func evaluateInitialHistoricalUnreadPolicyIfNeeded(for incoming: ReceivedDirectMessage) {
    guard incoming.source == .historical else { return }
    guard !didEvalHistoricalUnreadPolicy else { return }
    guard let ownerPubkey = identityService.pubkeyHex else { return }

    do {
      suppressUnreadDuringHistoricalRestore =
        !(try messageStore.hasPersistedConversationState(ownerPubkey: ownerPubkey))
    } catch {
      suppressUnreadDuringHistoricalRestore = false
      report(error: error)
    }
    didEvalHistoricalUnreadPolicy = true
  }
}

// MARK: - Incoming Session Handlers

extension AppSession {
  func persistIncomingSessionCreate(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }
    guard let validated = validatedSessionCreateInputs(incoming, ownerPubkey: ownerPubkey) else {
      return .ignored
    }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: validated.sessionID) else {
        return .ignored
      }
      let existing = try messageStore.session(
        sessionID: validated.sessionID, ownerPubkey: ownerPubkey)
      if let existing {
        guard existing.createdByPubkey == incoming.senderPubkey else { return .ignored }
        guard
          try messageStore.shouldApplyMemberSnapshot(
            ownerPubkey: ownerPubkey,
            sessionID: validated.sessionID,
            updatedAt: incoming.createdAt,
            eventID: incoming.eventID
          )
        else {
          return .ignored
        }
      }

      guard
        try applySessionSnapshotLocally(
          SessionSnapshotParams(
            ownerPubkey: ownerPubkey,
            sessionID: validated.sessionID,
            createdByPubkey: incoming.senderPubkey,
            sessionName: normalizedSessionName(incoming.payload.sessionName),
            memberPubkeys: validated.members,
            updatedAt: incoming.createdAt,
            eventID: incoming.eventID
          )) != nil
      else {
        return .ignored
      }
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }

  func validatedSessionCreateInputs(
    _ incoming: ReceivedDirectMessage,
    ownerPubkey: String
  ) -> ValidatedSessionCreateInputs? {
    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return nil }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return nil
    }
    guard members.contains(incoming.senderPubkey) else { return nil }
    guard members.contains(ownerPubkey) else { return nil }
    return ValidatedSessionCreateInputs(sessionID: sessionID, members: members)
  }

  func persistIncomingSessionMembers(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }
    guard let validated = validatedSessionMembersInputs(incoming) else {
      return .ignored
    }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: validated.sessionID) else {
        return .ignored
      }
      let existing = try messageStore.session(
        sessionID: validated.sessionID, ownerPubkey: ownerPubkey)
      if let existing {
        guard existing.createdByPubkey == incoming.senderPubkey else { return .ignored }
        guard
          try messageStore.shouldApplyMemberSnapshot(
            ownerPubkey: ownerPubkey,
            sessionID: validated.sessionID,
            updatedAt: incoming.createdAt,
            eventID: incoming.eventID
          )
        else {
          return .ignored
        }
      } else {
        guard validated.members.contains(ownerPubkey) else { return .ignored }
      }

      guard
        try applySessionSnapshotLocally(
          SessionSnapshotParams(
            ownerPubkey: ownerPubkey,
            sessionID: validated.sessionID,
            createdByPubkey: incoming.senderPubkey,
            sessionName: normalizedSessionName(incoming.payload.sessionName),
            memberPubkeys: validated.members,
            updatedAt: incoming.createdAt,
            eventID: incoming.eventID,
            isArchived: existing?.isArchived
          )) != nil
      else {
        return .ignored
      }
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }

  func validatedSessionMembersInputs(
    _ incoming: ReceivedDirectMessage
  ) -> ValidatedSessionCreateInputs? {
    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return nil }
    guard
      let members = incoming.payload.normalizedMemberPubkeys(),
      !members.isEmpty
    else {
      return nil
    }
    guard members.contains(incoming.senderPubkey) else { return nil }
    return ValidatedSessionCreateInputs(sessionID: sessionID, members: members)
  }

  func persistIncomingSessionDelete(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }

    do {
      guard
        let authorityPubkey = try sessionDeletionAuthorityPubkey(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID
        )
      else {
        return .pending
      }
      guard authorityPubkey == incoming.senderPubkey else { return .ignored }

      let didApply = try messageStore.applySessionDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        deletedByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      )
      let tombstoneExists = try hasDeletedSession(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID
      )
      let isDeleted = didApply || tombstoneExists
      if isDeleted {
        applySessionDeletionSideEffects(sessionID: sessionID)
        return .applied
      }
      return .ignored
    } catch {
      report(error: error)
      return .ignored
    }
  }

  func applySessionDeletionSideEffects(sessionID: String) {
    discardPendingIncomingSessionDependents(sessionID: sessionID)
    invalidateMemberIntervalCache(sessionID: sessionID)
    if pendingSessionNavigationRequest?.sessionID == sessionID {
      pendingSessionNavigationRequest = nil
    }
    schedulePushStateSync()
  }
}
