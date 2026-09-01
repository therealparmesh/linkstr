import XCTest

@testable import linkstr

final class SocialVideoExtractionServiceTests: XCTestCase {
  func testGenericMediaDoesNotUseProviderIdentityRules() throws {
    let sourceURL = try XCTUnwrap(URL(string: "https://example.com/video/12345678"))
    let candidateURL = try XCTUnwrap(
      URL(string: "https://cdn.example.com/video/87654321/stream.mp4")
    )

    let result = SocialVideoExtractionService.shared.resolvePlayableMedia(
      from: [candidateURL],
      sourceURL: sourceURL,
      userAgent: "test",
      cookies: []
    )

    guard case .ready(let media) = result else {
      return XCTFail("Expected generic media to remain provider-independent")
    }
    XCTAssertEqual(media.map(\.playbackURL), [candidateURL])
  }

  func testDirectMP4URLResolvesWithoutPageScrape() async throws {
    let url = try XCTUnwrap(URL(string: "https://cdn.example.com/videos/sample.mp4"))

    let state = await SocialVideoExtractionService.shared.extractPlayableMedia(from: url)

    guard case .ready(let media) = state else {
      XCTFail("expected direct mp4 URL to resolve as playable media")
      return
    }
    let first = try XCTUnwrap(media.first)
    XCTAssertEqual(first.playbackURL, url)
    XCTAssertFalse(first.isLocalFile)
  }

  func testDirectHLSURLResolvesWithoutPageScrape() async throws {
    let url = try XCTUnwrap(URL(string: "https://cdn.example.com/videos/master.m3u8"))

    let state = await SocialVideoExtractionService.shared.extractPlayableMedia(from: url)

    guard case .ready(let media) = state else {
      XCTFail("expected direct hls URL to resolve as playable media")
      return
    }
    let first = try XCTUnwrap(media.first)
    XCTAssertEqual(first.playbackURL, url)
    XCTAssertFalse(first.isLocalFile)
  }

  func testLikelyMediaURLRecognizesSignedInstagramCDNVideoWithoutMP4Suffix() {
    let url =
      "https://scontent-dfw5-2.cdninstagram.com/o1/v/t16/f2/m86/"
      + "8A4D5A0D62B8E6B4D3F1E9D3C7A4B8C?stp=dst-jpg_e15_fr_qp1080x1080"
      + "&_nc_ht=scontent-dfw5-2.cdninstagram.com&oe=67FA0D8F&oh=00_AYBexample"

    XCTAssertTrue(SocialVideoExtractionService.isLikelyMediaURLString(url.lowercased()))
  }

  func testLikelyMediaURLRecognizesSignedFBCDNInstagramVideoWithoutMP4Suffix() {
    let url =
      "https://scontent-lax3-2.xx.fbcdn.net/o1/v/t16/f2/m86/"
      + "2D6C9F7A8B4E1D3C5A7B9E2F4D6C8A0?stp=dst-jpg_e15_fr_qp1080x1080"
      + "&efg=eyJ2ZW5jb2RlX3RhZyI6InYxX3YxMCJ9"
      + "&_nc_ht=scontent-lax3-2.xx.fbcdn.net&oe=67FA0D8F&oh=00_AYBexample"

    XCTAssertTrue(SocialVideoExtractionService.isLikelyMediaURLString(url.lowercased()))
  }

  func testLikelyMediaURLRejectsInstagramCDNImageURL() {
    let url =
      "https://scontent-dfw5-2.cdninstagram.com/v/t51.82787-15/"
      + "611216339_17928777444190749_4481488707119326601_n.jpg"
      + "?stp=cmp1_dst-jpg_e35_s640x640_tt6&_nc_cat=108&ccb=7-5"
      + "&_nc_sid=18de74&_nc_ht=scontent-dfw5-2.cdninstagram.com&oe=69D1EEB6"

    XCTAssertFalse(SocialVideoExtractionService.isLikelyMediaURLString(url.lowercased()))
  }

  func testYouTubeHumanTimestampBecomesSeconds() {
    let strategy = URLClassifier.mediaStrategy(
      for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s"
    )
    guard case .embedOnly(let embedURL) = strategy else {
      return XCTFail("Expected a YouTube embed")
    }
    XCTAssertEqual(
      embedURL.absoluteString,
      "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0&start=3723"
    )
  }

  func testDedicatedEmbedURLsRejectOrdinaryProviderPages() {
    let facebookEmbedURL = URL(
      string:
        "https://www.facebook.com/plugins/post.php"
        + "?href=https%3A%2F%2Fwww.facebook.com%2Freel%2F123456789012345%2F"
    )!

    XCTAssertTrue(
      URLClassifier.isDedicatedEmbedURL(
        URL(string: "https://www.tiktok.com/player/v1/7596114833477537054")!
      )
    )
    XCTAssertTrue(
      URLClassifier.isDedicatedEmbedURL(
        URL(string: "https://www.instagram.com/reel/C7x5mYfP0R1/embed")!
      )
    )
    XCTAssertTrue(URLClassifier.isDedicatedEmbedURL(facebookEmbedURL))
    XCTAssertEqual(
      URLClassifier.mediaStrategy(for: facebookEmbedURL),
      .embedOnly(embedURL: facebookEmbedURL)
    )
    XCTAssertFalse(
      URLClassifier.isDedicatedEmbedURL(
        URL(string: "https://www.tiktok.com/@acct/video/7596114833477537054")!
      )
    )
    XCTAssertFalse(
      URLClassifier.isDedicatedEmbedURL(
        URL(string: "https://rumble.com/v5h7abc-sample-title.html")!
      )
    )
  }

