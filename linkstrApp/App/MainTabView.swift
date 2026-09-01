import SwiftData
import SwiftUI

enum AppTab: String, Hashable {
  case sessions
  case contacts
  case you
  case settings

  var title: String {
    switch self {
    case .sessions: return "sessions"
    case .contacts: return "contacts"
    case .you: return "you"
    case .settings: return "settings"
    }
  }

  var systemImage: String {
    switch self {
    case .sessions: return "bubble.left.and.bubble.right.fill"
    case .contacts: return "person.2.fill"
    case .you: return "qrcode.viewfinder"
    case .settings: return "gearshape.fill"
    }
  }
}

struct MainTabView: View {
  @EnvironmentObject private var session: AppSession
  private let ownerPubkey: String
  @Binding private var selectedTab: AppTab

  private struct SessionNavigationTarget: Identifiable, Hashable {
    let sessionID: String

    var id: String { sessionID }
  }

  @State private var isPresentingNewSession = false
  @State private var isPresentingAddContact = false
  @State private var isShowingArchivedSessions = false
  @State private var selectedSessionTarget: SessionNavigationTarget?

  @Query private var sessions: [SessionEntity]

  init(ownerPubkey: String, selectedTab: Binding<AppTab>) {
    self.ownerPubkey = ownerPubkey
    _selectedTab = selectedTab
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

      tabContent(.settings)
        .tag(AppTab.settings)
        .tabItem {
          Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

    .navigationDestination(item: $selectedSessionTarget) { target in
      SessionPostsView(
        ownerPubkey: ownerPubkey,
        sessionID: target.sessionID
      )
    }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        leadingToolbarAccessory
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        trailingToolbarAccessories
      }
    }
    .linkstrBarChrome()
    .onChange(of: selectedTab) { oldValue, newValue in
      if oldValue == .sessions, newValue != .sessions {
        isShowingArchivedSessions = false
      }
      if newValue != .sessions {
        selectedSessionTarget = nil
      }
    }
    .onChange(of: archivedSessionCount) { _, count in
      if count == 0, isShowingArchivedSessions {
        isShowingArchivedSessions = false
      }
    }
    .onAppear {
      navigateToPendingSessionIfNeeded()
    }
    .onChange(of: session.pendingSessionNavigationRequest?.id) { _, _ in
      navigateToPendingSessionIfNeeded()
    }
    .onChange(of: sessions.map(\.sessionID).stableTaskID) { _, _ in
      navigateToPendingSessionIfNeeded()
    }
    .sheet(isPresented: $isPresentingNewSession) {
      NewSessionSheet(ownerPubkey: ownerPubkey)
    }
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }

  @ViewBuilder
  private var leadingToolbarAccessory: some View {
    switch selectedTab {
    case .sessions:
      if archivedSessionCount > 0 {
        Button {
          isShowingArchivedSessions.toggle()
        } label: {
          Image(systemName: isShowingArchivedSessions ? "archivebox.fill" : "archivebox")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel(
          isShowingArchivedSessions ? "show active sessions" : "show archived sessions"
        )
        .tint(LinkstrTheme.accent)
      } else {
        EmptyView()
      }
    case .contacts, .you, .settings:
      EmptyView()
    }
  }

  @ViewBuilder
  private var trailingToolbarAccessories: some View {
    switch selectedTab {
    case .sessions:
      Button {
        isPresentingNewSession = true
      } label: {
        Image(systemName: "square.and.pencil")
          .linkstrToolbarIconLabel()
      }
      .accessibilityLabel("new session")
      .tint(LinkstrTheme.accent)

    case .contacts:
      Button {
        isPresentingAddContact = true
      } label: {
        Image(systemName: "person.badge.plus")
          .linkstrToolbarIconLabel()
      }
      .accessibilityLabel("add contact")
      .tint(LinkstrTheme.accent)

    case .you, .settings:
      EmptyView()
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
        addContact: { isPresentingAddContact = true }
      )
    case .you:
      YouView(openSettings: { selectedTab = .settings })
    case .settings:
      SettingsView()
    }
  }

  private func openSession(_ sessionID: String) {
    selectedTab = .sessions
    let target = SessionNavigationTarget(sessionID: sessionID)
    guard selectedSessionTarget != target else { return }
    selectedSessionTarget = target
  }

  private func navigateToPendingSessionIfNeeded() {
    guard let request = session.pendingSessionNavigationRequest else { return }
    guard sessions.contains(where: { $0.sessionID == request.sessionID }) else { return }
    openSession(request.sessionID)
    session.clearPendingSessionNavigationRequest()
  }
}
