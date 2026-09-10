import CryptoKit
import Security
import XCTest

@testable import linkstr

@MainActor
final class KeychainRecoveryTests: AppSessionTestCase {
  func testFailedUpdatePreservesPreviousKeychainValue() throws {
    let service = "linkstrTests.\(UUID().uuidString)"
    let keychain = KeychainStore(service: service)
    defer { try? keychain.delete("key") }
    try keychain.set("original", for: "key")

    let failing = KeychainStore(
      service: service,
      updateItem: { _, _ in errSecParam },
      addItem: { _, _ in
        XCTFail("An update failure must not fall through to an insertion.")
        return errSecSuccess
      }
    )
    XCTAssertThrowsError(try failing.set("replacement", for: "key"))
    XCTAssertEqual(try keychain.get("key"), "original")
    try keychain.set("replacement", for: "key")
    XCTAssertEqual(try keychain.get("key"), "replacement")
  }

  func testSetRetriesUpdateWhenAnotherWriterInsertsFirst() throws {
    var updates = 0
    var additions = 0
    let keychain = KeychainStore(
      service: "linkstrTests.\(UUID().uuidString)",
      updateItem: { _, attributes in
        updates += 1
        XCTAssertEqual((attributes as NSDictionary)[kSecValueData] as? Data, Data("value".utf8))
        return updates == 1 ? errSecItemNotFound : errSecSuccess
      },
      addItem: { _, _ in
        additions += 1
        return errSecDuplicateItem
      }
    )
    try keychain.set("value", for: "key")
    XCTAssertEqual(updates, 2)
    XCTAssertEqual(additions, 1)
  }

