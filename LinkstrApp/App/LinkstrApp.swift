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
      ContactEntity.self,
      RelayEntity.self,
      SessionMessageEntity.self,
    ])
    let container: ModelContainer
    do {
      let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
      container = try ModelContainer(for: schema, configurations: [configuration])
    } catch {
      NSLog("Persistent store unavailable, falling back to in-memory store: \(error)")
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
