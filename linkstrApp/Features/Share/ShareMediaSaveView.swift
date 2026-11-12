import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct ShareMediaSaveView: View {
  @Environment(\.openURL) private var openURL
  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler

  let draft: LinkstrDeepLinkCodec.MediaSaveDraft

  @State private var status: SaveStatus = .resolving
  @State private var resolutionAttempt = 0
  @State private var exportTarget: LocalMediaExportTarget?
  @State private var showingSaveDialog = false
  @State private var fileExportItem: LocalFileExportItem?

  private var sourceURL: URL? {
    LinkstrURLValidator.normalizedWebURL(from: draft.url).flatMap(URL.init(string:))
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrSheetTitle(title: "save video")

            LinkstrInsetSection {
              HStack(alignment: .top, spacing: LinkstrTheme.rowSpacing) {
                statusIndicator

                VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
                  Text(status.title)
                    .font(LinkstrTheme.font(.headline, weight: .semibold))
                    .foregroundStyle(LinkstrTheme.textPrimary)

                  if let message = status.message {
                    Text(message)
                      .font(LinkstrTheme.font(.subheadline))
                      .foregroundStyle(LinkstrTheme.textSecondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            if exportTarget != nil, !status.showsProgress {
              Button {
                if let exportTarget, FileManager.default.fileExists(atPath: exportTarget.fileURL.path) {
                  showingSaveDialog = true
                } else {
                  status = .resolving
                  resolutionAttempt += 1
                }
              } label: {
                LinkstrActionButtonLabel(title: "choose where to save", systemImage: "square.and.arrow.down")
              }
              .linkstrPrimaryButton()
            }
            if status.offersBrowserRecovery, let sourceURL {
              VStack(spacing: LinkstrTheme.compactSpacing) {
                if exportTarget == nil {
                  Button {
                    status = .resolving
                    resolutionAttempt += 1
                  } label: {
                    LinkstrActionButtonLabel(title: "try again", systemImage: "arrow.clockwise")
                  }
                  .linkstrPrimaryButton()
                }
                LinkstrBrowserButton { openURL(sourceURL) }
              }
            }

            LinkstrInsetSection(title: "original link") {
              LinkstrURLText(address: sourceURL?.absoluteString ?? draft.url)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .linkstrPageContentLayout()
        }
      }
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "close video save", icon: "xmark") {
            deepLinkHandler.clearMediaSaveDraft(matching: draft)
          }
        }
        .linkstrFlatToolbarItem()
      }
      .linkstrVideoSaveDialog(
        isPresented: $showingSaveDialog,
        target: exportTarget,
        onSaveToPhotos: { _ in status = .saving },
        onSaveToFiles: { fileExportItem = LocalFileExportItem(fileURL: $0, requestID: resolutionTaskID) }
      )
      #if canImport(UIKit)
        .sheet(item: $fileExportItem) { item in
          LocalFileExportSheet(url: item.fileURL) { result in
            guard deepLinkHandler.pendingMediaSaveDraft == draft, item.requestID == resolutionTaskID,
              fileExportItem == nil || fileExportItem?.id == item.id
            else { return }
            fileExportItem = nil
            switch result {
            case .exported:
              status = .saved("files")
              triggerSuccessHaptic()
              deepLinkHandler.clearMediaSaveDraft(matching: draft)
            case .cancelled:
              status = .ready
            case .failed:
              status = .failed("couldn’t save this video to files.")
            }
          }
        }
      #endif
    }
    .preferredColorScheme(.dark)
    .task(id: resolutionTaskID) {
      await resolveAndCache()
    }
    .task(id: status == .saving) {
      guard status == .saving, let exportTarget else { return }
      await performSaveToPhotos(exportTarget)
    }
  }

  private var resolutionTaskID: String { "\(draft.id)#\(resolutionAttempt)" }

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
    exportTarget = nil
    showingSaveDialog = false
    guard let sourceURL else {
      status = .unavailable("this share doesn’t contain a valid web link.")
      return
    }

    status = .resolving
    let extraction = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: sourceURL)
    guard !Task.isCancelled else { return }

    switch extraction {
    case .ready(let candidates) where !candidates.isEmpty:
      status = .caching
      if let localMedia = await cacheFirstAvailable(from: candidates) {
        guard !Task.isCancelled else { return }
        exportTarget = LocalMediaExportTarget(fileURL: localMedia.playbackURL)
        status = .ready
        showingSaveDialog = true
      } else {
        guard !Task.isCancelled else { return }
        status = .unavailable("couldn’t download this video. you can still open the original link.")
      }
    case .noVideo:
      status = .unavailable("no video found in this post.")
    case .ready, .cannotExtract:
      status = .unavailable("couldn’t find a downloadable video. you can still open the original link.")
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
  private func performSaveToPhotos(_ target: LocalMediaExportTarget) async {
    do {
      try await target.saveToPhotos()
      guard !Task.isCancelled, deepLinkHandler.pendingMediaSaveDraft == draft else { return }
      status = .saved("photos")
      triggerSuccessHaptic()
      deepLinkHandler.clearMediaSaveDraft(matching: draft)
    } catch {
      guard !Task.isCancelled, deepLinkHandler.pendingMediaSaveDraft == draft else { return }
      status = .failed(PhotoSaveError.message(for: error))
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
    case failed(String)

    var title: String {
      switch self {
      case .resolving:
        return "checking link"
      case .caching:
        return "preparing video"
      case .ready:
        return "ready to save"
      case .saving:
        return "saving"
      case .saved:
        return "saved"
      case .unavailable:
        return "save unavailable"
      case .failed:
        return "save failed"
      }
    }

    var message: String? {
      switch self {
      case .resolving:
        return "looking for a video to save."
      case .caching:
        return "downloading the video."
      case .ready, .saving:
        return nil
      case .saved(let destination):
        return "saved to \(destination)."
      case .unavailable(let reason), .failed(let reason):
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
      case .unavailable, .failed:
        return "exclamationmark.triangle.fill"
      }
    }

    var tint: Color {
      switch self {
      case .saved:
        return LinkstrTheme.statusSuccess
      case .unavailable, .failed:
        return LinkstrTheme.amber
      case .resolving, .caching, .ready, .saving:
        return LinkstrTheme.accent
      }
    }

    var showsProgress: Bool {
      switch self {
      case .resolving, .caching, .saving:
        return true
      case .ready, .saved, .unavailable, .failed:
        return false
      }
    }

    var offersBrowserRecovery: Bool {
      switch self {
      case .unavailable, .failed: true
      default: false
      }
    }
  }
}
