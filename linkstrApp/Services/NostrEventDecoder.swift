import Foundation
import NostrSDK

/// Cryptographic validation runs away from the main actor; persistence stays on the main actor.
actor NostrEventDecoder: EventVerifying {
  struct DecodedEvent {
    let message: ReceivedDirectMessage?
  }

  func isValid(_ event: NostrEvent) -> Bool {
    (try? verifyEvent(event)) != nil
  }

  func decode(
    _ event: NostrEvent, keypair: Keypair, source: DirectMessageIngestSource, skipGiftWrap: Bool
  ) -> DecodedEvent? {
    guard isValid(event) else { return nil }
    guard !skipGiftWrap, let wrapped = event as? GiftWrapEvent else {
      return DecodedEvent(message: nil)
    }
    // NIP-59 authenticates the sender through the seal; decryption alone does not verify authorship.
    guard let seal = try? wrapped.unwrappedSeal(using: keypair.privateKey),
      seal.kind == .seal, seal.tags.isEmpty, isValid(seal),
      let rumor = try? seal.unsealedRumor(using: keypair.privateKey),
      rumor.isRumor, rumor.pubkey == seal.pubkey, rumor.id == rumor.calculatedId,
      rumor.kind == .unknown(44_001),
      let data = rumor.content.data(using: .utf8),
      let payload = try? JSONDecoder().decode(LinkstrPayload.self, from: data),
      (try? payload.validated()) != nil
    else { return DecodedEvent(message: nil) }
    return DecodedEvent(message: ReceivedDirectMessage(
      eventID: rumor.id, transportEventID: wrapped.id, senderPubkey: seal.pubkey,
      payload: payload, createdAt: rumor.createdDate, source: source
    ))
  }

  func preferences(from events: [NostrEvent], keypair: Keypair) throws -> [PrivatePreference] {
    try events.map { event in
      try Task.checkCancellation()
      return try preference(from: event, keypair: keypair)
    }
  }

  func preferenceEvent(
    for preference: PrivatePreference, keypair: Keypair, createdAt: Int64
  ) throws -> NostrEvent {
    try PrivatePreferenceCodec().event(for: preference, keypair: keypair, createdAt: createdAt)
  }

  func preference(from event: NostrEvent, keypair: Keypair) throws -> PrivatePreference {
    guard let preference = try? PrivatePreferenceCodec().preference(from: event, keypair: keypair) else {
      throw PrivatePreferenceError.invalidEvent
    }
    return preference
  }
}
