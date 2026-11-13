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
  var allowsPhotoSave: Bool {
    guard fileURL.isFileURL,
      (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    else { return false }
    return ["mp4", "mov", "m4v"].contains(fileURL.pathExtension.lowercased())
  }

  @MainActor
  func saveToPhotos() async throws {
    try Task.checkCancellation()
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    try Task.checkCancellation()
    switch status {
    case .authorized, .limited:
      break
    case .denied, .restricted:
      throw PhotoSaveError.permissionRequired
    case .notDetermined:
      throw PhotoSaveError.permissionUnavailable
    @unknown default:
      throw PhotoSaveError.permissionUnavailable
    }

    try await PHPhotoLibrary.shared().performChanges {
      PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: fileURL, options: nil)
    }
  }
}

enum PhotoSaveError: LocalizedError {
  case permissionRequired
  case permissionUnavailable

  var errorDescription: String? {
    switch self {
    case .permissionRequired:
      "allow photos access in settings, or save to files."
    case .permissionUnavailable:
      "couldn’t check photos access. try saving to files."
    }
  }

  static func message(for error: Error) -> String {
    (error as? Self)?.errorDescription ?? "couldn’t save this video to photos. try saving to files."
  }
}

struct LocalFileExportItem: Identifiable {
  let id = UUID()
  let fileURL: URL
  let requestID: String
}

extension View {
  func linkstrVideoSaveDialog(
    isPresented: Binding<Bool>,
    target: LocalMediaExportTarget?,
    onSaveToPhotos: @escaping (LocalMediaExportTarget) -> Void,
    onSaveToFiles: @escaping (URL) -> Void
  ) -> some View {
    alert("save video", isPresented: isPresented, presenting: target) { target in
      if target.allowsPhotoSave {
        Button("save to photos") { onSaveToPhotos(target) }
      }
      Button("save to files") { onSaveToFiles(target.fileURL) }
      Button("cancel", role: .cancel) {}
    } message: { _ in
      Text("choose where to save this video.")
    }
  }
}

struct LocalMediaExportFeedback {
  let message: String
  var retryFileURL: URL?

  var title: String { retryFileURL == nil ? "saved" : "save failed" }
}

// MARK: - AdaptiveMediaView Export & Overlay Helpers

extension AdaptiveMediaView {
  func saveToPhotos(_ target: LocalMediaExportTarget) {
    guard photoSaveTask == nil else { return }
    photoSaveTask = Task { @MainActor in
      defer { if !Task.isCancelled { photoSaveTask = nil } }
      guard !Task.isCancelled else { return }
      do {
        try await target.saveToPhotos()
        guard !Task.isCancelled else { return }
        exportFeedback = LocalMediaExportFeedback(message: "saved to photos.")
      } catch {
        guard !Task.isCancelled else { return }
        exportFeedback = LocalMediaExportFeedback(
          message: PhotoSaveError.message(for: error), retryFileURL: target.fileURL
        )
      }
    }
  }

  func cancelPhotoSave() {
    photoSaveTask?.cancel()
    photoSaveTask = nil
  }

}

extension AdaptiveMediaView {
  var isShowingNativePlayer: Bool {
    !isResolvingPresentation && localPlaybackMode == .localPreferred && readyPlaybackMedia != nil
  }

  var reservesNativeControlsSpace: Bool {
    guard localPlaybackMode == .localPreferred else { return false }
    return isShowingNativePlayer || (extractionState == nil
      && (effectiveMediaStrategy == .directVideo || effectiveMediaStrategy.allowsLocalPlaybackToggle))
  }

  var saveVideoAction: (() -> Void)? {
    guard let media = cachedLocalMedia ?? readyPlaybackMedia,
      let fileURL = exportableLocalMediaURL(for: media) else { return nil }
    return {
      exportTarget = LocalMediaExportTarget(fileURL: fileURL)
    }
  }

  private var readyPlaybackMedia: PlayableMedia? {
    guard case .ready(let candidates) = extractionState else { return nil }
    return currentPlaybackCandidate(from: candidates)
  }

