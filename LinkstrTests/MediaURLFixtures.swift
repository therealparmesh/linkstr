import Foundation

@testable import Linkstr

enum MediaURLFixtures {
  enum StrategyKind {
    case extractionPreferred
    case embedOnly
    case link
  }

  enum EmbedExpectation {
    case exact(String)
    case prefix(String)
  }

  struct StrategyExpectation {
    let name: String
    let url: String
    let linkType: LinkType
    let strategyKind: StrategyKind
    let embedExpectation: EmbedExpectation?
    let allowsLocalPlayback: Bool
  }

  static let representativeStrategyExpectations: [StrategyExpectation] = [
    StrategyExpectation(
      name: "tiktok video",
      url: "https://www.tiktok.com/@acct/video/7596114833477537054",
      linkType: .tiktok,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.tiktok.com/embed/v2/7596114833477537054"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram reel",
      url: "https://www.instagram.com/reel/C7x5mYfP0R1/",
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/reel/C7x5mYfP0R1/embed"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram video post",
      url: "https://www.instagram.com/p/C7x5mYfP0R1/",
      linkType: .instagram,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.instagram.com/p/C7x5mYfP0R1/embed"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "facebook reel",
      url: "https://www.facebook.com/reel/123456789012345",
      linkType: .facebook,
      strategyKind: .extractionPreferred,
      embedExpectation: .prefix("https://www.facebook.com/plugins/video.php?href="),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "facebook video post",
      url: "https://www.facebook.com/some.page/videos/123456789012345/",
      linkType: .facebook,
      strategyKind: .embedOnly,
      embedExpectation: .prefix("https://www.facebook.com/plugins/video.php?href="),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtube watch",
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "rumble video",
      url: "https://rumble.com/v5h7abc-sample-title.html",
      linkType: .rumble,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://rumble.com/embed/v5h7abc/"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "x status",
      url: "https://x.com/jack/status/20",
      linkType: .twitter,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://x.com/i/status/20"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "fixupx status alias",
      url: "https://fixupx.com/nyjets/status/924685391524798464/video/1",
      linkType: .twitter,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://x.com/i/status/924685391524798464"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram profile",
      url: "https://www.instagram.com/nasa/",
      linkType: .instagram,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "facebook profile",
      url: "https://www.facebook.com/nasaearth/",
      linkType: .facebook,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "tiktok profile",
      url: "https://www.tiktok.com/@nasa",
      linkType: .tiktok,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "twitter profile",
      url: "https://x.com/nasa",
      linkType: .twitter,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "generic article",
      url: "https://example.com/article",
      linkType: .generic,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    ),
  ]

  static let aliasAndShareStrategyExpectations: [StrategyExpectation] = [
    StrategyExpectation(
      name: "vm tiktok short link",
      url: "https://vm.tiktok.com/ZMfooBar/",
      linkType: .tiktok,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://vm.tiktok.com/ZMfooBar/"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "mobile instagram reel",
      url: "https://m.instagram.com/reel/C7x5mYfP0R1/",
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/reel/C7x5mYfP0R1/embed"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram shared reel",
      url: "https://www.instagram.com/share/reel/DUSWiOIDivu/",
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/reel/DUSWiOIDivu/embed"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram shared post",
      url: "https://www.instagram.com/share/p/DUbRe_8EuQY/",
      linkType: .instagram,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.instagram.com/p/DUbRe_8EuQY/embed"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "facebook shared video",
      url: "https://www.facebook.com/share/v/10153231379946729/",
      linkType: .facebook,
      strategyKind: .embedOnly,
      embedExpectation: .prefix("https://www.facebook.com/plugins/video.php?href="),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "facebook shared reel",
      url: "https://www.facebook.com/share/r/213286701716863/",
      linkType: .facebook,
      strategyKind: .extractionPreferred,
      embedExpectation: .prefix("https://www.facebook.com/plugins/video.php?href="),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "youtube shorts",
      url: "https://www.youtube.com/shorts/aqz-KE-bpKQ",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.youtube.com/embed/aqz-KE-bpKQ?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtu.be short host",
      url: "https://youtu.be/dQw4w9WgXcQ",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
  ]

  static let validRootPayloadURLs: [String] = [
    "https://www.tiktok.com/@acct/video/7596114833477537054",
    "https://www.instagram.com/share/reel/DUSWiOIDivu/",
    "https://www.facebook.com/share/r/213286701716863/",
    "https://www.youtube.com/shorts/aqz-KE-bpKQ",
    "https://rumble.com/v8tc4h9-zelensky-has-rolled-the-world-in-less-than-2-minutes.html",
    "https://x.com/jack/status/20",
    "https://fixupx.com/nyjets/status/924685391524798464/video/1",
  ]
}
