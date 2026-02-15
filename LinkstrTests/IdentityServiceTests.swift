import XCTest

@testable import Linkstr

@MainActor
final class IdentityServiceTests: XCTestCase {
  override func setUpWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

  override func tearDownWithError() throws {
    try KeychainStore.shared.delete("nostr_nsec")
  }

  func testCreateRevealAndClearIdentityRoundTrip() throws {
    let service = IdentityService()

    try service.createNewIdentity()
    let nsec = try service.revealNsec()

    XCTAssertNotNil(service.keypair)
    XCTAssertTrue(nsec.hasPrefix("nsec1"))
    XCTAssertNotNil(service.npub)
    XCTAssertNotNil(service.pubkeyHex)

    try service.clearIdentity()
    XCTAssertNil(service.keypair)
    XCTAssertThrowsError(try service.revealNsec()) { error in
      switch error {
      case IdentityError.identityMissing:
        break
      case KeychainStoreError.readFailed:
        // Simulator keychain can return entitlement errors after clear.
        break
      default:
        XCTFail("Expected identityMissing/readFailed, got \(error)")
      }
    }
  }

  func testImportNsecPersistsAndCanBeReloaded() throws {
    let source = try TestKeyMaterialFactory.makeKeypair()
    let originalNsec = source.privateKey.nsec

    let importing = IdentityService()
    try importing.importNsec(originalNsec)
    XCTAssertEqual(importing.keypair?.privateKey.nsec, originalNsec)

    let reloaded = IdentityService()
    reloaded.loadIdentity()
    XCTAssertEqual(reloaded.keypair?.privateKey.nsec, originalNsec)
  }

  func testImportInvalidNsecThrowsIdentityError() {
    let service = IdentityService()
    XCTAssertThrowsError(try service.importNsec("not-a-real-nsec")) { error in
      guard case IdentityError.invalidNsec = error else {
        return XCTFail("Expected invalidNsec, got \(error)")
      }
    }
  }
}
