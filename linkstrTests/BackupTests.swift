import NostrSDK
import SwiftData
import XCTest

@testable import linkstr

@MainActor
final class BackupTests: AppSessionTestCase {
  func testRestoreReopensCommittedDataAndFinishesInterruptedActivation() async throws {
    let (_, template) = try makeSession()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = ModelConfiguration(schema: template.schema, url: directory.appendingPathComponent("backup.store"),
                                    cloudKitDatabase: .none)
    let backup = try populatedBackup()
    let worker = BackupWorker()
    do {
      let container = try ModelContainer(for: template.schema, configurations: [config])
      _ = try await worker.restore(backup, in: container)
      XCTAssertNil(try KeychainStore.shared.get("nostr_nsec"))
    }
    let reopened = try ModelContainer(for: template.schema, configurations: [config])
    let defaults = makeRelaySettingsUserDefaults()
    var overrides = AppSession.TestingOverrides()
    overrides.skipNostrNetworkStartup = true
    let session = AppSession(modelContext: reopened.mainContext, relaySettingsUserDefaults: defaults,
                             testingOverrides: overrides)
    await session.boot()
    XCTAssertTrue(session.didRestoreBackup)
    XCTAssertEqual(session.identityService.pubkeyHex, backup.owner)
    XCTAssertEqual(try session.identityService.revealNsec(), backup.nsec)
    XCTAssertFalse(try session.relayStore.backupSettings().loopLocalVideos)
    XCTAssertTrue(try session.relayStore.backupSettings().customRelays)
    XCTAssertTrue(try session.relayStore.backupSettings().relays.isEmpty)
    let activation = try await worker.pendingActivation(in: reopened)
    XCTAssertNil(activation)
    let state = try XCTUnwrap(fetchAccountStates(in: reopened.mainContext).first)
    XCTAssertTrue(state.hasRestoredBackup)
    let data = try await session.prepareBackup()
    let exported = try await worker.decode(data)
    XCTAssertEqual(exported.posts.map(\.id), ["post"])
    XCTAssertEqual(exported.posts.first?.note, "saved note")
    XCTAssertEqual(exported.posts.first?.readAt, Date(timeIntervalSince1970: 200))
    XCTAssertEqual(exported.posts.first?.transportIDs, ["wrap"])
    XCTAssertEqual(exported.sessions.first?.name, "friends")
    XCTAssertEqual(exported.members.count, 2)
    XCTAssertEqual(exported.intervals.count, 2)
    XCTAssertEqual(exported.reactions.first?.emoji, "🔥")
    XCTAssertEqual(exported.deletions.count, 2)
    XCTAssertEqual(exported.contacts.first?.alias, "friend")
    XCTAssertEqual(exported.follows.first?.eventID, "incoming-follow")
    XCTAssertEqual(exported.account?.followID, "follow")
    XCTAssertEqual(exported.preferences.count, 1)
    XCTAssertFalse(exported.preferences[0].pending)
  }

  func testOverlappingRestoreKeepsNewerClearsDeletionsMembershipAndReadState() async throws {
    let (_, container) = try makeSession()
    let worker = BackupWorker()
    let backup = try populatedBackup()
    let other = try populatedBackup()
    _ = try await worker.restore(other, in: container)
    _ = try await worker.restore(backup, in: container)
    var newer = backup
    newer.account?.followDate = Date(timeIntervalSince1970: 500)
    newer.account?.followID = "unfollow"
    newer.contacts = []
    newer.sessions[0].membershipDate = Date(timeIntervalSince1970: 500)
    newer.sessions[0].membershipID = "remove-member"
    newer.members[1].active = false
    newer.intervals[1].end = Date(timeIntervalSince1970: 500)
    newer.deletions.append(.init(sessionID: "session", postID: "post", pubkey: backup.posts[0].sender,
                                  updatedAt: Date(timeIntervalSince1970: 600), eventID: "delete-post"))
    let keypair = try XCTUnwrap(Keypair(nsec: backup.nsec))
    let clear = try PrivatePreferenceCodec().event(
      for: .archive(sessionID: "session", archived: false), keypair: keypair, createdAt: 600)
    newer.preferences = [.init(event: try JSONEncoder().encode(clear), pending: false)]
    newer.sessions[0].archived = false
    newer.posts = []
    newer.reactions = []
    _ = try await worker.restore(newer, in: container)
    for _ in 0..<2 { _ = try await worker.restore(backup, in: container) }
    let context = ModelContext(container)
    let restored = try BackupSnapshot(context: context, nsec: backup.nsec, owner: backup.owner,
                                      settings: backup.settings).decrypted()
    XCTAssertTrue(restored.posts.isEmpty)
    XCTAssertTrue(restored.reactions.isEmpty)
    XCTAssertTrue(restored.contacts.isEmpty)
    XCTAssertFalse(try XCTUnwrap(restored.sessions.first).archived)
    XCTAssertEqual(restored.members.filter(\.active).map(\.pubkey), [backup.owner])
    XCTAssertEqual(restored.intervals.first { $0.pubkey != backup.owner }?.end, Date(timeIntervalSince1970: 500))
    let retained = try BackupSnapshot(context: context, nsec: other.nsec, owner: other.owner,
                                     settings: other.settings).decrypted()
    XCTAssertEqual(retained.posts.map(\.id), ["post"])
    XCTAssertEqual(retained.posts.first?.readAt, Date(timeIntervalSince1970: 200))
  }

