import SwiftUI
import UIKit

struct DeepLinkDetailView: View {
  let sourceURL: URL

  @Environment(\.openURL) private var openURL
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var previewTitle: String?
  @State private var remotePostText: String?
  @State private var thumbnailImage: UIImage?
  @State private var embeddedPostURL: URL?
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
        LinkstrSheetTitle(title: "shared link")

        if isRegularLink {
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
            onEmbeddedPostVisibilityChange: { embeddedPostURL = $0 ? sourceURL : nil }
          )
        }
        linkDetails(showsArtwork: isRegularLink)
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
      .linkstrReadableContent()
    }
    .background(LinkstrBackgroundView())
    .navigationBarTitleDisplayMode(.inline)
    .task(id: previewURL) { await loadPreviewIfNeeded() }
    .task(id: previewURL) { await loadRemotePostText() }
  }

  private func linkDetails(showsArtwork: Bool) -> some View {
    let showsPreviewText = embeddedPostURL != sourceURL || dynamicTypeSize.isAccessibilitySize
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

      if showsPreviewText, let remotePostText {
        Text(remotePostText)
          .font(LinkstrTheme.font(.body))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      if showsPreviewText, let previewTitle, previewTitle != remotePostText {
        Text(previewTitle)
          .font(LinkstrTheme.font(remotePostText == nil ? .title2 : .caption, weight: .semibold))
          .foregroundStyle(remotePostText == nil ? LinkstrTheme.textPrimary : LinkstrTheme.textSecondary)
          .accessibilityAddTraits(remotePostText == nil ? .isHeader : [])
      }

      LinkstrURLText(address: sourceURL.absoluteString)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(LinkstrTheme.panelPadding)
    .linkstrCardSurface()
  }

  private func loadPreviewIfNeeded() async {
    previewTitle = nil
    thumbnailImage = nil

    guard let previewURL else { return }
    let previewAddress = previewURL.absoluteString

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
    guard let previewURL, SocialPostResolutionService.supportsRemotePostText(for: previewURL) else { return }
    let text = await SocialPostResolutionService.resolveRemotePostText(for: previewURL)
    guard !Task.isCancelled else { return }
    remotePostText = LinkstrPostPreview.text(text)
  }
}
