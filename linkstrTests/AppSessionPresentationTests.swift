import CoreImage
import Observation
import UIKit
import XCTest

@testable import linkstr

extension AppSessionPresentationTests {
  @MainActor
  func testCancelledPhotoSaveStopsBeforeRequestingLibraryAccess() async {
    let save = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        try await LocalMediaExportTarget(fileURL: URL(fileURLWithPath: "/missing-video.mp4")).saveToPhotos()
        XCTFail("a cancelled save must not reach Photos")
      } catch is CancellationError {
        // Cancellation takes precedence over permission and missing-file errors.
      } catch {
        XCTFail("expected cancellation, received \(error)")
      }
    }
    await save.value
  }

  @MainActor
  func testCachedDisplayValuesNotifyObserversWhenEdited() async throws {
    let owner = try TestKeyMaterialFactory.makePubkeyHex()
    defer { try? LocalDataCrypto.shared.clearKey(ownerPubkey: owner) }
    let post = try SessionMessageEntity(
      eventID: "preview", ownerPubkey: owner, conversationID: "session", rootID: "preview",
      kind: .root, senderPubkey: owner, url: "https://example.org", note: nil,
      timestamp: .now, linkType: .generic
    )
    let session = try SessionEntity(ownerPubkey: owner, sessionID: "session", name: "", createdByPubkey: owner)
    let contact = try ContactEntity(ownerPubkey: owner, targetPubkey: owner)
    let fields: [(String, () -> String?)] = [
      ("preview title", { post.metadataTitle }), ("thumbnail", { post.thumbnailURL }),
      ("session name", { session.name }), ("contact alias", { contact.localAlias })
    ]
    for value in ["updated", "", "updated again"] {
      let notifications = fields.map { name, read in
        _ = read() // Warm the cache before SwiftUI subscribes on a later render.
        let notification = expectation(description: "\(name) changed to \(value)")
        withObservationTracking { _ = read() } onChange: { notification.fulfill() }
        return notification
      }
      let optionalValue = value.isEmpty ? nil : value
      try post.setMetadata(title: optionalValue, thumbnailURL: optionalValue)
      try session.updateName(value, updatedAt: .now)
      try contact.updateAlias(optionalValue)
      await fulfillment(of: notifications, timeout: 0.1)
      XCTAssertEqual(post.metadataTitle, optionalValue)
      XCTAssertEqual(post.thumbnailURL, optionalValue)
      XCTAssertEqual(session.name, value)
      XCTAssertEqual(contact.localAlias, optionalValue)
    }
  }
}