  func testInvalidRestoreAndSignedInRestoreLeaveIdentityDataAndSettingsUntouched() async throws {
    let (session, container) = try makeSession()
    let backup = try populatedBackup()
    let settings = try session.relayStore.backupSettings()
    var invalid = backup
    invalid.nsec = "invalid"
    do {
      try await session.restoreBackup(invalid)
      XCTFail("invalid identity was restored")
    } catch IdentityError.invalidNsec { }
    invalid = backup
    invalid.posts.append(backup.posts[0])
    do {
      try await session.restoreBackup(invalid)
      XCTFail("duplicate data was restored")
    } catch BackupError.invalidFile { }
    XCTAssertNil(try KeychainStore.shared.get("nostr_nsec"))
    XCTAssertNil(session.identityService.keypair)
    XCTAssertTrue(try fetchMessages(in: container.mainContext).isEmpty)
    XCTAssertTrue(try fetchAccountStates(in: container.mainContext).isEmpty)
    let unchanged = try session.relayStore.backupSettings()
    XCTAssertEqual(unchanged.loopLocalVideos, settings.loopLocalVideos)
    XCTAssertEqual(unchanged.customRelays, settings.customRelays)
    XCTAssertEqual(unchanged.relays.map(\.url), settings.relays.map(\.url))
    XCTAssertEqual(unchanged.relays.map(\.enabled), settings.relays.map(\.enabled))
    try await session.restoreBackup(backup)
    XCTAssertEqual(session.identityService.pubkeyHex, backup.owner)
    do {
      try await session.restoreBackup(try populatedBackup())
      XCTFail("replaced a signed-in account")
    } catch BackupError.signedIn { }
    XCTAssertEqual(session.identityService.pubkeyHex, backup.owner)
  }

  func testConflictingPostFailsWithoutCommittingAndTransportOverlapPreservesReads() async throws {
    let (_, container) = try makeSession()
    let worker = BackupWorker()
    let backup = try populatedBackup()
    _ = try await worker.restore(backup, in: container)
    var incoming = backup
    incoming.posts[0].readAt = nil
    incoming.posts[0].transportIDs = ["other-wrap"]
    _ = try await worker.restore(incoming, in: container)
    incoming.posts[0].url = "https://example.com/changed"
    incoming.sessions[0].name = "must not commit"
    do {
      _ = try await worker.restore(incoming, in: container)
      XCTFail("conflicting post replaced saved content")
    } catch BackupError.conflict { }
    let context = ModelContext(container)
    let saved = try BackupSnapshot(context: context, nsec: backup.nsec, owner: backup.owner,
                                  settings: backup.settings).decrypted()
    XCTAssertEqual(saved.sessions.first?.name, "friends")
    XCTAssertEqual(saved.posts.first?.url, "https://example.com/post")
    XCTAssertEqual(saved.posts.first?.readAt, Date(timeIntervalSince1970: 200))
    XCTAssertEqual(Set(saved.posts[0].transportIDs), ["wrap", "other-wrap"])
  }

  private func populatedBackup() throws -> LinkstrBackup {
    let keypair = try XCTUnwrap(Keypair())
    let owner = keypair.publicKey.hex
    let peer = try TestKeyMaterialFactory.makePubkeyHex()
    let date = Date(timeIntervalSince1970: 100)
    var backup = LinkstrBackup(nsec: keypair.privateKey.nsec, owner: owner,
                              settings: .init(loopLocalVideos: false, customRelays: true, relays: []))
    backup.account = .init(followDate: date, followID: "follow", profileName: "name",
                           createdAt: date, updatedAt: date)
    backup.sessions = [.init(id: "session", name: "friends", creator: owner, createdAt: date,
                             updatedAt: date, archived: true, membershipDate: date, membershipID: "members")]
    backup.posts = [.init(id: "post", sessionID: "session", sender: peer, receiver: owner,
                          url: "https://example.com/post", note: "saved note", timestamp: date,
                          archived: true, readAt: Date(timeIntervalSince1970: 200), transportIDs: ["wrap"])]
    backup.members = [owner, peer].map {
      .init(sessionID: "session", pubkey: $0, active: true, createdAt: date, updatedAt: date)
    }
    backup.intervals = [owner, peer].map { .init(sessionID: "session", pubkey: $0, start: date) }
    backup.reactions = [.init(sessionID: "session", postID: "post", pubkey: owner,
                              emoji: "🔥", active: true, updatedAt: date, eventID: "reaction")]
    backup.deletions = [
      .init(sessionID: "removed", pubkey: owner, updatedAt: date, eventID: "delete-session"),
      .init(sessionID: "session", postID: "removed", pubkey: peer, updatedAt: date, eventID: "delete-root")
    ]
    backup.contacts = [.init(pubkey: peer, alias: "friend", createdAt: date, profileName: "peer",
                            profileDate: date, profileID: "profile")]
    backup.follows = [.init(pubkey: peer, follows: true, updatedAt: date, eventID: "incoming-follow")]
    let event = try PrivatePreferenceCodec().event(
      for: .archive(sessionID: "session", archived: true), keypair: keypair, createdAt: 100)
    backup.preferences = [.init(event: try JSONEncoder().encode(event), pending: false)]
    return backup
  }
}
