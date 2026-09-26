import NostrSDK
import XCTest

@testable import linkstr

@MainActor
final class NostrEventValidationTests: XCTestCase {
  func testPublishedPayloadsRoundTripForRecipientsAndSenderInLiveAndHistoricalDelivery() async throws {
    let sender = try XCTUnwrap(Keypair())
    let recipients = try (0..<2).map { _ in try XCTUnwrap(Keypair()) }
    let publishing = NostrDMService()
    publishing.keypair = sender
    var wrapperAuthors = Set<String>()

    for kind in NostrEventTestSupport.payloadKinds {
      let payload = NostrEventTestSupport.payload(
        kind, members: [sender.publicKey.hex] + recipients.map { $0.publicKey.hex })
      for includesSender in [false, true] {
        let targets = includesSender ? recipients + [sender] : recipients
        let events = try publishing.buildRumorAndGiftWrapEvents(
          payload: payload, recipientPubkeyHexes: targets.map { $0.publicKey.hex })
        XCTAssertEqual(events.giftWrapForRecipients.count, targets.count)
        XCTAssertEqual(events.giftWrapForSender == nil, includesSender)
        let wraps = events.giftWrapForRecipients + (events.giftWrapForSender.map { [$0] } ?? [])
        XCTAssertEqual(wraps.count, recipients.count + 1)

        for (recipient, wrap) in zip(recipients + [sender], wraps) {
          XCTAssertTrue(wrapperAuthors.insert(wrap.pubkey).inserted)
          try assertValidPublishedGiftWrap(wrap, sender: sender, recipient: recipient, rumorID: events.rumorEvent.id)
          for subscriptionID in ["live", "linkstr-backfill-compatibility"] {
            let receiving = NostrDMService()
            receiving.keypair = recipient
            var received: [ReceivedDirectMessage] = []
            receiving.onIncoming = { received.append($0) }
            try await NostrEventTestSupport.deliver(wrap, to: receiving, subscriptionID: subscriptionID)

            XCTAssertEqual(received.count, 1, "\(kind): \(subscriptionID)")
            XCTAssertEqual(received.first?.payload, payload)
            XCTAssertEqual(received.first?.senderPubkey, sender.publicKey.hex)
            XCTAssertEqual(received.first?.eventID, events.rumorEvent.id)
            XCTAssertEqual(received.first?.source, subscriptionID == "live" ? .live : .historical)
          }
        }
      }
    }
  }

  private func assertValidPublishedGiftWrap(
    _ event: NostrEvent, sender: Keypair, recipient: Keypair, rumorID: String
  ) throws {
    let verifier = NostrEventTestSupport()
    let wrap = try XCTUnwrap(event as? GiftWrapEvent)
    XCTAssertEqual(wrap.kind, .giftWrap)
    XCTAssertEqual(wrap.referencedPubkeys, [recipient.publicKey.hex])
    XCTAssertNotEqual(wrap.pubkey, sender.publicKey.hex)
    try verifier.verifyEvent(wrap)
    let seal = try wrap.unwrappedSeal(using: recipient.privateKey)
    try verifier.verifyEvent(seal)
    XCTAssertEqual(seal.kind, .seal)
    XCTAssertTrue(seal.tags.isEmpty)
    XCTAssertEqual(seal.pubkey, sender.publicKey.hex)
    let rumor = try seal.unsealedRumor(using: recipient.privateKey)
    XCTAssertTrue(rumor.isRumor)
    XCTAssertEqual(rumor.pubkey, seal.pubkey)
    XCTAssertEqual(rumor.id, rumor.calculatedId)
    XCTAssertEqual(rumor.id, rumorID)
  }

