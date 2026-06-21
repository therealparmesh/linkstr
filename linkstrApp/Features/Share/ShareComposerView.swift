import SwiftData
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct ShareComposerView: View {
  enum Field: Hashable {
    case link
    case note
  }

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject var appSession: AppSession
  @EnvironmentObject var deepLinkHandler: DeepLinkHandler

  @Query var sessions: [SessionEntity]

  @State var link: String
  @State var note: String
  @State var selectedSessionID: String?
  @State var isPresentingSessionPicker = false
  @State var isSending = false
  @State var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState var focusedField: Field?

  init(draft: LinkstrDeepLinkCodec.ShareDraft, ownerPubkey: String) {
    _link = State(initialValue: draft.url)
    _note = State(initialValue: draft.note ?? "")
    _sessions = Query(
      filter: #Predicate<SessionEntity> { session in
        session.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)]
    )
  }

  var activeSessions: [SessionEntity] {
    sessions.filter { sessionEntity in
      !sessionEntity.isArchived && appSession.isCurrentUserActiveMember(of: sessionEntity)
    }
  }

  var selectedSession: SessionEntity? {
    guard let selectedSessionID else { return nil }
    return activeSessions.first { $0.sessionID == selectedSessionID }
  }

  var normalizedURL: String? {
    LinkstrURLValidator.normalizedWebURL(from: link)
  }

  private var canSend: Bool {
    !isSending && selectedSession != nil && normalizedURL != nil
  }

  private var validationMessage: String? {
    if normalizedURL == nil {
      return "enter a valid link."
    }
    if selectedSession == nil {
      return activeSessions.isEmpty ? "no active sessions available." : "choose a session."
    }
    return nil
  }

  private var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isSending,
      progressMessage: "waiting for relay reconnect before sending...",
      validationMessage: validationMessage,
      validationColor: LinkstrTheme.destructive.opacity(0.9)
    )
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: "share link")

            LinkstrInsetSection(title: "link") {
              TextField("example.com", text: $link)
                .font(LinkstrTheme.body(14))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .disabled(isSending)
                .focused($focusedField, equals: .link)
                .lineLimit(1)
                .submitLabel(.next)
                .onSubmit {
                  focusedField = .note
                }
                .linkstrInputField()

              Text(linkFieldHint ?? " ")
                .font(LinkstrTheme.body(12))
                .foregroundStyle(linkFieldHintColor)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                .opacity(linkFieldHint == nil ? 0 : 1)
                .accessibilityHidden(linkFieldHint == nil)
            }

            LinkstrInsetSection(title: "session") {
              Button {
                focusedField = nil
                isPresentingSessionPicker = true
              } label: {
                selectedSessionRow
              }
              .buttonStyle(.plain)
              .disabled(isSending || activeSessions.isEmpty)
            }

            LinkstrInsetSection(title: "note", accessory: "optional") {
              ZStack(alignment: .topLeading) {
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("note")
                    .font(LinkstrTheme.body(14))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .padding(.top, LinkstrTheme.fieldVerticalPadding)
                    .padding(.leading, LinkstrTheme.fieldHorizontalPadding)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $note)
                  .font(LinkstrTheme.body(14))
                  .foregroundStyle(LinkstrTheme.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 112, maxHeight: 180)
                  .padding(4)
                  .focused($focusedField, equals: .note)
                  .disabled(isSending)
              }
              .linkstrFieldChrome()
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
        }
        .scrollDismissesKeyboard(.interactively)
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            deepLinkHandler.clearShareDraft()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("cancel")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isSending)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button {
            sendSharedLink()
          } label: {
            if isSending {
              ProgressView()
                .frame(width: 30, height: 30, alignment: .center)
            } else {
              Image(systemName: "paperplane.fill")
                .linkstrToolbarIconLabel()
            }
          }
          .accessibilityLabel("send shared link")
          .tint(LinkstrTheme.accent)
          .disabled(!canSend)
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
    }
    .preferredColorScheme(.dark)
    .onAppear {
      selectDefaultSessionIfNeeded()
    }
    .onChange(of: activeSessions.map(\.sessionID).stableTaskID) { _, _ in
      clearMissingSelectionIfNeeded()
      selectDefaultSessionIfNeeded()
    }
    .onChange(of: focusedField) { previousField, focusedField in
      guard previousField == .link, focusedField != .link else { return }
      guard let normalizedURL else { return }
      link = normalizedURL
    }
    .onChange(of: link) { _, _ in
      mutationFeedback.clear()
    }
    .onChange(of: note) { _, _ in
      mutationFeedback.clear()
    }
    .onChange(of: selectedSessionID) { _, _ in
      mutationFeedback.clear()
    }
    .sheet(isPresented: $isPresentingSessionPicker) {
      ShareSessionPickerSheet(
        sessions: activeSessions,
        selectedSessionID: $selectedSessionID
      )
      .presentationDetents([.fraction(0.86), .large])
      .presentationDragIndicator(.visible)
    }
  }

  @ViewBuilder
  private var selectedSessionRow: some View {
    if let selectedSession {
      ShareSelectedSessionRow(session: selectedSession)
    } else {
      LinkstrShareEmptyPickerState(
        title: "no active sessions",
        systemImage: "bubble.left.and.bubble.right",
        description: "create a session before sharing links."
      )
      .frame(maxWidth: .infinity, minHeight: 140)
      .contentShape(Rectangle())
    }
  }
}
