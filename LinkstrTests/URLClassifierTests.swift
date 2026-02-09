import XCTest

@testable import Linkstr

final class URLClassifierTests: XCTestCase {
  func testClassifySupportedHosts() {
    XCTAssertEqual(
      URLClassifier.classify("https://www.tiktok.com/@acct/video/7596114833477537054"), .tiktok)
    XCTAssertEqual(
      URLClassifier.classify("https://www.instagram.com/reel/C7x5mYfP0R1/"), .instagram)
    XCTAssertEqual(
      URLClassifier.classify("https://www.facebook.com/reel/123456789012345"), .facebook)
    XCTAssertEqual(URLClassifier.classify("https://youtu.be/dQw4w9WgXcQ"), .youtube)
    XCTAssertEqual(URLClassifier.classify("https://rumble.com/v5h7abc-sample.html"), .rumble)
    XCTAssertEqual(URLClassifier.classify("https://x.com/jack/status/20"), .twitter)
    XCTAssertEqual(
      URLClassifier.classify("https://twitter.com/nyjets/status/924685391524798464/video/1"),
      .twitter
    )
    XCTAssertEqual(
      URLClassifier.classify("https://fixupx.com/nyjets/status/924685391524798464/video/1"),
      .twitter
    )
    XCTAssertEqual(URLClassifier.classify("https://example.com/post/abc"), .generic)
  }

  func testMediaStrategyExtractionCandidates() {
    assertExtractionPreferred(
      "https://www.tiktok.com/@acct/video/7596114833477537054",
      expectedEmbedPrefix: "https://www.tiktok.com/embed/v2/"
    )
    assertExtractionPreferred(
      "https://vm.tiktok.com/ZMfooBar/",
      expectedEmbedPrefix: "https://vm.tiktok.com/ZMfooBar/"
    )
    assertExtractionPreferred(
      "https://www.instagram.com/reel/C7x5mYfP0R1/",
      expectedEmbedPrefix: "https://www.instagram.com/reel/C7x5mYfP0R1/embed"
    )
    assertExtractionPreferred(
      "https://www.facebook.com/reel/123456789012345",
      expectedEmbedPrefix: "https://www.facebook.com/plugins/video.php"
    )
  }

