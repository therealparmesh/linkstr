import Foundation

enum RecipientSearchLogic {
  static func selectedQuery(selectedRecipientNPub: String?, selectedDisplayName: String?) -> String
  {
    let trimmedName = selectedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedName.isEmpty {
      return trimmedName
    }
    return selectedRecipientNPub ?? ""
  }

  static func displayNameOrNPub(displayName: String, npub: String) -> String {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? npub : trimmed
  }

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
