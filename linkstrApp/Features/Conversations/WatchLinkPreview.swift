import SwiftUI

/// A readable fallback for articles, profiles, and social posts without playable media.
struct WatchLinkPreview: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.openURL) private var openURL

  let post: SessionMessageEntity
  let postText: String?

  private var sourceURL: URL? { LinkstrPostPreview.webURL(for: post.url) }

  var body: some View {
    GeometryReader { proxy in
      let thumbnailHeight = min(
        LinkstrPostPreview.maximumArtworkHeight, proxy.size.width * 0.56, proxy.size.height * 0.4
      )
      if proxy.size.height >= LinkstrTheme.minimumInteractiveDimension {
        ScrollView {
          preview(width: proxy.size.width, thumbnailHeight: thumbnailHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
      }
    }
  }

  private func preview(width: CGFloat, thumbnailHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if !dynamicTypeSize.isAccessibilitySize, thumbnailHeight >= 64, post.thumbnailURL != nil {
        LinkstrPostThumbnail(post: post, width: width, height: thumbnailHeight, cornerRadius: 0)
      }

      VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
        Text(LinkstrPostPreview.source(for: post.url) ?? "link")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textSecondary)
        if let postText {
          Text(postText)
            .font(LinkstrTheme.font(.body))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        } else if let title = LinkstrPostPreview.title(for: post) {
          Text(title)
            .font(LinkstrTheme.font(.headline))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        }
        if let sourceURL {
          Button {
            openURL(sourceURL)
          } label: {
            Label(LinkstrBrowserAction.title, systemImage: LinkstrBrowserAction.icon)
              .font(LinkstrTheme.font(.footnote, weight: .semibold))
              .foregroundStyle(LinkstrTheme.accent)
              .frame(maxWidth: .infinity, minHeight: LinkstrTheme.minimumInteractiveDimension, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding([.top, .horizontal], LinkstrTheme.panelPadding)
      .padding(.bottom, LinkstrTheme.metaSpacing)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(LinkstrTheme.textPrimary)
    .linkstrCardSurface()
  }
}
