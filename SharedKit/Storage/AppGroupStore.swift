import CryptoKit
import Darwin
import Foundation

protocol AppGroupStoreProtocol {
  func saveContactsSnapshot(_ contacts: [ContactSnapshot]) throws
  func loadContactsSnapshot() throws -> [ContactSnapshot]
  func appendPendingShare(_ item: PendingShareItem) throws
  func loadPendingShares() throws -> [PendingShareItem]
  func removePendingShares(withIDs ids: Set<String>) throws
}

enum AppGroupStoreError: Error {
  case appGroupUnavailable
  case lockCreationFailed(Int32)
  case lockAcquisitionFailed(Int32)
  case invalidSharedKeyMaterial
  case encryptionFailed
}

final class AppGroupStore {
  static let shared = AppGroupStore()

  let groupIdentifier = "group.com.parmscript.linkstr"
  private let contactsFileName = "contacts_snapshot.data"
  private let pendingSharesFileName = "pending_shares.data"
  private let pendingSharesLockFileName = "pending_shares.lock"
  private let sharedKeyFileName = "shared_store.key"

  private lazy var crypto = AppGroupCrypto(
    containerURLProvider: { [weak self] in
      guard let self else { throw AppGroupStoreError.appGroupUnavailable }
      return try self.containerURL()
    },
    keyFileName: sharedKeyFileName
  )

  private init() {}

  private func containerURL() throws -> URL {
    guard
      let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier)
    else {
      throw AppGroupStoreError.appGroupUnavailable
    }
    return containerURL
  }

  private func write<T: Encodable>(_ object: T, to fileName: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let plaintext = try encoder.encode(object)
    let ciphertext = try crypto.encrypt(plaintext)
    let url = try containerURL().appendingPathComponent(fileName)
    try ciphertext.write(to: url, options: [.atomic, .completeFileProtection])
  }

  private func read<T: Decodable>(_ type: T.Type, from fileName: String, defaultValue: T) throws
    -> T
  {
    let url = try containerURL().appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultValue
    }
    let ciphertext = try Data(contentsOf: url)
    let plaintext = try crypto.decrypt(ciphertext)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: plaintext)
  }

  func saveContactsSnapshot(_ contacts: [ContactSnapshot]) throws {
    try write(contacts, to: contactsFileName)
  }

  func loadContactsSnapshot() throws -> [ContactSnapshot] {
    try read([ContactSnapshot].self, from: contactsFileName, defaultValue: [])
  }

  func appendPendingShare(_ item: PendingShareItem) throws {
    try withPendingSharesLock {
      var items = try read([PendingShareItem].self, from: pendingSharesFileName, defaultValue: [])
      items.append(item)
      try write(items, to: pendingSharesFileName)
    }
  }

  func loadPendingShares() throws -> [PendingShareItem] {
    try withPendingSharesLock {
      try read([PendingShareItem].self, from: pendingSharesFileName, defaultValue: [])
    }
  }

  func removePendingShares(withIDs ids: Set<String>) throws {
    guard !ids.isEmpty else { return }
    try withPendingSharesLock {
      let items = try read([PendingShareItem].self, from: pendingSharesFileName, defaultValue: [])
      let remaining = items.filter { !ids.contains($0.id) }
      guard remaining.count != items.count else { return }
      try write(remaining, to: pendingSharesFileName)
    }
  }

  private func withPendingSharesLock<T>(_ body: () throws -> T) throws -> T {
    let lockURL = try containerURL().appendingPathComponent(pendingSharesLockFileName)
    let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw AppGroupStoreError.lockCreationFailed(errno)
    }
    defer {
      close(fd)
    }

    guard flock(fd, LOCK_EX) == 0 else {
      throw AppGroupStoreError.lockAcquisitionFailed(errno)
    }
    defer {
      flock(fd, LOCK_UN)
    }

    return try body()
  }
}

extension AppGroupStore: AppGroupStoreProtocol {}

private struct AppGroupCrypto {
  let containerURLProvider: () throws -> URL
  let keyFileName: String

  func encrypt(_ plaintext: Data) throws -> Data {
    let key = try symmetricKey()
    let sealedBox = try AES.GCM.seal(plaintext, using: key)
    guard let combined = sealedBox.combined else {
      throw AppGroupStoreError.encryptionFailed
    }
    return combined
  }

  func decrypt(_ ciphertext: Data) throws -> Data {
    let key = try symmetricKey()
    let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
    return try AES.GCM.open(sealedBox, using: key)
  }

  private func symmetricKey() throws -> SymmetricKey {
    let keyURL = try containerURLProvider().appendingPathComponent(keyFileName)
    if FileManager.default.fileExists(atPath: keyURL.path) {
      let existingData = try Data(contentsOf: keyURL)
      guard existingData.count == 32 else {
        throw AppGroupStoreError.invalidSharedKeyMaterial
      }
      return SymmetricKey(data: existingData)
    }

    let key = SymmetricKey(size: .bits256)
    let keyData = Data(key.withUnsafeBytes { Data($0) })
    try keyData.write(to: keyURL, options: [.atomic, .completeFileProtection])
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableURL = keyURL
    try? mutableURL.setResourceValues(resourceValues)
    return key
  }
}
