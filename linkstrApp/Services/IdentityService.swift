import Foundation
import NostrSDK

@MainActor
final class IdentityService: ObservableObject {
  enum LoadResult {
    case loaded
    case missing
    case failed
  }

  @Published private(set) var keypair: Keypair?

  private let keychain = KeychainStore.shared
  private let keychainKey = "nostr_nsec"

  var npub: String? {
    keypair?.publicKey.npub
  }

  var pubkeyHex: String? {
    keypair?.publicKey.hex
  }

  @discardableResult
  func loadIdentity() -> LoadResult {
    do {
      guard let nsec = try keychain.get(keychainKey) else {
        keypair = nil
        return .missing
      }
      guard let keypair = Keypair(nsec: nsec) else {
        self.keypair = nil
        NSLog("Failed loading identity: stored account key is invalid.")
        return .failed
      }
      self.keypair = keypair
      return .loaded
    } catch {
      keypair = nil
      NSLog("Failed loading identity: \(error.localizedDescription)")
      return .failed
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
      return "invalid secret key (nsec)."
    case .keyGenerationFailed:
      return "couldn't create a new account. please try again."
    case .identityMissing:
      return "no account found."
    }
  }
}
