import Foundation

extension AdaptiveMediaView {
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
  }

  func resetPlaybackPresentation() {
    cancelLocalCaching()
    cancelPhotoSave()
    exportTarget = nil
    fileExportItem = nil
    exportFeedback = nil
    cachedLocalMedia = nil
    resolvedPresentation = nil
    resetEmbeddedPresentation()
    detectedMediaAspectRatio = nil
    extractionState = nil
    playbackCandidateIndex = 0
    localPlaybackMode = .localPreferred
    localPlaybackRequestID = 0
  }

  func resolvePlaybackPresentation(
    sourceURL: URL,
    taskID: String
  ) async -> ResolvedPresentation? {
    let canonicalURL: URL
    if SocialURLHeuristics.isTikTokShortURL(sourceURL),
      let cachedCanonicalSourceURL,
      URLCanonicalizationService.canonicalTikTokPostURL(from: cachedCanonicalSourceURL) == cachedCanonicalSourceURL,
      resolveCachedLocalMedia?(cachedCanonicalSourceURL) != nil {
      canonicalURL = cachedCanonicalSourceURL
    } else {
      canonicalURL = await URLCanonicalizationService.shared.canonicalPlaybackURL(for: sourceURL)
    }
    guard isCurrentPlaybackTask(taskID) else { return nil }
    onResolvedSource?(canonicalURL)

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

  var localPreparationTaskID: String {
    let presentationState = activeResolvedPresentation == nil ? "resolving" : "resolved"
    let mode = localPlaybackMode == .localPreferred ? "local" : "embedded"
    return "\(playbackReloadTaskID)#\(presentationState)#\(mode)#\(localPlaybackRequestID)"
  }

  func prepareMediaIfNeeded() async {
    guard !isResolvingPresentation else { return }
    guard effectiveMediaStrategy == .directVideo || effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }
    guard let taskID = activeResolvedPresentation?.taskID else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cachedMedia = resolveCachedLocalMedia?(playbackSourceURL) {
      useCachedMedia(cachedMedia)
      return
    }

    if let cachedLocalMedia {
      extractionState = .ready([cachedLocalMedia])
      return
    }

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: playbackSourceURL)
    guard isCurrentPlaybackTask(taskID), localPlaybackMode == .localPreferred else { return }
    applyExtractionResult(result, sourceURL: playbackSourceURL)
  }

  func useCachedMedia(_ media: PlayableMedia) {
    LinkstrPlaybackDiagnostics.logger.debug("using cached playback")
    if media.isLocalFile {
      Task {
        await VideoCacheService.shared.touchCachedMedia(at: media.playbackURL)
      }
    }
    cachedLocalMedia = media
    extractionState = .ready([media])
  }

  func applyExtractionResult(_ result: ExtractionState, sourceURL: URL) {
    playbackCandidateIndex = 0
    extractionState = result

    switch result {
    case .ready(let candidates):
      LinkstrPlaybackDiagnostics.logger.debug("extraction ready: \(candidates.count) candidates")
      guard let media = candidates.first, media.isLocalFile else { return }
      Task {
        await VideoCacheService.shared.touchCachedMedia(at: media.playbackURL)
      }
      cachedLocalMedia = media
      persistLocalMedia?(sourceURL, media)
    case .noVideo:
      LinkstrPlaybackDiagnostics.logger.info("no extracted video; using fallback presentation")
      localPlaybackMode = .embedPreferred
    case .cannotExtract(let reason):
      LinkstrPlaybackDiagnostics.logger.notice(
        "extraction failed; using fallback presentation: \(reason, privacy: .private)"
      )
      localPlaybackMode = .embedPreferred
    }
  }

  func advancePlaybackCandidate(candidates: [PlayableMedia]) {
    let nextIndex = playbackCandidateIndex + 1
    if nextIndex < candidates.count {
      detectedMediaAspectRatio = nil
      playbackCandidateIndex = nextIndex
    } else {
      applyExtractionResult(
        .cannotExtract("none of the extracted video streams were playable."),
        sourceURL: effectiveSourceURL
      )
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
    if let facebookVideo = EmbeddedWebSource.facebookVideo(for: fallback) {
      return facebookVideo
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
