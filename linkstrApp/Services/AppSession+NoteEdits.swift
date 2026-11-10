import Foundation

extension AppSession {
  func editPostNoteAwaitingRelay(
    _ note: String?,
    on post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let owner = identityService.pubkeyHex, owner == post.ownerPubkey,
      post.kind == .root, post.senderMatchesHash(LocalDataCrypto.shared.digestHex(owner))
    else {
      composeError = "you can only edit notes on links you shared."
      return false
    }

    let storageID = post.storageID
    guard pendingNoteEdits.insert(storageID).inserted else { return false }
    defer { pendingNoteEdits.remove(storageID) }

    do {
      try await prepareRelayMutationIfNeeded(timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds)
      guard let current = try messageStore.message(storageID: storageID) else {
        composeError = "this post is no longer available."
        return false
      }

      let timestamp = try await nextPublicationTimestamp(
        after: current.noteEditedAt ?? current.timestamp,
        subject: "note edit", publicationOverridden: testingOverrides.sendPayload != nil
      )
      guard identityService.pubkeyHex == owner,
        let current = try messageStore.message(storageID: storageID)
      else {
        composeError = "this post is no longer available."
        return false
      }
      guard let activeRecipients = resolveOutboundRecipients(
          sessionID: current.conversationID, ownerPubkey: owner, senderPubkey: owner
        )
      else { return false }

      let normalized = normalizedNoteEdit(note)
      guard normalized != current.note else { return true }
      let recipients = try activeRecipients.filter { member in
        if member == owner { return true }
        return try messageStore.isMemberActive(
          sessionID: current.conversationID, ownerPubkey: owner, memberPubkey: member, at: current.timestamp
        )
      }
      return try await sendNoteEdit(normalized, on: current, timestamp: timestamp, recipients: recipients)
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }
  }

  private func sendNoteEdit(
    _ note: String?, on post: SessionMessageEntity, timestamp: Int64, recipients: [String]
  ) async throws -> Bool {
    let storageID = post.storageID
    let owner = post.ownerPubkey
    let payload = LinkstrPayload(
      conversationID: post.conversationID, rootID: post.rootID, kind: .noteEdit,
      url: nil, note: note, timestamp: timestamp
    )
    let eventID: String
    if isRelayPublicationEnabledForCurrentProcess() {
      eventID = try await sendPayloadAwaitingRelayAcceptance(
        payload: payload, recipientPubkeyHexes: recipients
      ).rumorEventID
    } else {
      eventID = makeLocalEventID()
    }
    guard identityService.pubkeyHex == owner,
      let current = try messageStore.message(storageID: storageID)
    else {
      composeError = "this post is no longer available."
      return false
    }

    let applied = try messageStore.applyNoteEdit(
      note, to: current, editedAt: Date(timeIntervalSince1970: TimeInterval(timestamp)), eventID: eventID
    )
    guard applied || current.noteEditEventID == NostrValueNormalizer.normalizedEventID(eventID) else {
      composeError = "a newer edit is already saved. review the note and try again."
      return false
    }
    composeError = nil
    return true
  }

  func persistIncomingNoteEdit(_ incoming: ReceivedDirectMessage) -> IncomingPersistenceOutcome {
    let payload = incoming.payload
    let sessionID = payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootID = payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let owner = identityService.pubkeyHex, !sessionID.isEmpty, !rootID.isEmpty,
      payload.url == nil, payload.timestamp > 0,
      incoming.createdAt == Date(timeIntervalSince1970: TimeInterval(payload.timestamp))
    else { return .ignored }

    switch resolveInboundSession(
      ownerPubkey: owner, sessionID: sessionID, senderPubkey: incoming.senderPubkey,
      timestamp: incoming.createdAt, source: incoming.source
    ) {
    case .pending: return .pending
    case .ignored: return .ignored
    case .ready: break
    }

    do {
      if try messageStore.hasRootDeletion(
        ownerPubkey: owner, sessionID: sessionID, rootID: rootID, deletedByPubkey: incoming.senderPubkey
      ) { return .ignored }
      guard let post = try messageStore.rootPost(ownerPubkey: owner, sessionID: sessionID, rootID: rootID)
      else { return .pending }
      guard post.senderMatchesHash(LocalDataCrypto.shared.digestHex(incoming.senderPubkey))
      else { return .ignored }

      let applied = try messageStore.applyNoteEdit(
        normalizedNoteEdit(payload.note), to: post, editedAt: incoming.createdAt, eventID: incoming.eventID
      )
      return applied ? .applied : .ignored
    } catch {
      reportIncomingPersistenceError(error)
      return .ignored
    }
  }

  private func normalizedNoteEdit(_ note: String?) -> String? {
    guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
  }
}

extension SessionMessageStore {
  func applyNoteEdit(
    _ note: String?, to post: SessionMessageEntity, editedAt: Date, eventID: String
  ) throws -> Bool {
    guard editedAt >= post.timestamp,
      let normalizedID = NostrValueNormalizer.normalizedEventID(eventID),
      NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: post.noteEditedAt, currentEventID: post.noteEditEventID,
        incomingUpdatedAt: editedAt, incomingEventID: normalizedID
      )
    else { return false }

    let previous = (post.encryptedNote, post.noteEditedAt, post.noteEditEventID)
    let ciphertext = try LocalDataCrypto.shared.encryptString(note, ownerPubkey: post.ownerPubkey)
    post.applyNoteRevision(ciphertext: ciphertext, editedAt: editedAt, eventID: normalizedID)
    do {
      try modelContext.save()
      return true
    } catch {
      post.applyNoteRevision(ciphertext: previous.0, editedAt: previous.1, eventID: previous.2)
      throw error
    }
  }
}
