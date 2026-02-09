import Darwin
import Foundation

enum AppGroupStoreError: Error {
  case appGroupUnavailable
  case lockCreationFailed(Int32)
  case lockAcquisitionFailed(Int32)
}

final class AppGroupStore {
  static let shared = AppGroupStore()

  let groupIdentifier = "group.com.parmscript.linkstr"
  private let contactsFileName = "contacts_snapshot.json"
  private let pendingSharesFileName = "pending_shares.json"
  private let pendingSharesLockFileName = "pending_shares.lock"

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
    let data = try encoder.encode(object)
    let url = try containerURL().appendingPathComponent(fileName)
    try data.write(to: url, options: .atomic)
  }

  private func read<T: Decodable>(_ type: T.Type, from fileName: String, defaultValue: T) throws
    -> T
  {
    let url = try containerURL().appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultValue
    }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
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
