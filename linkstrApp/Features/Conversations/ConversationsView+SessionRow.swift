import SwiftData
import SwiftUI
import UIKit

struct NewSessionSheet: View {
  enum Field: Hashable {
    case sessionName
    case search
  }

  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var session: AppSession
  @Query
  var contacts: [ContactEntity]

  @State var sessionName = ""
  @State var query = ""
  @State var selectedNPubs = Set<String>()
  @State var isCreating = false
  @State var isPresentingAddContact = false
  @State var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState var focusedField: Field?

  init(ownerPubkey: String) {
    _contacts = Query(
      filter: #Predicate<ContactEntity> { contact in
        contact.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\ContactEntity.createdAt)]
    )
  }

  var body: some View {
    let visibleContacts = filteredContacts
    let lastContactID = visibleContacts.last?.id

    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrSheetTitle(title: "new session")
            LinkstrInsetSection(title: "session details") {
              TextField("session name", text: $sessionName)
                .font(LinkstrTheme.font(.subheadline))
                .focused($focusedField, equals: .sessionName)
                .textInputAutocapitalization(.words)
                .submitLabel(contacts.isEmpty ? .done : .next)
                .onSubmit(handleSessionNameSubmit)
                .linkstrInputField()
            }

            LinkstrInsetSection(
              title: "members",
              accessory: "\(selectedNPubs.count + 1)",
              footer: "you’re included. choose contacts to invite, or start a session for yourself."
            ) {
              if contacts.isEmpty {
                LinkstrNoContactsPrompt {
                  focusedField = nil
                  isPresentingAddContact = true
                }
              } else {
                LinkstrSearchField(
                  prompt: "search contacts",
                  text: $query,
                  submitLabel: .done,
                  onSubmit: dismissKeyboard
                )
                .focused($focusedField, equals: .search)

                if visibleContacts.isEmpty {
                  Text("no contacts match.")
                    .font(LinkstrTheme.font(.footnote))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                } else {
                  VStack(spacing: 0) {
                    ForEach(visibleContacts) { contact in
                      let identity = session.resolvedIdentity(for: contact)
                      Button {
                        toggle(contact.npub)
                      } label: {
                        HStack(spacing: LinkstrTheme.rowSpacing) {
                          LinkstrContactAvatar(name: identity.displayName, size: LinkstrTheme.memberAvatarSize)
                            .accessibilityHidden(true)
                          LinkstrContactIdentityView(
                            identity: identity,
                            primaryFont: LinkstrTheme.font(.footnote, weight: .medium)
                          )

                          Spacer()

                          Image(
                            systemName: selectedNPubs.contains(contact.npub)
                              ? "checkmark.circle.fill" : "circle"
                          )
                          .font(LinkstrTheme.font(.title3, weight: .semibold))
                          .dynamicTypeSize(...DynamicTypeSize.xLarge)
                          .foregroundStyle(
                            selectedNPubs.contains(contact.npub)
                              ? LinkstrTheme.accent : LinkstrTheme.textTertiary
                          )
                          .accessibilityHidden(true)
                        }
                        .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
                        .contentShape(Rectangle())
                      }
                      .buttonStyle(.plain)
                      .contextMenu {
                        Button("copy public key", systemImage: "doc.on.doc") {
                          UIPasteboard.general.string = identity.npub
                        }
                      }
                      .accessibilityAction(named: Text("copy public key")) {
                        UIPasteboard.general.string = identity.npub
                      }
                      .accessibilityAddTraits(selectedNPubs.contains(contact.npub) ? .isSelected : [])
                      .accessibilityHint(
                        selectedNPubs.contains(contact.npub) ? "remove from session" : "add to session"
                      )

                      if contact.id != lastContactID {
                        LinkstrListRowDivider(leadingInset: 50)
                      }
                    }
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

      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          LinkstrHeaderButton(title: "cancel", icon: "xmark") {
            dismiss()
          }
          .disabled(isCreating)
        }
        .linkstrFlatToolbarItem()

        ToolbarItem(placement: .topBarTrailing) {
          LinkstrHeaderButton(title: "create session", icon: "checkmark", action: createSession)
            .disabled(isCreating || !canCreateSession)
        }
        .linkstrFlatToolbarItem()
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let footerStatus {
          LinkstrSheetStatusFooter(
            message: footerStatus.message,
            messageColor: footerStatus.color
          )
        }
      }
      .task(id: profileLookupPubkeys.stableTaskID) {
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
      }
      .onChange(of: sessionName) { _, _ in
        mutationFeedback.clear()
      }
    }
    .interactiveDismissDisabled(isCreating)
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }
}
