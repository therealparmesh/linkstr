import XCTest

@testable import linkstr

final class URLClassifierTests: XCTestCase {
  func testRepresentativeURLClassificationAndMediaStrategies() {
    for expectation in MediaURLFixtures.representativeStrategyExpectations {
      assertURLClassificationAndStrategy(expectation)
    }
  }

  func testAliasAndShareURLMediaStrategies() {
    for expectation in MediaURLFixtures.aliasAndShareStrategyExpectations {
      assertURLClassificationAndStrategy(expectation)
    }
  }

  func testClassifyRejectsLookalikeDomains() {
    XCTAssertEqual(URLClassifier.classify("https://notfacebook.com/reel/123456"), .generic)
    XCTAssertEqual(
      URLClassifier.classify("https://instagram.com.evil.com/reel/C7x5mYfP0R1/"), .generic)
    XCTAssertNil(
      SocialURLHeuristics.instagramCanonicalURL(
        for: URL(string: "https://instagram.com.evil.com/reel/C7x5mYfP0R1/")!
      )
    )
    XCTAssertEqual(
      URLClassifier.classify("https://reallytiktok.com/video/7596114833477537054"), .generic)
    XCTAssertEqual(URLClassifier.classify("https://twitter.com.evil.org/jack/status/20"), .generic)
  }

  func testFacebookVideoUsesLocalPlaybackWithMobileWebFallback() {
    let sourceURL = URL(
      string: "https://www.facebook.com/some.page/videos/123456789012345/"
    )!
    let strategy = URLClassifier.mediaStrategy(for: sourceURL)
    guard case .extractionPreferred(let embedURL) = strategy else {
      return XCTFail("Expected local playback for a Facebook video post")
    }

    XCTAssertEqual(
      embedURL.absoluteString,
      "https://m.facebook.com/watch/?v=123456789012345"
    )
    XCTAssertTrue(strategy.allowsLocalPlaybackToggle)
    XCTAssertFalse(URLClassifier.isDedicatedEmbedURL(embedURL))
    XCTAssertEqual(
      URLClassifier.preferredMediaAspectRatio(for: sourceURL, strategy: strategy),
      16.0 / 9.0,
      accuracy: 0.0001
    )
  }

  func testTwitterCanonicalStatusURLNormalizesStatusVariants() {
    XCTAssertEqual(
      SocialURLHeuristics.twitterCanonicalStatusURL(
        from: URL(string: "https://fixupx.com/nyjets/status/924685391524798464/video/1")!
      )?.absoluteString,
      "https://x.com/i/status/924685391524798464"
    )
    XCTAssertEqual(
      SocialURLHeuristics.twitterCanonicalStatusURL(
        from: URL(string: "https://twitter.com/FloodSocial/status/861627479294746624/photo/1")!
      )?.absoluteString,
      "https://x.com/i/status/861627479294746624"
    )
  }

  func testTwitterEmbedOnlyFallbackUsesTweetCardAspectRatio() {
    let sourceURL = URL(string: "https://x.com/jack/status/20")!
    let strategy = URLClassifier.MediaStrategy.embedOnly(
      embedURL: URL(string: "https://x.com/i/status/20")!)

    XCTAssertEqual(
      URLClassifier.preferredMediaAspectRatio(for: sourceURL, strategy: strategy),
      4.0 / 5.0,
      accuracy: 0.0001
    )
  }

  func testTikTokQueryVideoIDUsesCanonicalEmbedURL() {
    let sourceURL = "https://www.tiktok.com/?aweme_id=7596114833477537054"
    let strategy = URLClassifier.mediaStrategy(for: sourceURL)

    XCTAssertEqual(
      SocialURLHeuristics.tikTokPostID(from: URL(string: sourceURL)!),
      "7596114833477537054"
    )
    guard case .extractionPreferred(let embedURL) = strategy else {
      return XCTFail("Expected extractionPreferred for TikTok query video IDs")
    }
    XCTAssertEqual(embedURL.absoluteString, "https://www.tiktok.com/player/v1/7596114833477537054")
  }

  func testTikTokResolvedURLBecomesStableCanonicalVideoURL() throws {
    let resolvedURL = try XCTUnwrap(
      URL(
        string:
          "https://m.tiktok.com/@acct/video/7596114833477537054"
          + "?share_item_id=7596114833477537054&utm_source=copy#video"
      )
    )

    XCTAssertEqual(
      URLCanonicalizationService.canonicalTikTokPostURL(from: resolvedURL)?.absoluteString,
      "https://www.tiktok.com/@acct/video/7596114833477537054"
    )
    XCTAssertNil(
      URLCanonicalizationService.canonicalTikTokPostURL(
        from: try XCTUnwrap(
          URL(string: "https://tiktok.com.example.com/@acct/video/7596114833477537054")
        )
      )
    )
  }

