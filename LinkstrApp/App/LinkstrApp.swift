import SwiftData
import SwiftUI

@main
struct LinkstrAppMain: App {
  @Environment(\.scenePhase) private var scenePhase

  private let container: ModelContainer
  @StateObject private var session: AppSession

  init() {
    let schema = Schema([
      ContactEntity.self,
      RelayEntity.self,
      SessionMessageEntity.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    let container = try! ModelContainer(for: schema, configurations: [configuration])
    self.container = container
    _session = StateObject(wrappedValue: AppSession(modelContext: container.mainContext))
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(session)
        .onAppear {
          session.boot()
        }
        .onChange(of: scenePhase) { _, newValue in
          if newValue == .active {
            session.handleAppDidBecomeActive()
          }
        }
    }
    .modelContainer(container)
  }
}
