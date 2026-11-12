import SwiftUI

// MARK: - ShareComposerView Helpers

extension ShareComposerView {
  func selectDefaultSessionIfNeeded() {
    // Retain an unavailable selection so a different recipient is never substituted.
    guard selectedSessionID == nil else { return }
    selectedSessionID = activeSessions.first?.sessionID
  }

  func sendSharedLink() {
    guard let normalizedURL else { return }
    guard let selectedSession else { return }
    guard !isSending else { return }

    let targetSessionID = selectedSession.sessionID
    let targetSessionName = selectedSession.name
    let requestID = deepLinkHandler.latestRequestID

    link = normalizedURL
    focusedField = nil
    mutationFeedback.clear()

    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    isSending = true

    Task { @MainActor in
      let result = await appSession.performFormMutation {
        await appSession.createSessionPostAwaitingRelay(
          url: normalizedURL,
          note: trimmedNote.isEmpty ? nil : trimmedNote,
          session: selectedSession
        )
      }
      isSending = false
      guard deepLinkHandler.latestRequestID == requestID, deepLinkHandler.pendingShareDraft == draft else { return }
      if result.didSucceed {
        #if canImport(UIKit)
          let haptic = UINotificationFeedbackGenerator()
          haptic.prepare()
          haptic.notificationOccurred(.success)
        #endif
        appSession.requestSessionNavigation(to: targetSessionID)
        LinkstrToast.showSuccess("shared to \(targetSessionName)")
        deepLinkHandler.clearShareDraft(matching: draft)
      } else {
        mutationFeedback.record(errorMessage: result.errorMessage)
      }
    }
  }
}

// MARK: - Share Session Picker

struct ShareSessionPickerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let sessions: [SessionEntity]
  let avatarsBySessionID: [String: [SessionMemberAvatar]]
  @Binding var selectedSessionID: String?

  @State private var query = ""

  private var visibleSessions: [SessionEntity] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    guard !normalizedQuery.isEmpty else { return sessions }

    return sessions.filter { sessionEntity in
      sessionEntity.name.localizedLowercase.contains(normalizedQuery)
        || sessionEntity.sessionID.localizedLowercase.contains(normalizedQuery)
    }
  }

  var body: some View {
    let filteredSessions = visibleSessions

    NavigationStack {
      ZStack {
        LinkstrBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrSheetTitle(title: "choose a session")

            LinkstrInsetSection(title: "sessions") {
              LinkstrSearchField(
                prompt: "search sessions",
                text: $query,
                submitLabel: .search
              )

              sessionPicker(filteredSessions)
            }
          }
          .linkstrPageContentLayout()
        }
        .linkstrKeyboardDismissal()
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "close session picker", icon: "xmark") { dismiss() }
        }
        .linkstrFlatToolbarItem()
      }
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private func sessionPicker(_ visibleSessions: [SessionEntity]) -> some View {
    let lastSessionID = visibleSessions.last?.storageID

    if visibleSessions.isEmpty {
      LinkstrCenteredEmptyStateView(
        title: sessions.isEmpty ? "no active sessions" : "no sessions found",
        systemImage: sessions.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
        description: sessions.isEmpty ? "create a session before sharing links." : "try another search.",
        actionTitle: sessions.isEmpty ? nil : "clear search",
        actionSystemImage: "xmark.circle",
        action: { query = "" }
      )
      .frame(maxWidth: .infinity, minHeight: 180)
    } else {
      VStack(spacing: 0) {
        ForEach(visibleSessions, id: \.storageID) { sessionEntity in
          Button {
            selectedSessionID = sessionEntity.sessionID
            dismiss()
          } label: {
            ShareSessionPickerRow(
              session: sessionEntity,
              memberAvatars: avatarsBySessionID[sessionEntity.sessionID, default: []],
              isSelected: selectedSessionID == sessionEntity.sessionID
            )
          }
          .buttonStyle(.plain)

          if sessionEntity.storageID != lastSessionID {
            LinkstrListRowDivider(leadingInset: 50 + LinkstrTheme.rowSpacing)
          }
        }
      }
    }
  }
}

struct ShareSelectedSessionRow: View {
  let session: SessionEntity
  let memberAvatars: [SessionMemberAvatar]
  var isSelectable = false

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      SessionAvatarCluster(members: memberAvatars)

      Text(session.name)
        .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .multilineTextAlignment(.leading)

      if isSelectable {
        Spacer(minLength: 8)
        LinkstrDisclosureIndicator()
      }
    }
    .linkstrInputField()
    .contentShape(Rectangle())
  }
}

struct ShareSessionPickerRow: View {
  let session: SessionEntity
  let memberAvatars: [SessionMemberAvatar]
  let isSelected: Bool

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      SessionAvatarCluster(members: memberAvatars)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(session.name)
          .font(LinkstrTheme.font(.headline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Text(session.updatedAt.linkstrListTimestampLabel)
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Group {
        if isSelected {
          Image(systemName: "checkmark")
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.accent)
        } else {
          Color.clear
        }
      }
      .frame(width: 22, height: 22, alignment: .center)
      .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
