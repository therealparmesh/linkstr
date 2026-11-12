import SwiftData
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct ShareComposerView: View {
  @EnvironmentObject var appSession: AppSession
  @EnvironmentObject var deepLinkHandler: DeepLinkHandler
  let draft: LinkstrDeepLinkCodec.ShareDraft

  @Query var sessions: [SessionEntity]
  @Query private var members: [SessionMemberEntity]
  @Query private var contacts: [ContactEntity]
  private let ownerPubkeyHash: String

  @State var link: String
  @State var note: String
  @State var selectedSessionID: String?
  @State var isPresentingSessionPicker = false
  @State var isSending = false
  @State var mutationFeedback = LinkstrSheetMutationFeedback()
  @FocusState var focusedField: LinkstrShareDraftFields.Field?

  init(draft: LinkstrDeepLinkCodec.ShareDraft, ownerPubkey: String) {
    self.draft = draft
    ownerPubkeyHash = LocalDataCrypto.shared.digestHex(ownerPubkey)
    _members = Query(
      filter: #Predicate<SessionMemberEntity> { $0.ownerPubkey == ownerPubkey && $0.isActive },
      sort: [SortDescriptor(\SessionMemberEntity.createdAt), SortDescriptor(\SessionMemberEntity.storageID)]
    )
    _contacts = Query(filter: #Predicate<ContactEntity> { $0.ownerPubkey == ownerPubkey })
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

  private func memberAvatars(for sessionIDs: Set<String>) -> [String: [SessionMemberAvatar]] {
    let index = Dictionary(contacts.map { ($0.targetPubkey, $0) }, uniquingKeysWith: { first, _ in first })
    return SessionMemberAvatar.grouped(
      members, sessionIDs: sessionIDs, ownerHash: ownerPubkeyHash, contacts: index, appSession: appSession
    )
  }

  var selectedSession: SessionEntity? {
    guard let selectedSessionID else { return nil }
    return activeSessions.first { $0.sessionID == selectedSessionID }
  }

  var normalizedURL: String? {
    LinkstrDeepLinkCodec.webURL(fromInput: link)
  }

  private var canSend: Bool {
    !isSending && selectedSession != nil && normalizedURL != nil
  }

  private var validationMessage: String? {
    if normalizedURL == nil, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "enter a valid link."
    }
    if selectedSession == nil, !activeSessions.isEmpty {
      return "choose a session."
    }
    return nil
  }

  private var footerStatus: LinkstrSheetFooterStatus? {
    mutationFeedback.footerStatus(
      isRunning: isSending,
      progressMessage: "connecting to share your link",
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
            LinkstrSheetTitle(title: "share a link")

            LinkstrInsetSection(title: "to") {
              selectedSessionRow
            }

            LinkstrShareDraftFields(
              link: $link, note: $note, normalizedURL: normalizedURL,
              isSending: isSending, focusedField: $focusedField
            )
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
        .linkstrKeyboardDismissal()
        .modifier(LinkstrFocusedFieldScrolling(focusedField: focusedField))
      }
      .linkstrBarChrome()
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "cancel", icon: "xmark") { deepLinkHandler.clearShareDraft(matching: draft) }
            .disabled(isSending)
        }
        .linkstrFlatToolbarItem()
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if focusedField == nil {
          LinkstrShareFooter(status: footerStatus, canSend: canSend, isSending: isSending, send: sendSharedLink)
        }
      }
    }
    .interactiveDismissDisabled(isSending)
    .preferredColorScheme(.dark)
    .onAppear {
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
        avatarsBySessionID: memberAvatars(for: Set(activeSessions.map(\.sessionID))),
        selectedSessionID: $selectedSessionID
      )
      .presentationDetents([.fraction(0.86), .large])
      .presentationDragIndicator(.visible)
    }
  }

  @ViewBuilder
  private var selectedSessionRow: some View {
    if !activeSessions.isEmpty {
      Button {
        focusedField = nil
        isPresentingSessionPicker = true
      } label: {
        if let selectedSession {
          ShareSelectedSessionRow(
            session: selectedSession,
            memberAvatars: memberAvatars(for: [selectedSession.sessionID])[selectedSession.sessionID, default: []],
            isSelectable: true
          )
        } else {
          LinkstrActionButtonLabel(title: "choose a session", systemImage: "bubble.left.and.bubble.right")
        }
      }
      .buttonStyle(.plain)
      .accessibilityHint("choose where to share this link")
      .disabled(isSending)
    } else {
      LinkstrCenteredEmptyStateView(
        title: "no active sessions",
        systemImage: "bubble.left.and.bubble.right",
        description: "create a session before sharing links."
      )
      .frame(maxWidth: .infinity, minHeight: 140)
    }
  }
}
