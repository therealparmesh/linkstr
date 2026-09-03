@testable import linkstr

extension MediaURLFixtures {
  static let aliasAndShareStrategyExpectations: [StrategyExpectation] = [
    StrategyExpectation(
      name: "tiktok /t/ short link",
      url: "https://www.tiktok.com/t/ZTk1EeG6M/",
      linkType: .tiktok,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.tiktok.com/t/ZTk1EeG6M/"),
      allowsLocalPlayback: true
    ),
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
      embedExpectation: .exact("https://www.instagram.com/reel/C7x5mYfP0R1/?l=1"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram shared reel",
      url: "https://www.instagram.com/share/reel/DUSWiOIDivu/",
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/reel/DUSWiOIDivu/?l=1"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram shared post",
      url: "https://www.instagram.com/share/p/DUbRe_8EuQY/",
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/p/DUbRe_8EuQY/?l=1"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram post with language query",
      url: "https://www.instagram.com/p/C-dH1fUNQwq/?l=1",
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/p/C-dH1fUNQwq/?l=1"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "instagram reel with share token query",
      url: instagramShareTokenReelURL,
      linkType: .instagram,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://www.instagram.com/reel/DaBh1TUP5sC/?l=1"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "facebook shared video",
      url: "https://www.facebook.com/share/v/10153231379946729/",
      linkType: .facebook,
      strategyKind: .extractionPreferred,
      embedExpectation: .exact("https://m.facebook.com/watch/?v=10153231379946729"),
      allowsLocalPlayback: true
    ),
    StrategyExpectation(
      name: "facebook shared reel",
      url: "https://www.facebook.com/share/r/213286701716863/",
      linkType: .facebook,
      strategyKind: .extractionPreferred,
      embedExpectation: .prefix("https://www.facebook.com/plugins/post.php?href="),
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
      name: "youtube legacy video path",
      url: "https://www.youtube.com/v/dQw4w9WgXcQ",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtu.be short host",
      url: "https://youtu.be/dQw4w9WgXcQ",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact(
        "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtube live stream",
      url: "https://www.youtube.com/live/jfKfPfyJRdk",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact("https://www.youtube.com/embed/jfKfPfyJRdk?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtube watch with timestamp",
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact(
        "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0&start=43"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtube-nocookie embed",
      url: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
      linkType: .youtube,
      strategyKind: .embedOnly,
      embedExpectation: .exact(
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"),
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "youtube channel page",
      url: "https://www.youtube.com/@MrBeast",
      linkType: .youtube,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    ),
    StrategyExpectation(
      name: "rumble channel page",
      url: "https://rumble.com/c/RussellBrand",
      linkType: .rumble,
      strategyKind: .link,
      embedExpectation: nil,
      allowsLocalPlayback: false
    )
  ]

  static let validRootPayloadURLs: [String] = [
    "https://www.tiktok.com/@acct/video/7596114833477537054",
    "https://www.instagram.com/share/reel/DUSWiOIDivu/",
    "https://www.facebook.com/share/r/213286701716863/",
    "https://www.youtube.com/shorts/aqz-KE-bpKQ",
    "https://rumble.com/v8tc4h9-zelensky-has-rolled-the-world-in-less-than-2-minutes.html",
    "https://x.com/jack/status/20",
    "https://fixupx.com/nyjets/status/924685391524798464/video/1"
  ]
}
