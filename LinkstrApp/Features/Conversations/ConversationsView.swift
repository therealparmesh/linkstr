import NostrSDK
import SwiftData
import SwiftUI

private struct SessionSummary: Identifiable {
  let id: String
  let session: SessionEntity
  let latestTimestamp: Date
  let latestPreview: String
  let latestNote: String?
  let hasUnread: Bool
  let postCount: Int
}

private struct SessionMessageIndex {
  let rootsBySessionID: [String: [SessionMessageEntity]]

  init(messages: [SessionMessageEntity]) {
    var rootsBySessionID: [String: [SessionMessageEntity]] = [:]

    for message in messages {
      if message.kind == .root {
        rootsBySessionID[message.conversationID, default: []].append(message)
      }
    }

    self.rootsBySessionID = rootsBySessionID
  }
}

struct ConversationsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)])
  private var allSessions: [SessionEntity]

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @State private var selectedSessionID: String?
  @State private var isShowingSelectedSession = false
  @State private var isShowingArchivedSessions = false

  private var scopedSessions: [SessionEntity] {
    session.scopedSessions(from: allSessions)
  }

  private var scopedMessages: [SessionMessageEntity] {
    session.scopedMessages(from: allMessages)
  }

  private var messageIndex: SessionMessageIndex {
    SessionMessageIndex(messages: scopedMessages)
  }

  private var summaries: [SessionSummary] {
    scopedSessions.compactMap { sessionEntity in
      let posts = messageIndex.rootsBySessionID[sessionEntity.sessionID] ?? []
      let latestPost = posts.max(by: { $0.timestamp < $1.timestamp })
      let latestTimestamp = latestPost?.timestamp ?? sessionEntity.updatedAt
      let latestPreview = previewText(for: latestPost)
      let latestNote = normalizedNote(latestPost?.note)

      let hasUnread = posts.contains { hasUnreadIncomingRootPost($0) }

      return SessionSummary(
        id: sessionEntity.sessionID,
        session: sessionEntity,
        latestTimestamp: latestTimestamp,
        latestPreview: latestPreview,
        latestNote: latestNote,
        hasUnread: hasUnread,
        postCount: posts.count
      )
    }
    .sorted { $0.latestTimestamp > $1.latestTimestamp }
  }

  private var archivedSessionCount: Int {
    summaries.filter { $0.session.isArchived }.count
  }

  private var visibleSummaries: [SessionSummary] {
    if isShowingArchivedSessions {
      return summaries.filter { $0.session.isArchived }
    }
    return summaries.filter { !$0.session.isArchived }
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .scrollContentBackground(.hidden)
    .navigationDestination(isPresented: $isShowingSelectedSession) {
      if let sessionID = selectedSessionID,
        let targetSession = scopedSessions.first(where: { $0.sessionID == sessionID })
      {
        SessionPostsView(sessionEntity: targetSession)
      } else {
        ContentUnavailableView(
          "Session Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("This session is no longer available.")
        )
      }
    }
    .onAppear {
      navigateToPendingSessionIfNeeded()
    }
    .onChange(of: session.pendingSessionNavigationID) { _, _ in
      navigateToPendingSessionIfNeeded()
    }
    .onChange(of: scopedSessions.map(\.sessionID)) { _, _ in
      navigateToPendingSessionIfNeeded()
    }
    .onChange(of: archivedSessionCount) { _, count in
      if count == 0, isShowingArchivedSessions {
        isShowingArchivedSessions = false
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if scopedSessions.isEmpty {
      LinkstrCenteredEmptyStateView(
        title: "No Sessions",
        systemImage: "rectangle.stack.badge.plus",
        description: "Create a session to start tracking and discussing links."
      )
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          archiveToggleRow

          if visibleSummaries.isEmpty {
            ContentUnavailableView(
              isShowingArchivedSessions ? "No Archived Sessions" : "No Active Sessions",
              systemImage: isShowingArchivedSessions ? "archivebox" : "rectangle.stack",
              description: Text(
                isShowingArchivedSessions
                  ? "Archive a session to move it here."
                  : "Create a session or view archived sessions."
              )
            )
            .padding(.top, 12)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visibleSummaries) { summary in
                Button {
                  selectedSessionID = summary.session.sessionID
                  isShowingSelectedSession = true
                } label: {
                  SessionRowView(summary: summary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                  Button {
                    session.setSessionArchived(
                      sessionID: summary.session.sessionID,
                      archived: !summary.session.isArchived
                    )
                  } label: {
                    Label(
                      summary.session.isArchived ? "Unarchive Session" : "Archive Session",
                      systemImage: summary.session.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  @ViewBuilder
  private var archiveToggleRow: some View {
    if isShowingArchivedSessions {
      Button {
        isShowingArchivedSessions = false
      } label: {
        Label("Back to Active", systemImage: "arrow.left")
          .font(.custom(LinkstrTheme.bodyFont, size: 12))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
      .buttonStyle(.plain)
      .padding(.bottom, 4)
    } else if archivedSessionCount > 0 {
      HStack {
        Spacer(minLength: 0)
        Button {
          isShowingArchivedSessions = true
        } label: {
          Label(
            "Archived (\(archivedSessionCount))",
            systemImage: "archivebox"
          )
          .font(.custom(LinkstrTheme.bodyFont, size: 12))
          .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .buttonStyle(.plain)
      }
      .padding(.bottom, 2)
    }
  }

  private func hasUnreadIncomingRootPost(_ post: SessionMessageEntity) -> Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return post.senderPubkey != myPubkey && post.readAt == nil
  }

  private func previewText(for post: SessionMessageEntity?) -> String {
    guard let post else { return "No posts yet" }
    if let title = post.metadataTitle, !title.isEmpty {
      return title
    }
    if let url = post.url, !url.isEmpty {
      return url
    }
    return "Untitled post"
  }

  private func normalizedNote(_ note: String?) -> String? {
    guard let note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func navigateToPendingSessionIfNeeded() {
    guard let pendingID = session.pendingSessionNavigationID else { return }
    guard scopedSessions.contains(where: { $0.sessionID == pendingID }) else { return }
    selectedSessionID = pendingID
    isShowingSelectedSession = true
    session.clearPendingSessionNavigationID()
  }
}

private struct SessionRowView: View {
  let summary: SessionSummary

  private var subtitle: String {
    if let latestNote = summary.latestNote {
      return latestNote
    }
    return summary.latestPreview
  }

  var body: some View {
    HStack(spacing: 12) {
      LinkstrPeerAvatar(name: summary.session.name)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(summary.session.name)
            .font(.custom(LinkstrTheme.titleFont, size: 16))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(1)

          Spacer(minLength: 8)

          Text(summary.latestTimestamp.linkstrListTimestampLabel)
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
        }

        HStack(spacing: 6) {
          Text(subtitle)
            .font(.custom(LinkstrTheme.bodyFont, size: 13))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)

          Text("•")
            .font(.caption2)
            .foregroundStyle(LinkstrTheme.textSecondary)

          Text(summary.postCount == 1 ? "1 post" : "\(summary.postCount) posts")
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if summary.hasUnread {
        Circle()
          .fill(LinkstrTheme.neonAmber)
          .frame(width: 8, height: 8)
          .accessibilityLabel("Unread")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .padding(.horizontal, 4)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider()
    }
  }
}

private struct SessionPostsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var allContacts: [ContactEntity]

  @Query(sort: [SortDescriptor(\SessionMemberEntity.createdAt)])
  private var allMembers: [SessionMemberEntity]

  @Query(sort: [SortDescriptor(\SessionReactionEntity.updatedAt, order: .reverse)])
  private var allReactions: [SessionReactionEntity]

  let sessionEntity: SessionEntity

  @State private var isPresentingNewPost = false
  @State private var isPresentingMembers = false

  private var scopedMessages: [SessionMessageEntity] {
    session.scopedMessages(from: allMessages)
  }

  private var scopedContacts: [ContactEntity] {
    session.scopedContacts(from: allContacts)
  }

  private var scopedMembers: [SessionMemberEntity] {
    session.scopedSessionMembers(from: allMembers)
      .filter { $0.sessionID == sessionEntity.sessionID && $0.isActive }
  }

  private var scopedReactions: [SessionReactionEntity] {
    session.scopedReactions(from: allReactions)
      .filter { $0.sessionID == sessionEntity.sessionID && $0.isActive }
  }

  private var posts: [SessionMessageEntity] {
    scopedMessages
      .filter { $0.conversationID == sessionEntity.sessionID && $0.kind == .root }
      .sorted { $0.timestamp > $1.timestamp }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        if posts.isEmpty {
          ContentUnavailableView(
            "No Posts Yet",
            systemImage: "link.badge.plus",
            description: Text("Share a link in this session.")
          )
          .padding(.top, 24)
        } else {
          LinkstrSectionHeader(title: "Posts")

          ForEach(posts) { post in
            VStack(alignment: .leading, spacing: 10) {
              NavigationLink {
                PostDetailView(post: post, sessionName: sessionEntity.name)
              } label: {
                PostCardView(
                  post: post,
                  senderLabel: senderLabel(for: post),
                  isOutgoing: isOutgoing(post),
                  hasUnreadPost: hasUnreadIncomingRootPost(post)
                )
              }
              .buttonStyle(.plain)

              let summaries = reactionSummaries(for: post.rootID)
              if !summaries.isEmpty {
                LinkstrReactionRow(
                  summaries: summaries,
                  mode: .readOnly,
                  onToggleEmoji: nil,
                  onAddReaction: nil
                )
                .padding(.horizontal, 6)
              }
            }
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 24)
    }
    .scrollContentBackground(.hidden)
    .background(LinkstrBackgroundView())
    .navigationTitle(sessionEntity.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          isPresentingMembers = true
        } label: {
          Label("Members", systemImage: "person.2")
        }
        .tint(LinkstrTheme.neonCyan)

        Button {
          isPresentingNewPost = true
        } label: {
          Label("New Post", systemImage: "plus")
        }
        .tint(LinkstrTheme.neonCyan)
      }
    }
    .sheet(isPresented: $isPresentingNewPost) {
      NewPostSheet(sessionEntity: sessionEntity)
        .environmentObject(session)
    }
    .sheet(isPresented: $isPresentingMembers) {
      SessionMembersSheet(
        sessionEntity: sessionEntity,
        contacts: scopedContacts,
        activeMembers: scopedMembers
      )
      .environmentObject(session)
    }
  }

  private func reactionSummaries(for postID: String) -> [ReactionSummary] {
    let reactionsForPost = scopedReactions.filter { $0.postID == postID }
    guard !reactionsForPost.isEmpty else { return [] }

    let grouped = Dictionary(grouping: reactionsForPost, by: \.emoji)
    let myPubkey = session.identityService.pubkeyHex

    return
      grouped
      .map { emoji, reactions -> ReactionSummary in
        ReactionSummary(
          emoji: emoji,
          count: reactions.count,
          includesCurrentUser: reactions.contains { reaction in
            guard let myPubkey else { return false }
            return reaction.senderMatches(myPubkey)
          }
        )
      }
      .sorted {
        if $0.count == $1.count {
          return $0.emoji < $1.emoji
        }
        return $0.count > $1.count
      }
  }

  private func isOutgoing(_ message: SessionMessageEntity) -> Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return message.senderPubkey == myPubkey
  }

  private func senderLabel(for message: SessionMessageEntity) -> String {
    if isOutgoing(message) {
      return "You"
    }
    return session.contactName(for: message.senderPubkey, contacts: scopedContacts)
  }

  private func hasUnreadIncomingRootPost(_ post: SessionMessageEntity) -> Bool {
    guard !isOutgoing(post) else { return false }
    return post.readAt == nil
  }
}

private struct PostCardView: View {
  let post: SessionMessageEntity
  let senderLabel: String
  let isOutgoing: Bool
  let hasUnreadPost: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      thumbnailView

      VStack(alignment: .leading, spacing: 8) {
        Text(isOutgoing ? "Sent by You" : "Sent by \(senderLabel)")
          .font(.caption2)
          .foregroundStyle(LinkstrTheme.textSecondary)
          .lineLimit(1)

        Text(primaryText)
          .font(.custom(LinkstrTheme.titleFont, size: 15))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(2)

        if let noteText {
          Text(noteText)
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.92))
            .lineLimit(2)
        }

        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text("Post")
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)

          if hasUnreadPost {
            Circle()
              .fill(LinkstrTheme.neonAmber)
              .frame(width: 7, height: 7)
              .padding(.horizontal, 8)
          } else {
            Text("•")
              .font(.caption2)
              .foregroundStyle(LinkstrTheme.textSecondary)
              .padding(.horizontal, 8)
          }

          Text(post.timestamp.linkstrListTimestampLabel)
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .linkstrNeonCard()
  }

  private var primaryText: String {
    if let title = post.metadataTitle, !title.isEmpty {
      return title
    }
    if let url = post.url, !url.isEmpty {
      return url
    }
    return "Untitled post"
  }

  private var noteText: String? {
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  @ViewBuilder
  private var thumbnailView: some View {
    if let thumbnailURL = post.thumbnailURL,
      let image = UIImage(contentsOfFile: thumbnailURL)
    {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(LinkstrTheme.panelSoft)
        .frame(width: 52, height: 52)
        .overlay {
          Image(systemName: "link")
            .font(.body)
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
    }
  }
}

struct NewSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contacts: [ContactEntity]

  @State private var sessionName = ""
  @State private var query = ""
  @State private var selectedNPubs = Set<String>()
  @State private var isCreating = false

  private var canCreateSession: Bool {
    !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            LinkstrSectionHeader(title: "Session Name")
            TextField("Fun", text: $sessionName)
              .textInputAutocapitalization(.words)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .frame(minHeight: LinkstrTheme.inputControlMinHeight)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )

            LinkstrSectionHeader(title: "Members (Optional)")
            Text("Create solo or add contacts now. You can manage members later.")
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
              .foregroundStyle(LinkstrTheme.textSecondary)

            TextField("Search contacts", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .frame(minHeight: LinkstrTheme.inputControlMinHeight)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )

            if contacts.isEmpty {
              Text("No contacts yet. You can still create a solo session.")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
            } else if filteredContacts.isEmpty {
              Text("No contacts match.")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
            } else {
              VStack(spacing: 0) {
                ForEach(filteredContacts) { contact in
                  Button {
                    toggle(contact.npub)
                  } label: {
                    HStack(spacing: 10) {
                      LinkstrPeerAvatar(name: contact.displayName, size: 30)
                      VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                          .font(.custom(LinkstrTheme.bodyFont, size: 14))
                          .foregroundStyle(LinkstrTheme.textPrimary)
                        Text(contact.npub)
                          .font(.custom(LinkstrTheme.bodyFont, size: 11))
                          .foregroundStyle(LinkstrTheme.textSecondary)
                          .lineLimit(1)
                      }

                      Spacer()

                      Image(
                        systemName: selectedNPubs.contains(contact.npub)
                          ? "checkmark.circle.fill" : "circle"
                      )
                      .foregroundStyle(
                        selectedNPubs.contains(contact.npub)
                          ? LinkstrTheme.neonCyan : LinkstrTheme.textSecondary)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)

                  Divider()
                    .overlay(LinkstrTheme.textSecondary.opacity(0.2))
                }
              }
              .padding(.horizontal, 2)
            }

            Text(
              selectedNPubs.isEmpty
                ? "Creating a solo session" : "\(selectedNPubs.count) member(s) selected"
            )
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
          }
          .padding(.horizontal, 12)
          .padding(.top, 14)
          .padding(.bottom, 120)
        }
      }
      .navigationTitle("New Session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isCreating)
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          Button(action: createSession) {
            Label(isCreating ? "Creating…" : "Create Session", systemImage: "plus.circle.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrPrimaryButtonStyle())
          .disabled(isCreating || !canCreateSession)

          Text(isCreating ? "Waiting for relay reconnect before creating…" : " ")
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
            .opacity(isCreating ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
          Rectangle()
            .fill(LinkstrTheme.bgBottom.opacity(0.95))
            .overlay(alignment: .top) {
              Rectangle()
                .fill(LinkstrTheme.textSecondary.opacity(0.18))
                .frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        )
      }
    }
  }

  private var filteredContacts: [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: query,
      displayName: \.displayName,
      npub: \.npub
    )
  }

  private func toggle(_ npub: String) {
    if selectedNPubs.contains(npub) {
      selectedNPubs.remove(npub)
    } else {
      selectedNPubs.insert(npub)
    }
  }

  private func createSession() {
    guard !isCreating else { return }
    guard canCreateSession else { return }
    let selected = Array(selectedNPubs)
    isCreating = true

    Task { @MainActor in
      let didCreate = await session.createSessionAwaitingRelay(
        name: sessionName,
        memberNPubs: selected
      )
      isCreating = false
      if didCreate {
        dismiss()
      }
    }
  }
}

private struct SessionMembersSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let sessionEntity: SessionEntity
  let contacts: [ContactEntity]
  let activeMembers: [SessionMemberEntity]

  @State private var includedMemberHexes: Set<String>
  @State private var query = ""
  @State private var isSaving = false

  init(
    sessionEntity: SessionEntity, contacts: [ContactEntity], activeMembers: [SessionMemberEntity]
  ) {
    self.sessionEntity = sessionEntity
    self.contacts = contacts
    self.activeMembers = activeMembers
    let initialMembers = activeMembers.map(\.memberPubkey)
    _includedMemberHexes = State(initialValue: Set(initialMembers))
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            LinkstrSectionHeader(title: "Current Members")

            if visibleCurrentMembers.isEmpty {
              Text("Only you are in this session.")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
            } else {
              VStack(spacing: 0) {
                ForEach(visibleCurrentMembers, id: \.self) { memberHex in
                  HStack(spacing: 10) {
                    LinkstrPeerAvatar(name: memberDisplayName(for: memberHex), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(memberDisplayName(for: memberHex))
                        .font(.custom(LinkstrTheme.bodyFont, size: 14))
                        .foregroundStyle(LinkstrTheme.textPrimary)
                      Text(memberIdentityLabel(for: memberHex))
                        .font(.custom(LinkstrTheme.bodyFont, size: 11))
                        .foregroundStyle(LinkstrTheme.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                      includedMemberHexes.remove(memberHex)
                    }
                    .font(.custom(LinkstrTheme.bodyFont, size: 12))
                  }
                  .padding(.vertical, 8)

                  Divider()
                    .overlay(LinkstrTheme.textSecondary.opacity(0.2))
                }
              }
              .padding(.horizontal, 2)
            }

            LinkstrSectionHeader(title: "Add From Contacts")

            TextField("Search contacts", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .frame(minHeight: LinkstrTheme.inputControlMinHeight)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )

            if contacts.isEmpty {
              Text("No contacts yet.")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
            } else if filteredContacts.isEmpty {
              Text("No contacts match.")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
            } else {
              VStack(spacing: 0) {
                ForEach(filteredContacts) { contact in
                  let contactHex = PublicKey(npub: contact.npub)?.hex
                  Button {
                    guard let contactHex else { return }
                    if includedMemberHexes.contains(contactHex) {
                      includedMemberHexes.remove(contactHex)
                    } else {
                      includedMemberHexes.insert(contactHex)
                    }
                  } label: {
                    HStack(spacing: 10) {
                      LinkstrPeerAvatar(name: contact.displayName, size: 28)
                      VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                          .font(.custom(LinkstrTheme.bodyFont, size: 14))
                          .foregroundStyle(LinkstrTheme.textPrimary)
                        Text(contact.npub)
                          .font(.custom(LinkstrTheme.bodyFont, size: 11))
                          .foregroundStyle(LinkstrTheme.textSecondary)
                          .lineLimit(1)
                      }

                      Spacer()

                      Image(
                        systemName: (contactHex != nil && includedMemberHexes.contains(contactHex!))
                          ? "checkmark.circle.fill" : "circle"
                      )
                      .foregroundStyle(
                        (contactHex != nil && includedMemberHexes.contains(contactHex!))
                          ? LinkstrTheme.neonCyan : LinkstrTheme.textSecondary
                      )
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)

                  Divider()
                    .overlay(LinkstrTheme.textSecondary.opacity(0.2))
                }
              }
              .padding(.horizontal, 2)
            }
          }
          .padding(.horizontal, 12)
          .padding(.top, 14)
          .padding(.bottom, 24)
        }
      }
      .navigationTitle("Session Members")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving…" : "Save") {
            saveMembers()
          }
          .disabled(isSaving)
          .tint(LinkstrTheme.neonCyan)
        }
      }
    }
  }

  private var visibleCurrentMembers: [String] {
    let myPubkey = session.identityService.pubkeyHex
    return
      includedMemberHexes
      .filter { memberHex in
        guard let myPubkey else { return true }
        return memberHex != myPubkey
      }
      .sorted()
  }

  private var filteredContacts: [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: query,
      displayName: \.displayName,
      npub: \.npub
    )
  }

  private func memberDisplayName(for pubkeyHex: String) -> String {
    if pubkeyHex == session.identityService.pubkeyHex {
      return "You"
    }
    if let contact = contacts.first(where: { PublicKey(npub: $0.npub)?.hex == pubkeyHex }) {
      let trimmed = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    if let npub = PublicKey(hex: pubkeyHex)?.npub {
      return npub
    }
    return String(pubkeyHex.prefix(12))
  }

  private func memberIdentityLabel(for pubkeyHex: String) -> String {
    if let npub = PublicKey(hex: pubkeyHex)?.npub {
      return npub
    }
    return pubkeyHex
  }

  private func saveMembers() {
    guard !isSaving else { return }
    isSaving = true

    let memberNPubs = includedMemberHexes.compactMap { PublicKey(hex: $0)?.npub }

    Task { @MainActor in
      let didSave = await session.updateSessionMembersAwaitingRelay(
        session: sessionEntity,
        memberNPubs: memberNPubs
      )
      isSaving = false
      if didSave {
        dismiss()
      }
    }
  }
}
