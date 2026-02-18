import SwiftUI

struct DeepLinkVideoView: View {
  let payload: LinkstrDeepLinkPayload

  @Environment(\.openURL) private var openURL

  private var mediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: payload.url)
  }

  private var sourceURL: URL? {
    URL(string: payload.url)
  }

  private var sharedAtDate: Date? {
    guard payload.timestamp > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(payload.timestamp))
  }

  private var mediaAspectRatio: CGFloat {
    guard let sourceURL else {
      return 16.0 / 9.0
    }
    return URLClassifier.preferredMediaAspectRatio(for: sourceURL, strategy: mediaStrategy)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        videoBlock

        sourceInfoBlock

        if let sourceURL, mediaStrategy != .link {
          Button {
            openURL(sourceURL)
          } label: {
            Text("Open Source in Safari")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrSecondaryButtonStyle())
        }
      }
      .padding(12)
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
          mediaStrategy: mediaStrategy,
          mediaAspectRatio: mediaAspectRatio,
          showOpenSourceButtonInEmbedMode: false,
          openSourceAction: nil
        )
      case .link:
        Button("Open in Safari") {
          openURL(sourceURL)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(LinkstrPrimaryButtonStyle())
      }
    } else {
      Text("Invalid video URL")
        .font(.footnote)
        .foregroundStyle(LinkstrTheme.textSecondary)
    }
  }

  private var sourceInfoBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let host = sourceURL?.host?.replacingOccurrences(of: "www.", with: "") {
        Text(host)
          .font(.subheadline)
          .foregroundStyle(LinkstrTheme.textPrimary)
      }

      Text(payload.url)
        .font(.footnote)
        .foregroundStyle(LinkstrTheme.textSecondary)
        .textSelection(.enabled)

      if let sharedAtDate {
        Text("Shared \(sharedAtDate.formatted(date: .abbreviated, time: .shortened))")
          .font(.footnote)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(LinkstrTheme.panel.opacity(0.92))
    )
  }
}
