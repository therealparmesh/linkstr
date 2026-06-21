import XCTest

@testable import linkstr

final class SocialVideoExtractionServiceTests: XCTestCase {
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