final class AppSessionPresentationTests: XCTestCase {
  @MainActor
  func testThumbnailCacheKeepsDistinctSizesAndEvictsBoth() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    let cache = ThumbnailImageCache.shared
    defer {
      try? FileManager.default.removeItem(at: url)
      cache.removeImage(at: url.path)
    }
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360))
    let data = renderer.pngData { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    }
    try data.write(to: url)

    async let firstRow = cache.loadImageAsync(at: url.path, size: .listRow)
    async let secondRow = cache.loadImageAsync(at: url.path, size: .listRow)
    let (row, duplicateRow) = await (firstRow, secondRow)
    XCTAssertTrue(row === duplicateRow)
    let preview = await cache.loadImageAsync(at: url.path)
    XCTAssertEqual(row?.cgImage?.width, 256)
    XCTAssertEqual(preview?.cgImage?.width, 512)

    try FileManager.default.removeItem(at: url)
    cache.removeImage(at: url.path)
    let removedRow = await cache.loadImageAsync(at: url.path, size: .listRow)
    let removedPreview = await cache.loadImageAsync(at: url.path)
    XCTAssertNil(removedRow)
    XCTAssertNil(removedPreview)
  }

  func testPreviewTitleOmitsSourcePlaceholdersAndPreservesRealTitles() {
    let youtube = "https://youtu.be/aqz-KE-bpKQ"
    XCTAssertNil(LinkstrPostPreview.displayTitle("- YouTube", for: youtube))
    XCTAssertNil(LinkstrPostPreview.displayTitle(youtube, for: youtube))
    XCTAssertNil(LinkstrPostPreview.displayTitle("  |  ", for: youtube))
    XCTAssertEqual(
      LinkstrPostPreview.displayTitle("Big Buck Bunny - YouTube", for: youtube), "Big Buck Bunny - YouTube"
    )
    XCTAssertNil(LinkstrPostPreview.displayTitle("X", for: "https://x.com/jack/status/20"))
    let tiktok = "https://www.tiktok.com/@scout2015/video/6718335390845095173"
    XCTAssertEqual(
      LinkstrPostPreview.displayTitle("TikTok · Scout, Suki & Stella", for: tiktok), "Scout, Suki & Stella"
    )
    XCTAssertNil(LinkstrPostPreview.displayTitle("TikTok · ", for: tiktok))
    XCTAssertEqual(LinkstrPostPreview.displayTitle("Scout · Stella", for: tiktok), "Scout · Stella")
    XCTAssertNil(LinkstrPostPreview.displayTitle("Example.org", for: "https://example.org"))
    XCTAssertEqual(LinkstrPostPreview.displayTitle("Example Domain", for: "https://example.org"), "Example Domain")
  }

  func testPreviewSourceOnlyLabelsSupportedWebLinks() {
    XCTAssertNil(LinkstrPostPreview.source(for: "ftp://example.org/legacy"))
    XCTAssertNil(LinkstrPostPreview.kind(for: "ftp://x.com/jack/status/20"))
    XCTAssertEqual(LinkstrPostPreview.source(for: "example.org/article"), "example.org")
    XCTAssertEqual(LinkstrPostPreview.source(for: "https://x.com/jack/status/20"), "x post")
  }

  @MainActor
  func testThemedQRCodePreservesItsPayload() throws {
    let payload = "npub1example"
    let image = try XCTUnwrap(QRCodeGenerator.image(for: payload)?.cgImage)
    let detector = try XCTUnwrap(
      CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    )
    let codes = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }

    XCTAssertEqual(codes.first?.messageString, payload)
  }

  func testReactionSummaryBadgeTextCapsAtTenPlus() {
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 1, includesCurrentUser: false).badgeText,
      "1"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 10, includesCurrentUser: false).badgeText,
      "10"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 11, includesCurrentUser: false).badgeText,
      "10+"
    )
  }

  func testReactionSummaryReadOnlyBadgeTextHidesSingleReaction() {
    XCTAssertNil(
      ReactionSummary(emoji: "🔥", count: 1, includesCurrentUser: false).readOnlyBadgeText
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 2, includesCurrentUser: false).readOnlyBadgeText,
      "2"
    )
    XCTAssertEqual(
      ReactionSummary(emoji: "🔥", count: 12, includesCurrentUser: false).readOnlyBadgeText,
      "10+"
    )
  }

  func testTwitterStatusResponseParserExtractsPreviewFromVXPath() throws {
    let json = try jsonObject(
      from: """
        {
          "user_name": "frankie",
          "user_screen_name": "FrankieIsLost",
          "text": "watching the skyline drift by",
          "mediaURLs": ["https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg"],
          "media_extended": [
            {
              "type": "image",
              "thumbnail_url": "https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg",
              "url": "https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg"
            }
          ]
        }
        """
    )

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)
    XCTAssertFalse(summary.hasVideo)
    XCTAssertEqual(summary.preview?.title, "frankie (@FrankieIsLost)")
    XCTAssertEqual(summary.preview?.bodyText, "watching the skyline drift by")
    XCTAssertEqual(
      summary.preview?.imageURL?.absoluteString,
      "https://pbs.twimg.com/media/HCsD9p5XwAAANE6.jpg"
    )
  }

  func testTwitterStatusResponseParserExtractsPreviewFromFXPath() throws {
    let json = try jsonObject(
      from: """
        {
          "tweet": {
            "text": "rainy night drive",
            "author": {
              "name": "AlphaFox",
              "screen_name": "alphafox"
            },
            "media": {
              "photos": [
                {
                  "type": "photo",
                  "url": "https://pbs.twimg.com/media/example-photo.jpg?name=orig",
                  "width": 951,
                  "height": 419
                }
              ]
            }
          }
        }
        """
    )

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)
    XCTAssertFalse(summary.hasVideo)
    XCTAssertEqual(summary.preview?.title, "AlphaFox (@alphafox)")
    XCTAssertEqual(summary.preview?.bodyText, "rainy night drive")
    XCTAssertEqual(
      summary.preview?.imageURL?.absoluteString,
      "https://pbs.twimg.com/media/example-photo.jpg?name=orig"
    )
  }

  func testTwitterStatusResponseParserFindsNestedVideoURLs() throws {
    let json: [String: Any] = [
      "tweet": [
        "media": [
          "unexpected_shape": [
            [
              "nested": [
                "source": "https://video.twimg.com/ext_tw_video/20/pu/vid/1280x720/sample.mp4"
              ]
            ]
          ]
        ]
      ]
    ]

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)

    XCTAssertTrue(summary.hasVideo)
    XCTAssertEqual(
      summary.candidateURLs.map(\.absoluteString),
      ["https://video.twimg.com/ext_tw_video/20/pu/vid/1280x720/sample.mp4"]
    )
  }

  func testTwitterStatusResponseParserKeepsRootMediaVideoURLs() {
    let videoURL = "https://video.twimg.com/ext_tw_video/20/pu/vid/1280x720/root.mp4"
    let json: [String: Any] = [
      "media_extended": [
        ["type": "video", "url": videoURL]
      ]
    ]

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)

    XCTAssertTrue(summary.hasVideo)
    XCTAssertEqual(summary.candidateURLs.map(\.absoluteString), [videoURL])
  }

  func testTwitterStatusResponseParserIgnoresQuotedPostVideo() throws {
    let json: [String: Any] = [
      "tweet": [
        "text": "outer post with a photo",
        "media": [
          "photos": [
            ["type": "photo", "url": "https://pbs.twimg.com/media/outer.jpg"]
          ]
        ],
        "quoted_tweet": [
          "media": [
            "videos": [
              [
                "type": "video",
                "url": "https://video.twimg.com/ext_tw_video/99/pu/vid/quoted.mp4"
              ]
            ]
          ]
        ]
      ]
    ]

    let summary = TwitterStatusResponseParser.mediaSummary(from: json)

    XCTAssertFalse(summary.hasVideo)
    XCTAssertTrue(summary.candidateURLs.isEmpty)
  }

  func testLinkMetadataRefreshPolicyCases() {
    for testCase in linkMetadataRefreshPolicyCases {
      XCTAssertEqual(
        LinkMetadataRefreshPolicy.needsRefresh(
          linkType: testCase.linkType,
          title: testCase.metadataTitle,
          thumbnailPath: testCase.thumbnailPath,
          fileExists: testCase.fileExists
        ),
        testCase.expectedNeedsRefresh,
        testCase.title
      )
    }
  }

  func testContactAvatarInitialsPreferFirstAndLastWords() {
    XCTAssertEqual(
      LinkstrAvatarStyleResolver.contactInitials(for: "John Ronald Reuel Tolkien"),
      "JT"
    )
    XCTAssertEqual(
      LinkstrAvatarStyleResolver.contactInitials(for: "Ada Lovelace"),
      "AL"
    )
    XCTAssertEqual(
      LinkstrAvatarStyleResolver.contactInitials(for: "Madonna"),
      "MA"
    )
    XCTAssertEqual(
      LinkstrAvatarStyleResolver.contactInitials(for: "   "),
      "?"
    )
  }

  func testStableTaskIDIsDeterministicAndOrderIndependent() {
    XCTAssertEqual(["b", "a", "a"].stableTaskID, ["a", "b"].stableTaskID)
    XCTAssertEqual(Set(["b", "a"]).stableTaskID, ["a", "b"].stableTaskID)
    XCTAssertNotEqual(["ab"].stableTaskID, ["a", "b"].stableTaskID)
  }

  private func jsonObject(from raw: String) throws -> [String: Any] {
    let data = try XCTUnwrap(raw.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

private struct LinkMetadataRefreshTestCase {
  let title: String
  let linkType: LinkType
  let metadataTitle: String?
  let thumbnailPath: String?
  let fileExists: (String) -> Bool
  let expectedNeedsRefresh: Bool
}

private let linkMetadataRefreshPolicyCases: [LinkMetadataRefreshTestCase] = [
  LinkMetadataRefreshTestCase(
    title: "missing title refreshes",
    linkType: .generic,
    metadataTitle: "   ",
    thumbnailPath: "/tmp/thumb.png",
    fileExists: { _ in true },
    expectedNeedsRefresh: true
  ),
  LinkMetadataRefreshTestCase(
    title: "tiktok missing thumbnail refreshes lazily",
    linkType: .tiktok,
    metadataTitle: "some creator",
    thumbnailPath: nil,
    fileExists: { _ in false },
    expectedNeedsRefresh: true
  ),
  LinkMetadataRefreshTestCase(
    title: "twitter missing thumbnail refreshes lazily",
    linkType: .twitter,
    metadataTitle: "frankie (@FrankieIsLost)",
    thumbnailPath: nil,
    fileExists: { _ in false },
    expectedNeedsRefresh: true
  ),
  LinkMetadataRefreshTestCase(
    title: "generic missing thumbnail still skips refresh",
    linkType: .generic,
    metadataTitle: "Example title",
    thumbnailPath: nil,
    fileExists: { _ in false },
    expectedNeedsRefresh: false
  ),
  LinkMetadataRefreshTestCase(
    title: "existing missing file refreshes lazily",
    linkType: .instagram,
    metadataTitle: "Example title",
    thumbnailPath: "/tmp/thumb.png",
    fileExists: { _ in false },
    expectedNeedsRefresh: true
  ),
  LinkMetadataRefreshTestCase(
    title: "title and thumbnail present skips refresh",
    linkType: .twitter,
    metadataTitle: "AlphaFox (@alphafox)",
    thumbnailPath: "/tmp/thumb.png",
    fileExists: { _ in true },
    expectedNeedsRefresh: false
  )
]
