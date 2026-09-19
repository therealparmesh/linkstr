import Foundation
import NostrSDK

extension AppSession {
  func shouldApplyFollowList(_ incoming: ReceivedFollowList) -> Bool {
    NostrValueNormalizer.shouldApplyReplaceableEvent(
      currentUpdatedAt: latestAppliedFollowListCreatedAt,
      currentEventID: latestAppliedFollowListEventID,
      incomingUpdatedAt: incoming.createdAt, incomingEventID: incoming.eventID
    )
  }

  func applyFollowListState(_ incoming: ReceivedFollowList, aliasChange: PrivatePreference? = nil)
    throws {
    guard let keypair = identityService.keypair, keypair.publicKey.hex == incoming.authorPubkey
    else { return }
    // Save unrelated changes first so rollback only affects this follow-list update.
    try modelContext.save()
    do {
      if let aliasChange {
        try privatePreferenceStore.save(aliasChange, keypair: keypair, saveImmediately: false)
      }
      let added = try contactStore.replaceFollowedPubkeys(
        ownerPubkey: incoming.authorPubkey, pubkeyHexes: incoming.followedPubkeys,
        knownProfiles: remoteProfilesByPubkey, save: false
      )
      for contact in added {
        if let record = try privatePreferenceStore.record(
          for: .alias(pubkey: contact.targetPubkey, name: nil), keypair: keypair
        ),
          case .alias(_, let name) = try PrivatePreferenceCodec().preference(
            from: record.event(), keypair: keypair) {
          try contact.updateAlias(name)
        }
      }
      if let aliasChange, case .alias(let pubkey, let name) = aliasChange,
        let contact = try contactStore.contact(
          ownerPubkey: incoming.authorPubkey, targetPubkey: pubkey) {
        try contact.updateAlias(name)
      }
      try accountStateStore.stageFollowListState(
        ownerPubkey: incoming.authorPubkey, createdAt: incoming.createdAt,
        eventID: incoming.eventID, tags: incoming.tags
      )
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    latestAppliedFollowListCreatedAt = incoming.createdAt
    latestAppliedFollowListEventID = incoming.eventID
    if aliasChange != nil { schedulePrivatePreferenceSync() }
  }

  func persistIncomingFollowList(_ incoming: ReceivedFollowList) {
    guard incoming.authorPubkey == identityService.pubkeyHex else { return }
    // Replaying the current event also restores tag metadata absent in older local stores.
    let isCurrent = latestAppliedFollowListEventID == incoming.eventID
      && latestAppliedFollowListCreatedAt == incoming.createdAt
    guard isCurrent || shouldApplyFollowList(incoming) else { return }
    do {
      try applyFollowListState(incoming)
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
      latestAppliedFollowListEventID = watermark.eventID
    } catch {
      resetFollowListStateInMemory()
    }
  }
}