  func watchContentArea<Content: View>(
    edgeToEdge: Bool = false,
    @ViewBuilder content: @escaping (CGSize) -> Content
  ) -> some View {
    GeometryReader { proxy in
      let top = watchInsets.top + LinkstrTheme.compactSpacing
      let bottom = watchInsets.bottom + postControlsReservedHeight + LinkstrTheme.compactSpacing
      let height = max(1, proxy.size.height - top - bottom)
      let insetWidth = min(proxy.size.width, LinkstrTheme.readableContentMaxWidth)
        - LinkstrTheme.screenHorizontalPadding * 2
      let size = CGSize(width: max(1, edgeToEdge ? proxy.size.width : insetWidth), height: height)
      content(size)
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity)
        .padding(.top, top)
    }
  }

  func retryEmbeddedPlayback() {
    LinkstrPlaybackDiagnostics.logger.info("retrying official embed")
    resetEmbeddedPresentation()
    embeddedReloadID += 1
  }

  func resetEmbeddedPresentation() {
    embeddedLoadFailure = nil
    isEmbeddedContentReady = false
    hasRenderedEmbeddedPost = false
    embeddedContentHeight = nil
  }

  @ViewBuilder
  func mediaRecovery(_ title: String, retry: (() -> Void)?, offersLocalPlayback: Bool = false) -> some View {
    let recovery = VStack(spacing: LinkstrTheme.rowSpacing) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(LinkstrTheme.amber)
        .accessibilityHidden(true)
      Text(title)
        .font(LinkstrTheme.font(.headline))
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: LinkstrTheme.compactSpacing) {
        if let retry {
          secondaryActionButton("try again", systemImage: "arrow.clockwise", action: retry)
        }
        LinkstrBrowserButton(action: openSourceAction)
        if offersLocalPlayback { tryLocalPlaybackButton }
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: 320)
    .frame(maxWidth: .infinity)
    .padding(.vertical, LinkstrTheme.compactSpacing)
    .foregroundStyle(LinkstrTheme.textPrimary)

    if immersive {
      ScrollView { recovery }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
    } else {
      recovery
    }
  }

  func loadingIndicator(_ title: String) -> some View {
    let label = Text(title)
      .font(LinkstrTheme.font(.caption))
      .foregroundStyle(LinkstrTheme.textSecondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    return ViewThatFits(in: .vertical) {
      VStack(spacing: LinkstrTheme.compactSpacing) {
        ProgressView()
          .tint(LinkstrTheme.accent)
          .accessibilityHidden(true)
        label
      }
      label
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  func localPlaybackActions(exportFileURL: URL?, offersEmbed: Bool) -> some View {
    VStack(spacing: LinkstrTheme.compactSpacing) {
      if offersEmbed {
        secondaryActionButton(
          officialEmbedActionTitle, systemImage: "rectangle.inset.filled", action: useOfficialEmbed
        )
      }
      LinkstrBrowserButton(action: openSourceAction)
      if let exportFileURL {
        saveButton(for: exportFileURL)
      }
    }
  }

  var officialEmbedActionTitle: String { "use official embed" }

  var tryLocalPlaybackButton: some View {
    secondaryActionButton(localPlaybackActionTitle, systemImage: "play.rectangle", action: tryLocalPlayback)
  }

  var localPlaybackActionTitle: String {
    cachedLocalMedia?.isLocalFile == true ? "play downloaded video" : "try extracted video"
  }

  func saveButton(for fileURL: URL) -> some View {
    secondaryActionButton("save video", systemImage: "square.and.arrow.down") {
      exportTarget = LocalMediaExportTarget(fileURL: fileURL)
    }
  }

  func secondaryActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      LinkstrActionButtonLabel(title: title, systemImage: systemImage)
    }
    .frame(maxWidth: .infinity)
    .linkstrSecondaryButton()
  }

  func useOfficialEmbed() {
    LinkstrPlaybackDiagnostics.logger.info("switching to official embed")
    cancelLocalCaching()
    localPlaybackMode = .embedPreferred
  }

  func tryLocalPlayback() {
    LinkstrPlaybackDiagnostics.logger.info("retrying local playback")
    if case .cannotExtract = extractionState, cachedLocalMedia == nil {
      clearFailedLocalPlaybackState()
    }
    localPlaybackMode = .localPreferred
    localPlaybackRequestID += 1
    playbackCandidateIndex = 0
    resetEmbeddedPresentation()
    detectedMediaAspectRatio = nil
    extractionState = nil
  }

  func handlePlaybackFailure(currentMedia: PlayableMedia, candidates: [PlayableMedia]) {
    LinkstrPlaybackDiagnostics.logger.notice("playback candidate failed; cached file: \(currentMedia.isLocalFile)")
    if !currentMedia.isLocalFile, let cachedLocalMedia, cachedLocalMedia.isLocalFile {
      LinkstrPlaybackDiagnostics.logger.info("stream failed; trying downloaded copy")
      cancelLocalCaching()
      playbackCandidateIndex = 0
      useCachedMedia(cachedLocalMedia)
      return
    }

    if currentMedia.isLocalFile || cachedLocalMedia != nil {
      clearFailedLocalPlaybackState()
    } else {
      cancelLocalCaching()
    }

    if currentMedia.isLocalFile {
      tryLocalPlayback()
      return
    }

    advancePlaybackCandidate(candidates: candidates)
  }

}

enum LocalFileExportResult {
  case exported
  case cancelled
  case failed
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
        onComplete(urls.isEmpty ? .failed : .exported)
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
