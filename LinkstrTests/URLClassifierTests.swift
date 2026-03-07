import XCTest

@testable import Linkstr

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
    XCTAssertEqual(
      URLClassifier.classify("https://reallytiktok.com/video/7596114833477537054"), .generic)
    XCTAssertEqual(URLClassifier.classify("https://twitter.com.evil.org/jack/status/20"), .generic)
  }

  func testFacebookVideoEmbedUsesPluginParameters() {
    let strategy = URLClassifier.mediaStrategy(
      for: "https://www.facebook.com/some.page/videos/123456789012345/")
    guard case .embedOnly(let embedURL) = strategy else {
      return XCTFail("Expected embedOnly strategy for Facebook non-reel video post")
    }

    assertFacebookPluginEmbed(
      embedURL,
      expectedHref: "https://www.facebook.com/some.page/videos/123456789012345/"
    )
    XCTAssertFalse(strategy.allowsLocalPlaybackToggle)
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
    guard case .embedOnly = mobile else {
      return XCTFail("Expected embedOnly for facebook share/v links before canonicalization")
    }
  }

  func testFacebookCanonicalCandidateURLParsesOGURL() {
    let html = """
      <html><head>
      <meta property="og:url" content="https://www.facebook.com/reel/759763136853657/" />
      </head></html>
      """

    let candidate = URLCanonicalizationService.facebookCanonicalCandidateURL(fromHTML: html)
    XCTAssertEqual(candidate?.absoluteString, "https://www.facebook.com/reel/759763136853657/")
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

  private func assertURLClassificationAndStrategy(
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

  private func assertEmbedExpectation(
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

  private func assertFacebookPluginEmbed(_ embedURL: URL, expectedHref: String) {
    guard let components = URLComponents(url: embedURL, resolvingAgainstBaseURL: false) else {
      return XCTFail("Expected URL components for Facebook embed URL")
    }

    XCTAssertEqual(components.scheme, "https")
    XCTAssertEqual(components.host, "www.facebook.com")
    XCTAssertEqual(components.path, "/plugins/video.php")

    func value(_ key: String) -> String? {
      components.queryItems?.first(where: { $0.name == key })?.value
    }

    XCTAssertEqual(value("href"), expectedHref)
    XCTAssertEqual(value("show_text"), "false")
    XCTAssertEqual(value("autoplay"), "false")
    XCTAssertNotNil(value("width"))
    XCTAssertNotNil(value("height"))
  }
}
