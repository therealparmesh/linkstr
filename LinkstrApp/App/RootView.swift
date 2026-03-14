import SwiftUI

struct RootView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
  @State private var toastMessage: String?
  @State private var toastDisplayID = UUID()

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      Group {
        if !session.didFinishBoot {
          LinkstrBootLoadingView(statusMessage: session.bootStatusMessage)
        } else if session.shouldShowOnboarding {
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
          .padding(.top, LinkstrTheme.toastTopPadding)
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
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
    .tint(LinkstrTheme.accent)
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
    .fullScreenCover(
      isPresented: Binding(
        get: { deepLinkHandler.pendingURLString != nil },
        set: { isPresented in
          if !isPresented {
            deepLinkHandler.clear()
          }
        }
      )
    ) {
      if let urlString = deepLinkHandler.pendingURLString {
        NavigationStack {
          DeepLinkDetailView(urlString: urlString)
            .navigationTitle("shared link")
            .navigationBarTitleDisplayMode(.inline)
            .linkstrBarChrome()
            .toolbar {
              ToolbarItem(placement: .topBarLeading) {
                Button {
                  deepLinkHandler.clear()
                } label: {
                  Image(systemName: "xmark")
                    .linkstrToolbarIconLabel()
                }
                .accessibilityLabel("close shared link")
                .tint(LinkstrTheme.textSecondary)
              }
            }
        }
        .preferredColorScheme(.dark)
      } else {
        EmptyView()
      }
    }
  }
}

private struct LinkstrBootLoadingView: View {
  let statusMessage: String

  var body: some View {
    VStack(spacing: 18) {
      LinkstrAppIconBadge(size: 72)

      VStack(spacing: 8) {
        Text("loading linkstr")
          .font(LinkstrTheme.title(20))
          .foregroundStyle(LinkstrTheme.textPrimary)

        Text(statusMessage)
          .font(LinkstrTheme.body(14))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      ProgressView()
        .tint(LinkstrTheme.accent)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}
