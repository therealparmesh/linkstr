import Foundation

enum RecipientSearchLogic {
  static func filteredContacts<Contact>(
    _ contacts: [Contact],
    query: String,
    displayName: (Contact) -> String,
    npub: (Contact) -> String
  ) -> [Contact] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return contacts }
    let normalizedQuery = trimmedQuery.lowercased()

    return contacts.filter { contact in
      let name = displayName(contact).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return name.contains(normalizedQuery) || npub(contact).lowercased().contains(normalizedQuery)
    }
  }
}
