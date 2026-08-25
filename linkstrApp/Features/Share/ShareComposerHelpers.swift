import SwiftUI

// MARK: - ShareComposerView Helpers

extension ShareComposerView {
  var linkFieldHint: String? {
    let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let normalizedURL else { return "enter a valid link." }
    return NewPostSheet.composerAvailabilityHint(
      for: URLClassifier.mediaStrategy(for: normalizedURL)
    )
  }

  var linkFieldHintColor: Color {
    normalizedURL == nil
      ? LinkstrTheme.destructive.opacity(0.92)
      : LinkstrTheme.accent.opacity(0.92)
  }

  func selectDefaultSessionIfNeeded() {
    guard selectedSessionID == nil else { return }
    selectedSessionID = activeSessions.first?.sessionID
  }

  func clearMissingSelectionIfNeeded() {
    guard let selectedSessionID else { return }
    guard activeSessions.contains(where: { $0.sessionID == selectedSessionID }) else {
      self.selectedSessionID = nil
      return
    }
  }

  func sendSharedLink() {
    guard let normalizedURL else { return }
    guard let selectedSession else { return }
    guard !isSending else { return }

    let targetSessionID = selectedSession.sessionID
    let targetSessionName = selectedSession.name

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
      if result.didSucceed {
        #if canImport(UIKit)
          let haptic = UINotificationFeedbackGenerator()
          haptic.prepare()
          haptic.notificationOccurred(.success)
        #endif
        appSession.requestSessionNavigation(to: targetSessionID)
        LinkstrToast.showSuccess("shared to \(targetSessionName)")
        deepLinkHandler.clearShareDraft()
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
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: "choose session")

            LinkstrInsetSection(title: "session") {
              LinkstrSearchField(
                prompt: "search sessions",
                text: $query,
                submitLabel: .search
              )

              sessionPicker
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
        .scrollDismissesKeyboard(.interactively)
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
          .accessibilityLabel("close session picker")
          .tint(LinkstrTheme.textSecondary)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private var sessionPicker: some View {
    if visibleSessions.isEmpty {
      LinkstrShareEmptyPickerState(
        title: "no sessions found",
        systemImage: "magnifyingglass",
        description: "try a different search."
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
              isSelected: selectedSessionID == sessionEntity.sessionID
            )
          }
          .buttonStyle(.plain)

          if sessionEntity.storageID != visibleSessions.last?.storageID {
            LinkstrListRowDivider(leadingInset: 54)
          }
        }
      }
    }
  }
}

struct ShareSelectedSessionRow: View {
  let session: SessionEntity

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrSessionAvatar(seed: session.sessionID, size: 42)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(session.name)
          .font(LinkstrTheme.font(.headline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(1)

        Text("tap to change")
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .foregroundStyle(LinkstrTheme.textTertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      Image(systemName: "chevron.right")
        .font(LinkstrTheme.font(.footnote, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.name), tap to change")
  }
}

struct ShareSessionPickerRow: View {
  let session: SessionEntity
  let isSelected: Bool

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrSessionAvatar(seed: session.sessionID, size: 42)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(session.name)
          .font(LinkstrTheme.font(.headline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(1)

        Text(session.updatedAt.linkstrListTimestampLabel)
          .font(LinkstrTheme.font(.caption, weight: .medium))
          .foregroundStyle(LinkstrTheme.textTertiary)
          .lineLimit(1)
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
    .accessibilityLabel("\(session.name), \(isSelected ? "selected" : "not selected")")
  }
}

struct LinkstrShareEmptyPickerState: View {
  let title: String
  let systemImage: String
  let description: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(LinkstrTheme.font(.title2, weight: .semibold))
        .foregroundStyle(LinkstrTheme.accent)

      Text(title)
        .font(LinkstrTheme.font(.headline, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)

      Text(description)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 20)
  }
}
