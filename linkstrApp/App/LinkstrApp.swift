import SwiftData
import SwiftUI
import UIKit

@main
struct LinkstrAppMain: App {
  @Environment(\.scenePhase) private var scenePhase

  @UIApplicationDelegateAdaptor(LinkstrAppDelegate.self) private var appDelegate
  @StateObject private var bootstrap = AppBootstrapState()
  @StateObject private var deepLinkHandler = DeepLinkHandler()

  init() {
    Self.configureScrollViewAppearance()
    Self.configureNavigationAppearance()
  }

  private static func configureScrollViewAppearance() {
    let scrollViewAppearance = UIScrollView.appearance()
    scrollViewAppearance.backgroundColor = .clear
    scrollViewAppearance.bounces = true
    scrollViewAppearance.alwaysBounceVertical = true
    scrollViewAppearance.alwaysBounceHorizontal = false

    let collectionViewAppearance = UICollectionView.appearance()
    collectionViewAppearance.backgroundColor = .clear
    collectionViewAppearance.bounces = true
    collectionViewAppearance.alwaysBounceVertical = true
    collectionViewAppearance.alwaysBounceHorizontal = false
  }

  private static func configureNavigationAppearance() {
    let chromeColor = UIColor(LinkstrTheme.chrome)
    let textColor = UIColor(LinkstrTheme.textPrimary)
    let secondaryColor = UIColor(LinkstrTheme.textSecondary)
    let accentColor = UIColor(LinkstrTheme.accent)
    let separatorColor = UIColor(LinkstrTheme.separator)

    let navigationAppearance = UINavigationBarAppearance()
    navigationAppearance.configureWithOpaqueBackground()
    navigationAppearance.backgroundColor = chromeColor
    navigationAppearance.shadowColor = separatorColor
    navigationAppearance.titleTextAttributes = [.foregroundColor: textColor]
    navigationAppearance.largeTitleTextAttributes = [.foregroundColor: textColor]

    let navigationBarAppearance = UINavigationBar.appearance()
    navigationBarAppearance.standardAppearance = navigationAppearance
    navigationBarAppearance.compactAppearance = navigationAppearance
    navigationBarAppearance.scrollEdgeAppearance = navigationAppearance
    navigationBarAppearance.tintColor = accentColor

    let tabBarAppearance = UITabBarAppearance()
    tabBarAppearance.configureWithOpaqueBackground()
    tabBarAppearance.backgroundColor = chromeColor
    tabBarAppearance.shadowColor = separatorColor

    let itemAppearances = [
      tabBarAppearance.stackedLayoutAppearance,
      tabBarAppearance.inlineLayoutAppearance,
      tabBarAppearance.compactInlineLayoutAppearance
    ]
    for itemAppearance in itemAppearances {
      itemAppearance.normal.iconColor = secondaryColor
      itemAppearance.normal.titleTextAttributes = [.foregroundColor: secondaryColor]
      itemAppearance.selected.iconColor = accentColor
      itemAppearance.selected.titleTextAttributes = [.foregroundColor: accentColor]
    }

    let tabBar = UITabBar.appearance()
    tabBar.standardAppearance = tabBarAppearance
    if #available(iOS 15.0, *) {
      tabBar.scrollEdgeAppearance = tabBarAppearance
    }
    tabBar.tintColor = accentColor
    tabBar.unselectedItemTintColor = secondaryColor
  }

  var body: some Scene {
    WindowGroup {
      Group {
        switch bootstrap.startupState {
        case .ready(let readyContext, let storageIssue, let isUsingTemporaryStore):
          Group {
            if let storageIssue, !isUsingTemporaryStore {
              LinkstrStorageRecoveryView(
                title: "local storage unavailable",
                message: "linkstr couldn’t open saved data. retry startup or continue temporarily. "
                  + "changes you make in temporary mode won’t be saved when the app closes.",
                diagnostics: storageIssue,
                primaryActionTitle: "retry startup",
                onPrimaryAction: { bootstrap.reload() },
                secondaryActionTitle: "continue temporarily",
                onSecondaryAction: { bootstrap.continueWithTemporaryStore() }
              )
            } else {
              RootView()
                .environmentObject(readyContext.session)
                .environmentObject(deepLinkHandler)
                .onAppear {
                  Task {
                    await readyContext.session.boot()
                  }
                }
                .onReceive(readyContext.session.$didRestoreBackup) { restored in
                  if restored { bootstrap.reload() }
                }
                .onReceive(
                  NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataDidBecomeAvailableNotification
                  )
                ) { _ in
                  readyContext.session.handleProtectedDataDidBecomeAvailable()
                }
                .onReceive(
                  NotificationCenter.default.publisher(
                    for: .linkstrPushDeviceTokenDidChange
                  )
                ) { _ in
                  readyContext.session.handlePushDeviceTokenDidChange()
                }
                .onChange(of: scenePhase) { _, newValue in
                  switch newValue {
                  case .active:
                    readyContext.session.handleAppDidBecomeActive()
                  case .background:
                    readyContext.session.handleAppDidLeaveForeground()
                  case .inactive:
                    break
                  @unknown default:
                    break
                  }
                }
                .id(ObjectIdentifier(readyContext.session))
            }
          }
          .modelContainer(readyContext.container)
        case .fatal(let diagnostics):
          LinkstrStorageRecoveryView(
            title: "couldn’t start linkstr",
            message: "local storage and temporary mode are unavailable. retry startup.",
            diagnostics: diagnostics,
            primaryActionTitle: "retry startup",
            onPrimaryAction: {
              bootstrap.reload()
            },
            secondaryActionTitle: nil,
            onSecondaryAction: nil
          )
        case .loading:
          ZStack {
            LinkstrBackgroundView()
            VStack(spacing: LinkstrTheme.sectionStackSpacing) {
              LinkstrAppIconBadge(size: 72)

              ProgressView()
                .tint(LinkstrTheme.accent)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .onOpenURL { url in
        deepLinkHandler.handle(url: url)
      }
      .preferredColorScheme(.dark)
    }
  }
}

@MainActor
final class AppBootstrapState: ObservableObject {
  typealias ContainerFactory = (_ schema: Schema, _ isStoredInMemoryOnly: Bool) throws ->
    ModelContainer
  typealias SessionFactory = @MainActor (_ modelContext: ModelContext) -> AppSession
  private static let schema = Schema([
    PrivatePreferenceEntity.self,
    AccountStateEntity.self,
    ContactEntity.self,
    FollowRelationshipEntity.self,
    RelayEntity.self,
    SessionEntity.self,
    SessionMemberEntity.self,
    SessionMemberIntervalEntity.self,
    SessionReactionEntity.self,
    SessionDeletionTombstoneEntity.self,
    SessionPostDeletionEntity.self,
    SessionMessageEntity.self
  ])

  struct ReadyContext {
    let container: ModelContainer
    let session: AppSession
  }

  enum StartupState {
    case loading
    case ready(ReadyContext, storageIssue: String?, isUsingTemporaryStore: Bool)
    case fatal(String)
  }

  private let makeContainer: ContainerFactory
  private let makeSession: SessionFactory

  @Published private(set) var startupState: StartupState = .loading

  init(
    makeContainer: @escaping ContainerFactory = AppBootstrapState.defaultContainerFactory,
    makeSession: @escaping SessionFactory = { AppSession(modelContext: $0) }
  ) {
    self.makeContainer = makeContainer
    self.makeSession = makeSession
    reload()
  }

  func reload() {
    let schema = Self.schema
    startupState = .loading

    do {
      let container = try makeContainer(schema, false)
      let readyContext = ReadyContext(
        container: container,
        session: makeSession(container.mainContext)
      )
      startupState = .ready(readyContext, storageIssue: nil, isUsingTemporaryStore: false)
    } catch {
      NSLog("Persistent store unavailable, attempting in-memory recovery: \(error)")

      do {
        let container = try makeContainer(schema, true)
        let readyContext = ReadyContext(
          container: container,
          session: makeSession(container.mainContext)
        )
        // The unreadable persistent store may still need this account's original key.
        readyContext.session.isUsingRecoveryStore = true
        startupState = .ready(
          readyContext,
          storageIssue: error.localizedDescription,
          isUsingTemporaryStore: false
        )
      } catch let fallbackError {
        startupState = .fatal(
          Self.fatalStorageDiagnostics(
            persistentStoreError: error,
            fallbackError: fallbackError
          )
        )
      }
    }
  }

  func continueWithTemporaryStore() {
    guard case .ready(let readyContext, let storageIssue, _) = startupState else { return }
    startupState = .ready(
      readyContext,
      storageIssue: storageIssue,
      isUsingTemporaryStore: true
    )
  }

  nonisolated private static func defaultContainerFactory(
    schema: Schema,
    isStoredInMemoryOnly: Bool
  ) throws -> ModelContainer {
    let configuration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: isStoredInMemoryOnly,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  private static func fatalStorageDiagnostics(
    persistentStoreError: Error,
    fallbackError: Error
  ) -> String {
    let persistentDescription = persistentStoreError.localizedDescription.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let fallbackDescription = fallbackError.localizedDescription.trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    return
      """
      saved storage: \(persistentDescription)
      temporary storage: \(fallbackDescription)
      """
  }
}

struct LinkstrStorageRecoveryView: View {
  let title: String
  let message: String
  var diagnostics: String?
  let primaryActionTitle: String
  let onPrimaryAction: () -> Void
  let secondaryActionTitle: String?
  let onSecondaryAction: (() -> Void)?

  var body: some View {
    ZStack {
      LinkstrBackgroundView()

      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          Image(systemName: "externaldrive.badge.exclamationmark")
            .font(LinkstrTheme.font(.title2, weight: .semibold))
            .foregroundStyle(LinkstrTheme.amber)
            .frame(width: 52, height: 52)
            .background(LinkstrTheme.panelElevated, in: .rect(cornerRadius: LinkstrTheme.fieldCornerRadius))
            .accessibilityHidden(true)

          LinkstrScreenTitle(title: title)

          Text(message)
            .font(LinkstrTheme.font(.subheadline))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

          VStack(spacing: LinkstrTheme.buttonRowSpacing) {
            Button(action: onPrimaryAction) {
              LinkstrActionButtonLabel(title: primaryActionTitle)
            }
            .linkstrPrimaryButton()

            if let secondaryActionTitle, let onSecondaryAction {
              Button(action: onSecondaryAction) {
                LinkstrActionButtonLabel(title: secondaryActionTitle)
              }
              .linkstrSecondaryButton()
            }
          }

          if let diagnostics, !diagnostics.isEmpty {
            LinkstrDiagnosticDisclosure(details: diagnostics)
          }
        }
        .padding(LinkstrTheme.panelPadding)
        .frame(maxWidth: 520, alignment: .leading)
        .linkstrCardSurface(fill: LinkstrTheme.panelMuted)
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.vertical, LinkstrTheme.screenTopPadding)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.center, for: .alignment)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
