import Foundation

struct ContactPresentation: Identifiable {
  let pubkey: String
  let identity: LinkstrResolvedIdentity
  let contact: ContactEntity?
  var id: String { pubkey }

  static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
    let order = lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName)
    return order == .orderedSame ? lhs.pubkey < rhs.pubkey : order == .orderedAscending
  }

  static func filtered(_ rows: [Self], query: String) -> [Self] {
    RecipientSearchLogic.filteredContacts(
      rows, query: query, displayName: { $0.identity.displayName }, npub: { $0.identity.npub },
      additionalNames: { $0.identity.chosenName.map { [$0] } ?? [] }
    )
  }
}
