import SwiftData
import SwiftUI
import UIKit

struct ContactsView: View {
  @EnvironmentObject private var session: AppSession
  let addContact: () -> Void
  let ownerPubkey: String
  @Binding var isShowingAddedYou: Bool

  @Query
  private var contacts: [ContactEntity]

  @State private var selectedContact: ContactEntity?
  @State private var pendingContactRemoval: ContactEntity?
  @State private var addedYouQuery = ""
  @State private var query = ""

  init(
    ownerPubkey: String, isShowingAddedYou: Binding<Bool>,
    addContact: @escaping () -> Void
  ) {
    self.ownerPubkey = ownerPubkey
    self._isShowingAddedYou = isShowingAddedYou
    self.addContact = addContact
    _contacts = Query(
      filter: #Predicate<ContactEntity> { contact in
        contact.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\ContactEntity.createdAt)]
    )
  }

  private var preparedContacts: [ContactPresentation] {
    contacts.map {
      ContactPresentation(pubkey: $0.targetPubkey, identity: session.resolvedIdentity(for: $0), contact: $0)
    }.sorted(by: ContactPresentation.ordered)
  }

  var body: some View {
    let profileLookupPubkeys = contacts.map(\.targetPubkey)

    ZStack {
      LinkstrBackgroundView()
      if isShowingAddedYou {
        AddedYouView(
          ownerPubkey: ownerPubkey, contacts: contacts, query: $addedYouQuery, discovery: session.contactDiscovery
        )
      } else {
        content
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .contactRemoval(pending: $pendingContactRemoval)
    .onChange(of: contacts.map(\.persistentModelID)) { _, ids in
      if let selectedContact, !ids.contains(selectedContact.persistentModelID) { self.selectedContact = nil }
      if let pendingContactRemoval, !ids.contains(pendingContactRemoval.persistentModelID) {
        self.pendingContactRemoval = nil
      }
    }
    .task(id: profileLookupPubkeys.stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .navigationDestination(item: $selectedContact) { contact in
      EditContactView(contact: contact)
    }
  }

  @ViewBuilder
  private var content: some View {
    let orderedContacts = preparedContacts
    let visibleContacts = ContactPresentation.filtered(orderedContacts, query: query)

    if orderedContacts.isEmpty {
      VStack(spacing: 0) {
        LinkstrScreenTitle(title: "contacts")
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
        LinkstrCenteredEmptyStateView(
          title: "no contacts",
          systemImage: "person.2.slash",
          description: "add a contact. invite them when you start a session.",
          actionTitle: "add contact",
          actionSystemImage: "person.badge.plus",
          action: addContact
        )
      }
      .linkstrReadableContent()
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          LinkstrScreenTitle(title: "contacts")

          LinkstrSearchField(prompt: "search contacts", text: $query)

          if visibleContacts.isEmpty {
            LinkstrCenteredEmptyStateView(
              title: "no contacts found",
              systemImage: "magnifyingglass",
              description: "try another search.",
              actionTitle: "clear search",
              actionSystemImage: "xmark.circle",
              action: { query = "" }
            )
            .frame(maxWidth: .infinity, minHeight: 220)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visibleContacts) { row in
                if let contact = row.contact {
                  HStack(spacing: 0) {
                    Button { selectedContact = contact } label: { ContactRowView(identity: row.identity) }
                      .buttonStyle(.plain)
                    Menu {
                      Button("edit contact", systemImage: "pencil") {
                        selectedContact = contact
                      }
                      Button("copy public key", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = row.identity.npub
                      }
                    } label: {
                      Image(systemName: "ellipsis")
                        .frame(
                          width: LinkstrTheme.minimumInteractiveDimension,
                          height: LinkstrTheme.minimumInteractiveDimension
                        )
                    }
                    .tint(LinkstrTheme.textSecondary)
                    .accessibilityLabel("contact actions for \(row.identity.displayName)")
                  }
                  .contentShape(Rectangle())
                  .overlay(alignment: .bottom) { LinkstrListRowDivider(leadingInset: 62) }
                  .contextMenu {
                    Button("copy public key", systemImage: "doc.on.doc") {
                      UIPasteboard.general.string = row.identity.npub
                    }
                    Button("remove contact", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                      pendingContactRemoval = contact
                    }
                  }
                  .accessibilityAction(named: Text("remove contact")) { pendingContactRemoval = contact }
                }
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .linkstrKeyboardDismissal()
    }
  }

}

private struct ContactRowView: View {
  let identity: LinkstrResolvedIdentity

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrContactAvatar(name: identity.displayName, size: 48)

      LinkstrContactIdentityView(
        identity: identity,
        primaryFont: LinkstrTheme.font(.subheadline, weight: .medium)
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "chevron.right")
        .font(LinkstrTheme.font(.caption, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)
    }
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .contentShape(Rectangle())
  }
}
