import SwiftData
import SwiftUI
import UIKit

struct ContactsView: View {
  @EnvironmentObject private var session: AppSession
  @ObservedObject private var nostrService: NostrDMService
  let addContact: () -> Void
  let ownerPubkey: String
  let openAddedYou: () -> Void

  @Query
  private var contacts: [ContactEntity]

  @State private var selectedContact: ContactEntity?
  @State private var pendingContactRemoval: ContactEntity?
  @State private var query = ""

  init(
    ownerPubkey: String, openAddedYou: @escaping () -> Void, nostrService: NostrDMService,
    addContact: @escaping () -> Void
  ) {
    self.nostrService = nostrService
    self.ownerPubkey = ownerPubkey
    self.openAddedYou = openAddedYou
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
      content
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
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          heading
          addedYouShortcut
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.pageHeaderTopPadding)

        if nostrService.contactListLoadState == .unavailable {
          retryState
        } else if nostrService.contactListLoadState == .ready {
          LinkstrCenteredEmptyStateView(
            title: "no contacts",
            systemImage: "person.2.slash",
            description: "add people you want to share links with.",
            actionTitle: "add contact",
            actionSystemImage: "person.badge.plus",
            action: addContact
          )
        } else {
          LinkstrLoadingStateView(title: "loading contacts")
            .frame(maxHeight: .infinity)
        }
      }
      .linkstrReadableContent()
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          heading

          LinkstrSearchField(prompt: "search contacts", text: $query)
          addedYouShortcut

          if visibleContacts.isEmpty, nostrService.contactListLoadState == .unavailable {
            retryState
              .frame(maxWidth: .infinity, minHeight: 220)
          } else if visibleContacts.isEmpty, nostrService.contactListLoadState == .ready {
            LinkstrCenteredEmptyStateView(
              title: "no contacts found",
              systemImage: "magnifyingglass",
              description: "try another search.",
              actionTitle: "clear search",
              actionSystemImage: "xmark.circle",
              action: { query = "" }
            )
            .frame(maxWidth: .infinity, minHeight: 220)
          } else if visibleContacts.isEmpty {
            LinkstrLoadingStateView(title: "loading contacts")
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visibleContacts) { row in
                if let contact = row.contact {
                  Button { selectedContact = contact } label: { ContactRowView(identity: row.identity) }
                  .buttonStyle(.plain)
                  .overlay(alignment: .bottom) { LinkstrListRowDivider(leadingInset: 62) }
                  .contextMenu {
                    Button("copy public key", systemImage: "doc.on.doc") {
                      UIPasteboard.general.string = row.identity.npub
                    }
                    Button("remove contact", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                      pendingContactRemoval = contact
                    }
                  }
                  .accessibilityHint("edit contact")
                  .accessibilityAction(named: Text("copy public key")) {
                    UIPasteboard.general.string = row.identity.npub
                  }
                  .accessibilityAction(named: Text("remove contact")) { pendingContactRemoval = contact }
                }
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.pageHeaderTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .linkstrKeyboardDismissal()
    }
  }

  private var heading: some View {
    LinkstrPageHeader(title: "contacts") {
      LinkstrHeaderButton(title: "add contact", icon: "person.badge.plus", action: addContact)
    }
  }

  private var addedYouShortcut: some View {
    LinkstrPageShortcut(title: "added you", icon: "person.crop.circle.badge.plus", action: openAddedYou)
      .accessibilityHint("view people who added you")
  }

  private var retryState: some View {
    LinkstrCenteredEmptyStateView(
      title: "couldn’t load contacts",
      systemImage: "wifi.exclamationmark",
      description: "check your connection and try again.",
      actionTitle: "try again",
      actionSystemImage: "arrow.clockwise",
      action: {
        session.startNostrIfPossible()
        nostrService.refreshFollowList()
      }
    )
  }
}

private struct ContactRowView: View {
  let identity: LinkstrResolvedIdentity

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrContactAvatar(name: identity.displayName, size: LinkstrTheme.contactAvatarSize)
        .accessibilityHidden(true)

      LinkstrContactIdentityView(
        identity: identity,
        primaryFont: LinkstrTheme.font(.subheadline, weight: .medium)
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      LinkstrDisclosureIndicator()
    }
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .contentShape(Rectangle())
  }
}
