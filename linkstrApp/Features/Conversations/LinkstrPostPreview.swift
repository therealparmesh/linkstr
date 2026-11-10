import SwiftUI
import UIKit

enum LinkstrPostPreview {
  static func text(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  static func title(for post: SessionMessageEntity) -> String? {
    guard let title = text(post.metadataTitle), title != post.url,
      URL(string: title)?.scheme?.lowercased() != "https",
      URL(string: title)?.scheme?.lowercased() != "http"
    else { return nil }
    return title
  }

  static func source(for urlString: String?) -> String? {
    guard let urlString, let url = URL(string: urlString), let host = url.host else { return nil }
    let provider = URLClassifier.classify(url)
    let name = provider == .generic
      ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
      : (provider == .twitter ? "x" : provider.rawValue)
    return kind(for: urlString).map { "\(name) \($0)" } ?? name
  }

  static func kind(for urlString: String?) -> String? {
    guard let urlString, let url = URL(string: urlString) else { return nil }
    if SocialURLHeuristics.isInstagramReelURL(url) || SocialURLHeuristics.isFacebookReelURL(url) {
      return "reel"
    }
    if SocialURLHeuristics.isYouTubeVideoURL(url) || SocialURLHeuristics.isRumbleVideoURL(url)
      || SocialURLHeuristics.isTikTokVideoURL(url) || SocialURLHeuristics.isFacebookVideoURL(url) {
      return "video"
    }
    if SocialURLHeuristics.isTikTokPhotoURL(url) { return "photo post" }
    return nil
  }
}

struct LinkstrPostThumbnail: View {
  let post: SessionMessageEntity
  let width: CGFloat
  let height: CGFloat
  @State private var image: UIImage?

  private var placeholderIcon: String {
    switch LinkstrPostPreview.kind(for: post.url) {
    case "video", "reel": "play.fill"
    case "photo post": "photo"
    default: "link"
    }
  }

  var body: some View {
    Rectangle()
      .fill(LinkstrTheme.panelElevated)
      .overlay {
        if let image {
          Image(uiImage: image).resizable().scaledToFill()
        } else {
          Image(systemName: placeholderIcon)
            .font(LinkstrTheme.font(.footnote, weight: .medium))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
      }
      .frame(width: width, height: height)
      .clipShape(.rect(cornerRadius: 10))
      .accessibilityHidden(true)
      .task(id: post.encryptedThumbnailURL) {
        image = nil
        guard let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: post.thumbnailURL)?.path else { return }
        let loaded = await ThumbnailImageCache.shared.loadImageAsync(at: path)
        guard !Task.isCancelled else { return }
        image = loaded
      }
  }
}
