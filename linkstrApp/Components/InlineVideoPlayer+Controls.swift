import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - AdaptiveVideoPlaybackView Controls & Helpers

extension AdaptiveVideoPlaybackView {
  @ViewBuilder
  var content: some View {
    if isResolvingPresentation {
      mediaSurface {
        VStack(spacing: 8) {
          ProgressView()
          Text("loading post...")
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
      case .link:
        if let openSourceAction {
          Button {
            openSourceAction()
          } label: {
            LinkstrActionButtonLabel(title: "open in browser")
          }
          .frame(maxWidth: .infinity)
          .linkstrSecondaryButton()
        } else {
          EmptyView()
        }
      }
    }
  }

  @ViewBuilder
  func extractionPlaybackBlock(embedSource: EmbeddedWebSource) -> some View {
    switch extractionState {
    case .ready(let candidates):
      if let media = currentPlaybackCandidate(from: candidates) {
        let exportFileURL = exportableLocalMediaURL(for: cachedLocalMedia ?? media)
        VStack(alignment: .leading, spacing: 8) {
          mediaSurface {
            InlineVideoPlayer(
              media: media,
              onPlaybackReady: {
                guard currentPlaybackCandidate(from: candidates)?.playbackURL == media.playbackURL,
                  !media.isLocalFile
                else { return }
                scheduleLocalCachingIfNeeded(sourceURL: effectiveSourceURL, media: media)
              },
              onPlaybackFailed: {
                handlePlaybackFailure(currentMedia: media, candidates: candidates)
              },
              onAspectRatioChange: { aspectRatio in
                guard currentPlaybackCandidate(from: candidates)?.playbackURL == media.playbackURL
                else { return }
                if abs((detectedMediaAspectRatio ?? 0) - aspectRatio) > 0.001 {
                  detectedMediaAspectRatio = aspectRatio
                }
              }
            )
          }
          extractionReadyActions(exportFileURL: exportFileURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)
      }

    case .cannotExtract:
      embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)

    case nil:
      mediaSurface {
        VStack(spacing: 8) {
          ProgressView()
          Text("preparing video playback...")
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
  }

  func embedPlaybackBlock(
    embedSource: EmbeddedWebSource,
    allowsTryLocalPlayback: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if isRenderableEmbedSource(embedSource), !embeddedLoadFailed {
        embeddedPlayerSurface(embedSource)
      } else {
        Text("embedded playback unavailable. open the original post to view it.")
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let extractionFallbackReason {
        Text("video playback unavailable: \(extractionFallbackReason)")
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      let canOpenSource = showOpenSourceButtonInEmbedMode && openSourceAction != nil

      if allowsTryLocalPlayback, canOpenSource, let openSourceAction {
        HStack(spacing: 8) {
          retryLocalPlaybackButton
          openInBrowserButton(action: openSourceAction)
        }
      } else if allowsTryLocalPlayback {
        retryLocalPlaybackButton
      } else if canOpenSource, let openSourceAction {
        openInBrowserButton(action: openSourceAction)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func embeddedPlayerSurface(_ embedSource: EmbeddedWebSource) -> some View {
    mediaSurface(explicitHeight: embedSurfaceHeight(for: embedSource)) {
      ZStack {
        EmbeddedWebView(
          source: embedSource,
          onIntrinsicHeightChange: { height in
            guard embedSource.usesManagedHTMLDocument else { return }
            embeddedContentHeight = normalizedEmbedHeight(height)
          },
          onContentReadyChange: { isReady in
            guard embedSource.usesManagedHTMLDocument else { return }
            isEmbeddedContentReady = isReady
          },
          onLoadFailure: {
            embeddedLoadFailed = true
          }
        )
        .scopedPlaybackAudioSession()
        .opacity(shouldDeferEmbedReveal(for: embedSource) && !isEmbeddedContentReady ? 0 : 1)

        if shouldDeferEmbedReveal(for: embedSource) && !isEmbeddedContentReady {
          VStack(spacing: 8) {
            ProgressView()
            Text("loading post...")
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
    }
  }

  @ViewBuilder
  func extractionReadyActions(exportFileURL: URL?) -> some View {
    if let openSourceAction {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          useEmbeddedButton
          openInBrowserButton(action: openSourceAction)
        }
        if let exportFileURL {
          saveButton(for: exportFileURL)
        }
      }
    } else if let exportFileURL {
      HStack(spacing: 8) {
        useEmbeddedButton
        saveButton(for: exportFileURL)
      }
    } else {
      useEmbeddedButton
    }
  }

  var useEmbeddedButton: some View {
    secondaryActionButton("use embedded") {
      localPlaybackMode = .embedPreferred
    }
  }

  var retryLocalPlaybackButton: some View {
    secondaryActionButton("try local playback") {
      retryLocalPlayback()
    }
  }

  func openInBrowserButton(action: @escaping () -> Void) -> some View {
    secondaryActionButton("open in browser") {
      action()
    }
  }

  func saveButton(for fileURL: URL) -> some View {
    secondaryActionButton("save...") {
      exportTarget = LocalMediaExportTarget(
        fileURL: fileURL,
        allowsPhotoSave: supportsPhotoSave(fileURL: fileURL)
      )
    }
  }

  func secondaryActionButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      LinkstrActionButtonLabel(title: title)
    }
    .frame(maxWidth: .infinity)
    .linkstrSecondaryButton()
  }

  func retryLocalPlayback() {
    Task {
      if extractionFallbackReason != nil, cachedLocalMedia == nil {
        clearFailedLocalPlaybackState()
      }
      localPlaybackMode = .localPreferred
      playbackCandidateIndex = 0
      embeddedContentHeight = nil
      isEmbeddedContentReady = false
      detectedMediaAspectRatio = nil
      embeddedLoadFailed = false
      extractionState = nil
      extractionFallbackReason = nil
      await prepareMediaIfNeeded()
    }
  }

  func handlePlaybackFailure(currentMedia: PlayableMedia, candidates: [PlayableMedia]) {
    if currentMedia.isLocalFile {
      clearFailedLocalPlaybackState()
      retryLocalPlayback()
      return
    }

    advancePlaybackCandidate(candidates: candidates)
  }

  func currentPlaybackCandidate(from candidates: [PlayableMedia]) -> PlayableMedia? {
    guard playbackCandidateIndex < candidates.count else { return nil }
    return candidates[playbackCandidateIndex]
  }

  func advancePlaybackCandidate(candidates: [PlayableMedia]) {
    let nextIndex = playbackCandidateIndex + 1
    if nextIndex < candidates.count {
      detectedMediaAspectRatio = nil
      playbackCandidateIndex = nextIndex
    } else {
      extractionFallbackReason = "none of the extracted video streams were playable."
      localPlaybackMode = .embedPreferred
    }
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
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  func prepareMediaIfNeeded() async {
    guard !isResolvingPresentation else { return }
    guard effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cached = resolveCachedLocalMedia?(playbackSourceURL) {
      if cached.isLocalFile {
        Task {
          await VideoCacheService.shared.touchCachedMedia(at: cached.playbackURL)
        }
      }
      cachedLocalMedia = cached
      extractionState = .ready([cached])
      extractionFallbackReason = nil
      return
    }

    if let cachedLocalMedia {
      extractionState = .ready([cachedLocalMedia])
      extractionFallbackReason = nil
      return
    }

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: playbackSourceURL)
    playbackCandidateIndex = 0
    extractionState = result

    switch result {
    case .ready(let candidates):
      extractionFallbackReason = nil
      if let media = candidates.first {
        if media.isLocalFile {
          Task {
            await VideoCacheService.shared.touchCachedMedia(at: media.playbackURL)
          }
          cachedLocalMedia = media
          persistLocalMedia?(playbackSourceURL, media)
        }
      }
    case .cannotExtract(let reason):
      extractionFallbackReason = reason
      localPlaybackMode = .embedPreferred
    }
  }

  var effectiveSourceURL: URL {
    canonicalSourceURL ?? sourceURL
  }

  func resolvedOrFallbackEmbedSource(_ fallback: URL) -> EmbeddedWebSource {
    if let preferredEmbedSource {
      return preferredEmbedSource
    }

    return .url(fallback)
  }

  func shouldDeferEmbedReveal(for embedSource: EmbeddedWebSource) -> Bool {
    embedSource.usesManagedHTMLDocument
  }

  func isRenderableEmbedSource(_ embedSource: EmbeddedWebSource) -> Bool {
    switch embedSource {
    case .html:
      return true
    case .url(let url):
      return URLClassifier.isDedicatedEmbedURL(url)
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

  var effectiveMediaStrategy: URLClassifier.MediaStrategy {
    resolvedMediaStrategy ?? URLClassifier.mediaStrategy(for: effectiveSourceURL)
  }

  var effectiveMediaAspectRatio: CGFloat {
    if localPlaybackMode == .localPreferred, let detectedMediaAspectRatio {
      return detectedMediaAspectRatio
    }
    return URLClassifier.preferredMediaAspectRatio(
      for: effectiveSourceURL, strategy: effectiveMediaStrategy)
  }

  func exportableLocalMediaURL(for media: PlayableMedia) -> URL? {
    guard media.isLocalFile else { return nil }
    let fileURL = media.playbackURL
    guard fileURL.isFileURL else { return nil }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return fileURL
  }

  func supportsPhotoSave(fileURL: URL) -> Bool {
    guard fileURL.isFileURL else { return false }
    let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    if isDirectory { return false }
    let ext = fileURL.pathExtension.lowercased()
    return ext == "mp4" || ext == "mov" || ext == "m4v"
  }
}
