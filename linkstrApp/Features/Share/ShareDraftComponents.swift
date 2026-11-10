import SwiftUI
import UIKit

struct LinkstrDraftPreview: View {
  let url: String
  let loadsRichPreview: Bool
  @State private var title: String?
  @State private var image: UIImage?

  private var mediaStrategy: URLClassifier.MediaStrategy { URLClassifier.mediaStrategy(for: url) }

  static func availabilityHint(for strategy: URLClassifier.MediaStrategy) -> String? {
    switch strategy {
    case .extractionPreferred: "in-app playback and saving when available"
    case .embedOnly: "in-app playback when available"
    case .link: nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let image {
        Rectangle()
          .fill(LinkstrTheme.panelElevated)
          .overlay { Image(uiImage: image).resizable().scaledToFill() }
          .frame(height: 142)
          .clipped()
          .accessibilityHidden(true)
      }

      HStack(spacing: 10) {
        Image(systemName: mediaStrategy == .link ? "link" : "play.rectangle")
          .font(LinkstrTheme.font(.title3))
          .foregroundStyle(LinkstrTheme.accent)
          .frame(width: 38, height: 38)
          .background(LinkstrTheme.panelElevated, in: .rect(cornerRadius: 10))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text(title ?? LinkstrPostPreview.source(for: url) ?? "shared link")
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(2)
          if let title, let source = LinkstrPostPreview.source(for: url), title != source {
            Text(source)
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
          if let hint = Self.availabilityHint(for: mediaStrategy) {
            Text(hint)
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(10)
    }
    .background(LinkstrTheme.panel)
    .clipShape(.rect(cornerRadius: 14))
    .task(id: url) {
      title = nil
      image = nil
    }
    .task(id: loadsRichPreview ? url : nil) {
      guard loadsRichPreview else { return }
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      guard let preview = await URLMetadataService.shared.fetchPreview(for: url), !Task.isCancelled else { return }
      title = LinkstrPostPreview.text(preview.title)
      if title == url { title = nil }
      if let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: preview.thumbnailPath)?.path {
        let loaded = await ThumbnailImageCache.shared.loadImageAsync(at: path)
        guard !Task.isCancelled else { return }
        image = loaded
      }
    }
  }
}

struct LinkstrShareFooter: View {
  let status: LinkstrSheetFooterStatus?
  let canSend: Bool
  let isSending: Bool
  let send: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      if let status {
        Text(status.message)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(status.color)
          .multilineTextAlignment(.center)
      }

      Button(action: send) {
        HStack(spacing: 9) {
          if isSending {
            ProgressView().tint(LinkstrTheme.background)
          }
          Text(isSending ? "sharing link…" : "share to session")
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      }
      .linkstrPrimaryButton()
      .disabled(!canSend)
    }
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .padding(.vertical, 10)
    .linkstrReadableContent()
    .background(LinkstrTheme.background)
    .overlay(alignment: .top) { LinkstrListRowDivider(leadingInset: 0) }
  }
}
