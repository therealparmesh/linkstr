import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - AdaptiveVideoPlaybackView Controls & Helpers

extension AdaptiveVideoPlaybackView {
  @ViewBuilder
  var content: some View {
    if isResolvingPresentation {
      VStack(alignment: .leading, spacing: 8) {
        mediaSurface {
          VStack(spacing: 8) {
            ProgressView()
            Text("loading post...")
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        openInBrowserButton(action: openSourceAction)
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
        openInBrowserButton(action: openSourceAction)
      }
    }
  }

  @ViewBuilder
  func extractionPlaybackBlock(embedSource: EmbeddedWebSource) -> some View {
    switch extractionState {
    case .ready(let candidates):
      if let media = currentPlaybackCandidate(from: candidates) {
        let playbackTaskID = localPreparationTaskID
        let exportFileURL = exportableLocalMediaURL(for: cachedLocalMedia ?? media)
        VStack(alignment: .leading, spacing: 8) {
          mediaSurface {
            InlineVideoPlayer(
              media: media,
              onPlaybackReady: {
                guard !media.isLocalFile,
                  isCurrentPlaybackCallback(for: media, taskID: playbackTaskID) else { return }
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
              }
            )
          }
          localPlaybackActions(exportFileURL: exportFileURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)
      }

    case .cannotExtract:
      embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)

    case nil:
      VStack(alignment: .leading, spacing: 8) {
        mediaSurface {
          VStack(spacing: 8) {
            ProgressView()
            Text("preparing local playback...")
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        localPlaybackActions(exportFileURL: nil)
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
        Text("local playback unavailable: \(extractionFallbackReason)")
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if allowsTryLocalPlayback {
        playbackModeActions {
          tryLocalPlaybackButton
        }
      } else {
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

  func localPlaybackActions(exportFileURL: URL?) -> some View {
    VStack(spacing: 8) {
      playbackModeActions {
        useEmbeddedButton
      }
      if let exportFileURL {
        saveButton(for: exportFileURL)
      }
    }
  }

  func playbackModeActions<Action: View>(
    @ViewBuilder action: () -> Action
  ) -> some View {
    HStack(spacing: 8) {
      action()
      openInBrowserButton(action: openSourceAction)
    }
  }

  var useEmbeddedButton: some View {
    secondaryActionButton("use embedded") {
      cancelLocalCaching()
      localPlaybackMode = .embedPreferred
    }
  }

  var tryLocalPlaybackButton: some View {
    secondaryActionButton("try local playback") {
      tryLocalPlayback()
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

  func tryLocalPlayback() {
    if extractionFallbackReason != nil, cachedLocalMedia == nil {
      clearFailedLocalPlaybackState()
    }
    localPlaybackMode = .localPreferred
    localPlaybackRequestID += 1
    playbackCandidateIndex = 0
    embeddedContentHeight = nil
    isEmbeddedContentReady = false
    detectedMediaAspectRatio = nil
    embeddedLoadFailed = false
    extractionState = nil
    extractionFallbackReason = nil
  }

  func handlePlaybackFailure(currentMedia: PlayableMedia, candidates: [PlayableMedia]) {
    if currentMedia.isLocalFile || cachedLocalMedia != nil {
      clearFailedLocalPlaybackState()
    } else {
      cancelLocalCaching()
    }

    if currentMedia.isLocalFile {
      tryLocalPlayback()
      return
    }

    advancePlaybackCandidate(candidates: candidates)
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
