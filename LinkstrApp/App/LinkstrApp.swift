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
    scrollViewAppearance.keyboardDismissMode = .interactive

    let collectionViewAppearance = UICollectionView.appearance()
    collectionViewAppearance.backgroundColor = .clear
    collectionViewAppearance.bounces = true
    collectionViewAppearance.alwaysBounceVertical = true
    collectionViewAppearance.alwaysBounceHorizontal = false
    collectionViewAppearance.keyboardDismissMode = .interactive
  }

  private static func configureNavigationAppearance() {
    let chromeColor = UIColor(red: 0.09, green: 0.10, blue: 0.16, alpha: 0.88)
    let textColor = UIColor(red: 0.92, green: 0.94, blue: 0.99, alpha: 1)
    let secondaryColor = UIColor(red: 0.66, green: 0.71, blue: 0.84, alpha: 1)
    let accentColor = UIColor(red: 0.49, green: 0.67, blue: 0.99, alpha: 1)
    let separatorColor = UIColor.white.withAlphaComponent(0.06)

    let navigationAppearance = UINavigationBarAppearance()
    navigationAppearance.configureWithTransparentBackground()
    navigationAppearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterialDark)
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
    tabBarAppearance.configureWithTransparentBackground()
    tabBarAppearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterialDark)
    tabBarAppearance.backgroundColor = chromeColor
    tabBarAppearance.shadowColor = separatorColor

    let itemAppearances = [
      tabBarAppearance.stackedLayoutAppearance,
      tabBarAppearance.inlineLayoutAppearance,
      tabBarAppearance.compactInlineLayoutAppearance,
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
      switch bootstrap.startupState {
      case .ready(let readyContext, let recoveryMessage, let isUsingTemporaryStore):
        Group {
          if let recoveryMessage, !isUsingTemporaryStore {
            LinkstrStorageRecoveryView(
              title: "local storage unavailable",
              message: recoveryMessage,
              primaryActionTitle: "continue temporarily",
              onPrimaryAction: {
                bootstrap.continueWithTemporaryStore()
              },
              secondaryActionTitle: "retry startup",
              onSecondaryAction: {
                bootstrap.reload()
              }
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
              .onOpenURL { url in
                deepLinkHandler.handle(url: url)
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
              .onReceive(
                NotificationCenter.default.publisher(
                  for: .linkstrPushNotificationTapped
                )
              ) { notification in
                if let conversationID = notification.userInfo?["conversation_id"] as? String {
                  readyContext.session.pendingSessionNavigationID = conversationID
                }
              }
              .onChange(of: scenePhase) { _, newValue in
                switch newValue {
                case .active:
                  readyContext.session.handleAppDidBecomeActive()
                case .inactive, .background:
                  readyContext.session.handleAppDidLeaveForeground()
                @unknown default:
                  break
                }
              }
          }
        }
        .modelContainer(readyContext.container)
      case .fatal(let fatalStartupMessage):
        LinkstrStorageRecoveryView(
          title: "startup failed",
          message: fatalStartupMessage,
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
  }
}

@MainActor
final class AppBootstrapState: ObservableObject {
  typealias ContainerFactory = (_ schema: Schema, _ isStoredInMemoryOnly: Bool) throws ->
    ModelContainer
  typealias SessionFactory = @MainActor (_ modelContext: ModelContext) -> AppSession

  struct ReadyContext {
    let container: ModelContainer
    let session: AppSession
  }

  enum StartupState {
    case loading
    case ready(ReadyContext, recoveryMessage: String?, isUsingTemporaryStore: Bool)
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
    let schema = LinkstrAppBootstrapConfiguration.schema
    startupState = .loading

    do {
      let container = try makeContainer(schema, false)
      let readyContext = ReadyContext(
        container: container,
        session: makeSession(container.mainContext)
      )
      startupState = .ready(readyContext, recoveryMessage: nil, isUsingTemporaryStore: false)
    } catch {
      NSLog("Persistent store unavailable, attempting in-memory recovery: \(error)")

      do {
        let container = try makeContainer(schema, true)
        let readyContext = ReadyContext(
          container: container,
          session: makeSession(container.mainContext)
        )
        startupState = .ready(
          readyContext,
          recoveryMessage: Self.recoveryMessage(for: error),
          isUsingTemporaryStore: false
        )
      } catch let fallbackError {
        startupState = .fatal(
          Self.fatalStartupMessage(
            persistentStoreError: error,
            fallbackError: fallbackError
          )
        )
      }
    }
  }

  func continueWithTemporaryStore() {
    guard case .ready(let readyContext, let recoveryMessage, _) = startupState else { return }
    startupState = .ready(
      readyContext,
      recoveryMessage: recoveryMessage,
      isUsingTemporaryStore: true
    )
  }

  nonisolated private static func defaultContainerFactory(
    schema: Schema,
    isStoredInMemoryOnly: Bool
  ) throws -> ModelContainer {
    let configuration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: isStoredInMemoryOnly
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }

  private static func recoveryMessage(for error: Error) -> String {
    let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if description.isEmpty {
      return
        "linkstr couldn't open its local storage on this device. you can retry startup or continue in a temporary in-memory mode. temporary changes won't persist after the app closes."
    }

    return
      "linkstr couldn't open its local storage on this device. you can retry startup or continue in a temporary in-memory mode. temporary changes won't persist after the app closes.\n\nstorage error: \(description)"
  }

  private static func fatalStartupMessage(
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
      "linkstr couldn't start because both persistent and temporary local storage failed to initialize.\n\npersistent store error: \(persistentDescription)\n\ntemporary store error: \(fallbackDescription)"
  }
}

enum LinkstrAppBootstrapConfiguration {
  static let schema = Schema([
    AccountStateEntity.self,
    ContactEntity.self,
    RelayEntity.self,
    SessionEntity.self,
    SessionMemberEntity.self,
    SessionMemberIntervalEntity.self,
    SessionReactionEntity.self,
    SessionPostDeletionEntity.self,
    SessionMessageEntity.self,
  ])
}

struct LinkstrStorageRecoveryView: View {
  let title: String
  let message: String
  let primaryActionTitle: String
  let onPrimaryAction: () -> Void
  let secondaryActionTitle: String?
  let onSecondaryAction: (() -> Void)?

  var body: some View {
    ZStack {
      LinkstrBackgroundView()

      VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
        HStack(spacing: LinkstrTheme.rowSpacing) {
          Image(systemName: "externaldrive.badge.exclamationmark")
            .font(LinkstrTheme.system(24, weight: .semibold))
            .foregroundStyle(LinkstrTheme.amber)

          Text(title)
            .font(LinkstrTheme.title(24))
            .foregroundStyle(LinkstrTheme.textPrimary)
        }

        Text(message)
          .font(LinkstrTheme.body(14))
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
      }
      .padding(LinkstrTheme.panelPadding)
      .frame(maxWidth: 520, alignment: .leading)
      .linkstrSurfaceCard()
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
