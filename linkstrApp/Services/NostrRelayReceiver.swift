import NostrSDK

/// Events and EOSE share one queue so completion cannot overtake validation and persistence.
final class NostrRelayReceiver: RelayDelegate {
  enum Input {
    case state(Relay, Relay.State)
    case response(Relay, RelayResponse)
  }

  let stream: AsyncStream<Input>
  private let continuation: AsyncStream<Input>.Continuation

  private let onControlResponse: (Relay, RelayResponse) -> Void

  init(onControlResponse: @escaping (Relay, RelayResponse) -> Void) {
    self.onControlResponse = onControlResponse
    (stream, continuation) = AsyncStream.makeStream(of: Input.self)
  }

  func finish() {
    continuation.finish()
  }

  deinit {
    continuation.finish()
  }

  func relayStateDidChange(_ relay: Relay, state: Relay.State) {
    continuation.yield(.state(relay, state))
  }

  func relay(_ relay: Relay, didReceive response: RelayResponse) {
    switch response {
    case .ok, .auth:
      // Sending and authentication must not wait for historical messages to finish decrypting.
      onControlResponse(relay, response)
    default:
      continuation.yield(.response(relay, response))
    }
  }

  func relay(_ relay: Relay, didReceive event: RelayEvent) {
    // The raw response above already includes this event.
  }
}
