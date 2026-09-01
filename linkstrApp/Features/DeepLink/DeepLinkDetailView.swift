import SwiftUI
import UIKit

struct DeepLinkDetailView: View {
  let urlString: String

  @Environment(\.openURL) private var openURL

  @State private var previewTitle: String?
  @State private var previewThumbnailPath: String?
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
      VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
        LinkstrScreenTitle(title: "shared link")
        linkCard
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
      .linkstrReadableContent()
    }
    .background(LinkstrBackgroundView())
    .task(id: normalizedURLString) {
      await loadPreviewIfNeeded()
    }
  }

  private var linkCard: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
      if let previewTitle {
        Text(previewTitle)
          .font(LinkstrTheme.font(.headline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text(normalizedURLString ?? urlString)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)

      if let remotePostText {
        Text(remotePostText)
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      mediaBlock
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var mediaBlock: some View {
    if let sourceURL {
      switch mediaStrategy {
      case .extractionPreferred, .embedOnly:
        AdaptiveVideoPlaybackView(
          sourceURL: sourceURL,
          openSourceAction: { openURL(sourceURL) }
        )
      case .link:
        VStack(alignment: .leading, spacing: LinkstrTheme.rowSpacing) {
          if let thumbnailImage {
            Image(uiImage: thumbnailImage)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: .infinity, alignment: .leading)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(LinkstrTheme.separator, lineWidth: 1)
              }
          }

          Button("open in browser") {
            openURL(sourceURL)
          }
          .frame(maxWidth: .infinity)
          .linkstrSecondaryButton()
        }
      }
    } else {
      Text("invalid shared link")
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func loadPreviewIfNeeded() async {
    previewTitle = nil
    previewThumbnailPath = nil
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
    previewThumbnailPath = ManagedLocalFileScope.shared.normalizedManagedPath(
      resolvedPreview?.thumbnailPath
    )
    if let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: previewThumbnailPath)?.path {
      thumbnailImage = await ThumbnailImageCache.shared.loadImageAsync(at: path)
    } else {
      thumbnailImage = nil
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
