import Foundation
import NostrSDK
import SwiftData

// MARK: - Reactions

extension AppSession {
  @discardableResult
  func toggleReactionAwaitingRelay(
    emoji: String,
    post: SessionMessageEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let draft = makeReactionDraft(emoji: emoji, post: post) else {
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

    do {
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
      try persistReactionState(draft, eventID: reactionEventID)
      if shouldEnqueuePush, draft.payload.reactionActive == true {
        schedulePushEnqueue(
          PushEnqueueRequest(
            notificationType: "new_emoji_reaction",
            eventID: reactionEventID,
            conversationID: draft.payload.conversationID,
            recipientPubkeys: draft.recipientPubkeys,
            emoji: draft.payload.emoji
          )
        )
      }
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  func makeReactionDraft(emoji: String, post: SessionMessageEntity) -> ReactionDraft? {
    let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEmoji.isEmpty else {
      composeError = "pick an emoji reaction."
      return nil
    }
    guard let keypair = identityService.keypair, let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to react."
      return nil
    }

    guard
      let recipientPubkeys = resolveOutboundRecipients(
        sessionID: post.conversationID,
        ownerPubkey: ownerPubkey,
        senderPubkey: keypair.publicKey.hex
      )
    else {
      return nil
    }

    let existingReactions =
      (try? messageStore.reactions(
        ownerPubkey: ownerPubkey,
        sessionID: post.conversationID
      )) ?? []
    let senderHash = LocalDataCrypto.shared.digestHex(keypair.publicKey.hex)
    let currentlyActive = existingReactions.contains { reaction in
      reaction.postID == post.rootID
        && reaction.emoji == normalizedEmoji
        && reaction.senderMatchesHash(senderHash)
        && reaction.isActive
    }
    let nextState = !currentlyActive
    let timestamp = Int64(Date.now.timeIntervalSince1970)

    return ReactionDraft(
      payload: LinkstrPayload(
        conversationID: post.conversationID,
        rootID: post.rootID,
        kind: .reaction,
        url: nil,
        note: nil,
        timestamp: timestamp,
        emoji: normalizedEmoji,
        reactionActive: nextState
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
        updatedAt: .now,
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

  func mergedPubkeys(_ first: [String], _ second: [String]) -> [String] {
    NostrValueNormalizer.dedupedNormalizedPubkeyHexes(first + second)
  }

  func existingSessionName(for sessionID: String, ownerPubkey: String) -> String {
    do {
      if let session = try messageStore.session(sessionID: sessionID, ownerPubkey: ownerPubkey) {
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    } catch {
      // Ignore fetch failures and fall back to a generic title.
    }
    return "session"
  }
}
