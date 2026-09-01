import XCTest

@testable import linkstr

final class EmbeddedWebSourceTests: XCTestCase {
  func testFacebookVideoUsesOfficialOEmbedWithoutReplacingReels() throws {
    let videoURL = try XCTUnwrap(
      URL(string: "https://m.facebook.com/watch/?v=123456789012345")
    )
    guard case .html(let document, let baseURL) = EmbeddedWebSource.facebookVideo(for: videoURL)
    else {
      return XCTFail("Expected a Facebook oEmbed document")
    }

    XCTAssertEqual(baseURL?.absoluteString, "https://www.facebook.com")
    XCTAssertTrue(document.contains("https://graph.facebook.com/oembed_video?"))
    XCTAssertTrue(document.contains("123456789012345"))
    XCTAssertNil(
      EmbeddedWebSource.facebookVideo(
        for: try XCTUnwrap(URL(string: "https://www.facebook.com/reel/123456789012345/"))
      )
    )
  }
}
