import SwiftData
import SwiftUI

struct MainTabView: View {
  @EnvironmentObject private var session: AppSession

  private enum AppTab: String, CaseIterable, Identifiable {
    case sessions
    case contacts
    case share
    case settings

    var id: String { rawValue }

    var title: String {
      switch self {
      case .sessions: return "Sessions"
      case .contacts: return "Contacts"
      case .share: return "Share"
      case .settings: return "Settings"
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
  @State private var isPresentingNewPost = false
  @State private var isPresentingAddContact = false

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  private var scopedContacts: [ContactEntity] {
    guard let ownerPubkey = session.identityService.pubkeyHex else { return [] }
    return
      contacts
      .filter { $0.ownerPubkey == ownerPubkey }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
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
        ZStack {
          ForEach(AppTab.allCases) { tab in
            tabContent(tab)
              .opacity(selectedTab == tab ? 1 : 0)
              .allowsHitTesting(selectedTab == tab)
              .accessibilityHidden(selectedTab != tab)
          }
        }
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
    .sheet(isPresented: $isPresentingNewPost) {
      NewPostSheet(contacts: scopedContacts)
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
      if let headerAccessory {
        Button {
          headerAccessory.action()
        } label: {
          Image(systemName: headerAccessory.icon)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(LinkstrTheme.neonCyan)
            .frame(width: 36, height: 36)
            .background(
              Circle()
                .stroke(LinkstrTheme.textSecondary.opacity(0.3), lineWidth: 1)
            )
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  private var headerAccessory: (icon: String, action: () -> Void)? {
    switch selectedTab {
    case .sessions:
      return ("plus", { isPresentingNewPost = true })
    case .contacts:
      return ("person.badge.plus", { isPresentingAddContact = true })
    case .share, .settings:
      return nil
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
      ConversationsView()
    case .contacts:
      ContactsView()
    case .share:
      ShareIdentityView()
    case .settings:
      SettingsView()
    }
  }
}
