import Photos
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct ShareMediaSaveView: View {
  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler

  let draft: LinkstrDeepLinkCodec.MediaSaveDraft

  @State private var status: SaveStatus = .resolving
  @State private var cachedFileURL: URL?
  @State private var showingSaveDialog = false
  @State private var fileExportItem: LocalFileExportItem?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrScreenTitle(title: "save media")

            LinkstrInsetSection(title: "link") {
              Text(draft.url)
                .font(LinkstrTheme.font(.footnote))
                .foregroundStyle(LinkstrTheme.textPrimary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            LinkstrInsetSection(title: "status") {
              HStack(alignment: .top, spacing: LinkstrTheme.rowSpacing) {
                statusIndicator

                VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
                  Text(status.title)
                    .font(LinkstrTheme.font(.headline, weight: .semibold))
                    .foregroundStyle(LinkstrTheme.textPrimary)

                  Text(status.message)
                    .font(LinkstrTheme.font(.footnote))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
          .linkstrReadableContent()
        }
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            deepLinkHandler.clearMediaSaveDraft()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("close media save")
          .tint(LinkstrTheme.textSecondary)
        }
      }
      .alert(
        "save media",
        isPresented: $showingSaveDialog
      ) {
        Button("save to photos") {
          Task { await performSaveToPhotos() }
        }
        Button("save to files") {
          guard let url = cachedFileURL else { return }
          fileExportItem = LocalFileExportItem(fileURL: url)
        }
        Button("cancel", role: .cancel) {}
      } message: {
        Text("choose where to save this video")
      }
      #if canImport(UIKit)
        .sheet(item: $fileExportItem) { item in
          LocalFileExportSheet(url: item.fileURL) { result in
            fileExportItem = nil
            switch result {
            case .exported:
              status = .saved("files")
              triggerSuccessHaptic()
              deepLinkHandler.clearMediaSaveDraft()
            case .cancelled:
              status = .ready
            case .failed:
              status = .unavailable("could not save to files")
            }
          }
        }
      #endif
    }
    .preferredColorScheme(.dark)
    .task(id: draft.id) {
      await resolveAndCache()
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    ZStack {
      Circle()
        .fill(LinkstrTheme.panelElevated)
        .frame(width: 42, height: 42)

      if status.showsProgress {
        ProgressView()
          .tint(status.tint)
      } else {
        Image(systemName: status.systemImage)
          .font(LinkstrTheme.font(.title3, weight: .semibold))
          .foregroundStyle(status.tint)
      }
    }
    .accessibilityHidden(true)
  }

  @MainActor
  private func resolveAndCache() async {
    guard let sourceURL = URL(string: draft.url),
      LinkstrURLValidator.normalizedWebURL(from: draft.url) != nil
    else {
      status = .unavailable("this share does not contain a valid web link")
      return
    }

    status = .resolving
    let extraction = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: sourceURL)
    guard !Task.isCancelled else { return }

    switch extraction {
    case .ready(let candidates):
      guard !candidates.isEmpty else {
        status = .unavailable("could not find saveable media for this link")
        return
      }

      status = .caching
      if let localMedia = await cacheFirstAvailable(from: candidates) {
        guard !Task.isCancelled else { return }
        cachedFileURL = localMedia.playbackURL
        status = .ready
        showingSaveDialog = true
      } else {
        guard !Task.isCancelled else { return }
        status = .unavailable("could not prepare media for saving")
      }
    case .cannotExtract(let reason):
      status = .unavailable(reason)
    }
  }

  private func cacheFirstAvailable(
    from candidates: [PlayableMedia]
  ) async -> PlayableMedia? {
    let service = SocialVideoExtractionService.shared
    for candidate in candidates {
      guard !Task.isCancelled else { return nil }
      guard await candidate.loadVideoAsset() != nil else { continue }
      if let local = await service.cachePlayableMediaLocally(candidate) {
        return local
      }
    }
    return nil
  }

  @MainActor
  private func performSaveToPhotos() async {
    guard let fileURL = cachedFileURL else {
      status = .unavailable("no cached file available")
      return
    }

    status = .saving
    let authStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard authStatus == .authorized || authStatus == .limited else {
      status = .unavailable(
        "photos access needed — allow add-only photos access in settings.")
      return
    }

    do {
      try await withCheckedThrowingContinuation { continuation in
        PHPhotoLibrary.shared().performChanges(
          {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: fileURL, options: nil)
          },
          completionHandler: { success, error in
            if success {
              continuation.resume(returning: ())
            } else {
              continuation.resume(
                throwing: error ?? URLError(.cannotWriteToFile))
            }
          }
        )
      }
      status = .saved("photos")
      triggerSuccessHaptic()
      deepLinkHandler.clearMediaSaveDraft()
    } catch {
      status = .unavailable("could not save to photos")
    }
  }

  private func triggerSuccessHaptic() {
    #if canImport(UIKit)
      let haptic = UINotificationFeedbackGenerator()
      haptic.prepare()
      haptic.notificationOccurred(.success)
    #endif
  }
}

// MARK: - Status

extension ShareMediaSaveView {
  private enum SaveStatus: Equatable {
    case resolving
    case caching
    case ready
    case saving
    case saved(String)
    case unavailable(String)

    var title: String {
      switch self {
      case .resolving:
        return "checking link"
      case .caching:
        return "preparing media"
      case .ready:
        return "ready to save"
      case .saving:
        return "saving"
      case .saved:
        return "saved"
      case .unavailable:
        return "save unavailable"
      }
    }

    var message: String {
      switch self {
      case .resolving:
        return "looking for saveable media"
      case .caching:
        return "downloading media"
      case .ready:
        return "choose where to save"
      case .saving:
        return "saving now"
      case .saved(let destination):
        return "saved to \(destination)"
      case .unavailable(let reason):
        return reason
      }
    }

    var systemImage: String {
      switch self {
      case .resolving, .caching:
        return "magnifyingglass"
      case .ready, .saving:
        return "arrow.down.circle"
      case .saved:
        return "checkmark.circle.fill"
      case .unavailable:
        return "exclamationmark.triangle.fill"
      }
    }

    var tint: Color {
      switch self {
      case .saved:
        return LinkstrTheme.statusSuccess
      case .unavailable:
        return LinkstrTheme.amber
      case .resolving, .caching, .ready, .saving:
        return LinkstrTheme.accent
      }
    }

    var showsProgress: Bool {
      switch self {
      case .resolving, .caching, .saving:
        return true
      case .ready, .saved, .unavailable:
        return false
      }
    }
  }
}