  func testComposerAvailabilityHintMatchesMediaStrategy() {
    XCTAssertEqual(
      NewPostSheet.composerAvailabilityHint(
        for: URLClassifier.MediaStrategy.extractionPreferred(
          embedURL: URL(string: "https://www.tiktok.com/player/v1/7596114833477537054")!
        )
      ),
      "viewable in-app. may be saveable."
    )
    XCTAssertEqual(
      NewPostSheet.composerAvailabilityHint(
        for: URLClassifier.MediaStrategy.embedOnly(
          embedURL: URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")!
        )
      ),
      "viewable in-app."
    )
    XCTAssertNil(NewPostSheet.composerAvailabilityHint(for: .link))
  }

  func testFacebookShareURLHeuristic() {
    XCTAssertTrue(
      SocialURLHeuristics.isFacebookShareURL(
        URL(
          string:
            "https://m.facebook.com/share/v/1AnBCzUqak/?mibextid=wwXIfr&from_xma_click=xma_e2ee"
        )!
      )
    )
    XCTAssertTrue(
      SocialURLHeuristics.isFacebookShareURL(
        URL(string: "https://www.facebook.com/share/r/213286701716863/")!
      )
    )
    XCTAssertFalse(
      SocialURLHeuristics.isFacebookShareURL(
        URL(string: "https://www.facebook.com/reel/213286701716863/")!
      )
    )
  }

  func testMediaStrategyTreatsFacebookMobileShareLikeDesktopShare() {
    let desktop = URLClassifier.mediaStrategy(for: "https://www.facebook.com/share/v/1AnBCzUqak/")
    let mobile = URLClassifier.mediaStrategy(for: "https://m.facebook.com/share/v/1AnBCzUqak/")
    XCTAssertEqual(desktop, mobile)
    guard case .extractionPreferred = mobile else {
      return XCTFail("Expected local playback for Facebook share/v links")
    }
  }

  func testFacebookPageCanonicalURLPrefersReelMetadataOverVideoAlias() {
    let html = """
      <html><head>
      <meta property="og:url" content="https://www.facebook.com/reel/1088981923474158/" />
      </head></html>
      """

    let canonicalURL = URLCanonicalizationService.canonicalFacebookURL(
      pageFinalURL: URL(
        string: "https://www.facebook.com/ABC13Houston/videos/1088981923474158/"
      )!,
      html: html
    )
    XCTAssertEqual(
      canonicalURL?.absoluteString,
      "https://www.facebook.com/reel/1088981923474158/"
    )
  }

  func testFacebookPageCanonicalURLRejectsNonNumericWatchMetadata() {
    let html = """
      <meta property="og:url" content="https://www.facebook.com/watch/?v=related-video-slug">
      """

    let canonicalURL = URLCanonicalizationService.canonicalFacebookURL(
      pageFinalURL: URL(string: "https://www.facebook.com/watch/?v=1088981923474158")!,
      html: html
    )

    XCTAssertEqual(
      canonicalURL?.absoluteString,
      "https://www.facebook.com/watch/?v=1088981923474158"
    )
  }

  func testFacebookCanonicalizesSupportedNumericVideoFormats() {
    let expectedWatchURL = "https://www.facebook.com/watch/?v=1088981923474158"
    for source in [
      "https://www.facebook.com/video.php?v=1088981923474158",
      "https://www.facebook.com/ABC13Houston/videos/news-title/1088981923474158/"
    ] {
      let sourceURL = URL(string: source)!
      XCTAssertEqual(
        URLCanonicalizationService.canonicalFacebookURL(pageFinalURL: sourceURL, html: nil)?
          .absoluteString,
        expectedWatchURL
      )
    }

    let reelURL = URL(string: "https://www.facebook.com/reels/1088981923474158/")!
    XCTAssertEqual(
      URLCanonicalizationService.canonicalFacebookURL(pageFinalURL: reelURL, html: nil)?
        .absoluteString,
      "https://www.facebook.com/reel/1088981923474158/"
    )
  }

  func testFacebookCanonicalCandidateURLParsesCanonicalLinkAndDecodesEntities() {
    let html = """
      <html><head>
      <link rel="canonical" href="https://m.facebook.com/watch/?v=10153231379946729&amp;foo=bar" />
      </head></html>
      """

    let candidate = URLCanonicalizationService.facebookCanonicalCandidateURL(fromHTML: html)
    XCTAssertEqual(
      candidate?.absoluteString,
      "https://m.facebook.com/watch/?v=10153231379946729&foo=bar"
    )
  }

