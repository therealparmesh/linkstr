import Foundation

struct MediaDiscoveryBudget: Sendable {
  private let deadline: ContinuousClock.Instant

  init(duration: Duration = SocialVideoTimingDefaults.localDiscoveryBudget) {
    deadline = ContinuousClock().now.advanced(by: duration)
  }

  var permitsAttempt: Bool {
    !Task.isCancelled && ContinuousClock().now < deadline
  }
}

extension SocialVideoExtractionService {
  func extractPlayableMedia(from sourceURL: URL) async -> ExtractionState {
    let sourceURLString = sourceURL.absoluteString.lowercased()
    if Self.isLikelyMediaURLString(sourceURLString),
      let resolved = resolvePlayableMedia(
        from: [sourceURL],
        sourceURL: sourceURL,
        userAgent: Self.mobileUserAgent,
        cookies: []
      ) {
      return resolved
    }

    return await discoverPlayableMedia(
      from: sourceURL,
      budget: MediaDiscoveryBudget()
    )
  }

  private func discoverPlayableMedia(
    from sourceURL: URL,
    budget: MediaDiscoveryBudget
  ) async -> ExtractionState {
    let playbackSourceURL =
      await URLCanonicalizationService.shared.canonicalPlaybackURL(for: sourceURL)
    guard budget.permitsAttempt else {
      return .cannotExtract("could not find a usable video stream for this post.")
    }

    let linkType = URLClassifier.classify(playbackSourceURL)
    let providerResult: ExtractionState?
    switch linkType {
    case .tiktok:
      providerResult = await extractFromTikTok(
        sourceURL: playbackSourceURL,
        budget: budget
      )
    case .instagram:
      providerResult = await extractFromInstagram(
        sourceURL: playbackSourceURL,
        budget: budget
      )
    case .facebook:
      providerResult = await extractFromFacebook(
        sourceURL: playbackSourceURL,
        budget: budget
      )
    case .twitter:
      providerResult = await extractFromTwitter(
        sourceURL: playbackSourceURL,
        budget: budget
      )
    case .youtube, .rumble, .generic:
      providerResult = nil
    }

    if let providerResult {
      return providerResult
    }
    if linkType == .tiktok || linkType == .instagram || linkType == .facebook {
      return .cannotExtract("could not find a usable video stream for this post.")
    }
    guard budget.permitsAttempt else {
      return .cannotExtract("could not find a usable video stream for this post.")
    }
    return await extractViaGenericSniff(
      sourceURL: playbackSourceURL,
      budget: budget
    )
  }
}
