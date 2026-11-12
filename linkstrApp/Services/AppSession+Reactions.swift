import Foundation
import NostrSDK

// MARK: - Reactions

extension AppSession {
  @discardableResult
  func toggleReactionAwaitingRelay(
    emoji: String,
    post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    let owner = post.ownerPubkey
    let storageID = post.storageID
    let sourceService = nostrService
    let key = SessionReactionEntity.storageID(
      ownerPubkey: owner, sessionID: post.conversationID, postID: post.rootID,
      emoji: emoji.trimmingCharacters(in: .whitespacesAndNewlines), senderPubkey: owner
    )
    return await reactionMutations.run(key: key) { [self] in
      guard !Task.isCancelled, identityService.pubkeyHex == owner, nostrService === sourceService else { return false }
      return await publishReaction(
        emoji: emoji, storageID: storageID, timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds
      )
    }
  }

  private func publishReaction(
    emoji: String, storageID: String, timeoutSeconds: TimeInterval, pollIntervalSeconds: TimeInterval
  ) async -> Bool {
    guard let owner = identityService.pubkeyHex else { return false }
    let sourceService = nostrService

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds
      )
      try checkMutationContext(ownerPubkey: owner, sourceService: sourceService)
      guard let post = try messageStore.message(storageID: storageID),
        let draft = try await makeReactionDraft(emoji: emoji, post: post) else { return false }
      try checkMutationContext(ownerPubkey: owner, sourceService: sourceService)
      guard try messageStore.message(storageID: storageID) != nil else { return false }

      let reactionEventID: String
      let shouldEnqueuePush: Bool
      if isRelayPublicationEnabledForCurrentProcess() {
        reactionEventID = try await sendPayloadAwaitingRelayAcceptance(
          payload: draft.payload,
          recipientPubkeyHexes: draft.recipientPubkeys
        ).rumorEventID
        shouldEnqueuePush = true
      } else {
        reactionEventID = makeLocalEventID()
        shouldEnqueuePush = false
      }
      try checkMutationContext(ownerPubkey: draft.ownerPubkey, sourceService: sourceService)
      guard try messageStore.message(storageID: storageID) != nil else { return false }
      try persistReactionState(draft, eventID: reactionEventID)
      if shouldEnqueuePush, draft.payload.reactionActive == true {
        schedulePushEnqueue(
          PushEnqueueRequest(
            notificationType: "new_emoji_reaction",
            eventID: reactionEventID,
            conversationID: draft.payload.conversationID,
            recipientPubkeys: draft.recipientPubkeys,
            emoji: draft.payload.emoji,
            postID: draft.payload.rootID
          )
        )
      }
      composeError = nil
      return true
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      reportMutationError(error, ownerPubkey: owner, sourceService: sourceService)
      return false
    }
  }

  private func makeReactionDraft(emoji: String, post: SessionMessageEntity) async throws -> ReactionDraft? {
    let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else {
      composeError = "pick an emoji reaction."
      return nil
    }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to react."
      return nil
    }
    guard post.ownerPubkey == ownerPubkey else {
      composeError = "this post belongs to a different account."
      return nil
    }

    let existingReactions = try messageStore.reactions(ownerPubkey: ownerPubkey, sessionID: post.conversationID)
    let senderHash = LocalDataCrypto.shared.digestHex(keypair.publicKey.hex)
    let existing = existingReactions.first { reaction in
      reaction.postID == post.rootID
        && reaction.emoji == normalizedEmoji
        && reaction.senderMatchesHash(senderHash)
    }
    let sessionID = post.conversationID
    let rootID = post.rootID
    let nextState = !(existing?.isActive ?? false)
    let sourceService = nostrService
    let timestamp = try await nextPublicationTimestamp(
      after: existing?.updatedAt, subject: "reaction", publicationOverridden: testingOverrides.sendPayload != nil
    )
    try checkMutationContext(ownerPubkey: ownerPubkey, sourceService: sourceService)
    guard let recipientPubkeys = resolveOutboundRecipients(
      sessionID: sessionID, ownerPubkey: ownerPubkey, senderPubkey: keypair.publicKey.hex
    ) else { return nil }
    return ReactionDraft(
      payload: LinkstrPayload(
        conversationID: sessionID, rootID: rootID, kind: .reaction,
        url: nil, note: nil, timestamp: timestamp,
        emoji: normalizedEmoji, reactionActive: nextState
      ),
      ownerPubkey: ownerPubkey,
      senderPubkey: keypair.publicKey.hex,
      recipientPubkeys: recipientPubkeys
    )
  }

  func persistReactionState(_ draft: ReactionDraft, eventID: String) throws {
    guard let isActive = draft.payload.reactionActive else { return }
    let emoji = draft.payload.emoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !emoji.isEmpty else { return }
    let sessionID = draft.payload.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return }
    let postID = draft.payload.rootID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !postID.isEmpty else { return }

    try messageStore.upsertReaction(
      UpsertReactionParams(
        ownerPubkey: draft.ownerPubkey,
        sessionID: sessionID,
        postID: postID,
        emoji: emoji,
        senderPubkey: draft.senderPubkey,
        isActive: isActive,
        updatedAt: Date(timeIntervalSince1970: TimeInterval(draft.payload.timestamp)),
        eventID: eventID
      ))
  }
}

