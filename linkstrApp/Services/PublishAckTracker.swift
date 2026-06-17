import Foundation

struct PublishAckCompletion: Equatable {
  enum Outcome: Equatable {
    case succeeded
    case failed(String)
  }

  let batchID: UUID
  let outcome: Outcome
}

struct PublishAckTracker {
  private struct EventState {
    var expectedRelayURLs: Set<String>
    var failedRelayMessagesByURL: [String: String]
  }

  private struct BatchState {
    var eventStates: [String: EventState]
  }

  private var batchStateByID: [UUID: BatchState] = [:]
  private var batchIDByEventID: [String: UUID] = [:]

  mutating func registerBatch(eventIDs: [String], expectedRelayURLs: Set<String>) -> UUID {
    let normalizedEventIDs = Array(Set(eventIDs)).sorted()
    let batchID = UUID()
    let eventState = EventState(
      expectedRelayURLs: expectedRelayURLs,
      failedRelayMessagesByURL: [:]
    )
    batchStateByID[batchID] = BatchState(
      eventStates: Dictionary(uniqueKeysWithValues: normalizedEventIDs.map { ($0, eventState) })
    )
    for eventID in normalizedEventIDs {
      batchIDByEventID[eventID] = batchID
    }
    return batchID
  }

  mutating func acknowledge(
    relayURL: String,
    eventID: String,
    success: Bool,
    message: String
  ) -> PublishAckCompletion? {
    guard let batchID = batchIDByEventID[eventID], var batchState = batchStateByID[batchID],
      var eventState = batchState.eventStates[eventID]
    else {
      return nil
    }

    if success {
      batchState.eventStates.removeValue(forKey: eventID)
      batchIDByEventID.removeValue(forKey: eventID)
      if batchState.eventStates.isEmpty {
        batchStateByID.removeValue(forKey: batchID)
        return PublishAckCompletion(batchID: batchID, outcome: .succeeded)
      }
      batchStateByID[batchID] = batchState
      return nil
    }

    eventState.failedRelayMessagesByURL[relayURL] = message
    eventState.expectedRelayURLs.remove(relayURL)
    if eventState.expectedRelayURLs.isEmpty {
      let failureMessage =
        eventState.failedRelayMessagesByURL.values.first ?? "relays rejected this message."
      removeBatch(batchID)
      return PublishAckCompletion(batchID: batchID, outcome: .failed(failureMessage))
    }

    batchState.eventStates[eventID] = eventState
    batchStateByID[batchID] = batchState
    return nil
  }

  mutating func pruneRelay(_ relayURL: String) -> [PublishAckCompletion] {
    var completions: [PublishAckCompletion] = []

    for batchID in Array(batchStateByID.keys) {
      guard var batchState = batchStateByID[batchID] else { continue }

      var failedBatch = false
      for eventID in Array(batchState.eventStates.keys) {
        guard var eventState = batchState.eventStates[eventID] else { continue }
        guard eventState.expectedRelayURLs.remove(relayURL) != nil else { continue }

        if eventState.expectedRelayURLs.isEmpty {
          let failureMessage =
            eventState.failedRelayMessagesByURL.values.first ?? "relay connection dropped."
          removeBatch(batchID)
          completions.append(
            PublishAckCompletion(batchID: batchID, outcome: .failed(failureMessage))
          )
          failedBatch = true
          break
        }

        batchState.eventStates[eventID] = eventState
      }

      if !failedBatch {
        batchStateByID[batchID] = batchState
      }
    }

    return completions
  }

  mutating func removeBatch(_ batchID: UUID) {
    guard let batchState = batchStateByID.removeValue(forKey: batchID) else { return }
    for eventID in batchState.eventStates.keys {
      batchIDByEventID.removeValue(forKey: eventID)
    }
  }

  mutating func cancelAll() -> [UUID] {
    let batchIDs = Array(batchStateByID.keys)
    batchStateByID.removeAll()
    batchIDByEventID.removeAll()
    return batchIDs
  }
}
