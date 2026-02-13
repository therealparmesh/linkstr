import CryptoKit
import Foundation
import Security

enum KeychainStoreError: Error, LocalizedError {
  case saveFailed(OSStatus)
  case readFailed(OSStatus)
  case deleteFailed(OSStatus)
  case decodeFailed

  var errorDescription: String? {
    switch self {
    case .saveFailed:
      return "Couldn't save account keys on this device."
    case .readFailed:
      return "Couldn't load account keys from this device."
    case .deleteFailed:
      return "Couldn't remove account keys from this device."
    case .decodeFailed:
      return "Stored account keys are unreadable."
    }
  }
}

final class KeychainStore {
  static let shared = KeychainStore()

  private let service = "com.parmscript.linkstr"

  #if targetEnvironment(simulator)
    // Simulator builds can hit keychain entitlement availability issues.
    private let fallbackPrefix = "sim.keychain.fallback."
  #endif

  private init() {}

  func set(_ value: String, for key: String) throws {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]

    SecItemDelete(query as CFDictionary)

    var addQuery = query
    addQuery[kSecValueData as String] = data

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
      clearFallback(for: key)
      return
    }

    if setFallbackIfRecoverable(status, value: value, for: key) {
      return
    }

    throw KeychainStoreError.saveFailed(status)
  }

  func get(_ key: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return fallbackValue(for: key)
    }

    if status != errSecSuccess {
      if let fallback = fallbackValueIfRecoverable(status, for: key) {
        return fallback
      }
      throw KeychainStoreError.readFailed(status)
    }

    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainStoreError.decodeFailed
    }
    return value
  }

  func delete(_ key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]

    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound {
      clearFallback(for: key)
      return
    }

    if deleteFallbackIfRecoverable(status, for: key) {
      return
    }

    throw KeychainStoreError.deleteFailed(status)
  }

  private func setFallbackIfRecoverable(_ status: OSStatus, value: String, for key: String) -> Bool
  {
    #if targetEnvironment(simulator)
      guard isSimulatorRecoverableStatus(status) else { return false }
      UserDefaults.standard.set(value, forKey: fallbackKey(for: key))
      return true
    #else
      return false
    #endif
  }

  private func fallbackValueIfRecoverable(_ status: OSStatus, for key: String) -> String? {
    #if targetEnvironment(simulator)
      guard isSimulatorRecoverableStatus(status) else { return nil }
      return UserDefaults.standard.string(forKey: fallbackKey(for: key))
    #else
      return nil
    #endif
  }

  private func fallbackValue(for key: String) -> String? {
    #if targetEnvironment(simulator)
      return UserDefaults.standard.string(forKey: fallbackKey(for: key))
    #else
      return nil
    #endif
  }

  private func deleteFallbackIfRecoverable(_ status: OSStatus, for key: String) -> Bool {
    #if targetEnvironment(simulator)
      guard isSimulatorRecoverableStatus(status) else { return false }
      clearFallback(for: key)
      return true
    #else
      return false
    #endif
  }

  private func clearFallback(for key: String) {
    #if targetEnvironment(simulator)
      UserDefaults.standard.removeObject(forKey: fallbackKey(for: key))
    #endif
  }

  #if targetEnvironment(simulator)
    private func fallbackKey(for key: String) -> String {
      "\(fallbackPrefix)\(service).\(key)"
    }

    private func isSimulatorRecoverableStatus(_ status: OSStatus) -> Bool {
      status == errSecMissingEntitlement
        || status == errSecNotAvailable
        || status == errSecInteractionNotAllowed
    }
  #endif
}

enum LocalDataCryptoError: Error, LocalizedError {
  case invalidKeyMaterial
  case invalidCiphertext
  case decryptionFailed

  var errorDescription: String? {
    switch self {
    case .invalidKeyMaterial:
      return "Stored encryption key is invalid."
    case .invalidCiphertext:
      return "Stored encrypted data is invalid."
    case .decryptionFailed:
      return "Couldn't decrypt local data for this account."
    }
  }
}

final class LocalDataCrypto {
  static let shared = LocalDataCrypto()

  private let keychain = KeychainStore.shared
  private let keyPrefix = "local_data_key."

  private init() {}

  func encryptString(_ plaintext: String?, ownerPubkey: String) throws -> String? {
    guard let plaintext else { return nil }
    let key = try symmetricKey(for: ownerPubkey)
    let data = Data(plaintext.utf8)
    let sealedBox = try AES.GCM.seal(data, using: key)
    guard let combined = sealedBox.combined else {
      throw LocalDataCryptoError.invalidCiphertext
    }
    return combined.base64EncodedString()
  }

  func decryptString(_ ciphertext: String?, ownerPubkey: String) -> String? {
    guard let ciphertext else { return nil }
    do {
      let key = try symmetricKey(for: ownerPubkey)
      guard let combined = Data(base64Encoded: ciphertext) else {
        throw LocalDataCryptoError.invalidCiphertext
      }
      let sealedBox = try AES.GCM.SealedBox(combined: combined)
      let plaintext = try AES.GCM.open(sealedBox, using: key)
      guard let value = String(data: plaintext, encoding: .utf8) else {
        throw LocalDataCryptoError.decryptionFailed
      }
      return value
    } catch {
      return nil
    }
  }

  func clearKey(ownerPubkey: String) throws {
    try keychain.delete(keyName(for: ownerPubkey))
  }

  func digestHex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func symmetricKey(for ownerPubkey: String) throws -> SymmetricKey {
    let keyName = keyName(for: ownerPubkey)
    if let encodedKey = try keychain.get(keyName) {
      guard let data = Data(base64Encoded: encodedKey), data.count == 32 else {
        throw LocalDataCryptoError.invalidKeyMaterial
      }
      return SymmetricKey(data: data)
    }

    let key = SymmetricKey(size: .bits256)
    let keyData = Data(key.withUnsafeBytes { Data($0) })
    try keychain.set(keyData.base64EncodedString(), for: keyName)
    return key
  }

  private func keyName(for ownerPubkey: String) -> String {
    "\(keyPrefix)\(ownerPubkey)"
  }
}
