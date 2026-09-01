import NostrSDK
import SwiftData
import SwiftUI
import UIKit

struct LinkstrNoContactsPrompt: View {
  let addContact: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      Text("no contacts yet. add someone to invite them.")
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)

      Button(action: addContact) {
        LinkstrActionButtonLabel(title: "add contact", systemImage: "person.badge.plus")
      }
      .linkstrSecondaryButton()
    }
  }
}

// MARK: - NewSessionSheet Helpers

extension NewSessionSheet {
  var canCreateSession: Bool {
    !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var profileLookupPubkeys: [String] {
    contacts.map(\.targetPubkey)
  }

  var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isCreating,
      progressMessage: "waiting for relay reconnect before creating...",
      validationMessage: canCreateSession ? nil : "session name required."
    )
  }

  var filteredContacts: [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: query,
      displayName: { session.resolvedIdentity(for: $0).displayName },
      npub: \.npub,
      additionalNames: { session.searchableNames(for: $0) }
    )
  }

  func toggle(_ npub: String) {
    mutationFeedback.clear()
    if selectedNPubs.contains(npub) {
      selectedNPubs.remove(npub)
    } else {
      selectedNPubs.insert(npub)
    }
  }

  func createSession() {
    guard !isCreating else { return }
    guard canCreateSession else { return }
    dismissKeyboard()
    mutationFeedback.clear()
    let selected = Array(selectedNPubs)
    isCreating = true

    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.createSessionAwaitingRelay(
          name: sessionName,
          memberNPubs: selected
        )
      }
      isCreating = false
      if result.didSucceed {
        dismiss()
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }

  func handleSessionNameSubmit() {
    if contacts.isEmpty {
      createSession()
    } else {
      focusedField = .search
    }
  }

  func dismissKeyboard() {
    focusedField = nil
  }
}

// MARK: - SessionManagementSheet Helpers

extension SessionManagementSheet {
  @ViewBuilder
  func managementSections(
    hasContacts: Bool,
    filteredContacts: [ContactEntity]
  ) -> some View {
    addContactsSection(
      hasContacts: hasContacts,
      filteredContacts: filteredContacts
    )
    archiveSection
    dangerZoneSection
  }

