import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

extension AppSessionIngestTests {
  private struct AuthenticatedSessionFixture {
    let session: AppSession
    let container: ModelContainer
    let creator: Keypair
    let attacker: Keypair
  }

  func testForgedMembershipCannotChangeFutureMessageRecipients() async throws {
    let fixture = try await makeAuthenticatedSession()
    let session = fixture.session
    let container = fixture.container
    let creator = fixture.creator
    let attacker = fixture.attacker
    defer { withExtendedLifetime(container) {} }
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    let newcomer = try XCTUnwrap(Keypair())
    let original = [owner, creator.publicKey.hex, attacker.publicKey.hex]
    let updated = original + [newcomer.publicKey.hex]
    let payload = NostrEventTestSupport.payload(.sessionMembers, members: updated, timestamp: 200)

    try await deliverAuthenticatedPayload(payload, author: creator, signer: attacker, to: session.nostrService)
    XCTAssertEqual(Set(try session.activeMemberPubkeys(sessionID: "session", ownerPubkey: owner)), Set(original))
    XCTAssertEqual(
      Set(try XCTUnwrap(session.resolveOutboundRecipients(
        sessionID: "session", ownerPubkey: owner, senderPubkey: owner))), Set(original))
    XCTAssertTrue(session.pendingIncomingMessages.isEmpty)

    // A correctly authenticated member still cannot exercise the creator's permissions.
    try await deliverAuthenticatedPayload(payload, author: attacker, signer: attacker, to: session.nostrService)
    XCTAssertEqual(Set(try session.activeMemberPubkeys(sessionID: "session", ownerPubkey: owner)), Set(original))

    try await deliverAuthenticatedPayload(payload, author: creator, signer: creator, to: session.nostrService)
    XCTAssertEqual(
      Set(try XCTUnwrap(session.resolveOutboundRecipients(
        sessionID: "session", ownerPubkey: owner, senderPubkey: owner))), Set(updated))
  }

  func testForgedDeletesCannotRemovePostsOrSessionsButAuthenticDeletesStillWork() async throws {
    let fixture = try await makeAuthenticatedSession()
    let session = fixture.session
    let container = fixture.container
    let creator = fixture.creator
    let attacker = fixture.attacker
    defer { withExtendedLifetime(container) {} }
    let owner = try XCTUnwrap(session.identityService.pubkeyHex)
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    let root = try await deliverAuthenticatedPayload(
      NostrEventTestSupport.payload(.root, members: [], timestamp: 110),
      author: creator, signer: creator, to: session.nostrService)
    XCTAssertEqual(try fetchMessages(in: container.mainContext).map(\.eventID), [root.id])

    for kind in [LinkstrPayloadKind.rootDelete, .sessionDelete] {
      let payload = NostrEventTestSupport.payload(kind, members: [], rootID: root.id, timestamp: 200)
      try await deliverAuthenticatedPayload(payload, author: creator, signer: attacker, to: session.nostrService)
    }
    XCTAssertEqual(try fetchMessages(in: container.mainContext).map(\.eventID), [root.id])
    XCTAssertNotNil(try session.messageStore.session(sessionID: "session", ownerPubkey: owner))
    XCTAssertTrue(try fetchPostDeletions(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchSessionDeletionTombstones(in: container.mainContext).isEmpty)
    XCTAssertTrue(session.pendingIncomingMessages.isEmpty)

    let deletion = NostrEventTestSupport.payload(.rootDelete, members: [], rootID: root.id, timestamp: 200)
    try await deliverAuthenticatedPayload(deletion, author: creator, signer: creator, to: session.nostrService)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertEqual(try fetchPostDeletions(in: container.mainContext).count, 1)
    let sessionDeletion = NostrEventTestSupport.payload(.sessionDelete, members: [], timestamp: 210)
    try await deliverAuthenticatedPayload(sessionDeletion, author: creator, signer: creator, to: session.nostrService)
    XCTAssertNil(try session.messageStore.session(sessionID: "session", ownerPubkey: owner))
    XCTAssertEqual(try fetchSessionDeletionTombstones(in: container.mainContext).count, 1)
  }

  private func makeAuthenticatedSession() async throws -> AuthenticatedSessionFixture {
    let (session, container) = try makeSession()
    try session.identityService.createNewIdentity()
    let owner = try XCTUnwrap(session.identityService.keypair)
    let creator = try XCTUnwrap(Keypair())
    let attacker = try XCTUnwrap(Keypair())
    session.nostrService.keypair = owner
    session.nostrService.onIncoming = { [weak session] in session?.persistIncoming($0) }
    let payload = NostrEventTestSupport.payload(
      .sessionCreate, members: [owner.publicKey.hex, creator.publicKey.hex, attacker.publicKey.hex])
    try await deliverAuthenticatedPayload(payload, author: creator, signer: creator, to: session.nostrService)
    XCTAssertNotNil(try session.messageStore.session(sessionID: "session", ownerPubkey: owner.publicKey.hex))
    return AuthenticatedSessionFixture(session: session, container: container, creator: creator, attacker: attacker)
  }

  @discardableResult
  private func deliverAuthenticatedPayload(
    _ payload: LinkstrPayload, author: Keypair, signer: Keypair, to service: NostrDMService
  ) async throws -> NostrEvent {
    let recipient = try XCTUnwrap(service.keypair)
    let rumor = try NostrEventTestSupport.rumor(payload, author: author.publicKey)
    let wrap = try service.giftWrap(withRumor: rumor, toRecipient: recipient.publicKey, signedBy: signer)
    try await NostrEventTestSupport.deliver(wrap, to: service)
    return rumor
  }
}