// MARK: - Vanish & Account Deletion Event

extension AppSession {
  func makeVanishEvent(relayURLs: [String], signedBy keypair: Keypair) throws -> NostrEvent {
    let normalizedRelayURLs =
      Array(
        Set(
          relayURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )
      )
      .sorted()

    let relayTags: [Tag]
    if normalizedRelayURLs.isEmpty {
      relayTags = try [customTag(name: "relay", value: "ALL_RELAYS")]
    } else {
      relayTags = try normalizedRelayURLs.map { try customTag(name: "relay", value: $0) }
    }

    return try NostrEvent.Builder<NostrEvent>(kind: .unknown(62))
      .content("account deletion request")
      .appendTags(contentsOf: relayTags)
      .build(signedBy: keypair)
  }

  func customTag(name: String, value: String) throws -> Tag {
    let rawTag = [name, value]
    let data = try JSONEncoder().encode(rawTag)
    return try JSONDecoder().decode(Tag.self, from: data)
  }
}

// MARK: - Shared Publishing & Recipient Utilities

extension AppSession {
  func publishEventAwaitingRelayAcceptance(_ event: NostrEvent) async throws -> String {
    if let publishRelayEventOverride = testingOverrides.publishRelayEvent {
      return try await publishRelayEventOverride(event)
    }
    return try await nostrService.publishEventAwaitingRelayAcceptance(event)
  }

  func sendPayloadAwaitingRelayAcceptance(
    payload: LinkstrPayload,
    recipientPubkeyHexes: [String]
  ) async throws -> SentPayloadReceipt {
    if let sendPayloadOverride = testingOverrides.sendPayload {
      guard !recipientPubkeyHexes.isEmpty else {
        throw NostrServiceError.invalidPubkey
      }
      return try await sendPayloadOverride(payload, recipientPubkeyHexes)
    }
    return try await nostrService.sendAwaitingRelayAcceptance(
      payload: payload,
      toMany: recipientPubkeyHexes
    )
  }

  func localSendReceipt(withRumorEventID rumorEventID: String) -> SentPayloadReceipt {
    SentPayloadReceipt(rumorEventID: rumorEventID, publishedEventIDs: [])
  }

  func normalizedMemberPubkeys(fromNPubs memberNPubs: [String], myPubkey: String) -> [String] {
    var members: [String] = []
    if let normalizedMyPubkey = NostrValueNormalizer.normalizedPubkeyHex(myPubkey) {
      members.append(normalizedMyPubkey)
    }
    for npub in memberNPubs {
      guard
        let memberPubkey = NostrValueNormalizer.normalizedPubkeyHex(
          fromAnyPublicKeyString: npub)
      else { continue }
      members.append(memberPubkey)
    }
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(members)
  }

  func activeMemberPubkeys(sessionID: String, ownerPubkey: String) throws -> [String] {
    let members = try messageStore.members(
      sessionID: sessionID,
      ownerPubkey: ownerPubkey,
      activeOnly: true
    ).map(\.memberPubkey)
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(members)
  }

  func resolveOutboundRecipients(
    sessionID: String,
    ownerPubkey: String,
    senderPubkey: String
  ) -> [String]? {
    do {
      guard
        try messageStore.isMemberActive(
          sessionID: sessionID,
          ownerPubkey: ownerPubkey,
          memberPubkey: senderPubkey,
          at: .now
        )
      else {
        composeError = "you're no longer a member of this session."
        return nil
      }
      let recipientPubkeys = try activeMemberPubkeys(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey
      )
      guard recipientPubkeys.contains(senderPubkey) else {
        composeError = "you're no longer a member of this session."
        return nil
      }
      return recipientPubkeys
    } catch {
      composeError = error.localizedDescription
      return nil
    }
  }

  func resolveDeletionRecipients(
    sessionID: String,
    ownerPubkey: String,
    senderPubkey: String
  ) -> [String]? {
    do {
      let knownMemberPubkeys = try messageStore.members(
        sessionID: sessionID,
        ownerPubkey: ownerPubkey,
        activeOnly: false
      ).map(\.memberPubkey)
      let recipientPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(
        knownMemberPubkeys + [senderPubkey])
      guard recipientPubkeys.contains(senderPubkey) else {
        composeError = "this post is no longer associated with a valid session membership set."
        return nil
      }
      return recipientPubkeys
    } catch {
      composeError = error.localizedDescription
      return nil
    }
  }

}
