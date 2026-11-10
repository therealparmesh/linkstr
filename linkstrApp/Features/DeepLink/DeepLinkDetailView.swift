import SwiftUI
import UIKit

struct DeepLinkDetailView: View {
  let urlString: String

  @Environment(\.openURL) private var openURL

  @State private var previewTitle: String?
  @State private var remotePostText: String?
  @State private var thumbnailImage: UIImage?

  private var normalizedURLString: String? {
    LinkstrURLValidator.normalizedWebURL(from: urlString)
  }

  private var sourceURL: URL? {
    guard let normalizedURLString else { return nil }
    return URL(string: normalizedURLString)
  }

  private var mediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: normalizedURLString)
  }

  var body: some View {
    ScrollView {
      if let sourceURL {
        VStack(alignment: .leading, spacing: 18) {
          if mediaStrategy != .link {
            AdaptiveVideoPlaybackView(sourceURL: sourceURL, openSourceAction: { openURL(sourceURL) })
          } else if let thumbnailImage {
            Image(uiImage: thumbnailImage)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: .infinity)
              .clipShape(.rect(cornerRadius: 14))
              .accessibilityHidden(true)
          }
          linkDetails(sourceURL)
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.vertical, LinkstrTheme.screenTopPadding)
        .linkstrReadableContent()
      } else {
        LinkstrCenteredEmptyStateView(
          title: "link unavailable", systemImage: "link.badge.plus",
          description: "this share doesn’t contain a valid web link."
        )
        .frame(minHeight: 300)
      }
    }
    .background(LinkstrBackgroundView())
    .navigationTitle("shared link")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: normalizedURLString) { await loadPreviewIfNeeded() }
  }

  private func linkDetails(_ sourceURL: URL) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let source = LinkstrPostPreview.source(for: normalizedURLString) {
        Label(source, systemImage: "link")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(LinkstrTheme.accent)
      }

      if let previewTitle {
        Text(previewTitle)
          .font(LinkstrTheme.font(.title2, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .accessibilityAddTraits(.isHeader)
      }

      if let remotePostText {
        Text(remotePostText)
          .font(LinkstrTheme.font(.subheadline))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      Text(normalizedURLString ?? urlString)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .textSelection(.enabled)

      if mediaStrategy == .link {
        Button { openURL(sourceURL) } label: {
          LinkstrActionButtonLabel(title: "open original link", systemImage: "arrow.up.right")
        }
        .linkstrPrimaryButton()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func loadPreviewIfNeeded() async {
    previewTitle = nil
    remotePostText = nil
    thumbnailImage = nil

    guard let normalizedURLString else {
      return
    }

    async let preview = URLMetadataService.shared.fetchPreview(for: normalizedURLString)
    async let remotePostText = resolvedRemotePostText(for: normalizedURLString)

    let resolvedPreview = await preview
    guard !Task.isCancelled else { return }
    previewTitle = LinkMetadataRefreshPolicy.normalizedTitle(resolvedPreview?.title)
    if let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: resolvedPreview?.thumbnailPath)?.path {
      let image = await ThumbnailImageCache.shared.loadImageAsync(at: path)
      guard !Task.isCancelled else { return }
      thumbnailImage = image
    }
    let resolvedRemotePostText = await remotePostText
    guard !Task.isCancelled else { return }
    self.remotePostText = resolvedRemotePostText
  }

  private func shouldLoadRemotePostText(for urlString: String) -> Bool {
    guard let url = URL(string: urlString) else { return false }
    return SocialPostResolutionService.supportsRemotePostText(for: url)
  }

  private func resolvedRemotePostText(for urlString: String) async -> String? {
    guard shouldLoadRemotePostText(for: urlString) else { return nil }
    guard let url = URL(string: urlString) else { return nil }
    return await SocialPostResolutionService.resolveRemotePostText(for: url)
  }
}
