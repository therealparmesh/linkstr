import Foundation

enum AppGroupStoreError: Error {
  case appGroupUnavailable
}

final class AppGroupStore {
  static let shared = AppGroupStore()

  let groupIdentifier = "group.com.parmscript.linkstr"
  private let contactsFileName = "contacts_snapshot.json"
  private let pendingSharesFileName = "pending_shares.json"

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
    var items = try loadPendingShares()
    items.append(item)
    try write(items, to: pendingSharesFileName)
  }

  func loadPendingShares() throws -> [PendingShareItem] {
    try read([PendingShareItem].self, from: pendingSharesFileName, defaultValue: [])
  }

  func consumePendingShares() throws -> [PendingShareItem] {
    let items = try loadPendingShares()
    try write([PendingShareItem](), to: pendingSharesFileName)
    return items
  }
}
