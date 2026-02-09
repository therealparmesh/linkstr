import Foundation
import Security

enum KeychainStoreError: Error, LocalizedError {
  case saveFailed(OSStatus)
  case readFailed(OSStatus)
  case deleteFailed(OSStatus)
  case decodeFailed

  var errorDescription: String? {
    switch self {
    case .saveFailed(let status):
      return "Failed to save key material: \(Self.message(for: status))."
    case .readFailed(let status):
      return "Failed to read key material: \(Self.message(for: status))."
    case .deleteFailed(let status):
      return "Failed to delete key material: \(Self.message(for: status))."
    case .decodeFailed:
      return "Stored key material is corrupted."
    }
  }

  private static func message(for status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
      return "\(message) (OSStatus \(status))"
    }
    return "OSStatus \(status)"
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
