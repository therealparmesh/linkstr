import SwiftData
import SwiftUI
import UIKit

struct SessionManagementSheet: View {
  enum Field: Hashable {
    case sessionName
  }

  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var session: AppSession
  @Query
  var contacts: [ContactEntity]
  @Query
  var activeMembers: [SessionMemberEntity]

  let sessionEntity: SessionEntity

  @State var sessionName = ""
  @State var includedMemberHexes = Set<String>()
  @State var query = ""
  @State var isSaving = false
  @State var isDeletingSession = false
  @State var isPresentingDeleteConfirmation = false
  @State var isPresentingAddContact = false
  @State var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState var focusedField: Field?

  init(sessionEntity: SessionEntity) {
    self.sessionEntity = sessionEntity
    let ownerPubkey = sessionEntity.ownerPubkey
    let sessionID = sessionEntity.sessionID
    _contacts = Query(
      filter: #Predicate<ContactEntity> { contact in
        contact.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\ContactEntity.createdAt)]
    )
    _activeMembers = Query(
      filter: #Predicate<SessionMemberEntity> { member in
        member.ownerPubkey == ownerPubkey
          && member.sessionID == sessionID
          && member.isActive == true
      },
      sort: [SortDescriptor(\SessionMemberEntity.createdAt)]
    )
  }

  var body: some View {
    let orderedContacts = sortedContacts
    let currentMembers = visibleCurrentMembers(contacts: orderedContacts)
    let availableContacts = filteredContacts(contacts: orderedContacts)
    let lookupPubkeys = profileLookupPubkeys(contacts: orderedContacts, currentMembers: currentMembers)

    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: canManageSession ? "manage session" : "session members")
            LinkstrInsetSection(title: "session details") {
              if canManageSession {
                TextField("session name", text: $sessionName)
                  .font(LinkstrTheme.font(.subheadline))
                  .focused($focusedField, equals: .sessionName)
                  .textInputAutocapitalization(.words)
                  .submitLabel(.done)
                  .onSubmit { focusedField = nil }
                  .linkstrInputField()
              } else {
                Text(sessionEntity.name)
                  .font(LinkstrTheme.font(.footnote))
                  .foregroundStyle(LinkstrTheme.textPrimary)
                  .lineLimit(3)
                  .textSelection(.enabled)
                  .linkstrInputField()
              }
            }
            LinkstrInsetSection(
              title: "current members",
              accessory: "\(currentMembers.count + 1)"
            ) {
              if currentMembers.isEmpty {
                Text("only you are in this session.")
                  .font(LinkstrTheme.font(.footnote))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              } else {
                VStack(spacing: 0) {
                  ForEach(currentMembers) { member in
                    let memberHex = member.pubkey
                    let identity = member.identity
                    HStack(spacing: LinkstrTheme.rowSpacing) {
                      LinkstrContactAvatar(
                        name: identity.displayName,
                        size: 38
                      )

                      LinkstrContactIdentityView(
                        identity: identity,
                        primaryFont: LinkstrTheme.font(.footnote, weight: .medium)
                      )

                      Spacer()

                      AddContactButton(
                        pubkey: memberHex, displayName: identity.displayName, isAdded: member.contact != nil
                      )
                      .disabled(isSaving || isDeletingSession)

                      if canManageSession {
                        Button(role: .destructive) {
                          includedMemberHexes.remove(memberHex)
                        } label: {
                          Image(systemName: "minus.circle.fill")
                            .font(LinkstrTheme.font(.title3, weight: .semibold))
                            .foregroundStyle(LinkstrTheme.destructive)
                            .frame(
                              width: LinkstrTheme.minimumInteractiveDimension,
                              height: LinkstrTheme.minimumInteractiveDimension
                            )
                        }
                        .accessibilityLabel("remove \(identity.displayName) from session")
                      }
                    }
                    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
                    .contextMenu {
                      Button("copy public key", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = identity.npub
                      }
                    }
                    .accessibilityAction(named: Text("copy public key")) { UIPasteboard.general.string = identity.npub }

                    if memberHex != currentMembers.last?.pubkey {
                      LinkstrListRowDivider(leadingInset: 50)
                    }
                  }
                }
              }
            }

            if canManageSession {
              managementSections(
                hasContacts: !orderedContacts.isEmpty,
                filteredContacts: availableContacts
              )
            } else {
              readOnlySections
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
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel(canManageSession ? "cancel" : "close")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isSaving || isDeletingSession)
        }
        if canManageSession {
          ToolbarItem(placement: .confirmationAction) {
            Button {
              saveSession()
            } label: {
              Image(systemName: "checkmark")
                .linkstrToolbarIconLabel()
            }
            .accessibilityLabel(isSaving ? "saving session" : "save session")
            .disabled(isSaving || isDeletingSession || !canSave)
            .tint(LinkstrTheme.accent)
          }
        }
      }
      .alert("delete session", isPresented: $isPresentingDeleteConfirmation) {
        Button("delete session", role: .destructive) {
          guard !isDeletingSession else { return }
          UINotificationFeedbackGenerator().notificationOccurred(.warning)
          mutationFeedback.clear()
          isDeletingSession = true
          Task { @MainActor in
            let result = await session.performFormMutation {
              await session.deleteSessionAwaitingRelay(sessionEntity)
            }
            isDeletingSession = false
            if result.didSucceed {
              dismiss()
            } else {
              mutationFeedback.record(errorMessage: result.errorMessage)
            }
          }
        }
        Button("cancel", role: .cancel) {}
      } message: {
        Text(
          "this permanently removes the session from your device and sends a delete notice to known members."
        )
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if canManageSession, let footerStatus {
          LinkstrSheetStatusFooter(
            message: footerStatus.message,
            messageColor: footerStatus.color
          )
        }
      }
      .task(id: lookupPubkeys.stableTaskID) {
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: lookupPubkeys)
      }
      .onAppear(perform: syncStateIfNeeded)
      .onChange(of: sessionName) { _, _ in
        mutationFeedback.clear()
      }
      .onChange(of: includedMemberHexes.stableTaskID) { _, _ in
        mutationFeedback.clear()
      }
      .onChange(of: activeMembers.map(\.memberPubkey).stableTaskID) { _, _ in
        syncMembersIfNeeded()
      }
    }
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }
}