  @ViewBuilder
  private func addContactsSection(
    hasContacts: Bool,
    filteredContacts: [ContactEntity]
  ) -> some View {
    let lastContactID = filteredContacts.last?.id
    LinkstrInsetSection(title: "add from contacts") {
      if !hasContacts {
        LinkstrNoContactsPrompt {
          focusedField = nil
          isPresentingAddContact = true
        }
      } else {
        LinkstrSearchField(prompt: "search contacts", text: $query)

        if filteredContacts.isEmpty {
          Text("no contacts match.")
            .font(LinkstrTheme.font(.footnote))
            .foregroundStyle(LinkstrTheme.textSecondary)
        } else {
          VStack(spacing: 0) {
            ForEach(filteredContacts) { contact in
              managementContactRow(contact, isLast: contact.id == lastContactID)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func managementContactRow(_ contact: ContactEntity, isLast: Bool) -> some View {
    let identity = session.resolvedIdentity(for: contact)
    let contactHex = contact.targetPubkey
    Button {
      if includedMemberHexes.contains(contactHex) {
        includedMemberHexes.remove(contactHex)
      } else {
        includedMemberHexes.insert(contactHex)
      }
    } label: {
      HStack(spacing: LinkstrTheme.rowSpacing) {
        LinkstrContactAvatar(name: identity.displayName, size: 38)
        LinkstrContactIdentityView(
          identity: identity,
          primaryFont: LinkstrTheme.font(.footnote, weight: .medium)
        )

        Spacer()

        Image(
          systemName: includedMemberHexes.contains(contactHex)
            ? "checkmark.circle.fill" : "circle"
        )
        .font(LinkstrTheme.font(.title3, weight: .semibold))
        .foregroundStyle(
          includedMemberHexes.contains(contactHex)
            ? LinkstrTheme.accent : LinkstrTheme.textTertiary
        )
      }
      .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)

    if !isLast {
      LinkstrListRowDivider(leadingInset: 50)
    }
  }

  private var dangerZoneSection: some View {
    LinkstrInsetSection(title: "danger zone", footer: deleteFooterText) {
      Button(role: .destructive) {
        guard !isSaving, !isDeletingSession else { return }
        focusedField = nil
        mutationFeedback.clear()
        isPresentingDeleteConfirmation = true
      } label: {
        HStack(spacing: LinkstrTheme.rowSpacing) {
          Label("delete session", systemImage: "trash")
            .font(LinkstrTheme.font(.footnote, weight: .semibold))
          Spacer()
        }
        .foregroundStyle(LinkstrTheme.destructive)
        .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving || isDeletingSession)
    }
  }

  @ViewBuilder
  var readOnlySections: some View {
    archiveSection

    LinkstrInsetSection(title: "permissions") {
      Text("only the session creator can rename, delete, or change membership.")
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
    }
  }

  @ViewBuilder
  var archiveSection: some View {
    LinkstrInsetSection(
      title: "session visibility",
      footer: archiveFooterText
    ) {
      Button {
        toggleArchived()
      } label: {
        HStack(spacing: LinkstrTheme.rowSpacing) {
          Label(
            sessionEntity.isArchived ? "unarchive session" : "archive session",
            systemImage: sessionEntity.isArchived ? "tray.and.arrow.up" : "archivebox"
          )
          .font(LinkstrTheme.font(.footnote, weight: .semibold))
          Spacer()
        }
        .foregroundStyle(LinkstrTheme.textPrimary)
        .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving || isDeletingSession)
    }
  }

  var sortedContacts: [ContactEntity] {
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

  var canManageSession: Bool {
    session.canManageSession(for: sessionEntity)
  }

  var canSave: Bool {
    !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isSaving || isDeletingSession,
      progressMessage: isDeletingSession
        ? "waiting for relay reconnect before deleting..."
        : "waiting for relay reconnect before saving...",
      validationMessage: isDeletingSession || canSave ? nil : "session name required."
    )
  }

  var archiveFooterText: String {
    sessionEntity.isArchived
      ? "unarchiving returns this session to the main sessions list on this device."
      : "archiving hides this session from the main sessions list on this device."
  }

  var deleteFooterText: String {
    "deleting removes this session from the app and sends delete notices to known members."
  }

  func visibleCurrentMembers(contacts: [ContactEntity]) -> [String] {
    let myPubkey = session.identityService.pubkeyHex
    return
      includedMemberHexes
      .filter { memberHex in
        guard let myPubkey else { return true }
        return memberHex != myPubkey
      }
      .sorted {
        session.displayName(for: $0, contacts: contacts).localizedCaseInsensitiveCompare(
          session.displayName(for: $1, contacts: contacts)
        ) == .orderedAscending
      }
  }

  func filteredContacts(contacts: [ContactEntity]) -> [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: query,
      displayName: { session.resolvedIdentity(for: $0).displayName },
      npub: \.npub,
      additionalNames: { session.searchableNames(for: $0) }
    )
  }

  func profileLookupPubkeys(
    contacts: [ContactEntity],
    currentMembers: [String]
  ) -> [String] {
    var pubkeys = contacts.map(\.targetPubkey)
    pubkeys.append(contentsOf: currentMembers)
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeys)
  }

  func memberIdentity(
    for pubkeyHex: String,
    contacts: [ContactEntity]
  ) -> LinkstrResolvedIdentity? {
    guard pubkeyHex != session.identityService.pubkeyHex else { return nil }
    return session.resolvedIdentity(for: pubkeyHex, contacts: contacts)
  }

  func saveSession() {
    guard canManageSession else {
      session.composeError = "only the session creator can manage this session."
      return
    }
    guard !isSaving, !isDeletingSession, canSave else { return }
    focusedField = nil
    mutationFeedback.clear()
    isSaving = true

    let memberNPubs = includedMemberHexes.compactMap { PublicKey(hex: $0)?.npub }
    let nameToSend = pendingSessionName

    Task { @MainActor in
      let result = await session.performFormMutation {
        await session.updateSessionMembersAwaitingRelay(
          session: sessionEntity,
          memberNPubs: memberNPubs,
          sessionName: nameToSend
        )
      }
      isSaving = false
      if result.didSucceed {
        dismiss()
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }

  var pendingSessionName: String? {
    let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != sessionEntity.name else { return nil }
    return trimmed
  }

  func syncStateIfNeeded() {
    if sessionName.isEmpty {
      sessionName = sessionEntity.name
    }
    syncMembersIfNeeded()
  }

  func syncMembersIfNeeded() {
    guard includedMemberHexes.isEmpty else { return }
    includedMemberHexes = Set(activeMembers.map(\.memberPubkey))
  }

  func toggleArchived() {
    guard !isSaving, !isDeletingSession else { return }
    focusedField = nil
    mutationFeedback.clear()
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    session.setSessionArchived(
      sessionID: sessionEntity.sessionID,
      archived: !sessionEntity.isArchived
    )
    dismiss()
  }
}