  func testFacebookCanonicalCandidateURLParsesSingleQuotedCanonicalLink() {
    let html = """
      <html><head>
      <link href='https://m.facebook.com/watch/?v=10153231379946729&amp;foo=bar' \
      rel='canonical alternate' />
      </head></html>
      """

    let candidate = URLCanonicalizationService.facebookCanonicalCandidateURL(fromHTML: html)
    XCTAssertEqual(
      candidate?.absoluteString,
      "https://m.facebook.com/watch/?v=10153231379946729&foo=bar"
    )
  }

  func testCanonicalPlaybackURLIgnoresInstagramQueriesForPostIdentity() async throws {
    let shareTokenURL = try XCTUnwrap(URL(string: MediaURLFixtures.instagramShareTokenReelURL))
    let languageURL = try XCTUnwrap(URL(string: MediaURLFixtures.instagramLanguageReelURL))
    let arbitraryQueryURL = try XCTUnwrap(
      URL(string: MediaURLFixtures.instagramArbitraryQueryReelURL)
    )

    let canonicalShareTokenURL =
      await URLCanonicalizationService.shared.canonicalPlaybackURL(for: shareTokenURL)
    let canonicalLanguageURL =
      await URLCanonicalizationService.shared.canonicalPlaybackURL(for: languageURL)
    let canonicalArbitraryQueryURL =
      await URLCanonicalizationService.shared.canonicalPlaybackURL(for: arbitraryQueryURL)

    XCTAssertEqual(
      SocialURLHeuristics.instagramPostID(from: shareTokenURL),
      "DaBh1TUP5sC"
    )
    XCTAssertEqual(
      canonicalShareTokenURL.absoluteString,
      MediaURLFixtures.instagramCanonicalReelURL
    )
    XCTAssertEqual(canonicalShareTokenURL, canonicalLanguageURL)
    XCTAssertEqual(canonicalShareTokenURL, canonicalArbitraryQueryURL)
  }
}

extension URLClassifierTests {
  func testTikTokResolvedPhotoURLBecomesStableCanonicalPostURL() throws {
    let resolvedPhotoURL = try XCTUnwrap(
      URL(
        string:
          "https://m.tiktok.com/@acct/photo/7651971146413329671"
          + "?share_item_id=7651971146413329671&utm_source=copy"
      )
    )
    XCTAssertEqual(
      URLCanonicalizationService.canonicalTikTokPostURL(from: resolvedPhotoURL)?.absoluteString,
      "https://www.tiktok.com/@acct/photo/7651971146413329671"
    )
  }
}

private extension URLClassifierTests {
  func assertURLClassificationAndStrategy(
    _ expectation: MediaURLFixtures.StrategyExpectation
  ) {
    XCTAssertEqual(
      URLClassifier.classify(expectation.url),
      expectation.linkType,
      "Unexpected link type for \(expectation.name)"
    )

    let strategy = URLClassifier.mediaStrategy(for: expectation.url)
    switch (expectation.strategyKind, strategy) {
    case (.extractionPreferred, .extractionPreferred(let embedURL)):
      assertEmbedExpectation(
        expectation.embedExpectation, actualURL: embedURL, name: expectation.name)
    case (.embedOnly, .embedOnly(let embedURL)):
      assertEmbedExpectation(
        expectation.embedExpectation, actualURL: embedURL, name: expectation.name)
    case (.link, .link):
      XCTAssertNil(expectation.embedExpectation, "Link strategies should not expect embeds")
    default:
      XCTFail("Unexpected media strategy for \(expectation.name): \(strategy)")
    }

    XCTAssertEqual(
      strategy.allowsLocalPlaybackToggle,
      expectation.allowsLocalPlayback,
      "Unexpected playback toggle support for \(expectation.name)"
    )
  }

  func assertEmbedExpectation(
    _ expectation: MediaURLFixtures.EmbedExpectation?,
    actualURL: URL,
    name: String
  ) {
    guard let expectation else {
      return XCTFail("Missing embed expectation for \(name)")
    }

    switch expectation {
    case .exact(let expectedURL):
      XCTAssertEqual(actualURL.absoluteString, expectedURL, "Unexpected embed URL for \(name)")
    case .prefix(let expectedPrefix):
      XCTAssertTrue(
        actualURL.absoluteString.hasPrefix(expectedPrefix),
        "Unexpected embed URL prefix for \(name): \(actualURL.absoluteString)"
      )
    }
  }
}
