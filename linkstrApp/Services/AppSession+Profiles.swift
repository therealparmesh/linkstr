import Foundation

// MARK: - Identity Resolution

extension AppSession {
  func resolvedIdentity(for contact: ContactEntity) -> LinkstrResolvedIdentity {
    LinkstrResolvedIdentity(
      localAlias: contact.localAlias,
      chosenName: preferredChosenName(for: contact),
      pubkeyHex: contact.targetPubkey
    )
  }

  func resolvedIdentity(for pubkeyHex: String, contacts: [ContactEntity]) -> LinkstrResolvedIdentity {
    let normalizedPubkey = NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
    if let contact = contacts.first(where: { $0.targetPubkey == normalizedPubkey }) {
      return resolvedIdentity(for: contact)
    }
    return LinkstrResolvedIdentity(
      localAlias: nil,
      chosenName: remoteProfilesByPubkey[normalizedPubkey]?.chosenName,
      pubkeyHex: normalizedPubkey
    )
  }

  func displayName(for pubkeyHex: String, contacts: [ContactEntity]) -> String {
    resolvedIdentity(for: pubkeyHex, contacts: contacts).displayName
  }

  func searchableNames(for contact: ContactEntity) -> [String] {
    var names: [String] = []
    if let localAlias = contact.localAlias {
      names.append(localAlias)
    }
    if let chosenName = preferredChosenName(for: contact),
      names.contains(where: { $0.localizedCaseInsensitiveCompare(chosenName) == .orderedSame })
        == false {
      names.append(chosenName)
    }
    return names
  }
}

// MARK: - Remote Profile State

extension AppSession {
  func resetRemoteProfileStateInMemory() {
    remoteProfileLookupGeneration += 1
    remoteProfilesByPubkey = [:]
    inFlightRemoteProfilePubkeys.removeAll()
    pendingRemoteProfilePubkeys.removeAll()
  }

  func preferredChosenName(for contact: ContactEntity) -> String? {
    let normalizedPubkey =
      NostrValueNormalizer.normalizedPubkeyHex(contact.targetPubkey) ?? contact.targetPubkey
    return remoteProfilesByPubkey[normalizedPubkey]?.chosenName
  }

  func updateRemoteProfileSnapshot(
    pubkeyHex: String,
    chosenName: String?,
    createdAt: Date,
    eventID: String?
  ) {
    let normalizedPubkey = NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    if let existing = remoteProfilesByPubkey[normalizedPubkey],
      !NostrValueNormalizer.shouldApplyStateUpdate(
        currentUpdatedAt: existing.updatedAt,
        currentEventID: existing.eventID,
        incomingUpdatedAt: createdAt,
        incomingEventID: normalizedEventID
      ) {
      return
    }
    remoteProfilesByPubkey[normalizedPubkey] = KnownProfileSnapshot(
      chosenName: NostrProfileMetadata.normalizedChosenName(chosenName),
      updatedAt: createdAt,
      eventID: normalizedEventID
    )
    inFlightRemoteProfilePubkeys.remove(normalizedPubkey)
    pendingRemoteProfilePubkeys.remove(normalizedPubkey)
  }
}

// MARK: - Remote Profile Lookups

extension AppSession {
  func requestRemoteProfilesIfNeeded(pubkeyHexes: [String]) {
    let missingPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes).filter {
      remoteProfilesByPubkey[$0] == nil && inFlightRemoteProfilePubkeys.contains($0) == false
    }
    guard !missingPubkeys.isEmpty else { return }
    guard canFetchRemoteProfilesInCurrentProcess else { return }
    submitRemoteProfileLookupIfPossible(missingPubkeys)
  }

  func markRemoteProfilesInFlight(_ pubkeyHexes: [String]) {
    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes)
    guard !normalizedPubkeys.isEmpty else { return }
    inFlightRemoteProfilePubkeys.formUnion(normalizedPubkeys)
    let retryDelayNanoseconds = remoteProfileRetryNanoseconds
    let generation = remoteProfileLookupGeneration
    Task { [weak self, normalizedPubkeys] in
      try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self, normalizedPubkeys] in
        guard let self else { return }
        guard self.remoteProfileLookupGeneration == generation else { return }
        self.inFlightRemoteProfilePubkeys.subtract(normalizedPubkeys)
        let unresolvedPubkeys = normalizedPubkeys.filter { self.remoteProfilesByPubkey[$0] == nil }
        guard !unresolvedPubkeys.isEmpty else { return }
        self.pendingRemoteProfilePubkeys.formUnion(unresolvedPubkeys)
        self.retryPendingRemoteProfileRequestsIfNeeded()
      }
    }
  }

  var canFetchRemoteProfilesInCurrentProcess: Bool {
    testingOverrides.requestProfileMetadata != nil || shouldFetchMetadataForCurrentProcess()
  }

  func submitRemoteProfileLookupIfPossible(_ pubkeyHexes: [String]) {
    let normalizedPubkeys = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes).filter {
      remoteProfilesByPubkey[$0] == nil
    }
    guard !normalizedPubkeys.isEmpty else { return }

    let didRequest: Bool
    if let requestProfileMetadata = testingOverrides.requestProfileMetadata {
      didRequest = requestProfileMetadata(normalizedPubkeys)
    } else {
      didRequest = nostrService.requestProfileMetadata(pubkeyHexes: normalizedPubkeys)
    }

    if didRequest {
      pendingRemoteProfilePubkeys.subtract(normalizedPubkeys)
      markRemoteProfilesInFlight(normalizedPubkeys)
    } else {
      pendingRemoteProfilePubkeys.formUnion(normalizedPubkeys)
    }
  }

  func retryPendingRemoteProfileRequestsIfNeeded() {
    guard canFetchRemoteProfilesInCurrentProcess else { return }
    let pendingPubkeys = pendingRemoteProfilePubkeys.filter {
      remoteProfilesByPubkey[$0] == nil && inFlightRemoteProfilePubkeys.contains($0) == false
    }
    guard !pendingPubkeys.isEmpty else { return }
    submitRemoteProfileLookupIfPossible(Array(pendingPubkeys))
  }
}
