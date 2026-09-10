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
      return "couldn't save account keys on this device."
    case .readFailed:
      return "couldn't load account keys from this device."
    case .deleteFailed:
      return "couldn't remove account keys from this device."
    case .decodeFailed:
      return "stored account keys are unreadable."
    }
  }
}

final class KeychainStore {
  static let shared = KeychainStore()

  private let service: String
  private let updateItem: (CFDictionary, CFDictionary) -> OSStatus
  private let addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  private let migratoryAccessibility = kSecAttrAccessibleWhenUnlocked

  #if targetEnvironment(simulator)
    // Simulator builds can hit keychain entitlement availability issues.
    private let fallbackPrefix = "sim.keychain.fallback."
  #endif

  init(
    service: String = "com.parmscript.linkstr",
    updateItem: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
    addItem: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
  ) {
    self.service = service
    self.updateItem = updateItem
    self.addItem = addItem
  }

  func set(_ value: String, for key: String) throws {
    let status = update(value, for: key)
    if status == errSecSuccess {
      clearFallback(for: key)
      return
    }
    if status == errSecItemNotFound {
      if try insert(value, for: key) { return }
      let retryStatus = update(value, for: key)
      guard retryStatus == errSecSuccess else {
        throw KeychainStoreError.saveFailed(retryStatus)
      }
      clearFallback(for: key)
      return
    }
    if setFallbackIfRecoverable(status, value: value, for: key) { return }
    throw KeychainStoreError.saveFailed(status)
  }

  private func update(_ value: String, for key: String) -> OSStatus {
    updateItem(
      query(for: key, synchronizableQuery: kSecAttrSynchronizableAny) as CFDictionary,
      [
        kSecValueData as String: Data(value.utf8),
        kSecAttrAccessible as String: migratoryAccessibility
      ] as CFDictionary
    )
  }

  // A competing writer's key must be reused, never overwritten by a new random key.
  func insert(_ value: String, for key: String) throws -> Bool {
    let data = Data(value.utf8)

    // Prefer synchronizable storage so encrypted backups + device migration can carry keychain
    // identity/local-data keys across phones when iCloud Keychain is available.
    let syncStatus = add(data, for: key, synchronizable: true)
    if syncStatus == errSecSuccess {
      clearFallback(for: key)
      return true
    }
    if syncStatus == errSecDuplicateItem { return false }

    // Fallback keeps sign-in available when synchronizable keychain is unavailable on device.
    let localStatus = add(data, for: key, synchronizable: false)
    if localStatus == errSecSuccess {
      clearFallback(for: key)
      return true
    }
    if localStatus == errSecDuplicateItem { return false }

    if setFallbackIfRecoverable(localStatus, value: value, for: key)
      || setFallbackIfRecoverable(syncStatus, value: value, for: key) {
      return true
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
      SecItemDelete(query(for: key, synchronizableQuery: nil) as CFDictionary)
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
    return addItem(addQuery as CFDictionary, nil)
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
      kSecAttrAccount as String: key
    ]
    if let synchronizableQuery {
      baseQuery[kSecAttrSynchronizable as String] = synchronizableQuery
    }
    return baseQuery
  }

  private func setFallbackIfRecoverable(_ status: OSStatus, value: String, for key: String) -> Bool {
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
  case missingKey
  case invalidKeyMaterial
  case invalidCiphertext
  case decryptionFailed

  var errorDescription: String? {
    switch self {
    case .missingKey:
      return
        "this account's encryption key is unavailable. restore its keychain data and try again."
    case .invalidKeyMaterial:
      return "stored encryption key is invalid."
    case .invalidCiphertext:
      return "stored encrypted data is invalid."
    case .decryptionFailed:
      return "couldn't decrypt local data for this account."
    }
  }
}

final class LocalDataCrypto {
  static let shared = LocalDataCrypto()

  private let keychain: KeychainStore
  private let keyPrefix = "local_data_key."
  private var symmetricKeyCache: [String: SymmetricKey] = [:]
  private var existingKeyOwners: Set<String> = []
  private let symmetricKeyCacheLock = NSLock()

  init(keychain: KeychainStore = .shared) {
    self.keychain = keychain
  }

  func preserveExistingKey(ownerPubkey: String) {
    symmetricKeyCacheLock.lock()
    defer { symmetricKeyCacheLock.unlock() }
    existingKeyOwners.insert(ownerPubkey)
  }

  func requireExistingKey(ownerPubkey: String) throws {
    preserveExistingKey(ownerPubkey: ownerPubkey)
    _ = try symmetricKey(for: ownerPubkey, allowCreation: false)
  }

  func encryptString(_ plaintext: String?, ownerPubkey: String) throws -> String? {
    let key = try symmetricKey(for: ownerPubkey, allowCreation: true)
    guard let plaintext else { return nil }
    let data = Data(plaintext.utf8)
    let sealedBox = try AES.GCM.seal(data, using: key)
    guard let combined = sealedBox.combined else {
      throw LocalDataCryptoError.invalidCiphertext
    }
    return combined.base64EncodedString()
  }

  func decryptString(_ ciphertext: String?, ownerPubkey: String) -> String? {
    guard let ciphertext, !ciphertext.isEmpty else { return nil }
    preserveExistingKey(ownerPubkey: ownerPubkey)
    do {
      let key = try symmetricKey(for: ownerPubkey, allowCreation: false)
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
    symmetricKeyCacheLock.lock()
    defer { symmetricKeyCacheLock.unlock() }
    try keychain.delete(keyName(for: ownerPubkey))
    symmetricKeyCache.removeValue(forKey: ownerPubkey)
    existingKeyOwners.remove(ownerPubkey)
  }

  func digestHex(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    let hexChars: [UInt8] = Array("0123456789abcdef".utf8)
    var bytes = [UInt8]()
    bytes.reserveCapacity(64)
    for byte in digest {
      bytes.append(hexChars[Int(byte >> 4)])
      bytes.append(hexChars[Int(byte & 0x0F)])
    }
    return String(bytes: bytes, encoding: .ascii)!
  }

  private func symmetricKey(for ownerPubkey: String, allowCreation: Bool) throws -> SymmetricKey {
    symmetricKeyCacheLock.lock()
    defer { symmetricKeyCacheLock.unlock() }
    if let cached = symmetricKeyCache[ownerPubkey] {
      return cached
    }

    let keyName = keyName(for: ownerPubkey)
    var encodedKey = try keychain.get(keyName)
    if encodedKey == nil {
      guard allowCreation, !existingKeyOwners.contains(ownerPubkey) else {
        throw LocalDataCryptoError.missingKey
      }
      let key = SymmetricKey(size: .bits256)
      let newValue = key.withUnsafeBytes { Data($0) }.base64EncodedString()
      if try keychain.insert(newValue, for: keyName) {
        encodedKey = newValue
      } else {
        encodedKey = try keychain.get(keyName)
      }
    }
    guard let encodedKey else { throw LocalDataCryptoError.missingKey }
    guard let data = Data(base64Encoded: encodedKey), data.count == 32 else {
      throw LocalDataCryptoError.invalidKeyMaterial
    }
    let key = SymmetricKey(data: data)
    symmetricKeyCache[ownerPubkey] = key
    existingKeyOwners.insert(ownerPubkey)
    return key
  }

  private func keyName(for ownerPubkey: String) -> String {
    "\(keyPrefix)\(ownerPubkey)"
  }
}