  func testMediaPresentationGeometryUsesOnlyValidReportedSizes() {
    XCTAssertEqual(
      MediaPresentationGeometry.aspectRatio(for: CGSize(width: 1_080, height: 1_920)) ?? 0,
      CGFloat(9.0 / 16.0),
      accuracy: 0.0001
    )
    XCTAssertEqual(
      MediaPresentationGeometry.aspectRatio(for: CGSize(width: 1_920, height: 1_080)) ?? 0,
      CGFloat(16.0 / 9.0),
      accuracy: 0.0001
    )
    XCTAssertNil(MediaPresentationGeometry.aspectRatio(for: .zero))
  }

  func testFacebookOpaqueShareTokensAreNotGuessedAsCanonicalIDs() async {
    for sourceURL in [
      URL(string: "https://www.facebook.com/share/v/1AnBCzUqak/")!,
      URL(string: "https://www.facebook.com/share/r/1AnBCzUqak/")!
    ] {
      let fallback = await URLCanonicalizationService.shared.fallbackCanonicalFacebookURL(
        from: sourceURL
      )
      XCTAssertNil(fallback)
    }
  }
}

extension SocialVideoExtractionServiceTests {
  func testInstagramPageVideoExtractionIncludesCarouselAndRejectsRelatedPosts() {
    let html = """
      <script type="application/json">
      {
        "items": [
          {
            "code": "requestedPost",
            "if_not_gated_logged_out": {
              "code": "requestedPost",
              "carousel_media": [
                {
                  "image_versions2": {"candidates": []}
                },
                {
                  "video_versions": [
                    {"url": "https://scontent.cdninstagram.com/video/requested.mp4"}
                  ]
                }
              ]
            }
          },
          {
            "code": "relatedPost",
            "video_versions": [
              {"url": "https://scontent.cdninstagram.com/video/related.mp4"}
            ]
          }
        ]
      }
      </script>
      """

    let urls = SocialVideoExtractionService.extractInstagramPageVideoURLs(
      fromHTML: html,
      expectedPostID: "requestedPost"
    )

    XCTAssertEqual(
      urls.map(\.absoluteString),
      ["https://scontent.cdninstagram.com/video/requested.mp4"]
    )
  }

  func testTikTokPageVideoExtractionUsesTheVerifiedPostContainer() {
    let html = """
      <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">
      {
        "__DEFAULT_SCOPE__": {
          "webapp.reflow.video.detail": {
            "itemInfo": {
              "itemStruct": {
                "id": "123456789",
                "video": {
                  "playAddr": "https://v16.tiktok.com/video/tos/requested.mp4",
                  "downloadAddr": "https://v16.tiktok.com/video/tos/requested-download.mp4"
                }
              }
            }
          }
        },
        "related": {
          "id": "987654321",
          "video": {
            "id": "987654321",
            "playAddr": "https://v16.tiktok.com/video/tos/related.mp4"
          }
        }
      }
      </script>
      """

    let urls = SocialVideoExtractionService.extractTikTokPageVideoURLs(
      fromHTML: html,
      expectedVideoID: "123456789"
    )

    XCTAssertEqual(
      urls.map(\.absoluteString),
      [
        "https://v16.tiktok.com/video/tos/requested.mp4",
        "https://v16.tiktok.com/video/tos/requested-download.mp4"
      ]
    )
  }

  func testFacebookPageVideoExtractionVerifiesKnownPostIdentity() throws {
    let sourceURL = try XCTUnwrap(
      URL(string: "https://www.facebook.com/reel/123456789012345/")
    )
    let videoURL = "https://video.xx.fbcdn.net/video/requested.mp4"
    let matchingHTML = """
      <meta property="og:url" content="https://www.facebook.com/reel/123456789012345/">
      <meta property="og:video" content="\(videoURL)">
      """
    let unrelatedHTML = """
      <meta property="og:url" content="https://www.facebook.com/reel/999999999999999/">
      <meta property="og:video" content="https://video.xx.fbcdn.net/video/related.mp4">
      """
    XCTAssertEqual(
      SocialVideoExtractionService.extractFacebookPageVideoURLs(
        fromHTML: matchingHTML,
        pageURL: sourceURL,
        sourceURL: sourceURL
      ).map(\.absoluteString),
      [videoURL]
    )
    XCTAssertEqual(
      SocialVideoExtractionService.extractFacebookPageVideoURLs(
        fromHTML: matchingHTML,
        pageURL: try XCTUnwrap(
          URL(string: "https://www.facebook.com/watch/?v=555555555555555")
        ),
        sourceURL: sourceURL
      ).map(\.absoluteString),
      [videoURL]
    )
    XCTAssertEqual(
      SocialVideoExtractionService.extractFacebookPageVideoURLs(
        fromHTML: matchingHTML,
        pageURL: sourceURL,
        sourceURL: try XCTUnwrap(
          URL(string: "https://www.facebook.com/share/v/1EscaUGs3R/")
        )
      ).map(\.absoluteString),
      [videoURL]
    )
    XCTAssertTrue(
      SocialVideoExtractionService.extractFacebookPageVideoURLs(
        fromHTML: unrelatedHTML,
        pageURL: try XCTUnwrap(
          URL(string: "https://www.facebook.com/reel/999999999999999/")
        ),
        sourceURL: sourceURL
      ).isEmpty
    )
  }
}
