import SwiftUI
import UIKit

enum LinkstrPostPreview {
  static let maximumArtworkHeight: CGFloat = 220

  static func webURL(for rawURL: String?) -> URL? {
    rawURL.flatMap(LinkstrURLValidator.validatedWebURL(from:))
  }

  static func text(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  static func title(for post: SessionMessageEntity) -> String? {
    displayTitle(post.metadataTitle, for: post.url)
  }

  static func displayTitle(_ value: String?, for urlString: String?) -> String? {
    guard var title = text(value) else { return nil }
    let url = webURL(for: urlString)
    let provider = url.map(URLClassifier.classify)
    if provider == .tiktok, let prefix = title.range(of: "TikTok · ", options: [.anchored, .caseInsensitive]) {
      guard let remainingTitle = text(String(title[prefix.upperBound...])) else { return nil }
      title = remainingTitle
    }

    guard title != urlString,
      URL(string: title)?.scheme?.lowercased() != "https",
      URL(string: title)?.scheme?.lowercased() != "http"
    else { return nil }

    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|·"))
    let comparableTitle = title.trimmingCharacters(in: separators).lowercased()
    guard !comparableTitle.isEmpty, comparableTitle != url.flatMap(source(for:))?.lowercased() else { return nil }
    if let provider {
      if provider != .generic, comparableTitle == provider.rawValue.lowercased() { return nil }
      if provider == .twitter, comparableTitle == "x" { return nil }
    }
    return title
  }

  static func source(for urlString: String?) -> String? {
    webURL(for: urlString).flatMap(source(for:))
  }

  private static func source(for url: URL) -> String? {
    guard let host = url.host else { return nil }
    let provider = URLClassifier.classify(url)
    let name = provider == .generic
      ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
      : (provider == .twitter ? "x" : provider.rawValue)
    return kind(for: url).map { "\(name) \($0)" } ?? name
  }

  static func kind(for urlString: String?) -> String? {
    guard let url = webURL(for: urlString) else { return nil }
    return kind(for: url)
  }

  private static func kind(for url: URL) -> String? {
    if SocialURLHeuristics.isInstagramReelURL(url) || SocialURLHeuristics.isFacebookReelURL(url) {
      return "reel"
    }
    if URLClassifier.isDirectVideoURL(url) || SocialURLHeuristics.isYouTubeVideoURL(url)
      || SocialURLHeuristics.isRumbleVideoURL(url)
      || SocialURLHeuristics.isTikTokVideoURL(url) || SocialURLHeuristics.isFacebookVideoURL(url) {
      return "video"
    }
    if SocialURLHeuristics.isTikTokPhotoURL(url) { return "photo post" }
    if SocialURLHeuristics.isTwitterStatusURL(url) { return "post" }
    return nil
  }
}

struct LinkstrPostThumbnail: View {
  let post: SessionMessageEntity
  let width: CGFloat
  let height: CGFloat
  var size: ThumbnailImageCache.Size = .preview
  var cornerRadius = LinkstrTheme.thumbnailCornerRadius
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
      .clipShape(.rect(cornerRadius: cornerRadius))
      .overlay(alignment: .bottomTrailing) {
        if image != nil, size == .listRow, placeholderIcon == "play.fill" {
          Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .frame(width: 19, height: 19)
            .background(LinkstrTheme.background, in: Circle())
            .padding(4)
        }
      }
      .accessibilityHidden(true)
      .task(id: post.encryptedThumbnailURL) {
        image = nil
        guard let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: post.thumbnailURL)?.path else { return }
        let loaded = await ThumbnailImageCache.shared.loadImageAsync(at: path, size: size)
        guard !Task.isCancelled else { return }
        image = loaded
      }
  }
}
