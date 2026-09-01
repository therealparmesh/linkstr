import Foundation

extension AdaptiveVideoPlaybackView {
  struct ResolvedPresentation {
    let taskID: String
    let canonicalSourceURL: URL
    let preferredEmbedSource: EmbeddedWebSource?
    let mediaStrategy: URLClassifier.MediaStrategy
  }

  func reloadPlaybackPresentation() async {
    let requestedTaskID = playbackReloadTaskID
    let requestedSourceURL = sourceURL
    resetPlaybackPresentation()

    guard
      let presentation = await resolvePlaybackPresentation(
        sourceURL: requestedSourceURL,
        taskID: requestedTaskID
      )
    else { return }

    resolvedPresentation = presentation
    await prepareMediaIfNeeded()
  }

  func resetPlaybackPresentation() {
    localCacheTask?.cancel()
    localCacheTask = nil
    cachedLocalMedia = nil
    resolvedPresentation = nil
    embeddedContentHeight = nil
    isEmbeddedContentReady = false
    detectedMediaAspectRatio = nil
    embeddedLoadFailed = false
    extractionState = nil
    extractionFallbackReason = nil
    playbackCandidateIndex = 0
    localPlaybackMode = .localPreferred
  }

  func resolvePlaybackPresentation(
    sourceURL: URL,
    taskID: String
  ) async -> ResolvedPresentation? {
    let canonicalURL = await URLCanonicalizationService.shared.canonicalPlaybackURL(for: sourceURL)
    guard isCurrentPlaybackTask(taskID) else { return nil }

    var embedSource: EmbeddedWebSource?
    var mediaStrategy = URLClassifier.mediaStrategy(for: canonicalURL)

    if SocialURLHeuristics.isTwitterStatusURL(canonicalURL) {
      let twitterPresentation =
        await TwitterStatusResolutionService.shared.resolvedPresentation(for: canonicalURL)
      guard isCurrentPlaybackTask(taskID) else { return nil }
      mediaStrategy = twitterPresentation?.strategy ?? .link
      if let document = twitterPresentation?.embedHTMLDocument {
        embedSource = .html(
          document: document,
          baseURL: URL(string: "https://publish.twitter.com")
        )
      }
    }

    if URLClassifier.classify(canonicalURL) == .rumble, embedSource == nil,
      let rumbleEmbedURL = await URLCanonicalizationService.shared.preferredRumbleEmbedURL(
        for: canonicalURL) {
      embedSource = .url(rumbleEmbedURL)
    }
    guard isCurrentPlaybackTask(taskID) else { return nil }

    return ResolvedPresentation(
      taskID: taskID,
      canonicalSourceURL: canonicalURL,
      preferredEmbedSource: embedSource,
      mediaStrategy: mediaStrategy
    )
  }

  func isCurrentPlaybackTask(_ taskID: String) -> Bool {
    !Task.isCancelled && taskID == playbackReloadTaskID
  }

  func prepareMediaIfNeeded() async {
    guard !isResolvingPresentation else { return }
    guard effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }
    guard let taskID = activeResolvedPresentation?.taskID else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cachedMedia = resolveCachedLocalMedia?(playbackSourceURL) {
      useCachedMedia(cachedMedia)
      return
    }

    if let cachedLocalMedia {
      extractionState = .ready([cachedLocalMedia])
      extractionFallbackReason = nil
      return
    }

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: playbackSourceURL)
    guard isCurrentPlaybackTask(taskID) else { return }
    applyExtractionResult(result, sourceURL: playbackSourceURL)
  }

  func useCachedMedia(_ media: PlayableMedia) {
    if media.isLocalFile {
      Task {
        await VideoCacheService.shared.touchCachedMedia(at: media.playbackURL)
      }
    }
    cachedLocalMedia = media
    extractionState = .ready([media])
    extractionFallbackReason = nil
  }

  func applyExtractionResult(_ result: ExtractionState, sourceURL: URL) {
    playbackCandidateIndex = 0
    extractionState = result

    switch result {
    case .ready(let candidates):
      extractionFallbackReason = nil
      guard let media = candidates.first, media.isLocalFile else { return }
      Task {
        await VideoCacheService.shared.touchCachedMedia(at: media.playbackURL)
      }
      cachedLocalMedia = media
      persistLocalMedia?(sourceURL, media)
    case .cannotExtract(let reason):
      extractionFallbackReason = reason
      localPlaybackMode = .embedPreferred
    }
  }

  var activeResolvedPresentation: ResolvedPresentation? {
    guard resolvedPresentation?.taskID == playbackReloadTaskID else { return nil }
    return resolvedPresentation
  }

  var isResolvingPresentation: Bool {
    activeResolvedPresentation == nil
  }

  var effectiveSourceURL: URL {
    activeResolvedPresentation?.canonicalSourceURL ?? sourceURL
  }

  func resolvedOrFallbackEmbedSource(_ fallback: URL) -> EmbeddedWebSource {
    if let preferredEmbedSource = activeResolvedPresentation?.preferredEmbedSource {
      return preferredEmbedSource
    }
    return .url(fallback)
  }

  var effectiveMediaStrategy: URLClassifier.MediaStrategy {
    activeResolvedPresentation?.mediaStrategy
      ?? URLClassifier.mediaStrategy(for: sourceURL)
  }

  var effectiveMediaAspectRatio: CGFloat {
    if localPlaybackMode == .localPreferred, let detectedMediaAspectRatio {
      return detectedMediaAspectRatio
    }
    return URLClassifier.preferredMediaAspectRatio(
      for: effectiveSourceURL, strategy: effectiveMediaStrategy)
  }
}
