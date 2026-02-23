import SwiftData
import SwiftUI

struct MainTabView: View {
  @EnvironmentObject private var session: AppSession

  private struct HeaderAccessory: Identifiable {
    let id: String
    let icon: String
    let action: () -> Void
    let isActive: Bool
  }

  private enum AppTab: String, CaseIterable, Identifiable {
    case sessions
    case contacts
    case share
    case settings

    var id: String { rawValue }

    var title: String {
      switch self {
      case .sessions: return "sessions"
      case .contacts: return "contacts"
      case .share: return "share"
      case .settings: return "settings"
      }
    }

    var systemImage: String {
      switch self {
      case .sessions: return "bubble.left.and.bubble.right"
      case .contacts: return "person.2"
      case .share: return "qrcode"
      case .settings: return "gearshape"
      }
    }
  }

  @State private var selectedTab: AppTab = .sessions
  @State private var isPresentingNewSession = false
  @State private var isPresentingAddContact = false
  @State private var isShowingArchivedSessions = false

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @Query(sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)])
  private var allSessions: [SessionEntity]

  private var scopedContacts: [ContactEntity] {
    session.scopedContacts(from: contacts)
  }

  private var scopedSessions: [SessionEntity] {
    session.scopedSessions(from: allSessions)
  }

  private var archivedSessionCount: Int {
    scopedSessions.filter(\.isArchived).count
  }

  private let tabBarHeight: CGFloat = 72
  private let tabBarBottomPadding: CGFloat = 8

  init() {
    UIScrollView.appearance().backgroundColor = .clear
    UICollectionView.appearance().backgroundColor = .clear
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      VStack(spacing: 0) {
        header
        tabContent(selectedTab)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      tabBar
        .frame(height: tabBarHeight)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, tabBarBottomPadding)
    }
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
      NewSessionSheet(contacts: scopedContacts)
    }
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet()
    }
  }

  private var header: some View {
    HStack {
      Text("linkstr")
        .font(.custom(LinkstrTheme.titleFont, size: 34))
        .foregroundStyle(LinkstrTheme.textPrimary)
      Spacer()
      ForEach(headerAccessories) { accessory in
        Button {
          accessory.action()
        } label: {
          Image(systemName: accessory.icon)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(accessory.isActive ? LinkstrTheme.textPrimary : LinkstrTheme.neonCyan)
            .frame(width: 36, height: 36)
            .background(
              Circle()
                .fill(accessory.isActive ? LinkstrTheme.neonCyan.opacity(0.85) : .clear)
            )
            .overlay(
              Circle()
                .stroke(
                  accessory.isActive
                    ? LinkstrTheme.neonCyan.opacity(0.95) : LinkstrTheme.textSecondary.opacity(0.3),
                  lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  private var headerAccessories: [HeaderAccessory] {
    switch selectedTab {
    case .sessions:
      var accessories: [HeaderAccessory] = []
      if archivedSessionCount > 0 {
        accessories.append(
          HeaderAccessory(
            id: "archive-toggle",
            icon: isShowingArchivedSessions ? "archivebox.fill" : "archivebox",
            action: { isShowingArchivedSessions.toggle() },
            isActive: isShowingArchivedSessions
          ))
      }
      accessories.append(
        HeaderAccessory(
          id: "new-session",
          icon: "plus",
          action: { isPresentingNewSession = true },
          isActive: false
        ))
      return accessories
    case .contacts:
      return [
        HeaderAccessory(
          id: "new-contact",
          icon: "person.badge.plus",
          action: { isPresentingAddContact = true },
          isActive: false
        )
      ]
    case .share, .settings:
      return []
    }
  }

  private var tabBar: some View {
    HStack(spacing: 8) {
      ForEach(AppTab.allCases) { tab in
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            selectedTab = tab
          }
        } label: {
          VStack(spacing: 4) {
            Image(systemName: tab.systemImage)
              .font(.system(size: 24, weight: .semibold))
            Text(tab.title)
              .font(.custom(LinkstrTheme.bodyFont, size: 11))
          }
          .foregroundStyle(
            selectedTab == tab ? LinkstrTheme.neonCyan : LinkstrTheme.textPrimary
          )
          .frame(maxWidth: .infinity, minHeight: 56)
          .background(
            Capsule()
              .fill(selectedTab == tab ? LinkstrTheme.textPrimary.opacity(0.2) : .clear)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .fill(LinkstrTheme.panel.opacity(0.92))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 30, style: .continuous)
        .stroke(LinkstrTheme.textSecondary.opacity(0.2), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func tabContent(_ tab: AppTab) -> some View {
    switch tab {
    case .sessions:
      ConversationsView(isShowingArchivedSessions: $isShowingArchivedSessions)
    case .contacts:
      ContactsView()
    case .share:
      ShareIdentityView()
    case .settings:
      SettingsView()
    }
  }
}
