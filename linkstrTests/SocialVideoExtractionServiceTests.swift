import XCTest

@testable import linkstr

final class SocialVideoExtractionServiceTests: XCTestCase {
  func testInstagramPlaybackProbesTryLightweightURLBeforeShareToken() throws {
    let sourceURL = try XCTUnwrap(
      URL(string: "https://www.instagram.com/reel/DaBh1TUP5sC/?igsh=MmFyM2E2anAyMXdt")
    )
    let canonicalURL = try XCTUnwrap(SocialURLHeuristics.instagramCanonicalURL(for: sourceURL))

    let probeURLs = SocialVideoExtractionService.instagramPlaybackProbeURLs(
      sourceURL: sourceURL,
      canonicalURL: canonicalURL
    )

    XCTAssertEqual(
      probeURLs.map(\.absoluteString),
      [
        "https://www.instagram.com/reel/DaBh1TUP5sC/?l=1",
        "https://www.instagram.com/reel/DaBh1TUP5sC/?igsh=MmFyM2E2anAyMXdt",
        "https://www.instagram.com/reel/DaBh1TUP5sC/",
        "https://www.instagram.com/reel/DaBh1TUP5sC/embed"
      ]
    )
    XCTAssertEqual(Set(probeURLs.map(\.absoluteString)).count, probeURLs.count)
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
}
