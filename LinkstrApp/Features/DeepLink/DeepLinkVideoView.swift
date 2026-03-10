import SwiftUI

struct DeepLinkVideoView: View {
  let payload: LinkstrDeepLinkPayload

  @Environment(\.openURL) private var openURL

  private var mediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: normalizedURLString)
  }

  private var sourceURL: URL? {
    guard let normalizedURLString else { return nil }
    return URL(string: normalizedURLString)
  }

  private var normalizedURLString: String? {
    LinkstrURLValidator.normalizedWebURL(from: payload.url)
  }

  private var sharedAtDate: Date? {
    guard payload.timestamp > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(payload.timestamp))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
        videoBlock
        sourceInfoBlock
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
    }
    .background(LinkstrBackgroundView())
  }

  @ViewBuilder
  private var videoBlock: some View {
    if let sourceURL {
      switch mediaStrategy {
      case .extractionPreferred, .embedOnly:
        AdaptiveVideoPlaybackView(
          sourceURL: sourceURL,
          showOpenSourceButtonInEmbedMode: true,
          openSourceAction: { openURL(sourceURL) }
        )
      case .link:
        Button("open in browser") {
          openURL(sourceURL)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.accent)
      }
    } else {
      LinkstrInsetSection(title: "unavailable") {
        Text("invalid video link")
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
  }

  private var sourceInfoBlock: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      if let host = normalizedDisplayHost {
        Text(host)
          .font(LinkstrTheme.body(14, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
      }

      Text(normalizedURLString ?? payload.url)
        .font(LinkstrTheme.body(12))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .textSelection(.enabled)

      if let sharedAtDate {
        Text("shared \(sharedAtDate.formatted(date: .abbreviated, time: .shortened))")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .linkstrSurfaceCard()
  }

  private var normalizedDisplayHost: String? {
    guard let host = sourceURL?.host?.lowercased() else { return nil }
    if host.hasPrefix("www.") {
      return String(host.dropFirst(4))
    }
    if host.hasPrefix("m.") {
      return String(host.dropFirst(2))
    }
    return host
  }
}
