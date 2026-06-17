import Foundation

enum RecipientSearchLogic {
  static func filteredContacts<Contact>(
    _ contacts: [Contact],
    query: String,
    displayName: (Contact) -> String,
    npub: (Contact) -> String,
    additionalNames: (Contact) -> [String] = { _ in [] }
  ) -> [Contact] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return contacts }
    let normalizedQuery = trimmedQuery.lowercased()

    return contacts.filter { contact in
      let candidateNames =
        [displayName(contact)] + additionalNames(contact)

      let matchesName = candidateNames.contains { candidate in
        candidate
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
          .contains(normalizedQuery)
      }
      return matchesName || npub(contact).lowercased().contains(normalizedQuery)
    }
  }
}
