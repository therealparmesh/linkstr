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
  private let migratoryAccessibility = kSecAttrAccessibleWhenUnlocked

  #if targetEnvironment(simulator)
    // Simulator builds can hit keychain entitlement availability issues.
    private let fallbackPrefix = "sim.keychain.fallback."
  #endif

  private init() {}

  func set(_ value: String, for key: String) throws {
    let data = Data(value.utf8)
    deletePrimaryAndLegacyItems(for: key)

    // Prefer synchronizable storage so encrypted backups + device migration can carry keychain
    // identity/local-data keys across phones when iCloud Keychain is available.
    let syncStatus = add(data, for: key, synchronizable: true)
    if syncStatus == errSecSuccess {
      clearFallback(for: key)
      return
    }

    // Fallback keeps login available when synchronizable keychain is unavailable on device.
    let localStatus = add(data, for: key, synchronizable: false)
    if localStatus == errSecSuccess {
      clearFallback(for: key)
      return
    }

    if setFallbackIfRecoverable(localStatus, value: value, for: key)
      || setFallbackIfRecoverable(syncStatus, value: value, for: key)
    {
      return
    }

    throw KeychainStoreError.saveFailed(localStatus)
  }

  func get(_ key: String) throws -> String? {
    if let value = try readValue(for: key, synchronizableQuery: kSecAttrSynchronizableAny) {
      return value
    }
    if let value = try readValue(for: key, synchronizableQuery: nil) {
      return value
    }
    return fallbackValue(for: key)
  }

  func delete(_ key: String) throws {
    let statuses: [OSStatus] = [
      SecItemDelete(query(for: key, synchronizableQuery: kCFBooleanTrue) as CFDictionary),
      SecItemDelete(query(for: key, synchronizableQuery: kCFBooleanFalse) as CFDictionary),
      SecItemDelete(query(for: key, synchronizableQuery: nil) as CFDictionary),
    ]

    if statuses.contains(errSecSuccess) || statuses.allSatisfy({ $0 == errSecItemNotFound }) {
      clearFallback(for: key)
      return
    }

    let firstError =
      statuses.first(where: { $0 != errSecSuccess && $0 != errSecItemNotFound }) ?? errSecParam

    if deleteFallbackIfRecoverable(firstError, for: key) {
      return
    }

    throw KeychainStoreError.deleteFailed(firstError)
  }

  private func add(_ data: Data, for key: String, synchronizable: Bool) -> OSStatus {
    var addQuery = query(
      for: key,
      synchronizableQuery: synchronizable ? kCFBooleanTrue : kCFBooleanFalse
    )
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = migratoryAccessibility
    return SecItemAdd(addQuery as CFDictionary, nil)
  }

  private func deletePrimaryAndLegacyItems(for key: String) {
    let deleteQueries: [[String: Any]] = [
      query(for: key, synchronizableQuery: kCFBooleanTrue),
      query(for: key, synchronizableQuery: kCFBooleanFalse),
      query(for: key, synchronizableQuery: nil),
    ]
    for deleteQuery in deleteQueries {
      SecItemDelete(deleteQuery as CFDictionary)
    }
  }

  private func readValue(for key: String, synchronizableQuery: Any?) throws -> String? {
    var readQuery = query(for: key, synchronizableQuery: synchronizableQuery)
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
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

  private func query(for key: String, synchronizableQuery: Any?) -> [String: Any] {
    var baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    if let synchronizableQuery {
      baseQuery[kSecAttrSynchronizable as String] = synchronizableQuery
    }
    return baseQuery
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
