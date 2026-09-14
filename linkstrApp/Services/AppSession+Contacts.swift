import Foundation

// MARK: - Contact & Follow List Management

extension AppSession {
  @discardableResult
  func addContact(
    npub: String,
    alias: String,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }

    let targetPubkey: String
    do {
      targetPubkey = try contactStore.normalizeFollowTarget(npub)
    } catch {
      report(error: error)
      return false
    }

    let normalizedAlias = contactStore.normalizeAlias(alias)
    if contactStore.hasContact(ownerPubkey: ownerPubkey, withTargetPubkey: targetPubkey) {
      return updateExistingContactAlias(
        targetPubkey: targetPubkey,
        alias: normalizedAlias
      )
    }

    return await addNewContact(
      ownerPubkey: ownerPubkey,
      targetPubkey: targetPubkey,
      alias: normalizedAlias,
      timeoutSeconds: timeoutSeconds,
      pollIntervalSeconds: pollIntervalSeconds
    )
  }

  private func updateExistingContactAlias(
    targetPubkey: String,
    alias: String?
  ) -> Bool {
    do {
      try savePrivatePreference(.alias(pubkey: targetPubkey, name: alias))
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  private func addNewContact(
    ownerPubkey: String,
    targetPubkey: String,
    alias: String?,
    timeoutSeconds: TimeInterval,
    pollIntervalSeconds: TimeInterval
  ) async -> Bool {
    let nextFollowedPubkeys: [String]
    do {
      nextFollowedPubkeys = try updatedFollowedPubkeys(
        ownerPubkey: ownerPubkey
      ) { followedPubkeys in
        followedPubkeys.insert(targetPubkey)
      }
    } catch {
      report(error: error)
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishFollowListAwaitingRelayAcceptance(
          followedPubkeyHexes: nextFollowedPubkeys
        )
      }
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    guard identityService.pubkeyHex == ownerPubkey else { return false }
    do {
      try persistLocalFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        followedPubkeys: nextFollowedPubkeys
      ) { [self] in
        if let alias {
          try savePrivatePreference(.alias(pubkey: targetPubkey, name: alias))
        }
      }
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func updateContactAlias(_ contact: ContactEntity, alias: String) -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }
    guard contact.ownerPubkey == ownerPubkey else {
      composeError = "this contact belongs to a different account."
      return false
    }

    do {
      let normalizedAlias = contactStore.normalizeAlias(alias)
      try savePrivatePreference(.alias(pubkey: contact.targetPubkey, name: normalizedAlias))
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  @discardableResult
  func removeContact(
    _ contact: ContactEntity,
    timeoutSeconds: TimeInterval = RelayMutationDefaults.timeoutSeconds,
    pollIntervalSeconds: TimeInterval = RelayMutationDefaults.pollIntervalSeconds
  ) async -> Bool {
    guard let ownerPubkey = identityService.pubkeyHex else {
      composeError = "you're signed out. sign in to manage contacts."
      return false
    }
    guard contact.ownerPubkey == ownerPubkey else {
      composeError = "this contact belongs to a different account."
      return false
    }

    let nextFollowedPubkeys: [String]
    do {
      nextFollowedPubkeys = try updatedFollowedPubkeys(
        ownerPubkey: ownerPubkey
      ) { followedPubkeys in
        followedPubkeys.remove(contact.targetPubkey)
      }
    } catch {
      report(error: error)
      return false
    }

    do {
      try await prepareRelayMutationIfNeeded(
        timeoutSeconds: timeoutSeconds,
        pollIntervalSeconds: pollIntervalSeconds
      )
      if isRelayPublicationEnabledForCurrentProcess() {
        _ = try await publishFollowListAwaitingRelayAcceptance(
          followedPubkeyHexes: nextFollowedPubkeys
        )
      }
    } catch MutationPreparationError.relayBlocked {
      return false
    } catch {
      report(error: error)
      return false
    }

    guard let keypair = identityService.keypair, keypair.publicKey.hex == ownerPubkey else { return false }
    do {
      try privatePreferenceStore.save(.alias(pubkey: contact.targetPubkey, name: nil), keypair: keypair)
      defer { schedulePrivatePreferenceSync() }
      try persistLocalFollowedPubkeys(
        ownerPubkey: ownerPubkey,
        followedPubkeys: nextFollowedPubkeys
      )
      composeError = nil
      return true
    } catch {
      report(error: error)
      return false
    }
  }

  // MARK: - Follow List State

  func publishFollowListAwaitingRelayAcceptance(followedPubkeyHexes: [String]) async throws
    -> String {
    if let publishFollowListOverride = testingOverrides.publishFollowList {
      return try await publishFollowListOverride(followedPubkeyHexes)
    }
    return try await nostrService.publishFollowListAwaitingRelayAcceptance(
      followedPubkeyHexes: followedPubkeyHexes
    )
  }

  func updatedFollowedPubkeys(
    ownerPubkey: String,
    mutating mutation: (inout Set<String>) -> Void
  ) throws -> [String] {
    var followedPubkeys = Set(try contactStore.followedPubkeys(ownerPubkey: ownerPubkey))
    mutation(&followedPubkeys)
    return followedPubkeys.sorted()
  }

  func persistLocalFollowedPubkeys(
    ownerPubkey: String,
    followedPubkeys: [String],
    aliasMutation: (() throws -> Void)? = nil
  ) throws {
    try applyFollowListState(
      ownerPubkey: ownerPubkey,
      followedPubkeys: followedPubkeys,
      createdAt: Date.now,
      eventID: nil,
      aliasMutation: aliasMutation
    )
  }

  func applyFollowListState(
    ownerPubkey: String,
    followedPubkeys: [String],
    createdAt: Date,
    eventID: String?,
    aliasMutation: (() throws -> Void)? = nil
  ) throws {
    try contactStore.replaceFollowedPubkeys(
      ownerPubkey: ownerPubkey,
      pubkeyHexes: followedPubkeys,
      knownProfiles: remoteProfilesByPubkey
    )
    try restorePrivatePreferences()
    try aliasMutation?()
    latestAppliedFollowListCreatedAt = createdAt
    latestAppliedFollowListEventID = eventID
    persistFollowListState(ownerPubkey: ownerPubkey, createdAt: createdAt, eventID: eventID)
  }

  func persistIncomingFollowList(_ incoming: ReceivedFollowList) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    guard incoming.authorPubkey == ownerPubkey else { return }
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(incoming.eventID)

    if !NostrValueNormalizer.shouldApplyStateUpdate(
      currentUpdatedAt: latestAppliedFollowListCreatedAt,
      currentEventID: latestAppliedFollowListEventID,
      incomingUpdatedAt: incoming.createdAt,
      incomingEventID: normalizedEventID
    ) {
      return
    }

    do {
      try applyFollowListState(
        ownerPubkey: ownerPubkey,
        followedPubkeys: incoming.followedPubkeys,
        createdAt: incoming.createdAt,
        eventID: normalizedEventID
      )
    } catch {
      report(error: error)
    }
  }

  func resetFollowListStateInMemory() {
    latestAppliedFollowListCreatedAt = nil
    latestAppliedFollowListEventID = nil
  }

  func loadPersistedFollowListState(ownerPubkey: String) {
    do {
      let watermark = try accountStateStore.followListWatermark(ownerPubkey: ownerPubkey)
      latestAppliedFollowListCreatedAt = watermark.createdAt
      latestAppliedFollowListEventID = NostrValueNormalizer.normalizedEventID(watermark.eventID)
    } catch {
      resetFollowListStateInMemory()
    }
  }

  func persistFollowListState(ownerPubkey: String, createdAt: Date, eventID: String?) {
    do {
      try accountStateStore.setFollowListWatermark(
        ownerPubkey: ownerPubkey,
        createdAt: createdAt,
        eventID: NostrValueNormalizer.normalizedEventID(eventID)
      )
    } catch {
      report(error: error)
    }
  }
}
