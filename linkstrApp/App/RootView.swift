import SwiftUI

private enum RootViewTimingDefaults {
  static let contentTransitionDuration: TimeInterval = 0.3
}

@MainActor
struct RootView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler
  @ObservedObject private var pushNotifications: PushNotificationService
  @State private var toasts = LinkstrToastPresenter()
  @State private var selectedTab: AppTab = .sessions

  init(pushNotifications: PushNotificationService? = nil) {
    self.pushNotifications = pushNotifications ?? .shared
  }

  private var sharedLinkDetailBinding: Binding<Bool> {
    Binding(
      get: { canPresentMediaSave && deepLinkHandler.pendingSharedURL != nil },
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
    session.didFinishBoot && !session.isRestoringBackup && session.restoreRecoveryError == nil
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      Group {
        if let error = session.restoreRecoveryError {
          LinkstrStorageRecoveryView(
            title: "restore paused",
            message: "linkstr couldn’t finish restoring your account. retry to continue.",
            diagnostics: error, primaryActionTitle: "retry restore",
            onPrimaryAction: { Task { await session.boot() } },
            secondaryActionTitle: nil, onSecondaryAction: nil)
        } else if session.didRestoreBackup {
          LinkstrBootLoadingView(statusMessage: "restoring backup…")
        } else if !session.didFinishBoot {
          LinkstrBootLoadingView(statusMessage: session.bootStatusMessage)
            .transition(.opacity)
        } else if session.shouldShowOnboarding {
          OnboardingView()
            .transition(.opacity)
        } else {
          MainTabView(
            ownerPubkey: session.identityService.pubkeyHex ?? "",
            selectedTab: $selectedTab,
            relaySettingsRequest: toasts.relaySettingsRequest
          )
          .environment(
            \.isUnderlyingMediaCovered,
            sharedLinkDetailBinding.wrappedValue || shareDraftBinding.wrappedValue != nil
              || mediaSaveDraftBinding.wrappedValue != nil
          )
          .transition(.opacity)
        }
      }
      .animation(
        reduceMotion ? nil : .easeInOut(duration: RootViewTimingDefaults.contentTransitionDuration),
        value: session.didFinishBoot
      )
      .animation(
        reduceMotion ? nil : .easeInOut(duration: RootViewTimingDefaults.contentTransitionDuration),
        value: session.shouldShowOnboarding
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tint(LinkstrTheme.accent)
    .onChange(of: pushNotifications.pendingNavigation?.id, initial: true) { _, _ in
      guard let request = pushNotifications.pendingNavigation else { return }
      deepLinkHandler.clearPendingRoutes()
      session.pendingSessionNavigationRequest = request
      pushNotifications.clearPendingNavigation(id: request.id)
    }
    .onChange(of: session.shouldShowOnboarding) { _, shouldShowOnboarding in
      if shouldShowOnboarding {
        selectedTab = .sessions
      }
    }
    .onChange(of: session.composeError) { _, newValue in
      guard let newValue, !newValue.isEmpty else { return }
      guard session.shouldPresentComposeErrorToast else { return }
      toasts.show(
        newValue,
        isSuccess: false,
        opensRelaySettings: session.isRelayConnectionAlertMessage(newValue)
      )
      session.composeError = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: .linkstrSuccessToast)) { notification in
      guard let message = notification.object as? String else { return }
      toasts.show(message, isSuccess: true)
    }
    .onChange(of: toasts.relaySettingsRequest) { _, _ in
      deepLinkHandler.clearPendingRoutes()
    }
    .fullScreenCover(
      isPresented: sharedLinkDetailBinding
    ) {
      if let sourceURL = deepLinkHandler.pendingSharedURL {
        NavigationStack {
          DeepLinkDetailView(sourceURL: sourceURL)
            .linkstrBarChrome()
            .linkstrSheetHeader(title: "shared link") {
              LinkstrHeaderButton(title: "close shared link", icon: "xmark") {
                deepLinkHandler.clearSharedLinkDetail()
              }
            } actions: {
              EmptyView()
            }
        }
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
    .environment(toasts)
  }
}

private struct LinkstrBootLoadingView: View {
  let statusMessage: String

  var body: some View {
    VStack(spacing: 18) {
      LinkstrAppIconBadge(size: 72)

      VStack(spacing: LinkstrTheme.compactSpacing) {
        Text("loading linkstr")
          .font(LinkstrTheme.font(.title3, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)

        Text(statusMessage)
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      ProgressView()
        .tint(LinkstrTheme.accent)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .safeAreaInset(edge: .top, spacing: 0) { LinkstrToastOutlet() }
  }
}
