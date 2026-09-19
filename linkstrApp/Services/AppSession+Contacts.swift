import Foundation
import NostrSDK

extension AppSession {
  @discardableResult
  func addContact(
    npub: String, alias: String,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    await changeContact(
      key: npub, adding: true, alias: .some(contactStore.normalizeAlias(alias)),
      timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds
    )
  }

  @discardableResult
  func ensureContact(pubkey: String) async -> Bool {
    await changeContact(key: pubkey, adding: true)
  }

  @discardableResult
  func removeContact(
    _ contact: ContactEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard contact.ownerPubkey == identityService.pubkeyHex else {
      composeError = "this contact belongs to a different account."
      return false
    }
    return await changeContact(
      key: contact.targetPubkey, adding: false,
      timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds
    )
  }

  private func changeContact(
    key: String, adding: Bool, alias: String?? = nil,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let owner = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }
    let target: String
    do {
      target = try contactStore.normalizeFollowTarget(key)
    } catch {
      report(error: error)
      return false
    }
    if adding, alias == nil, target == owner { return false }
    return await contactMutations.run { [self] in
      guard identityService.pubkeyHex == owner, !Task.isCancelled else { return false }
      do {
        let exists = try contactStore.contact(ownerPubkey: owner, targetPubkey: target) != nil
        if exists == adding {
          if adding, let alias { try savePrivatePreference(.alias(pubkey: target, name: alias)) }
          composeError = nil
          return true
        }
        try await prepareRelayMutationIfNeeded(
          timeoutSeconds: timeoutSeconds, pollIntervalSeconds: pollIntervalSeconds
        )
        return try await publishContactChange(
          owner: owner, target: target, adding: adding, alias: alias)
      } catch MutationPreparationError.relayBlocked {
        return false
      } catch {
        if identityService.pubkeyHex == owner, !Task.isCancelled { report(error: error) }
        return false
      }
    }
  }

  private func publishContactChange(owner: String, target: String, adding: Bool, alias: String??)
    async throws -> Bool {
    let sourceService = nostrService
    for _ in 0..<3 {
      let timestamp = try await nextFollowListTimestamp()
      guard !Task.isCancelled, identityService.pubkeyHex == owner, nostrService === sourceService
      else { return false }
      var followed = Set(try contactStore.followedPubkeys(ownerPubkey: owner))
      if adding { followed.insert(target) } else { followed.remove(target) }
      let receipt = try await publishFollowListAwaitingRelayAcceptance(
        followedPubkeyHexes: followed.sorted(), createdAt: timestamp
      )
      guard !Task.isCancelled, identityService.pubkeyHex == owner, nostrService === sourceService
      else { return false }
      let isCurrentReceipt = latestAppliedFollowListEventID == receipt.eventID
      if !isCurrentReceipt && !shouldApplyFollowList(receipt) { continue }
      let aliasChange: PrivatePreference?
      if !adding {
        aliasChange = .alias(pubkey: target, name: nil)
      } else if let alias {
        aliasChange = .alias(pubkey: target, name: alias)
      } else {
        aliasChange = nil
      }
      do {
        try applyFollowListState(receipt, aliasChange: aliasChange)
      } catch {
        composeError =
          "contacts updated on relays, but couldn't be saved on this device. reconnect to sync again."
        return false
      }
      composeError = nil
      return true
    }
    composeError = "contacts changed on another device. try again."
    return false
  }

  @discardableResult
  func updateContactAlias(_ contact: ContactEntity, alias: String) -> Bool {
    guard let owner = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }
    guard contact.ownerPubkey == owner else {
      composeError = "this contact belongs to a different account."
      return false
    }
    do {
      try savePrivatePreference(
        .alias(pubkey: contact.targetPubkey, name: contactStore.normalizeAlias(alias)))
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func nextFollowListTimestamp() async throws -> Int64 {
    try await nextPublicationTimestamp(
      after: latestAppliedFollowListCreatedAt, subject: "contact list",
      publicationOverridden: testingOverrides.publishFollowList != nil)
  }

  func publishFollowListAwaitingRelayAcceptance(
    followedPubkeyHexes: [String], createdAt: Int64? = nil
  ) async throws -> ReceivedFollowList {
    guard let keypair = identityService.keypair else { throw NostrServiceError.missingIdentity }
    let timestamp: Int64
    if let createdAt {
      timestamp = createdAt
    } else {
      timestamp = try await nextFollowListTimestamp()
    }
    try Task.checkCancellation()
    guard identityService.pubkeyHex == keypair.publicKey.hex else { throw CancellationError() }
    let retainedTags = try accountStateStore.followListTags(ownerPubkey: keypair.publicKey.hex)
    let desired = Set(followedPubkeyHexes)
    let tags = retainedTags.filter { $0.name != "p" || desired.contains($0.value) }
    let retainedKeys = Set(tags.filter { $0.name == "p" }.map(\.value))
    let newTags = try followedPubkeyHexes.filter { !retainedKeys.contains($0) }.map {
      try PubkeyTag(pubkey: $0).tag
    }
    let allTags = tags + newTags
    let event = try NostrEvent.Builder<NostrEvent>(kind: .followList)
      .createdAt(timestamp).appendTags(contentsOf: allTags).build(signedBy: keypair)
    let eventID: String
    if let publish = testingOverrides.publishFollowList {
      eventID = try await publish(followedPubkeyHexes)
    } else if isRelayPublicationEnabledForCurrentProcess() {
      eventID = try await nostrService.publishEventAwaitingRelayAcceptance(event)
    } else {
      eventID = event.id
    }
    return ReceivedFollowList(
      eventID: eventID, authorPubkey: keypair.publicKey.hex,
      followedPubkeys: followedPubkeyHexes, createdAt: event.createdDate, tags: allTags
    )
  }
}
