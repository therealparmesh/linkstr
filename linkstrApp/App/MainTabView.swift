import SwiftData
import SwiftUI

enum AppTab: String, Hashable {
  case sessions
  case contacts
  case you

  var title: String {
    switch self {
    case .sessions: return "sessions"
    case .contacts: return "contacts"
    case .you: return "you"
    }
  }

  var systemImage: String {
    switch self {
    case .sessions: return "bubble.left.and.bubble.right.fill"
    case .contacts: return "person.2.fill"
    case .you: return "person.crop.circle"
    }
  }
}

struct MainTabView: View {
  @EnvironmentObject private var session: AppSession
  private let ownerPubkey: String
  @Binding private var selectedTab: AppTab
  let relaySettingsRequest: UUID?

  @State private var isPresentingNewSession = false
  @State private var isPresentingAddContact = false
  @State private var isShowingArchivedSessions = false
  @State private var navigationPath: [AppRoute] = []
  @State private var watchPositions: [String: String] = [:]
  @State private var navigationID = UUID()

  @Query private var sessions: [SessionEntity]

  init(ownerPubkey: String, selectedTab: Binding<AppTab>, relaySettingsRequest: UUID?) {
    self.ownerPubkey = ownerPubkey
    _selectedTab = selectedTab
    self.relaySettingsRequest = relaySettingsRequest
    _sessions = Query(
      filter: #Predicate<SessionEntity> { session in
        session.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)]
    )
  }

  private var archivedSessionCount: Int {
    sessions.filter(\.isArchived).count
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      tabs
    }
    .id(navigationID)
    .onChange(of: session.pendingSessionNavigationRequest?.id, initial: true) { _, _ in
      navigateToPendingSessionIfNeeded()
    }
    .onChange(of: relaySettingsRequest) { _, request in
      guard request != nil else { return }
      selectedTab = .you
      navigationPath = [.settings(.relays)]
    }
  }

  private var tabs: some View {
    TabView(selection: $selectedTab) {
      tabContent(.sessions)
        .tag(AppTab.sessions)
        .tabItem {
          Label(AppTab.sessions.title, systemImage: AppTab.sessions.systemImage)
        }

      tabContent(.contacts)
        .tag(AppTab.contacts)
        .tabItem {
          Label(AppTab.contacts.title, systemImage: AppTab.contacts.systemImage)
        }

      tabContent(.you)
        .tag(AppTab.you)
        .tabItem {
          Label(AppTab.you.title, systemImage: AppTab.you.systemImage)
        }

    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

    .navigationDestination(for: AppRoute.self) { route in
      switch route {
      case .session(let sessionID, let postID):
        SessionPostsView(ownerPubkey: ownerPubkey, sessionID: sessionID, scrollToPostID: postID) { postID in
          watchPositions[sessionID] = postID
        }
      case .watch(let sessionID, let postID):
        SessionPostsView(
          ownerPubkey: ownerPubkey, sessionID: sessionID, startingWatchPostID: postID, opensInWatch: true
        ) { postID in
          watchPositions[sessionID] = postID
        }
      case .addedYou:
        AddedYouView(ownerPubkey: ownerPubkey, discovery: session.contactDiscovery) {
          isPresentingAddContact = true
        }
        .background(LinkstrBackgroundView())
      case .settings(let section):
        SettingsView(initialSection: section)
          .toolbarVisibility(.hidden, for: .tabBar)
      }
    }
    .linkstrBarChrome()
    .onChange(of: selectedTab) { oldValue, newValue in
      if oldValue == .sessions, newValue != .sessions {
        isShowingArchivedSessions = false
      }
    }
    .onChange(of: archivedSessionCount) { _, count in
      if count == 0, isShowingArchivedSessions {
        isShowingArchivedSessions = false
      }
    }
    .sheet(isPresented: $isPresentingNewSession) {
      NewSessionSheet(ownerPubkey: ownerPubkey)
    }
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }

  @ViewBuilder
  private func tabContent(_ tab: AppTab) -> some View {
    switch tab {
    case .sessions:
      ConversationsView(
        ownerPubkey: ownerPubkey,
        isShowingArchivedSessions: $isShowingArchivedSessions,
        createSession: { isPresentingNewSession = true },
        openSession: openSession
      )
    case .contacts:
      ContactsView(
        ownerPubkey: ownerPubkey,
        openAddedYou: { navigationPath.append(.addedYou) },
        nostrService: session.nostrService,
        addContact: { isPresentingAddContact = true }
      )
    case .you:
      YouView { section in navigationPath.append(.settings(section)) }
    }
  }

  private func openSession(_ sessionID: String) {
    selectedTab = .sessions
    navigationPath = [.watch(sessionID, startingPostID: watchPositions[sessionID])]
  }

  private func navigateToPendingSessionIfNeeded() {
    guard let request = session.pendingSessionNavigationRequest else { return }
    selectedTab = .sessions
    isPresentingNewSession = false
    isPresentingAddContact = false
    navigationPath = request.path
    // Replace the stack's identity to dismiss any child sheet, even for the same destination.
    navigationID = request.id
    session.clearPendingSessionNavigationRequest()
  }
}
