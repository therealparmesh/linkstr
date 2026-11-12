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
  @State var isShowingAvailableContacts = false
  @State var pendingContactAddition: ContactPresentation?
  @State var pendingMemberChange: ContactPresentation?
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
    let includesYou = session.identityService.pubkeyHex.map(includedMemberHexes.contains) ?? false
    let availableContacts = filteredContacts(contacts: orderedContacts)
    let lookupPubkeys = profileLookupPubkeys(contacts: orderedContacts, currentMembers: currentMembers)

    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrSheetTitle(title: canManageSession ? "manage session" : "session members")
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
                  .font(LinkstrTheme.font(.subheadline))
                  .foregroundStyle(LinkstrTheme.textPrimary)
                  .lineLimit(3)
                  .textSelection(.enabled)
                  .linkstrInputField()
              }
            }
            LinkstrInsetSection(
              title: "members",
              accessory: includesYou ? "\(includedMemberHexes.count) including you" : "\(includedMemberHexes.count)",
              footer: canManageSession ? "membership changes take effect when you save." : nil
            ) {
              if currentMembers.isEmpty {
                Text(includesYou ? "only you are in this session." : "no active members.")
                  .font(LinkstrTheme.font(.footnote))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              } else {
                VStack(spacing: 0) {
                  ForEach(currentMembers) { member in
                    let identity = member.identity
                    HStack(spacing: LinkstrTheme.rowSpacing) {
                      LinkstrContactAvatar(name: identity.displayName, size: LinkstrTheme.memberAvatarSize)
                        .accessibilityHidden(true)

                      LinkstrContactIdentityView(
                        identity: identity,
                        primaryFont: LinkstrTheme.font(.subheadline, weight: .medium)
                      )
                      .frame(maxWidth: .infinity, alignment: .leading)

                      if member.contact == nil {
                        LinkstrHeaderButton(
                          title: "add \(identity.displayName) to contacts", icon: "person.badge.plus"
                        ) {
                          pendingContactAddition = member
                        }
                        .disabled(isSaving || isDeletingSession)
                      }

                      if canManageSession {
                        LinkstrHeaderButton(
                          title: "remove \(identity.displayName) from session",
                          icon: "person.badge.minus",
                          foreground: LinkstrTheme.destructive
                        ) {
                          pendingMemberChange = member
                        }
                        .disabled(isSaving || isDeletingSession)
                      }
                    }
                    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
                    .contentShape(Rectangle())
                    .contextMenu {
                      Button("copy public key", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = identity.npub
                      }
                      if canManageSession {
                        Button("remove from session", systemImage: "person.badge.minus", role: .destructive) {
                          pendingMemberChange = member
                        }
                        .disabled(isSaving || isDeletingSession)
                      }
                    }
                    .accessibilityAction(named: Text("copy public key")) { UIPasteboard.general.string = identity.npub }

                    if member.pubkey != currentMembers.last?.pubkey {
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
          .linkstrPageContentLayout()
        }
        .linkstrKeyboardDismissal()
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(
            title: canManageSession ? "cancel" : "close", icon: "xmark"
          ) {
            dismiss()
          }
          .disabled(isSaving || isDeletingSession)
        }
        .linkstrFlatToolbarItem()
        if canManageSession {
          ToolbarItem(placement: .confirmationAction) {
            LinkstrHeaderButton(title: "save session", icon: "checkmark", action: saveSession)
              .disabled(isSaving || isDeletingSession || !canSave)
          }
          .linkstrFlatToolbarItem()
        }
      }
      .contactAddition(pending: $pendingContactAddition)
      .sheet(item: $pendingMemberChange) { member in
        let isRemoving = includedMemberHexes.contains(member.pubkey)
        LinkstrConfirmationSheet(
          title: isRemoving ? "remove from session" : "add to session",
          message: isRemoving
            ? "remove \(member.identity.displayName) from this session when you save? your contacts stay unchanged."
            : "add \(member.identity.displayName) to this session when you save?",
          isDestructive: isRemoving,
          onConfirm: {
            if isRemoving {
              includedMemberHexes.remove(member.pubkey)
            } else {
              includedMemberHexes.insert(member.pubkey)
            }
          }
        )
      }
      .sheet(isPresented: $isPresentingDeleteConfirmation) {
        LinkstrConfirmationSheet(
          title: "delete session",
          message:
            "linkstr notifies known members and removes this session from this device. "
              + "older copies may remain on relays.",
          onConfirm: {
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
    .interactiveDismissDisabled(isSaving || isDeletingSession)
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }
}
