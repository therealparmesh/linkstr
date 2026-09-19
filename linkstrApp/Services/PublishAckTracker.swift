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
    var pendingRelayURLs: Set<String>
    var rejectionMessage: String?
  }

  private struct BatchState {
    let expectedRelayURLs: Set<String>
    var eventStates: [String: EventState]
  }

  private var batchStateByID: [UUID: BatchState] = [:]

  mutating func registerBatch(eventIDs: [String], expectedRelayURLs: Set<String>) -> UUID {
    let batchID = UUID()
    let eventState = EventState(pendingRelayURLs: expectedRelayURLs)
    batchStateByID[batchID] = BatchState(
      expectedRelayURLs: expectedRelayURLs,
      eventStates: Dictionary(uniqueKeysWithValues: Set(eventIDs).map { ($0, eventState) })
    )
    return batchID
  }

  mutating func acknowledge(
    relayURL: String,
    eventID: String,
    success: Bool,
    message: String
  ) -> [PublishAckCompletion] {
    var completions: [PublishAckCompletion] = []
    for batchID in Array(batchStateByID.keys) {
      guard var batchState = batchStateByID[batchID],
        var eventState = batchState.eventStates[eventID],
        batchState.expectedRelayURLs.contains(relayURL)
      else { continue }

      if success {
        batchState.eventStates.removeValue(forKey: eventID)
        if batchState.eventStates.isEmpty {
          batchStateByID.removeValue(forKey: batchID)
          completions.append(PublishAckCompletion(batchID: batchID, outcome: .succeeded))
          continue
        }
      } else {
        guard eventState.pendingRelayURLs.remove(relayURL) != nil else { continue }
        if eventState.pendingRelayURLs.isEmpty {
          batchStateByID.removeValue(forKey: batchID)
          completions.append(PublishAckCompletion(batchID: batchID, outcome: .failed(message)))
          continue
        }
        eventState.rejectionMessage = message
        batchState.eventStates[eventID] = eventState
      }
      batchStateByID[batchID] = batchState
    }
    return completions
  }

  mutating func pruneRelay(_ relayURL: String) -> [PublishAckCompletion] {
    var completions: [PublishAckCompletion] = []

    for batchID in Array(batchStateByID.keys) {
      guard var batchState = batchStateByID[batchID] else { continue }

      var failedBatch = false
      for eventID in Array(batchState.eventStates.keys) {
        guard var eventState = batchState.eventStates[eventID] else { continue }
        guard eventState.pendingRelayURLs.remove(relayURL) != nil else { continue }

        if eventState.pendingRelayURLs.isEmpty {
          let failureMessage =
            eventState.rejectionMessage ?? "relay connection dropped."
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
    batchStateByID.removeValue(forKey: batchID)
  }

  mutating func cancelAll() -> [UUID] {
    let batchIDs = Array(batchStateByID.keys)
    batchStateByID.removeAll()
    return batchIDs
  }
}
