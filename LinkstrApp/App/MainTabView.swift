import SwiftData
import SwiftUI

struct MainTabView: View {
  @EnvironmentObject private var session: AppSession

  private struct SessionNavigationTarget: Identifiable, Hashable {
    let id: String
  }

  private enum AppTab: String, CaseIterable, Identifiable {
    case sessions
    case contacts
    case you
    case settings

    var id: String { rawValue }

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

  @State private var selectedTab: AppTab = .sessions
  @State private var isPresentingNewSession = false
  @State private var isPresentingAddContact = false
  @State private var isShowingArchivedSessions = false
  @State private var selectedSessionTarget: SessionNavigationTarget?

  @Query(sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)])
  private var allSessions: [SessionEntity]

  private var scopedSessions: [SessionEntity] {
    OwnerScopedCollections.sessions(allSessions, ownerPubkey: session.identityService.pubkeyHex)
  }

  private var archivedSessionCount: Int {
    scopedSessions.filter(\.isArchived).count
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
    .navigationTitle(
      selectedTab == .sessions && isShowingArchivedSessions
        ? "archived" : selectedTab.title
    )
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(item: $selectedSessionTarget) { target in
      if let targetSession = scopedSessions.first(where: { $0.sessionID == target.id }) {
        SessionPostsView(sessionEntity: targetSession)
      } else {
        ContentUnavailableView(
          "session unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("this session is no longer available.")
        )
      }
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
    }
    .onChange(of: archivedSessionCount) { _, count in
      if count == 0, isShowingArchivedSessions {
        isShowingArchivedSessions = false
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
    .sheet(isPresented: $isPresentingNewSession) {
      NewSessionSheet()
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
        isShowingArchivedSessions: $isShowingArchivedSessions,
        openSession: openSession
      )
    case .contacts:
      ContactsView()
    case .you:
      YouView()
    case .settings:
      SettingsView()
    }
  }

  private func openSession(_ sessionID: String) {
    selectedTab = .sessions
    selectedSessionTarget = SessionNavigationTarget(id: sessionID)
  }

  private func navigateToPendingSessionIfNeeded() {
    guard let pendingID = session.pendingSessionNavigationID else { return }
    guard scopedSessions.contains(where: { $0.sessionID == pendingID }) else { return }
    openSession(pendingID)
    session.clearPendingSessionNavigationID()
  }
}
