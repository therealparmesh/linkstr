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
    let sourceService = nostrService

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      reportMutationError(error, ownerPubkey: ownerPubkey, sourceService: sourceService)
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
    let sourceService = nostrService
    let sessionID = makeLocalEventID()
    let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
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
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
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
      reportMutationError(error, ownerPubkey: ownerPubkey, sourceService: sourceService)
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
    let sourceService = nostrService
    let sessionID = session.sessionID

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
      guard let current = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) else {
        composeError = "this session is no longer available."
        return false
      }
      return await publishAndPersistMemberUpdate(
        session: current, ownerPubkey: ownerPubkey,
        members: normalizedMemberPubkeys(fromNPubs: memberNPubs, myPubkey: keypair.publicKey.hex),
        sessionName: sessionName
      )
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      reportMutationError(error, ownerPubkey: ownerPubkey, sourceService: sourceService)
      return false
    }
  }

  private func publishAndPersistMemberUpdate(
    session: SessionEntity,
    ownerPubkey: String,
    members: [String],
    sessionName: String?
  ) async -> Bool {
    let sourceService = nostrService
    let sessionID = session.sessionID
    let previousTimestamp = session.membershipStateUpdatedAt ?? session.updatedAt
    do {
      let timestamp = try await nextPublicationTimestamp(
        after: previousTimestamp, subject: "session update", publicationOverridden: testingOverrides.sendPayload != nil
      )
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
      guard let current = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) else {
        composeError = "this session is no longer available."
        return false
      }
      let payload = makeSessionMembersPayload(
        session: current, name: sessionName ?? current.name, members: members,
        timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp))
      )
      let updateRecipients = try computeMemberUpdateRecipients(
        session: current, ownerPubkey: ownerPubkey, members: members
      )
      let membershipEventID = try await publishOrLocalEventID(payload: payload, recipientPubkeyHexes: updateRecipients)
      try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
      return try persistMemberUpdate(payload, ownerPubkey: ownerPubkey, members: members, eventID: membershipEventID)
    } catch {
      reportMutationError(error, ownerPubkey: ownerPubkey, sourceService: sourceService)
      return false
    }
  }

  private func persistMemberUpdate(
    _ payload: LinkstrPayload, ownerPubkey: String, members: [String], eventID: String
  ) throws -> Bool {
    guard let current = try messageStore.session(sessionID: payload.conversationID, ownerPubkey: ownerPubkey) else {
      composeError = "this session is no longer available."
      return false
    }
    if current.membershipStateEventID == NostrValueNormalizer.normalizedEventID(eventID) {
      composeError = nil
      return true
    }
    let updatedAt = Date(timeIntervalSince1970: TimeInterval(payload.timestamp))
    guard try messageStore.shouldApplyMemberSnapshot(
      ownerPubkey: ownerPubkey, sessionID: payload.conversationID, updatedAt: updatedAt, eventID: eventID
    ) else {
      composeError = "this session changed on another device. review it and try again."
      return false
    }
    _ = try applySessionSnapshotLocally(
      SessionSnapshotParams(
        ownerPubkey: ownerPubkey, sessionID: payload.conversationID, createdByPubkey: current.createdByPubkey,
        sessionName: payload.sessionName, memberPubkeys: members, updatedAt: updatedAt,
        eventID: eventID, isArchived: current.isArchived
      ))
    composeError = nil
    return true
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

}
