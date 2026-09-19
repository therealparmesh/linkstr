import Foundation

// MARK: - Identity Resolution

extension AppSession {
  func resolvedIdentity(for contact: ContactEntity) -> LinkstrResolvedIdentity {
    LinkstrResolvedIdentity(
      localAlias: contact.localAlias,
      chosenName: preferredChosenName(for: contact),
      pubkeyHex: contact.targetPubkey, npub: contact.npub
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
    pauseRemoteProfileRequests()
    remoteProfileAttempts.removeAll()
    remoteProfileRetryAfter.removeAll()
    remoteProfilesByPubkey = [:]
    inFlightRemoteProfilePubkeys.removeAll()
    pendingRemoteProfilePubkeys.removeAll()
  }

  func preferredChosenName(for contact: ContactEntity) -> String? {
    let normalizedPubkey =
      NostrValueNormalizer.normalizedPubkeyHex(contact.targetPubkey) ?? contact.targetPubkey
    return (remoteProfilesByPubkey[normalizedPubkey] ?? contact.profileSnapshot)?.chosenName
  }

  func updateRemoteProfileSnapshot(
    pubkeyHex: String,
    chosenName: String?,
    createdAt: Date,
    eventID: String?
  ) {
    guard let ownerPubkey = identityService.pubkeyHex else { return }
    let normalizedPubkey = NostrValueNormalizer.normalizedPubkeyHex(pubkeyHex) ?? pubkeyHex
    let normalizedEventID = NostrValueNormalizer.normalizedEventID(eventID)
    if let existing = remoteProfilesByPubkey[normalizedPubkey],
      !NostrValueNormalizer.shouldApplyReplaceableEvent(
        currentUpdatedAt: existing.updatedAt,
        currentEventID: existing.eventID,
        incomingUpdatedAt: createdAt,
        incomingEventID: normalizedEventID
      ) {
      return
    }
    let profile = KnownProfileSnapshot(
      chosenName: NostrProfileMetadata.normalizedChosenName(chosenName),
      updatedAt: createdAt,
      eventID: normalizedEventID
    )
    do {
      remoteProfilesByPubkey[normalizedPubkey] = try contactStore.updateProfile(
        profile, ownerPubkey: ownerPubkey, targetPubkey: normalizedPubkey
      )
    } catch {
      report(error: error)
      return
    }
    inFlightRemoteProfilePubkeys.remove(normalizedPubkey)
    pendingRemoteProfilePubkeys.remove(normalizedPubkey)
    remoteProfileAttempts.removeValue(forKey: normalizedPubkey)
    remoteProfileRetryAfter.removeValue(forKey: normalizedPubkey)
  }
}

// MARK: - Remote Profile Lookups

extension AppSession {
  func requestRemoteProfilesIfNeeded(pubkeyHexes: [String]) {
    let missing = NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeyHexes).filter {
      remoteProfilesByPubkey[$0] == nil && !inFlightRemoteProfilePubkeys.contains($0)
    }
    pendingRemoteProfilePubkeys.formUnion(missing)
    retryPendingRemoteProfileRequestsIfNeeded()
  }

  func pauseRemoteProfileRequests() {
    remoteProfileLookups.values.forEach { $0.timeout.cancel() }
    remoteProfileLookups.removeAll()
    pendingRemoteProfilePubkeys.formUnion(inFlightRemoteProfilePubkeys)
    inFlightRemoteProfilePubkeys.removeAll()
  }

  func markRemoteProfilesInFlight(_ pubkeyHexes: [String], requestID: UUID) {
    inFlightRemoteProfilePubkeys.formUnion(pubkeyHexes)
    for key in pubkeyHexes { remoteProfileAttempts[key, default: 0] += 1 }
    let attempt = pubkeyHexes.compactMap { remoteProfileAttempts[$0] }.max() ?? 1
    let delay = remoteProfileRetryNanoseconds * UInt64(1 << min(attempt - 1, 2))
    let timeout = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard !Task.isCancelled else { return }
      self?.finishRemoteProfileLookup(requestID, completed: false)
    }
    remoteProfileLookups[requestID] = (pubkeyHexes, timeout)
  }

  func finishRemoteProfileLookup(_ requestID: UUID, completed: Bool) {
    guard let lookup = remoteProfileLookups.removeValue(forKey: requestID) else { return }
    lookup.timeout.cancel()
    for key in lookup.keys where inFlightRemoteProfilePubkeys.contains(key) {
      inFlightRemoteProfilePubkeys.remove(key)
      guard remoteProfilesByPubkey[key] == nil else { continue }
      pendingRemoteProfilePubkeys.insert(key)
      if completed || remoteProfileAttempts[key, default: 0] >= 3 {
        remoteProfileRetryAfter[key] = Date.now.addingTimeInterval(300)
      }
    }
    retryPendingRemoteProfileRequestsIfNeeded()
  }

  var canFetchRemoteProfilesInCurrentProcess: Bool {
    testingOverrides.requestProfileMetadata != nil || shouldFetchMetadataForCurrentProcess()
  }

  func retryPendingRemoteProfileRequestsIfNeeded() {
    guard canFetchRemoteProfilesInCurrentProcess else { return }
    let now = Date.now
    let pending = pendingRemoteProfilePubkeys.filter {
      remoteProfilesByPubkey[$0] == nil && !inFlightRemoteProfilePubkeys.contains($0)
        && (remoteProfileRetryAfter[$0] ?? .distantPast) <= now
    }.sorted()
    let available = max(0, 2 - remoteProfileLookups.count) * 50
    let ready = Array(pending.prefix(available))
    for offset in stride(from: 0, to: ready.count, by: 50) {
      let keys = Array(ready[offset..<min(offset + 50, ready.count)])
      for key in keys where remoteProfileRetryAfter[key] != nil {
        remoteProfileAttempts.removeValue(forKey: key)
        remoteProfileRetryAfter.removeValue(forKey: key)
      }
      let requestID = UUID()
      let didRequest = testingOverrides.requestProfileMetadata?(keys)
        ?? nostrService.requestProfileMetadata(pubkeyHexes: keys, requestID: requestID)
      guard didRequest else { return }
      pendingRemoteProfilePubkeys.subtract(keys)
      markRemoteProfilesInFlight(keys, requestID: requestID)
    }
  }
}
