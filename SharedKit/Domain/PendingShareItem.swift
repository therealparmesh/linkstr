import Foundation

struct PendingShareItem: Codable, Identifiable, Hashable {
  let id: String
  let ownerPubkey: String
  let url: String
  let contactNPub: String
  let note: String?
  let createdAt: Date

  init(
    id: String = UUID().uuidString,
    ownerPubkey: String,
    url: String,
    contactNPub: String,
    note: String? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.ownerPubkey = ownerPubkey
    self.url = url
    self.contactNPub = contactNPub
    self.note = note
    self.createdAt = createdAt
  }
}
