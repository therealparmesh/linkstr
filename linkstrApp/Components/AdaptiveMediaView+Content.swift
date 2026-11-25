import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - AdaptiveMediaView Controls & Helpers

extension AdaptiveMediaView {
  private var sharedLinkLoadingHeight: CGFloat { 180 }

  var isMediaCovered: Bool {
    isCovered || isUnderlyingMediaCovered || exportTarget != nil
      || fileExportItem != nil || exportFeedback != nil || photoSaveTask != nil
  }

  @ViewBuilder
  var content: some View {
    if isResolvingPresentation, immersive {
      watchContentArea { _ in
        LinkstrMediaLoadingView()
      }
    } else if isResolvingPresentation {
      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        mediaSurface(explicitHeight: sharedLinkLoadingHeight) {
          LinkstrMediaLoadingView()
        }
        linkContent
        LinkstrBrowserButton(action: openSourceAction)
      }
    } else {
      switch effectiveMediaStrategy {
      case .extractionPreferred(let embedURL):
        let resolvedEmbedSource = resolvedOrFallbackEmbedSource(embedURL)
        if localPlaybackMode == .embedPreferred {
          embedPlaybackBlock(embedSource: resolvedEmbedSource, allowsTryLocalPlayback: true)
        } else {
          extractionPlaybackBlock(embedSource: resolvedEmbedSource)
        }
      case .embedOnly(let embedURL):
        embedPlaybackBlock(
          embedSource: resolvedOrFallbackEmbedSource(embedURL), allowsTryLocalPlayback: false)
      case .directVideo:
        if localPlaybackMode == .embedPreferred {
          directVideoUnavailable
        } else {
          extractionPlaybackBlock(embedSource: nil)
        }
      case .link:
        if immersive {
          watchContentArea { _ in linkContent }
        } else {
          VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
            linkContent
            LinkstrBrowserButton(action: openSourceAction)
          }
        }
      }
    }
  }

  @ViewBuilder
  func extractionPlaybackBlock(embedSource: EmbeddedWebSource?) -> some View {
    switch extractionState {
    case .ready(let candidates):
      if let media = currentPlaybackCandidate(from: candidates) {
        let playbackTaskID = localPreparationTaskID
        let exportFileURL = exportableLocalMediaURL(for: cachedLocalMedia ?? media)
        let player = InlineVideoPlayer(
          media: media,
          isShowingFullscreenPlayer: $isShowingFullscreenPlayer,
          toggleVideoFit: { fitsEntireVideo.toggle() },
          onPlaybackReady: {
            guard !media.isLocalFile,
              isCurrentPlaybackCallback(for: media, taskID: playbackTaskID)
            else { return }
            scheduleLocalCachingIfNeeded(sourceURL: effectiveSourceURL, media: media)
          },
          onPlaybackFailed: {
            guard isCurrentPlaybackCallback(for: media, taskID: playbackTaskID) else { return }
            handlePlaybackFailure(currentMedia: media, candidates: candidates)
          },
          onAspectRatioChange: { aspectRatio in
            guard isCurrentPlaybackCallback(for: media, taskID: playbackTaskID) else { return }
            if abs((detectedMediaAspectRatio ?? 0) - aspectRatio) > 0.001 {
              detectedMediaAspectRatio = aspectRatio
            }
          },
          immersive: immersive,
          isCovered: isMediaCovered,
          watchBottomInset: watchInsets.bottom,
          watchVideoInsets: fitsEntireVideo
            ? EdgeInsets(
              top: watchInsets.top, leading: watchInsets.leading,
              bottom: watchInsets.bottom + postControlsReservedHeight + watchControlsHeight,
              trailing: watchInsets.trailing
            ) : nil,
          onWatchControlsHeightChange: { watchControlsHeight = $0 }
        )
        localPlayerBlock(player, exportFileURL: exportFileURL, offersEmbed: embedSource != nil)
      } else {
        fallbackPlaybackBlock(embedSource)
      }

    case .noVideo, .cannotExtract:
      fallbackPlaybackBlock(embedSource)

    case nil:
      localPlaybackLoading(offersEmbed: embedSource != nil)
    }
  }

  @ViewBuilder
  private func localPlaybackLoading(offersEmbed: Bool) -> some View {
    if immersive {
      watchContentArea { _ in
        LinkstrMediaLoadingView()
      }
    } else {
      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        mediaSurface(explicitHeight: sharedLinkLoadingHeight) { LinkstrMediaLoadingView() }
        linkContent
        localPlaybackActions(exportFileURL: nil, offersEmbed: offersEmbed)
      }
    }
  }

  @ViewBuilder
  private func fallbackPlaybackBlock(_ embedSource: EmbeddedWebSource?) -> some View {
    if let embedSource {
      embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)
    } else {
      directVideoUnavailable
    }
  }

  @ViewBuilder
  private var directVideoUnavailable: some View {
    if immersive {
      watchContentArea { _ in directVideoRecovery }
    } else {
      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        directVideoRecovery
        linkContent
      }
    }
  }

  private var directVideoRecovery: some View {
    mediaRecovery("couldn’t play this video", retry: tryLocalPlayback)
  }

  @ViewBuilder
  private func localPlayerBlock(_ player: InlineVideoPlayer, exportFileURL: URL?, offersEmbed: Bool) -> some View {
    if immersive {
      player
    } else {
      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        mediaSurface { player }
        linkContent
        localPlaybackActions(exportFileURL: exportFileURL, offersEmbed: offersEmbed)
      }
    }
  }

  @ViewBuilder
  func embedPlaybackBlock(
    embedSource: EmbeddedWebSource,
    allowsTryLocalPlayback: Bool
  ) -> some View {
    let canRender = isRenderableEmbedSource(embedSource)
    if immersive {
      watchContentArea(
        edgeToEdge: canRender && embeddedLoadFailure == nil && !embedSource.usesManagedHTMLDocument
      ) { size in
        if canRender, embeddedLoadFailure == nil {
          let isDocument = embedSource.usesManagedHTMLDocument
          let aspectRatio = effectiveMediaAspectRatio
          let fittedWidth = isDocument ? size.width : min(size.width, size.height * aspectRatio)
          // Give portrait web players room to lay out their controls before scaling them down.
          let width = !isDocument && aspectRatio < 1 ? max(320, fittedWidth) : fittedWidth
          let documentHeight = embedSurfaceHeight(for: embedSource) ?? width / aspectRatio
          let scalesToFit = embedSource.isFacebookVideoDocument || width > fittedWidth
          let height = scalesToFit ? documentHeight : min(size.height, documentHeight)
          let scale = scalesToFit ? min(1, fittedWidth / width, size.height / height) : 1
          embeddedPlayerSurface(embedSource, explicitHeight: height, allowsVerticalScroll: isDocument && !scalesToFit)
            .frame(width: width)
            .scaleEffect(scale)
            .frame(width: width * scale, height: height * scale)
        } else {
          embedRecovery(offersModeSwitch: allowsTryLocalPlayback)
        }
      }
    } else {
      standardEmbedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: allowsTryLocalPlayback)
    }
  }

  private func standardEmbedPlaybackBlock(
    embedSource: EmbeddedWebSource, allowsTryLocalPlayback: Bool
  ) -> some View {
    let canRender = isRenderableEmbedSource(embedSource)
    return VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      if canRender, embeddedLoadFailure == nil {
        embeddedPlayerSurface(embedSource)
        linkContent
        LinkstrBrowserButton(action: openSourceAction)
        if allowsTryLocalPlayback { tryLocalPlaybackButton }
      } else {
        embedRecovery(offersModeSwitch: allowsTryLocalPlayback)
        linkContent
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func embedRecovery(offersModeSwitch: Bool) -> some View {
    mediaRecovery(
      embeddedLoadFailure == .tiktokRateLimited
        ? "tiktok is limiting requests"
        : "couldn’t load the official embed",
      retry: nil,
      offersLocalPlayback: offersModeSwitch
    )
  }

  func embeddedPlayerSurface(
    _ embedSource: EmbeddedWebSource, explicitHeight: CGFloat? = nil, allowsVerticalScroll: Bool = false
  ) -> some View {
    let waitsForEmbed = !isEmbeddedContentReady
    let hidesDocument = embedSource.usesManagedHTMLDocument && waitsForEmbed
    let height = explicitHeight ?? (hidesDocument ? sharedLinkLoadingHeight : embedSurfaceHeight(for: embedSource))
    return mediaSurface(explicitHeight: height) { Color.clear }
      .overlay {
        EmbeddedWebView(
          source: embedSource,
          onIntrinsicHeightChange: { height in
            guard embedSource.usesManagedHTMLDocument else { return }
            embeddedContentHeight = normalizedEmbedHeight(height)
          },
          onContentReadyChange: { isReady in
            isEmbeddedContentReady = isReady
          },
          onRenderedPostChange: { hasRenderedEmbeddedPost = $0 },
          onProviderFailure: {
            LinkstrPlaybackDiagnostics.logger.notice("official player reported a provider error")
          },
          onLoadFailure: { failure in
            if embeddedLoadFailure == nil {
              LinkstrPlaybackDiagnostics.logger.notice(
                "official embed failed; rate limited: \(failure == .tiktokRateLimited)"
              )
              embeddedLoadFailure = failure
            }
          },
          isPlaybackSuspended: isMediaCovered || (immersive && scenePhase != .active),
          allowsVerticalScroll: allowsVerticalScroll
        )
        .scopedPlaybackAudioSession()
        .opacity(hidesDocument ? 0 : 1)
        .allowsHitTesting(!hidesDocument)
        .accessibilityHidden(hidesDocument)

        if waitsForEmbed {
          LinkstrMediaLoadingView()
            .allowsHitTesting(false)
        }
      }
      .clipShape(.rect(cornerRadius: LinkstrTheme.fieldCornerRadius))
  }

  var watchPlaybackMenu: WatchPlaybackMenu {
    let offersEmbed = localPlaybackMode == .localPreferred && (isShowingNativePlayer || extractionState == nil)
    return WatchPlaybackMenu(
      openBrowser: openSourceAction,
      switchTitle: offersEmbed ? officialEmbedActionTitle : localPlaybackActionTitle,
      switchIcon: offersEmbed ? "rectangle.inset.filled" : "play.rectangle",
      switchMode: effectiveMediaStrategy.allowsLocalPlaybackToggle
        ? (offersEmbed ? useOfficialEmbed : tryLocalPlayback) : nil,
      fullScreen: isShowingNativePlayer ? { isShowingFullscreenPlayer = true } : nil
    )
  }

  func currentPlaybackCandidate(from candidates: [PlayableMedia]) -> PlayableMedia? {
    guard playbackCandidateIndex < candidates.count else { return nil }
    return candidates[playbackCandidateIndex]
  }

  func isCurrentPlaybackCallback(for media: PlayableMedia, taskID: String) -> Bool {
    guard taskID == localPreparationTaskID,
      case .ready(let candidates) = extractionState
    else { return false }
    return currentPlaybackCandidate(from: candidates)?.playbackURL == media.playbackURL
  }

  func mediaSurface<Content: View>(
    explicitHeight: CGFloat? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Group {
      if let explicitHeight {
        content()
          .frame(maxWidth: .infinity)
          .frame(height: explicitHeight)
      } else {
        content()
          .frame(maxWidth: .infinity)
          .aspectRatio(effectiveMediaAspectRatio, contentMode: .fit)
      }
    }
    .background(LinkstrTheme.panelMuted)
    .clipShape(RoundedRectangle(cornerRadius: LinkstrTheme.fieldCornerRadius, style: .continuous))
  }

  func isRenderableEmbedSource(_ embedSource: EmbeddedWebSource) -> Bool {
    switch embedSource {
    case .html:
      return true
    case .url(let url):
      return URLClassifier.isDedicatedEmbedURL(url)
        || (SocialURLHeuristics.isInstagramHost(url)
          && SocialURLHeuristics.instagramPostID(from: url) != nil)
    }
  }

  func embedSurfaceHeight(for embedSource: EmbeddedWebSource) -> CGFloat? {
    guard embedSource.usesManagedHTMLDocument else { return nil }
    return embeddedContentHeight
  }

  func normalizedEmbedHeight(_ height: CGFloat) -> CGFloat {
    guard height.isFinite else { return 220 }
    return max(height.rounded(.up), 220)
  }

  func exportableLocalMediaURL(for media: PlayableMedia) -> URL? {
    guard media.isLocalFile else { return nil }
    let fileURL = media.playbackURL
    guard fileURL.isFileURL else { return nil }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return fileURL
  }
}

struct WatchPlaybackMenu: View {
  let openBrowser: () -> Void
  let switchTitle: String
  let switchIcon: String
  let switchMode: (() -> Void)?
  let fullScreen: (() -> Void)?

  var body: some View {
    Menu {
      Button(LinkstrBrowserAction.title, systemImage: LinkstrBrowserAction.icon, action: openBrowser)
      if let switchMode { Button(switchTitle, systemImage: switchIcon, action: switchMode) }
      if let fullScreen { Button("full screen", systemImage: "arrow.up.left.and.arrow.down.right", action: fullScreen) }
    } label: {
      Image(systemName: "ellipsis")
        .linkstrToolbarIconLabel()
        .foregroundStyle(LinkstrTheme.textPrimary)
    }
    .accessibilityLabel("view options")
  }
}
