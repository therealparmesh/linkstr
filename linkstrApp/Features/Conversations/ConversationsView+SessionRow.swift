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
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: "new session")
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
              accessory: "\(selectedNPubs.count + 1)"
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

                if filteredContacts.isEmpty {
                  Text("no contacts match.")
                    .font(LinkstrTheme.font(.footnote))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                } else {
                  VStack(spacing: 0) {
                    ForEach(filteredContacts) { contact in
                      let identity = session.resolvedIdentity(for: contact)
                      Button {
                        toggle(contact.npub)
                      } label: {
                        HStack(spacing: LinkstrTheme.rowSpacing) {
                          LinkstrContactAvatar(name: identity.displayName, size: 38)
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
                          .foregroundStyle(
                            selectedNPubs.contains(contact.npub)
                              ? LinkstrTheme.accent : LinkstrTheme.textTertiary
                          )
                        }
                        .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
                        .contentShape(Rectangle())
                      }
                      .buttonStyle(.plain)

                      if contact.id != filteredContacts.last?.id {
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
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("cancel")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isCreating)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button {
            createSession()
          } label: {
            if isCreating {
              ProgressView()
                .frame(width: 30, height: 30, alignment: .center)
            } else {
              Image(systemName: "plus.circle.fill")
                .linkstrToolbarIconLabel()
            }
          }
          .accessibilityLabel("create session")
          .tint(LinkstrTheme.accent)
          .disabled(isCreating || !canCreateSession)
        }
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
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }
}

// MARK: - SessionManagementSheet

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
              accessory: "\(visibleCurrentMembers.count + 1)"
            ) {
              if visibleCurrentMembers.isEmpty {
                Text("only you are in this session.")
                  .font(LinkstrTheme.font(.footnote))
                  .foregroundStyle(LinkstrTheme.textSecondary)
              } else {
                VStack(spacing: 0) {
                  ForEach(visibleCurrentMembers, id: \.self) { memberHex in
                    let identity = memberIdentity(for: memberHex)
                    HStack(spacing: LinkstrTheme.rowSpacing) {
                      LinkstrContactAvatar(
                        name: identity?.displayName ?? "you",
                        size: 38
                      )

                      if let identity {
                        LinkstrContactIdentityView(
                          identity: identity,
                          primaryFont: LinkstrTheme.font(.footnote, weight: .medium)
                        )
                      } else {
                        Text("you")
                          .font(LinkstrTheme.font(.footnote, weight: .medium))
                          .foregroundStyle(LinkstrTheme.textPrimary)
                      }

                      Spacer()

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
                        .accessibilityLabel("remove \(identity?.displayName ?? "member")")
                      }
                    }
                    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)

                    if memberHex != visibleCurrentMembers.last {
                      LinkstrListRowDivider(leadingInset: 50)
                    }
                  }
                }
              }
            }

            if canManageSession {
              managementSections
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
      .task(id: profileLookupPubkeys.stableTaskID) {
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
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