  func testMissingKeyDoesNotReplaceLegacyEncryptionAndCanRecover() throws {
    let keychain = KeychainStore(service: "linkstrTests.\(UUID().uuidString)")
    let owner = UUID().uuidString
    let keyName = "local_data_key.\(owner)"
    defer { try? keychain.delete(keyName) }
    let keyData = Data(repeating: 42, count: 32)
    let key = SymmetricKey(data: keyData)
    let encrypted = try XCTUnwrap(AES.GCM.seal(Data("original alias".utf8), using: key).combined)
      .base64EncodedString()
    let crypto = LocalDataCrypto(keychain: keychain)

    XCTAssertNil(crypto.decryptString(encrypted, ownerPubkey: owner))
    XCTAssertNil(try keychain.get(keyName))
    XCTAssertThrowsError(try crypto.encryptString("new alias", ownerPubkey: owner))
    XCTAssertThrowsError(try crypto.encryptString(nil, ownerPubkey: owner))
    XCTAssertNil(try keychain.get(keyName))

    try keychain.set(keyData.base64EncodedString(), for: keyName)
    XCTAssertEqual(crypto.decryptString(encrypted, ownerPubkey: owner), "original alias")
    let newEncrypted = try XCTUnwrap(crypto.encryptString("new alias", ownerPubkey: owner))
    let sealed = try AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: newEncrypted)))
    XCTAssertEqual(try AES.GCM.open(sealed, using: key), Data("new alias".utf8))
    XCTAssertEqual(try keychain.get(keyName), keyData.base64EncodedString())
  }

  func testFreshStorageCreatesOneReusableKey() throws {
    let keychain = KeychainStore(service: "linkstrTests.\(UUID().uuidString)")
    let owner = UUID().uuidString
    let keyName = "local_data_key.\(owner)"
    defer { try? keychain.delete(keyName) }
    let first = LocalDataCrypto(keychain: keychain)
    XCTAssertNil(first.decryptString(nil, ownerPubkey: owner))
    XCTAssertNil(try keychain.get(keyName))
    let encrypted = try first.encryptString("alias", ownerPubkey: owner)
    let originalKey = try XCTUnwrap(keychain.get(keyName))
    let reloaded = LocalDataCrypto(keychain: keychain)
    XCTAssertEqual(reloaded.decryptString(encrypted, ownerPubkey: owner), "alias")
    _ = try reloaded.encryptString("another alias", ownerPubkey: owner)
    XCTAssertEqual(try keychain.get(keyName), originalKey)
  }

  func testEncryptionReusesCompetingWritersKey() throws {
    let service = "linkstrTests.\(UUID().uuidString)"
    let keychain = KeychainStore(service: service)
    let owner = UUID().uuidString
    let keyName = "local_data_key.\(owner)"
    defer { try? keychain.delete(keyName) }
    let winningKey = Data(repeating: 7, count: 32)
    let racingKeychain = KeychainStore(
      service: service,
      addItem: { _, _ in
        do {
          try keychain.set(winningKey.base64EncodedString(), for: keyName)
        } catch {
          XCTFail("Could not seed the competing key: \(error)")
        }
        return errSecDuplicateItem
      })
    let crypto = LocalDataCrypto(keychain: racingKeychain)
    let encrypted = try XCTUnwrap(crypto.encryptString("alias", ownerPubkey: owner))
    let sealed = try AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: encrypted)))
    XCTAssertEqual(
      try AES.GCM.open(sealed, using: SymmetricKey(data: winningKey)), Data("alias".utf8))
    XCTAssertEqual(try keychain.get(keyName), winningKey.base64EncodedString())
  }

  func testRestoredAccountBlocksWritesBeforeReadingAndRetriesAliasDecryption() throws {
    let (session, container) = try makeSession()
    let identity = try TestKeyMaterialFactory.makeKeypair()
    let owner = identity.publicKey.hex
    let keyName = "local_data_key.\(owner)"
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    let contact = try ContactEntity(ownerPubkey: owner, targetPubkey: owner, alias: "Heather")
    container.mainContext.insert(contact)
    try container.mainContext.save()
    let ciphertext = contact.encryptedAlias
    let originalKey = try XCTUnwrap(KeychainStore.shared.get(keyName))
    try LocalDataCrypto.shared.clearKey(ownerPubkey: owner)

    session.importNsec(identity.privateKey.nsec)
    XCTAssertThrowsError(try contact.updateAlias("different alias"))
    XCTAssertThrowsError(try contact.updateAlias(nil))
    XCTAssertEqual(contact.encryptedAlias, ciphertext)
    XCTAssertNil(try KeychainStore.shared.get(keyName))
    XCTAssertNil(contact.localAlias)

    try KeychainStore.shared.set(originalKey, for: keyName)
    XCTAssertEqual(contact.localAlias, "Heather")
    XCTAssertEqual(contact.encryptedAlias, ciphertext)
  }

  func testRestoredPostsWithoutContactsRetainCiphertextAndRetryDecryption() throws {
    let (session, container) = try makeSession()
    let identity = try TestKeyMaterialFactory.makeKeypair()
    let owner = identity.publicKey.hex
    let keyName = "local_data_key.\(owner)"
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    let post = try SessionMessageEntity(
      eventID: "post", ownerPubkey: owner, conversationID: "session", rootID: "post",
      kind: .root, senderPubkey: owner, url: "https://example.com", note: "saved note",
      timestamp: .now, linkType: .generic, thumbnailURL: "https://example.com/image.jpg",
      metadataTitle: "saved title"
    )
    container.mainContext.insert(post)
    try container.mainContext.save()
    let originalTitle = post.encryptedMetadataTitle
    let originalKey = try XCTUnwrap(KeychainStore.shared.get(keyName))
    try LocalDataCrypto.shared.clearKey(ownerPubkey: owner)

    session.importNsec(identity.privateKey.nsec)
    XCTAssertThrowsError(try post.setMetadata(title: nil, thumbnailURL: nil))
    XCTAssertEqual(post.encryptedMetadataTitle, originalTitle)
    XCTAssertNil(try KeychainStore.shared.get(keyName))
    XCTAssertEqual(post.senderPubkey, "")
    XCTAssertNil(post.url)
    XCTAssertNil(post.note)
    XCTAssertNil(post.thumbnailURL)
    XCTAssertNil(post.metadataTitle)

    try KeychainStore.shared.set(originalKey, for: keyName)
    XCTAssertEqual(post.senderPubkey, owner)
    XCTAssertEqual(post.url, "https://example.com")
    XCTAssertEqual(post.note, "saved note")
    XCTAssertEqual(post.thumbnailURL, "https://example.com/image.jpg")
    XCTAssertEqual(post.metadataTitle, "saved title")
    XCTAssertEqual(post.encryptedMetadataTitle, originalTitle)
  }
}