  func testGiftWrapRejectsInvalidEventIntegrityBeforeDeduplication() async throws {
    let service = NostrDMService()
    let sender = try XCTUnwrap(Keypair())
    let recipient = try XCTUnwrap(Keypair())
    service.keypair = recipient
    let payload = LinkstrPayload(
      conversationID: "session", rootID: "post", kind: .root,
      url: "https://example.com", note: nil, timestamp: 100)
    let content = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
    let rumor = NostrEvent.Builder<NostrEvent>(kind: service.linkstrRumorKind)
      .content(content).build(pubkey: sender.publicKey)
    let seal = try service.seal(withRumor: rumor, toRecipient: recipient.publicKey, signedBy: sender)
    let valid = try service.giftWrap(withSeal: seal, toRecipient: recipient.publicKey)
    let invalidOuter: GiftWrapEvent = try NostrEventTestSupport.changing(
      valid, field: "sig", to: String(repeating: "0", count: 128))
    let invalidSeal: SealEvent = try NostrEventTestSupport.changing(
      seal, field: "sig", to: String(repeating: "0", count: 128))
    let invalidSealed = try service.giftWrap(withSeal: invalidSeal, toRecipient: recipient.publicKey)
    let invalidIDRumor: NostrEvent = try NostrEventTestSupport.changing(
      rumor, field: "id", to: String(repeating: "0", count: 64))
    let invalidID = try service.giftWrap(
      withRumor: invalidIDRumor, toRecipient: recipient.publicKey, signedBy: sender)
    var received: [ReceivedDirectMessage] = []
    service.onIncoming = { received.append($0) }

    for invalid in [invalidOuter, invalidSealed, invalidID] {
      try await NostrEventTestSupport.deliver(invalid, to: service)
      XCTAssertTrue(received.isEmpty)
    }
    try await NostrEventTestSupport.deliver(valid, to: service)
    try await NostrEventTestSupport.deliver(valid, to: service)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?.senderPubkey, sender.publicKey.hex)
    XCTAssertEqual(received.first?.eventID, rumor.id)
  }

  func testImpersonationIsRejectedForEveryPayloadBeforeItCanPoisonLegitimateDelivery() async throws {
    let sender = try XCTUnwrap(Keypair())
    let attacker = try XCTUnwrap(Keypair())
    let recipient = try XCTUnwrap(Keypair())
    for kind in NostrEventTestSupport.payloadKinds {
      let payload = NostrEventTestSupport.payload(kind, members: [sender.publicKey.hex, recipient.publicKey.hex])
      let rumor = try NostrEventTestSupport.rumor(payload, author: sender.publicKey)
      for subscriptionID in ["live", "linkstr-backfill-security"] {
        let service = NostrDMService()
        service.keypair = recipient
        var received: [ReceivedDirectMessage] = []
        service.onIncoming = { received.append($0) }
        let forged = try service.giftWrap(
          withRumor: rumor, toRecipient: recipient.publicKey, signedBy: attacker)
        // Both signatures and encryption are valid; only the claimed inner author is forged.
        try NostrEventTestSupport().verifyEvent(forged)
        try NostrEventTestSupport().verifyEvent(forged.unwrappedSeal(using: recipient.privateKey))
        XCTAssertEqual(try forged.unsealedRumor(using: recipient.privateKey)?.pubkey, sender.publicKey.hex)
        try await NostrEventTestSupport.deliver(forged, to: service, subscriptionID: subscriptionID)
        XCTAssertTrue(received.isEmpty, "\(kind): \(subscriptionID)")
        XCTAssertTrue(service.processedEventIDs.isEmpty)
        XCTAssertTrue(service.processedGiftWrapEventIDs.isEmpty)

        let valid = try service.giftWrap(withRumor: rumor, toRecipient: recipient.publicKey, signedBy: sender)
        try await NostrEventTestSupport.deliver(valid, to: service, subscriptionID: subscriptionID)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.senderPubkey, sender.publicKey.hex)
      }
    }
  }

  func testNIP59RejectsSignedRumorsAndTaggedSealsWithoutRestrictingOuterTags() async throws {
    let service = NostrDMService()
    let sender = try XCTUnwrap(Keypair())
    let recipient = try XCTUnwrap(Keypair())
    service.keypair = recipient
    let payload = NostrEventTestSupport.payload(.root, members: [])
    let rumor = try NostrEventTestSupport.rumor(payload, author: sender.publicKey)
    let signedRumor = try NostrEvent.Builder<NostrEvent>(kind: service.linkstrRumorKind)
      .content(rumor.content).build(signedBy: sender)
    let signedContent = try XCTUnwrap(String(data: JSONEncoder().encode(signedRumor), encoding: .utf8))
    let signedRumorSeal = try SealEvent(
      content: service.encrypt(
        plaintext: signedContent, privateKeyA: sender.privateKey, publicKeyB: recipient.publicKey), signedBy: sender)
    let validSeal = try service.seal(withRumor: rumor, toRecipient: recipient.publicKey, signedBy: sender)
    let tag = try JSONDecoder().decode(Tag.self, from: Data("[\"alt\",\"private message\"]".utf8))
    let taggedSeal = try SealEvent(content: validSeal.content, tags: [tag], signedBy: sender)
    var received: [ReceivedDirectMessage] = []
    service.onIncoming = { received.append($0) }
    for invalidSeal in [signedRumorSeal, taggedSeal] {
      try NostrEventTestSupport().verifyEvent(invalidSeal)
      try await NostrEventTestSupport.deliver(
        service.giftWrap(withSeal: invalidSeal, toRecipient: recipient.publicKey), to: service)
    }
    XCTAssertTrue(received.isEmpty)
    let valid = try service.giftWrap(withSeal: validSeal, toRecipient: recipient.publicKey, tags: [tag], createdAt: 1)
    try await NostrEventTestSupport.deliver(valid, to: service)
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first?.createdAt, rumor.createdDate)
  }

  func testInvalidPublicEventsCannotReachCallbacksOrSuppressValidEvents() async throws {
    let service = NostrDMService()
    let owner = try XCTUnwrap(Keypair())
    let other = try XCTUnwrap(Keypair())
    service.keypair = owner
    var follows: [ReceivedFollowList] = []
    var profiles: [ReceivedProfileMetadata] = []
    var preferences: [NostrEvent] = []
    service.onFollowList = { follows.append($0) }
    service.onProfileMetadata = { profiles.append($0) }
    service.onPrivatePreference = { preferences.append($0) }
    let follow = try service.followList(withPubkeys: [other.publicKey.hex], signedBy: owner)
    let profile = try NostrEvent.Builder<NostrEvent>(kind: .metadata)
      .content("{\"name\":\"friend\"}").build(signedBy: other)
    let preference = try PrivatePreferenceCodec().event(
      for: .archive(sessionID: "session", archived: true), keypair: owner, createdAt: 100)
    for event in [follow, profile, preference] {
      let invalid = try NostrEventTestSupport.changing(event, field: "sig", to: String(repeating: "0", count: 128))
      try await NostrEventTestSupport.deliver(invalid, to: service)
    }
    XCTAssertTrue(follows.isEmpty && profiles.isEmpty && preferences.isEmpty)
    XCTAssertTrue(service.processedEventIDs.isEmpty)
    for event in [follow, profile, preference] { try await NostrEventTestSupport.deliver(event, to: service) }
    try await NostrEventTestSupport.deliver(
      service.followList(withPubkeys: [owner.publicKey.hex], signedBy: other), to: service)
    XCTAssertEqual(follows.map(\.eventID), [follow.id])
    XCTAssertEqual(profiles.map(\.eventID), [profile.id])
    XCTAssertEqual(preferences.map(\.id), [preference.id])
  }

  func testBackfillCountsValidDuplicateEnvelopesWithoutIngestingDuplicates() async throws {
    let service = NostrDMService()
    let recipient = try XCTUnwrap(Keypair())
    let sender = try XCTUnwrap(Keypair())
    service.keypair = recipient
    let subscriptionID = "linkstr-backfill-security"
    service.activeBackfillStates[subscriptionID] = NostrDMService.BackfillState(
      kind: .recipient, page: 0, until: nil, pageSize: 500, expectedRelayURLs: ["relay"])
    var received: [ReceivedDirectMessage] = []
    service.onIncoming = { received.append($0) }
    let payload = NostrEventTestSupport.payload(.root, members: [])
    let rumor = try NostrEventTestSupport.rumor(payload, author: sender.publicKey)
    let wrap = try service.giftWrap(withRumor: rumor, toRecipient: recipient.publicKey, signedBy: sender)
    let invalid = try NostrEventTestSupport.changing(wrap, field: "sig", to: String(repeating: "0", count: 128))
    try await NostrEventTestSupport.deliver(invalid, to: service, subscriptionID: subscriptionID)
    XCTAssertEqual(service.activeBackfillStates[subscriptionID]?.receivedGiftWrapCount, 0)
    XCTAssertNil(service.activeBackfillStates[subscriptionID]?.oldestCreatedAt)
    for _ in 0..<2 { try await NostrEventTestSupport.deliver(wrap, to: service, subscriptionID: subscriptionID) }
    XCTAssertEqual(service.activeBackfillStates[subscriptionID]?.receivedGiftWrapCount, 2)
    XCTAssertEqual(service.activeBackfillStates[subscriptionID]?.oldestCreatedAt, wrap.createdAt)
    XCTAssertEqual(received.count, 1)
  }

  func testFailedProfileRelayDoesNotDiscardOtherRelayResponses() {
    let service = NostrDMService()
    let requestID = UUID()
    service.profileQueries["query"] = NostrDMService.ProfileQuery(
      requestID: requestID, expectedRelays: ["first", "second"])
    var completion: Bool?
    service.onProfileLookupComplete = { completedID, completed in
      XCTAssertEqual(completedID, requestID)
      completion = completed
    }

    service.completeProfileQuery(relayURL: "first", subscriptionID: "query", failed: true)
    XCTAssertNil(completion)
    XCTAssertNotNil(service.profileQueries["query"])
    service.completeProfileQuery(relayURL: "second", subscriptionID: "query")
    XCTAssertEqual(completion, false)
    XCTAssertNil(service.profileQueries["query"])
  }

}
