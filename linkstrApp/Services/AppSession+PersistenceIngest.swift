import Foundation
import NostrSDK
import SwiftData

// MARK: - Incoming Reaction Persistence

extension AppSession {
  func persistIncomingReaction(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }
    guard let validated = validatedReactionInputs(incoming) else {
      return .ignored
    }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: validated.sessionID) else {
        return .ignored
      }
    } catch {
      report(error: error)
      return .ignored
    }

    switch resolveInboundSession(
      ownerPubkey: ownerPubkey,
      sessionID: validated.sessionID,
      senderPubkey: incoming.senderPubkey,
      timestamp: incoming.createdAt,
      source: incoming.source
    ) {
    case .ready:
      break
    case .pending:
      return .pending
    case .ignored:
      return .ignored
    }

    return applyReactionToPost(
      incoming: incoming,
      ownerPubkey: ownerPubkey,
      validated: validated
    )
  }

  private func applyReactionToPost(
    incoming: ReceivedDirectMessage,
    ownerPubkey: String,
    validated: ValidatedReactionInputs
  ) -> IncomingPersistenceOutcome {
    do {
      guard
        let root = try messageStore.rootPost(
          ownerPubkey: ownerPubkey,
          sessionID: validated.sessionID,
          rootID: validated.postID
        )
      else {
        return .pending
      }
      if try messageStore.hasRootDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: validated.sessionID,
        rootID: validated.postID,
        deletedByPubkey: root.senderPubkey
      ) {
        return .ignored
      }

      try messageStore.upsertReaction(
        UpsertReactionParams(
          ownerPubkey: ownerPubkey,
          sessionID: validated.sessionID,
          postID: validated.postID,
          emoji: validated.emoji,
          senderPubkey: incoming.senderPubkey,
          isActive: validated.isActive,
          updatedAt: incoming.createdAt,
          eventID: incoming.eventID
        ))
      return .applied
    } catch {
      report(error: error)
      return .ignored
    }
  }
}

// MARK: - Incoming Root Deletion Persistence

extension AppSession {
  func persistIncomingRootDeletion(_ incoming: ReceivedDirectMessage)
    -> IncomingPersistenceOutcome {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    let rootID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootID.isEmpty else { return .ignored }

    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
      return try applyRootDeletionIfAuthorized(
        incoming: incoming,
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: rootID
      )
    } catch {
      report(error: error)
      return .ignored
    }
  }

  private func applyRootDeletionIfAuthorized(
    incoming: ReceivedDirectMessage,
    ownerPubkey: String,
    sessionID: String,
    rootID: String
  ) throws -> IncomingPersistenceOutcome {
    if try messageStore.rootDeletion(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      rootID: rootID,
      deletedByPubkey: incoming.senderPubkey
    ) != nil {
      _ = try messageStore.applyRootDeletion(
        ApplyRootDeletionParams(
          ownerPubkey: ownerPubkey,
          sessionID: sessionID,
          rootID: rootID,
          deletedByPubkey: incoming.senderPubkey,
          updatedAt: incoming.createdAt,
          eventID: incoming.eventID
        ))
      discardPendingIncomingReactions(sessionID: sessionID, rootID: rootID)
      return .applied
    }

    guard
      let existingRoot = try messageStore.rootPost(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: rootID
      )
    else {
      return .pending
    }

    let incomingSenderHash = LocalDataCrypto.shared.digestHex(incoming.senderPubkey)
    guard existingRoot.senderMatchesHash(incomingSenderHash) else {
      return .ignored
    }

    _ = try messageStore.applyRootDeletion(
      ApplyRootDeletionParams(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: rootID,
        deletedByPubkey: incoming.senderPubkey,
        updatedAt: incoming.createdAt,
        eventID: incoming.eventID
      ))
    discardPendingIncomingReactions(sessionID: sessionID, rootID: rootID)
    return .applied
  }
}

// MARK: - Incoming Root Post Persistence