  func testMediaStrategyEmbedOnlySites() {
    let youtube = URLClassifier.mediaStrategy(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    guard case .embedOnly(let youtubeEmbedURL) = youtube else {
      return XCTFail("Expected embedOnly strategy for YouTube")
    }
    XCTAssertEqual(youtubeEmbedURL.absoluteString, "https://www.youtube.com/embed/dQw4w9WgXcQ")

    let rumble = URLClassifier.mediaStrategy(for: "https://rumble.com/v5h7abc-sample-title.html")
    guard case .embedOnly(let rumbleEmbedURL) = rumble else {
      return XCTFail("Expected embedOnly strategy for Rumble")
    }
    XCTAssertEqual(rumbleEmbedURL.absoluteString, "https://rumble.com/embed/v5h7abc")

    let instagramVideoPost = URLClassifier.mediaStrategy(
      for: "https://www.instagram.com/p/C7x5mYfP0R1/")
    guard case .embedOnly(let instagramEmbedURL) = instagramVideoPost else {
      return XCTFail("Expected embedOnly strategy for Instagram non-reel post")
    }
    XCTAssertEqual(
      instagramEmbedURL.absoluteString, "https://www.instagram.com/p/C7x5mYfP0R1/embed")

    let instagramTVPost = URLClassifier.mediaStrategy(
      for: "https://www.instagram.com/tv/C7x5mYfP0R1/")
    guard case .embedOnly(let instagramTVEmbedURL) = instagramTVPost else {
      return XCTFail("Expected embedOnly strategy for Instagram tv post")
    }
    XCTAssertEqual(
      instagramTVEmbedURL.absoluteString, "https://www.instagram.com/tv/C7x5mYfP0R1/embed")

    let facebookVideoPost = URLClassifier.mediaStrategy(
      for: "https://www.facebook.com/some.page/videos/123456789012345/")
    guard case .embedOnly(let facebookEmbedURL) = facebookVideoPost else {
      return XCTFail("Expected embedOnly strategy for Facebook non-reel video post")
    }
    XCTAssertTrue(
      facebookEmbedURL.absoluteString.hasPrefix("https://www.facebook.com/plugins/video.php"))

    XCTAssertFalse(youtube.showsVideoPill)
    XCTAssertFalse(youtube.allowsLocalPlaybackToggle)
    XCTAssertFalse(rumble.showsVideoPill)
    XCTAssertFalse(rumble.allowsLocalPlaybackToggle)
    XCTAssertFalse(instagramVideoPost.showsVideoPill)
    XCTAssertFalse(instagramVideoPost.allowsLocalPlaybackToggle)
    XCTAssertEqual(instagramVideoPost.contentKindLabel, "Link")
    XCTAssertEqual(instagramTVPost.contentKindLabel, "Link")
    XCTAssertFalse(facebookVideoPost.showsVideoPill)
    XCTAssertFalse(facebookVideoPost.allowsLocalPlaybackToggle)
    XCTAssertEqual(youtube.contentKindLabel, "Link")
  }

  func testMediaStrategyGenericLink() {
    let strategy = URLClassifier.mediaStrategy(for: "https://example.com/article")
    XCTAssertEqual(strategy, .link)
    XCTAssertFalse(strategy.showsVideoPill)
    XCTAssertFalse(strategy.allowsLocalPlaybackToggle)
    XCTAssertNil(strategy.embedURL)

    let instagramProfile = URLClassifier.mediaStrategy(for: "https://www.instagram.com/nasa/")
    XCTAssertEqual(instagramProfile, .link)

    let facebookProfile = URLClassifier.mediaStrategy(for: "https://www.facebook.com/nasaearth/")
    XCTAssertEqual(facebookProfile, .link)

    let tiktokProfile = URLClassifier.mediaStrategy(for: "https://www.tiktok.com/@nasa")
    XCTAssertEqual(tiktokProfile, .link)

    let twitterProfile = URLClassifier.mediaStrategy(for: "https://x.com/nasa")
    XCTAssertEqual(twitterProfile, .link)
  }

  func testMediaStrategyTwitterVideoAndNonVideoStatuses() {
    assertExtractionPreferred(
      "https://twitter.com/nyjets/status/924685391524798464/video/1",
      expectedEmbedPrefix: "https://fixupx.com/nyjets/status/924685391524798464/video/1"
    )
    assertExtractionPreferred(
      "http://twitter.com/nyjets/status/924685391524798464/video/1",
      expectedEmbedPrefix: "https://fixupx.com/nyjets/status/924685391524798464/video/1"
    )

    assertEmbedOnly(
      "https://twitter.com/FloodSocial/status/861627479294746624/photo/1",
      expectedEmbedPrefix: "https://fixupx.com/FloodSocial/status/861627479294746624/photo/1"
    )
    assertEmbedOnly(
      "https://x.com/jack/status/20",
      expectedEmbedPrefix: "https://fixupx.com/jack/status/20"
    )
  }

  func testYouTubeEmbedForShortsAndYoutuBe() {
    let shorts = URLClassifier.mediaStrategy(for: "https://www.youtube.com/shorts/dQw4w9WgXcQ")
    guard case .embedOnly(let shortsEmbedURL) = shorts else {
      return XCTFail("Expected embedOnly strategy for YouTube shorts")
    }
    XCTAssertEqual(shortsEmbedURL.absoluteString, "https://www.youtube.com/embed/dQw4w9WgXcQ")

    let youtuBe = URLClassifier.mediaStrategy(for: "https://youtu.be/dQw4w9WgXcQ")
    guard case .embedOnly(let youtuBeEmbedURL) = youtuBe else {
      return XCTFail("Expected embedOnly strategy for youtu.be")
    }
    XCTAssertEqual(youtuBeEmbedURL.absoluteString, "https://www.youtube.com/embed/dQw4w9WgXcQ")
  }

  func testMediaStrategyWithPublicSampleLinks() {
    assertExtractionPreferred(
      "https://www.tiktok.com/@boogiebug0/video/7596114833477537054?is_from_webapp=1",
      expectedEmbedPrefix: "https://www.tiktok.com/embed/v2/7596114833477537054"
    )
    assertExtractionPreferred(
      "https://www.instagram.com/reel/DUSWiOIDivu/",
      expectedEmbedPrefix: "https://www.instagram.com/reel/DUSWiOIDivu/embed"
    )
    assertExtractionPreferred(
      "https://www.facebook.com/reel/213286701716863",
      expectedEmbedPrefix: "https://www.facebook.com/plugins/video.php"
    )

    assertEmbedOnly(
      "https://www.instagram.com/p/DUbRe_8EuQY/",
      expectedEmbedPrefix: "https://www.instagram.com/p/DUbRe_8EuQY/embed"
    )
    assertEmbedOnly(
      "https://www.facebook.com/facebook/videos/10153231379946729/",
      expectedEmbedPrefix: "https://www.facebook.com/plugins/video.php"
    )
    assertEmbedOnly(
      "https://www.facebook.com/watch/?v=10153231379946729",
      expectedEmbedPrefix: "https://www.facebook.com/plugins/video.php"
    )
    assertEmbedOnly(
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      expectedEmbedPrefix: "https://www.youtube.com/embed/dQw4w9WgXcQ"
    )
    assertEmbedOnly(
      "https://www.youtube.com/shorts/aqz-KE-bpKQ",
      expectedEmbedPrefix: "https://www.youtube.com/embed/aqz-KE-bpKQ"
    )
    assertEmbedOnly(
      "https://rumble.com/v8tc4h9-zelensky-has-rolled-the-world-in-less-than-2-minutes.html",
      expectedEmbedPrefix: "https://rumble.com/embed/v8tc4h9"
    )
  }

  private func assertExtractionPreferred(_ url: String, expectedEmbedPrefix: String) {
    let strategy = URLClassifier.mediaStrategy(for: url)
    guard case .extractionPreferred(let embedURL) = strategy else {
      return XCTFail("Expected extractionPreferred for \(url)")
    }
    XCTAssertTrue(embedURL.absoluteString.hasPrefix(expectedEmbedPrefix))
    XCTAssertTrue(strategy.showsVideoPill)
    XCTAssertTrue(strategy.allowsLocalPlaybackToggle)
    XCTAssertEqual(strategy.contentKindLabel, "Video")
  }

  private func assertEmbedOnly(_ url: String, expectedEmbedPrefix: String) {
    let strategy = URLClassifier.mediaStrategy(for: url)
    guard case .embedOnly(let embedURL) = strategy else {
      return XCTFail("Expected embedOnly for \(url)")
    }
    XCTAssertTrue(embedURL.absoluteString.hasPrefix(expectedEmbedPrefix))
    XCTAssertFalse(strategy.showsVideoPill)
    XCTAssertFalse(strategy.allowsLocalPlaybackToggle)
    XCTAssertEqual(strategy.contentKindLabel, "Link")
  }
}
