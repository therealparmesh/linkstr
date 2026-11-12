import SwiftUI
import UIKit

struct DeepLinkDetailView: View {
  let sourceURL: URL

  @Environment(\.openURL) private var openURL
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var previewTitle: String?
  @State private var remotePostText: String?
  @State private var thumbnailImage: UIImage?
  @State private var resolvedShortLink: (original: URL, destination: URL)?

  private var mediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: sourceURL)
  }

  private var previewURL: URL? {
    guard SocialURLHeuristics.isTikTokShortURL(sourceURL) else { return sourceURL }
    guard let resolvedShortLink, resolvedShortLink.original == sourceURL else { return nil }
    return resolvedShortLink.destination
  }

  var body: some View {
    let isRegularLink = mediaStrategy == .link
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
        if isRegularLink {
          linkDetails(showsArtwork: true)
          LinkstrBrowserButton { openURL(sourceURL) }
        } else {
          AdaptiveMediaView(
            sourceURL: sourceURL,
            openSourceAction: { openURL(sourceURL) },
            onResolvedSource: { destination in
              if SocialURLHeuristics.isTikTokShortURL(sourceURL) {
                resolvedShortLink = (sourceURL, destination)
              }
            },
            linkContent: { linkDetails(showsArtwork: false) }
          )
        }
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
      .linkstrReadableContent()
    }
    .background(LinkstrBackgroundView())
    .navigationTitle("shared link")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: previewURL) { await loadPreviewIfNeeded() }
    .task(id: previewURL) { await loadRemotePostText() }
  }

  private func linkDetails(showsArtwork: Bool) -> some View {
    return VStack(alignment: .leading, spacing: LinkstrTheme.buttonRowSpacing) {
      if showsArtwork, !dynamicTypeSize.isAccessibilitySize, let thumbnailImage {
        Image(uiImage: thumbnailImage)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: LinkstrPostPreview.maximumArtworkHeight)
          .clipShape(.rect(cornerRadius: LinkstrTheme.fieldCornerRadius))
          .accessibilityHidden(true)
      }

      if let source = LinkstrPostPreview.source(for: (previewURL ?? sourceURL).absoluteString) {
        Label(source, systemImage: "link")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .foregroundStyle(LinkstrTheme.accent)
      }

      if let previewTitle {
        Text(previewTitle)
          .font(LinkstrTheme.font(.title2, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityAddTraits(.isHeader)
      }

      if let remotePostText, remotePostText != previewTitle {
        Text(remotePostText)
          .font(LinkstrTheme.font(.body))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      LinkstrURLText(address: sourceURL.absoluteString)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(LinkstrTheme.textPrimary)
    .padding(.vertical, LinkstrTheme.compactSpacing)
  }

  private func loadPreviewIfNeeded() async {
    previewTitle = nil
    thumbnailImage = nil

    guard let previewURL else { return }
    let previewAddress = previewURL.absoluteString

    if let title = await URLMetadataService.shared.fetchYouTubeVideoTitle(for: previewURL) {
      guard !Task.isCancelled else { return }
      previewTitle = LinkstrPostPreview.displayTitle(title, for: previewAddress)
      return
    }
    guard !Task.isCancelled else { return }
    let resolvedPreview = await URLMetadataService.shared.fetchPreview(for: previewAddress)
    guard !Task.isCancelled else { return }
    previewTitle = LinkstrPostPreview.displayTitle(resolvedPreview?.title, for: previewAddress)
    guard mediaStrategy == .link,
      let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: resolvedPreview?.thumbnailPath)?.path
    else { return }
    let image = await ThumbnailImageCache.shared.loadImageAsync(at: path)
    guard !Task.isCancelled else { return }
    thumbnailImage = image
  }

  private func loadRemotePostText() async {
    remotePostText = nil
    guard let previewURL, mediaStrategy != .directVideo else { return }
    let text: String?
    if SocialPostResolutionService.supportsRemotePostText(for: previewURL) {
      text = await SocialPostResolutionService.resolveRemotePostText(for: previewURL)
    } else {
      text = await URLMetadataService.shared.fetchPageDescription(for: previewURL)
    }
    guard !Task.isCancelled else { return }
    remotePostText = LinkstrPostPreview.text(text)
  }
}
