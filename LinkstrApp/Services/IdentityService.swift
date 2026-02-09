import Foundation
import NostrSDK

@MainActor
final class IdentityService: ObservableObject {
  @Published private(set) var keypair: Keypair?

  private let keychain = KeychainStore.shared
  private let keychainKey = "nostr_nsec"

  var npub: String? {
    keypair?.publicKey.npub
  }

  var pubkeyHex: String? {
    keypair?.publicKey.hex
  }

  func loadIdentity() {
    do {
      guard let nsec = try keychain.get(keychainKey) else { return }
      keypair = Keypair(nsec: nsec)
    } catch {
      print("Failed loading identity: \(error)")
    }
  }

  func importNsec(_ nsec: String) throws {
    guard let keypair = Keypair(nsec: nsec.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw IdentityError.invalidNsec
    }
    try keychain.set(keypair.privateKey.nsec, for: keychainKey)
    self.keypair = keypair
  }

  func createNewIdentity() throws {
    guard let keypair = Keypair() else {
      throw IdentityError.keyGenerationFailed
    }
    try keychain.set(keypair.privateKey.nsec, for: keychainKey)
    self.keypair = keypair
  }

  func revealNsec() throws -> String {
    guard let nsec = try keychain.get(keychainKey) else {
      throw IdentityError.identityMissing
    }
    return nsec
  }

  func clearIdentity() throws {
    try keychain.delete(keychainKey)
    keypair = nil
  }

}

enum IdentityError: Error, LocalizedError {
  case invalidNsec
  case keyGenerationFailed
  case identityMissing

  var errorDescription: String? {
    switch self {
    case .invalidNsec:
      return "Invalid nsec key."
    case .keyGenerationFailed:
      return "Unable to generate a new keypair."
    case .identityMissing:
      return "No identity found."
    }
  }
}
