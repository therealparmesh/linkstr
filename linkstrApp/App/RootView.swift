import SwiftUI

private enum RootViewTimingDefaults {
  static let toastAnimationDuration: TimeInterval = 0.2
  static let toastDisplayDuration: TimeInterval = 2
  static let contentTransitionDuration: TimeInterval = 0.3
}

struct RootView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
  @State private var toastMessage: String?
  @State private var toastIsSuccess: Bool = false
  @State private var toastOpensRelaySettings = false
  @State private var toastDisplayID = UUID()
  @State private var selectedTab: AppTab = .sessions

  private var sharedLinkDetailBinding: Binding<Bool> {
    Binding(
      get: { deepLinkHandler.pendingURLString != nil },
      set: { isPresented in
        if !isPresented {
          deepLinkHandler.clearSharedLinkDetail()
        }
      }
    )
  }

  private var shareDraftBinding: Binding<LinkstrDeepLinkCodec.ShareDraft?> {
    Binding(
      get: {
        guard canPresentShareComposer else { return nil }
        return deepLinkHandler.pendingShareDraft
      },
      set: { draft in
        if draft == nil {
          deepLinkHandler.clearShareDraft()
        }
      }
    )
  }

  private var mediaSaveDraftBinding: Binding<LinkstrDeepLinkCodec.MediaSaveDraft?> {
    Binding(
      get: {
        guard canPresentMediaSave else { return nil }
        return deepLinkHandler.pendingMediaSaveDraft
      },
      set: { draft in
        if draft == nil {
          deepLinkHandler.clearMediaSaveDraft()
        }
      }
    )
  }

  private var canPresentShareComposer: Bool {
    session.didFinishBoot
      && !session.shouldShowOnboarding
      && session.identityService.pubkeyHex != nil
  }

  private var canPresentMediaSave: Bool {
    session.didFinishBoot
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      Group {
        if !session.didFinishBoot {
          LinkstrBootLoadingView(statusMessage: session.bootStatusMessage)
            .transition(.opacity)
        } else if session.shouldShowOnboarding {
          OnboardingView()
            .transition(.opacity)
        } else {
          NavigationStack {
            MainTabView(
              ownerPubkey: session.identityService.pubkeyHex ?? "",
              selectedTab: $selectedTab
            )
          }
          .transition(.opacity)
        }
      }
      .animation(
        .easeInOut(duration: RootViewTimingDefaults.contentTransitionDuration),
        value: session.didFinishBoot
      )
      .animation(
        .easeInOut(duration: RootViewTimingDefaults.contentTransitionDuration),
        value: session.shouldShowOnboarding
      )
    }
    .overlay(alignment: .top) {
      if let toastMessage {
        Button(action: handleToastTap) {
          LinkstrErrorToast(message: toastMessage, isSuccess: toastIsSuccess)
        }
        .buttonStyle(.plain)
        .padding(.top, LinkstrTheme.toastTopPadding)
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityHint(
          toastOpensRelaySettings ? "opens relay settings" : "dismisses notification"
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .preferredColorScheme(.dark)
    .tint(LinkstrTheme.accent)
    .onChange(of: session.shouldShowOnboarding) { _, shouldShowOnboarding in
      if shouldShowOnboarding {
        selectedTab = .sessions
      }
    }
    .onChange(of: session.composeError) { _, newValue in
      guard let newValue, !newValue.isEmpty else { return }
      guard session.shouldPresentComposeErrorToast else { return }
      withAnimation(.easeIn(duration: RootViewTimingDefaults.toastAnimationDuration)) {
        toastIsSuccess = false
        toastMessage = newValue
        toastOpensRelaySettings = session.isRelayConnectionAlertMessage(newValue)
      }
      session.composeError = nil
      toastDisplayID = UUID()
    }
    .onReceive(NotificationCenter.default.publisher(for: .linkstrSuccessToast)) { notification in
      guard let message = notification.object as? String else { return }
      withAnimation(.easeIn(duration: RootViewTimingDefaults.toastAnimationDuration)) {
        toastIsSuccess = true
        toastMessage = message
        toastOpensRelaySettings = false
      }
      toastDisplayID = UUID()
    }
    .task(id: toastDisplayID) {
      guard toastMessage != nil else { return }
      try? await Task.sleep(for: .seconds(RootViewTimingDefaults.toastDisplayDuration))
      guard !Task.isCancelled else { return }
      dismissToast()
    }
    .fullScreenCover(
      isPresented: sharedLinkDetailBinding
    ) {
      if let urlString = deepLinkHandler.pendingURLString {
        NavigationStack {
          DeepLinkDetailView(urlString: urlString)
            .linkstrBarChrome()
            .toolbar {
              ToolbarItem(placement: .topBarLeading) {
                Button {
                  deepLinkHandler.clearSharedLinkDetail()
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
    .fullScreenCover(item: shareDraftBinding) { draft in
      if let ownerPubkey = session.identityService.pubkeyHex {
        ShareComposerView(draft: draft, ownerPubkey: ownerPubkey)
      } else {
        EmptyView()
      }
    }
    .fullScreenCover(item: mediaSaveDraftBinding) { draft in
      ShareMediaSaveView(draft: draft)
    }
  }

  private func handleToastTap() {
    let shouldOpenRelaySettings = toastOpensRelaySettings
    dismissToast()
    if shouldOpenRelaySettings {
      selectedTab = .settings
    }
  }

  private func dismissToast() {
    withAnimation(.easeOut(duration: RootViewTimingDefaults.toastAnimationDuration)) {
      toastMessage = nil
    }
    toastOpensRelaySettings = false
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
