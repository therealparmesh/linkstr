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

    return contacts.filter { contact in
      contactMatches(
        query: trimmedQuery,
        displayName: displayName(contact),
        npub: npub(contact)
      )
    }
  }

  static func contactMatches(query: String, displayName: String, npub: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedQuery.isEmpty else { return true }
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return name.contains(normalizedQuery) || npub.lowercased().contains(normalizedQuery)
  }
}
