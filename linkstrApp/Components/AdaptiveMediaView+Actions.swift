import Photos
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

enum MediaPresentationGeometry {
  static func aspectRatio(for presentationSize: CGSize) -> CGFloat? {
    let width = presentationSize.width
    let height = presentationSize.height
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
    let ratio = width / height
    return ratio.isFinite && ratio > 0 ? ratio : nil
  }
}

struct LocalMediaExportTarget {
  let fileURL: URL
  let allowsPhotoSave: Bool
}

struct LocalFileExportItem: Identifiable {
  let id = UUID()
  let fileURL: URL
}

// MARK: - AdaptiveMediaView Export & Overlay Helpers

extension AdaptiveMediaView {
  func saveToPhotos(_ fileURL: URL) {
    Task { @MainActor in
      let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
      switch status {
      case .authorized, .limited:
        break
      case .denied, .restricted:
        showExportFeedback(
          title: "photos access needed",
          message: "allow add-only photos access in settings to save videos to your gallery."
        )
        return
      case .notDetermined:
        showExportFeedback(title: "save failed", message: "couldn't determine photos permission.")
        return
      @unknown default:
        showExportFeedback(title: "save failed", message: "unexpected photos permission state.")
        return
      }

      do {
        try await withCheckedThrowingContinuation { continuation in
          PHPhotoLibrary.shared().performChanges(
            {
              let creationRequest = PHAssetCreationRequest.forAsset()
              creationRequest.addResource(with: .video, fileURL: fileURL, options: nil)
            },
            completionHandler: { success, error in
              if success {
                continuation.resume(returning: ())
              } else {
                continuation.resume(throwing: error ?? URLError(.cannotWriteToFile))
              }
            }
          )
        }
        showExportFeedback(title: "saved", message: "saved to photos.")
      } catch {
        showExportFeedback(title: "save failed", message: "couldn't save this video to photos.")
      }
    }
  }

  func showExportFeedback(title: String, message: String) {
    exportFeedbackTitle = title
    exportFeedbackMessage = message
  }
}

extension AdaptiveMediaView {
  var isShowingNativePlayer: Bool {
    !isResolvingPresentation && localPlaybackMode == .localPreferred && readyPlaybackMedia != nil
  }

  var saveVideoAction: (() -> Void)? {
    guard let media = cachedLocalMedia ?? readyPlaybackMedia,
      let fileURL = exportableLocalMediaURL(for: media) else { return nil }
    return {
      exportTarget = LocalMediaExportTarget(fileURL: fileURL, allowsPhotoSave: supportsPhotoSave(fileURL: fileURL))
    }
  }

  private var readyPlaybackMedia: PlayableMedia? {
    guard case .ready(let candidates) = extractionState else { return nil }
    return currentPlaybackCandidate(from: candidates)
  }

  func watchContentArea<Content: View>(@ViewBuilder content: @escaping (CGSize) -> Content) -> some View {
    GeometryReader { proxy in
      let top = watchInsets.top + 112
      let height = max(1, proxy.size.height - top - overlayHeight - 16)
      let size = CGSize(width: max(1, proxy.size.width - 32), height: height)
      content(size)
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity)
        .padding(.top, top)
    }
  }

  func retryEmbeddedPlayback() {
    embeddedLoadFailed = false
    isEmbeddedContentReady = false
    embeddedContentHeight = nil
  }

  func mediaStatus(
    _ title: String, message: String, isLoading: Bool,
    offersEmbed: Bool = false, offersRetry: Bool = false
  ) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        if isLoading {
          ProgressView().tint(LinkstrTheme.accent)
        } else {
          Image(systemName: "exclamationmark.triangle").font(.title2)
        }
        Text(title).font(LinkstrTheme.font(.headline))
        if !message.isEmpty {
          Text(message)
            .font(LinkstrTheme.font(.subheadline))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        if offersRetry {
          secondaryActionButton("retry embed", action: retryEmbeddedPlayback)
        }
        if offersEmbed { useEmbeddedButton }
        openInBrowserButton(action: openSourceAction)
      }
      .multilineTextAlignment(.center)
      .padding(20)
      .background(LinkstrTheme.panel, in: .rect(cornerRadius: 20))
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.center, for: .alignment)
    .foregroundStyle(LinkstrTheme.textPrimary)
  }

  func loadingIndicator(_ title: String) -> some View {
    VStack(spacing: 8) {
      ProgressView().tint(LinkstrTheme.accent)
      Text(title)
        .font(LinkstrTheme.font(.caption))
        .foregroundStyle(LinkstrTheme.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  func immersivePlaybackMenu(
    local: Bool, showsSystemPlayer: Bool = false
  ) -> some View {
    Menu {
      if local {
        Button("use official embed", systemImage: "rectangle.inset.filled") {
          cancelLocalCaching()
          localPlaybackMode = .embedPreferred
        }
      } else {
        Button("try extracted video", systemImage: "play.rectangle", action: tryLocalPlayback)
      }
      if showsSystemPlayer {
        Button("open system player", systemImage: "arrow.up.left.and.arrow.down.right") {
          isPresentingSystemPlayer = true
        }
      }
    } label: {
      Image(systemName: "slider.horizontal.3")
        .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.58), in: Circle())
    }
    .accessibilityLabel("playback options")
    .padding(.top, 62 + watchInsets.top)
    .padding(.trailing, 12)
  }
}

enum LocalFileExportResult {
  case exported
  case cancelled
  case failed(String)
}

#if canImport(UIKit)
  struct LocalFileExportSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (LocalFileExportResult) -> Void

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
      private let onComplete: (LocalFileExportResult) -> Void
      private var didComplete = false

      init(onComplete: @escaping (LocalFileExportResult) -> Void) {
        self.onComplete = onComplete
      }

      func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
      ) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(.exported)
      }

      func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(.cancelled)
      }
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      picker.delegate = context.coordinator
      picker.allowsMultipleSelection = false
      return picker
    }

    func updateUIViewController(
      _ uiViewController: UIDocumentPickerViewController,
      context: Context
    ) {}
  }
#endif
