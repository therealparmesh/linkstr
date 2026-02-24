import SwiftData
import SwiftUI

@main
struct LinkstrAppMain: App {
  @Environment(\.scenePhase) private var scenePhase

  private let container: ModelContainer
  @StateObject private var session: AppSession
  @StateObject private var deepLinkHandler = DeepLinkHandler()

  init() {
    let schema = Schema([
      AccountStateEntity.self,
      ContactEntity.self,
      RelayEntity.self,
      SessionEntity.self,
      SessionMemberEntity.self,
      SessionMemberIntervalEntity.self,
      SessionReactionEntity.self,
      SessionMessageEntity.self,
    ])
    let container: ModelContainer
    do {
      let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
      container = try ModelContainer(for: schema, configurations: [configuration])
    } catch {
      guard Self.shouldAllowInMemoryStoreFallback() else {
        fatalError("Persistent store unavailable: \(error)")
      }

      NSLog("Persistent store unavailable, using in-memory fallback for this process: \(error)")
      do {
        let fallbackConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
      } catch {
        fatalError("Unable to initialize any model container: \(error)")
      }
    }
    self.container = container
    _session = StateObject(wrappedValue: AppSession(modelContext: container.mainContext))
  }

  private static func shouldAllowInMemoryStoreFallback() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    if environment["XCTestConfigurationFilePath"] != nil {
      return true
    }
    return environment["LINKSTR_ALLOW_IN_MEMORY_STORE_FALLBACK"] == "1"
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(session)
        .environmentObject(deepLinkHandler)
        .onAppear {
          session.boot()
        }
        .onOpenURL { url in
          deepLinkHandler.handle(url: url)
        }
        .onChange(of: scenePhase) { _, newValue in
          switch newValue {
          case .active:
            session.handleAppDidBecomeActive()
          case .background:
            session.handleAppDidLeaveForeground()
          case .inactive:
            break
          @unknown default:
            break
          }
        }
    }
    .modelContainer(container)
  }
}
