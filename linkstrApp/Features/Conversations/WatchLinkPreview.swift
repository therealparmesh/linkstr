import SwiftUI

/// A readable fallback for articles, profiles, and social posts without playable media.
struct WatchLinkPreview: View {
  let post: SessionMessageEntity
  @State private var remoteText: String?

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if post.thumbnailURL != nil {
            LinkstrPostThumbnail(post: post, width: proxy.size.width, height: min(220, proxy.size.width * 0.56))
          }
          VStack(alignment: .leading, spacing: 12) {
            Label(LinkstrPostPreview.source(for: post.url) ?? "shared link", systemImage: "link")
              .font(LinkstrTheme.font(.caption, weight: .semibold))
              .foregroundStyle(LinkstrTheme.accent)
            if let title = LinkstrPostPreview.title(for: post) {
              Text(title)
                .font(LinkstrTheme.font(.title2, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            }
            if let remoteText {
              Text(remoteText)
                .font(LinkstrTheme.font(.body))
                .textSelection(.enabled)
            }
            if let url = post.url {
              Text(url)
                .font(LinkstrTheme.font(.footnote))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .textSelection(.enabled)
            }
          }
          .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(LinkstrTheme.textPrimary)
        .background(LinkstrTheme.panel, in: .rect(cornerRadius: 20))
        .clipShape(.rect(cornerRadius: 20))
      }
      .scrollBounceBehavior(.basedOnSize)
      .defaultScrollAnchor(.center, for: .alignment)
    }
    .task(id: post.url) {
      remoteText = nil
      guard let url = post.url.flatMap(URL.init(string:)),
        SocialPostResolutionService.supportsRemotePostText(for: url) else { return }
      let text = await SocialPostResolutionService.resolveRemotePostText(for: url)
      guard !Task.isCancelled else { return }
      remoteText = LinkstrPostPreview.text(text)
    }
  }
}
