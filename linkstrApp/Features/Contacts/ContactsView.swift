import SwiftData
import SwiftUI
import UIKit

struct ContactsView: View {
  @EnvironmentObject private var session: AppSession
  let addContact: () -> Void

  @Query
  private var contacts: [ContactEntity]

  @State private var selectedContact: ContactEntity?
  @State private var pendingContactRemoval: ContactEntity?
  @State private var isRemovingContact = false
  @State private var query = ""

  init(ownerPubkey: String, addContact: @escaping () -> Void) {
    self.addContact = addContact
    _contacts = Query(
      filter: #Predicate<ContactEntity> { contact in
        contact.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\ContactEntity.createdAt)]
    )
  }

  private var sortedContacts: [ContactEntity] {
    return
      contacts
      .map { contact in
        (contact: contact, displayName: session.resolvedIdentity(for: contact).displayName)
      }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
      .map(\.contact)
  }

  private func visibleContacts(in contacts: [ContactEntity]) -> [ContactEntity] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return contacts }
    return RecipientSearchLogic.filteredContacts(
      contacts,
      query: normalizedQuery,
      displayName: { session.resolvedIdentity(for: $0).displayName },
      npub: \.npub,
      additionalNames: { session.searchableNames(for: $0) }
    )
  }

  var body: some View {
    let profileLookupPubkeys = contacts.map(\.targetPubkey)

    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .alert("remove contact", isPresented: isPresentingRemovalConfirmation) {
      Button("cancel", role: .cancel) {}
      Button(isRemovingContact ? "removing..." : "remove", role: .destructive) {
        removePendingContact()
      }
    } message: {
      Text(removeContactConfirmationMessage)
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
    let orderedContacts = sortedContacts
    let visibleContacts = visibleContacts(in: orderedContacts)

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
              ForEach(visibleContacts) { contact in
                let identity = session.resolvedIdentity(for: contact)
                Button {
                  selectedContact = contact
                } label: {
                  ContactRowView(identity: identity)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                  Button(role: .destructive) {
                    pendingContactRemoval = contact
                  } label: {
                    Label("remove contact", systemImage: "person.crop.circle.badge.minus")
                  }
                }
                .accessibilityHint("long press for contact actions.")
                .accessibilityAction(named: Text("remove contact")) {
                  pendingContactRemoval = contact
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

  private var isPresentingRemovalConfirmation: Binding<Bool> {
    Binding(
      get: { pendingContactRemoval != nil },
      set: { isPresented in
        if !isPresented {
          pendingContactRemoval = nil
        }
      }
    )
  }

  private var removeContactConfirmationMessage: String {
    guard let pendingContactRemoval else {
      return "this updates your follow list on relays and removes this contact locally."
    }

    return
      "this updates your follow list on relays, removes "
      + "\(session.resolvedIdentity(for: pendingContactRemoval).displayName) "
      + "from your contacts, and removes the contact locally."
  }

  private func removePendingContact() {
    guard !isRemovingContact, let pendingContactRemoval else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    isRemovingContact = true
    Task { @MainActor in
      let didRemove = await session.removeContact(pendingContactRemoval)
      isRemovingContact = false
      if didRemove {
        self.pendingContactRemoval = nil
      }
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
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider(leadingInset: 62)
    }
  }
}

private struct EditContactView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contact: ContactEntity

  @State private var alias: String

  init(contact: ContactEntity) {
    self.contact = contact
    _alias = State(initialValue: contact.localAlias ?? "")
  }

  var body: some View {
    let identity = session.resolvedIdentity(for: contact)
    ZStack {
      LinkstrBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          LinkstrScreenTitle(title: "edit contact")

          LinkstrInsetSection(
            title: "contact",
            footer: "only you see this alias. the public key (npub) stays the real identity."
          ) {
            HStack(spacing: LinkstrTheme.rowSpacing) {
              LinkstrContactAvatar(name: identity.displayName, size: 54)
              LinkstrContactIdentityView(identity: identity, lineLimit: 2)
            }
          }

          LinkstrInsetSection(title: "alias") {
            TextField("alias", text: $alias)
              .font(LinkstrTheme.font(.subheadline))
              .textInputAutocapitalization(.words)
              .submitLabel(.done)
              .onSubmit(saveAlias)
              .linkstrInputField()
          }

          if let nostrChosenName = identity.chosenName {
            LinkstrInsetSection(title: "published nostr name") {
              Text(nostrChosenName)
                .font(LinkstrTheme.font(.footnote))
                .foregroundStyle(
                  contact.localAlias == nil
                    ? LinkstrTheme.textPrimary : LinkstrTheme.accentPink.opacity(0.88)
                )
                .lineLimit(3)
                .textSelection(.enabled)
                .linkstrInputField()
            }
          }

          LinkstrInsetSection(title: "public key (npub)") {
            Text(contact.npub)
              .font(LinkstrTheme.font(.footnote))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .lineLimit(1)
              .textSelection(.enabled)
              .linkstrInputField()
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .linkstrKeyboardDismissal()
    }
    .navigationBarBackButtonHidden(true)
    .linkstrBarChrome()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("back")
        .tint(LinkstrTheme.accent)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          saveAlias()
        } label: {
          Image(systemName: "checkmark")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("save contact")
        .tint(LinkstrTheme.accent)
        .disabled(canSaveAlias == false)
      }
    }
  }

  private func saveAlias() {
    guard canSaveAlias else { return }
    let didSave = session.updateContactAlias(contact, alias: alias)
    if didSave {
      dismiss()
    }
  }

  private var canSaveAlias: Bool {
    normalizedAlias != persistedAlias
  }

  private var normalizedAlias: String {
    alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var persistedAlias: String {
    contact.localAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
