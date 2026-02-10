import SwiftUI

struct RootView: View {
  @EnvironmentObject private var session: AppSession
  @State private var toastMessage: String?
  @State private var toastDisplayID = UUID()

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      Group {
        if !session.didFinishBoot {
          ProgressView("Loading account…")
            .tint(LinkstrTheme.neonCyan)
            .foregroundStyle(LinkstrTheme.textSecondary)
        } else if !session.hasIdentity {
          OnboardingView()
        } else {
          NavigationStack {
            MainTabView()
          }
        }
      }
    }
    .overlay(alignment: .top) {
      if let toastMessage {
        LinkstrErrorToast(message: toastMessage)
          .padding(.top, 8)
          .padding(.horizontal, 16)
          .transition(.move(edge: .top).combined(with: .opacity))
          .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) {
              self.toastMessage = nil
            }
          }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .preferredColorScheme(.dark)
    .tint(LinkstrTheme.neonCyan)
    .onChange(of: session.composeError) { _, newValue in
      guard let newValue, !newValue.isEmpty else { return }
      withAnimation(.easeIn(duration: 0.18)) {
        toastMessage = newValue
      }
      session.composeError = nil
      toastDisplayID = UUID()
    }
    .task(id: toastDisplayID) {
      guard toastMessage != nil else { return }
      try? await Task.sleep(for: .seconds(2.2))
      withAnimation(.easeOut(duration: 0.18)) {
        toastMessage = nil
      }
    }
  }
}