extension AppSession {
  func persistIncomingRootPost(
    _ incoming: ReceivedDirectMessage,
    transportEventIDs: [String]
  ) -> IncomingPersistenceOutcome {
    guard let ownerPubkey = identityService.pubkeyHex else { return .ignored }

    let sessionID = incoming.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return .ignored }
    do {
      guard try !hasDeletedSession(ownerPubkey: ownerPubkey, sessionID: sessionID) else {
        return .ignored
      }
    } catch {
      report(error: error)
      return .ignored
    }
    let payloadRootID = incoming.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !payloadRootID.isEmpty, payloadRootID != incoming.eventID {
      return .ignored
    }

    guard let payloadURL = incoming.payload.url,
      let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: payloadURL)
    else {
      return .ignored
    }

    let existingSession: SessionEntity
    switch resolveInboundSession(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      senderPubkey: incoming.senderPubkey,
      timestamp: incoming.createdAt,
      source: incoming.source
    ) {
    case .ready(let session):
      existingSession = session
    case .pending:
      return .pending
    case .ignored:
      return .ignored
    }

    return insertOrUpdateRootPost(
      InsertOrUpdateRootPostParams(
        incoming: incoming,
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        normalizedURL: normalizedURL,
        existingSession: existingSession,
        transportEventIDs: transportEventIDs
      ))
  }

  private func insertOrUpdateRootPost(
    _ params: InsertOrUpdateRootPostParams
  ) -> IncomingPersistenceOutcome {
    let incoming = params.incoming
    let ownerPubkey = params.ownerPubkey
    let sessionID = params.sessionID
    let transportEventIDs = params.transportEventIDs
    do {
      if try messageStore.hasRootDeletion(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: incoming.eventID,
        deletedByPubkey: incoming.senderPubkey
      ) {
        discardPendingIncomingReactions(sessionID: sessionID, rootID: incoming.eventID)
        return .ignored
      }

      if let existing = try messageStore.rootPost(
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        rootID: incoming.eventID
      ) {
        if existing.appendPublishedTransportEventIDs(transportEventIDs) {
          try modelContext.save()
        }
        return .applied
      }

      return try insertNewRootPost(params)
    } catch {
      return handleRootPostInsertionError(
        error: error,
        ownerPubkey: ownerPubkey,
        sessionID: sessionID,
        eventID: incoming.eventID,
        transportEventIDs: transportEventIDs
      )
    }
  }

  private func insertNewRootPost(
    _ params: InsertOrUpdateRootPostParams
  ) throws -> IncomingPersistenceOutcome {
    let incoming = params.incoming
    let ownerPubkey = params.ownerPubkey
    let sessionID = params.sessionID
    let existingSession = params.existingSession

    _ = try messageStore.upsertSession(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      name: existingSession.name,
      createdByPubkey: existingSession.createdByPubkey,
      updatedAt: incoming.createdAt,
      isArchived: existingSession.isArchived
    )

    let isEchoedOutgoing = ownerPubkey == incoming.senderPubkey
    let shouldMarkReadOnInsert =
      isEchoedOutgoing
      || (incoming.source == .historical
        && suppressUnreadDuringHistoricalRestore)
    let message = try SessionMessageEntity(
      eventID: incoming.eventID,
      ownerPubkey: ownerPubkey,
      conversationID: sessionID,
      rootID: incoming.eventID,
      kind: .root,
      senderPubkey: incoming.senderPubkey,
      url: params.normalizedURL,
      note: incoming.payload.note,
      timestamp: incoming.createdAt,
      readAt: shouldMarkReadOnInsert ? incoming.createdAt : nil,
      linkType: URLClassifier.classify(params.normalizedURL),
      publishedTransportEventIDs: params.transportEventIDs
    )
    try messageStore.insert(message)
    return .applied
  }

  private func handleRootPostInsertionError(
    error: Error,
    ownerPubkey: String,
    sessionID: String,
    eventID: String,
    transportEventIDs: [String]
  ) -> IncomingPersistenceOutcome {
    if let existing = try? messageStore.rootPost(
      ownerPubkey: ownerPubkey,
      sessionID: sessionID,
      rootID: eventID
    ) {
      if existing.appendPublishedTransportEventIDs(transportEventIDs) {
        try? modelContext.save()
      }
      return .applied
    }
    report(error: error)
    return .ignored
  }
}
