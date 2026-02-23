import AVFoundation
import AVKit
import Photos
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct InlineVideoPlayer: View {
  let media: PlayableMedia
  @State private var player: AVPlayer?
  @State private var isShowingFullscreenPlayer = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let player {
          VideoPlayer(player: player)
            .onAppear { player.play() }
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

      Button {
        isShowingFullscreenPlayer = true
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .padding(8)
          .background(
            Circle()
              .fill(LinkstrTheme.panel.opacity(0.84))
          )
      }
      .padding(8)
    }
    .fullScreenCover(isPresented: $isShowingFullscreenPlayer) {
      if let player {
        FullScreenAVPlayerView(player: player)
          .ignoresSafeArea()
          .background(Color.black)
      }
    }
    .task {
      let item: AVPlayerItem
      if media.headers.isEmpty {
        item = AVPlayerItem(url: media.playbackURL)
      } else {
        let asset = AVURLAsset(
          url: media.playbackURL, options: ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
        item = AVPlayerItem(asset: asset)
      }
      player = AVPlayer(playerItem: item)
    }
    .onDisappear {
      player?.pause()
    }
  }
}

private struct FullScreenAVPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.showsPlaybackControls = true
    controller.entersFullScreenWhenPlaybackBegins = true
    controller.exitsFullScreenWhenPlaybackEnds = false
    controller.player = player
    player.play()
    return controller
  }

  func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
    uiViewController.player = player
  }
}

struct AdaptiveVideoPlaybackView: View {
  private enum LocalPlaybackMode {
    case localPreferred
    case embedPreferred
  }

  let sourceURL: URL
  let showOpenSourceButtonInEmbedMode: Bool
  let openSourceAction: (() -> Void)?
  let resolveCachedLocalMedia: ((URL) -> PlayableMedia?)?
  let persistLocalMedia: ((URL, PlayableMedia) -> Void)?

  @State private var canonicalSourceURL: URL?
  @State private var preferredEmbedURL: URL?
  @State private var extractionState: ExtractionState?
  @State private var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State private var extractionFallbackReason: String?
  @State private var exportTarget: LocalMediaExportTarget?
  @State private var fileExportItem: LocalFileExportItem?
  @State private var exportFeedbackTitle = ""
  @State private var exportFeedbackMessage: String?

  init(
    sourceURL: URL,
    showOpenSourceButtonInEmbedMode: Bool = true,
    openSourceAction: (() -> Void)? = nil,
    resolveCachedLocalMedia: ((URL) -> PlayableMedia?)? = nil,
    persistLocalMedia: ((URL, PlayableMedia) -> Void)? = nil
  ) {
    self.sourceURL = sourceURL
    self.showOpenSourceButtonInEmbedMode = showOpenSourceButtonInEmbedMode
    self.openSourceAction = openSourceAction
    self.resolveCachedLocalMedia = resolveCachedLocalMedia
    self.persistLocalMedia = persistLocalMedia
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .task(id: sourceURL.absoluteString) {
        preferredEmbedURL = nil
        let canonical = await URLCanonicalizationService.shared.canonicalPlaybackURL(for: sourceURL)
        canonicalSourceURL = canonical
        preferredEmbedURL = await URLCanonicalizationService.shared.preferredEmbedURL(
          for: canonical)
        extractionState = nil
        extractionFallbackReason = nil
        localPlaybackMode = .localPreferred
        await prepareMediaIfNeeded()
      }
      .confirmationDialog(
        "save local media",
        isPresented: Binding(
          get: { exportTarget != nil },
          set: { isPresented in
            if !isPresented {
              exportTarget = nil
            }
          }
        ),
        titleVisibility: .visible
      ) {
        if let target = exportTarget {
          if target.allowsPhotoSave {
            Button("save to photos") {
              saveToPhotos(target.fileURL)
              exportTarget = nil
            }
          }
          Button("save to files") {
            fileExportItem = LocalFileExportItem(fileURL: target.fileURL)
            exportTarget = nil
          }
        }
        Button("cancel", role: .cancel) {
          exportTarget = nil
        }
      }
      .sheet(item: $fileExportItem) { item in
        LocalFileExportSheet(url: item.fileURL) { result in
          fileExportItem = nil
          switch result {
          case .exported:
            showExportFeedback(title: "saved", message: "saved to files.")
          case .cancelled:
            break
          case .failed(let message):
            showExportFeedback(title: "save failed", message: message)
          }
        }
      }
      .alert(
        exportFeedbackTitle,
        isPresented: Binding(
          get: { exportFeedbackMessage != nil },
          set: { isPresented in
            if !isPresented {
              exportFeedbackMessage = nil
            }
          }
        ),
        actions: {
          Button("ok", role: .cancel) {}
        },
        message: {
          Text(exportFeedbackMessage ?? "")
        }
      )
  }

  @ViewBuilder
  private var content: some View {
    switch effectiveMediaStrategy {
    case .extractionPreferred(let embedURL):
      let resolvedEmbedURL = resolvedOrFallbackEmbedURL(embedURL)
      if localPlaybackMode == .embedPreferred {
        embedPlaybackBlock(embedURL: resolvedEmbedURL, allowsTryLocalPlayback: true)
      } else {
        extractionPlaybackBlock(embedURL: resolvedEmbedURL)
      }
    case .embedOnly(let embedURL):
      embedPlaybackBlock(
        embedURL: resolvedOrFallbackEmbedURL(embedURL), allowsTryLocalPlayback: false)
    case .link:
      if let openSourceAction {
        Button {
          openSourceAction()
        } label: {
          Text("open in safari")
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderedProminent)
        .tint(LinkstrTheme.neonCyan)
      } else {
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private func extractionPlaybackBlock(embedURL: URL) -> some View {
    switch extractionState {
    case .ready(let media):
      let exportFileURL = exportableLocalMediaURL(for: media)
      VStack(alignment: .leading, spacing: 8) {
        mediaSurface {
          InlineVideoPlayer(media: media)
        }
        extractionReadyActions(exportFileURL: exportFileURL)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

    case .cannotExtract:
      embedPlaybackBlock(embedURL: embedURL, allowsTryLocalPlayback: true)

    case nil:
      mediaSurface {
        VStack(spacing: 8) {
          ProgressView()
          Text("preparing video playback...")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
  }

  private func embedPlaybackBlock(embedURL: URL, allowsTryLocalPlayback: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      mediaSurface {
        EmbeddedWebView(url: embedURL)
      }

      if let extractionFallbackReason {
        Text("video playback unavailable: \(extractionFallbackReason)")
          .font(.footnote)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      let canOpenSource = showOpenSourceButtonInEmbedMode && openSourceAction != nil

      if allowsTryLocalPlayback, canOpenSource, let openSourceAction {
        HStack(spacing: 8) {
          retryLocalPlaybackButton
          openInSafariButton(action: openSourceAction)
        }
      } else if allowsTryLocalPlayback {
        retryLocalPlaybackButton
      } else if canOpenSource, let openSourceAction {
        openInSafariButton(action: openSourceAction)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func extractionReadyActions(exportFileURL: URL?) -> some View {
    if let openSourceAction {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          useEmbeddedButton
          openInSafariButton(action: openSourceAction)
        }
        if let exportFileURL {
          saveButton(for: exportFileURL)
        }
      }
    } else if let exportFileURL {
      HStack(spacing: 8) {
        useEmbeddedButton
        saveButton(for: exportFileURL)
      }
    } else {
      useEmbeddedButton
    }
  }

  private var useEmbeddedButton: some View {
    secondaryActionButton("use embedded") {
      localPlaybackMode = .embedPreferred
    }
  }

  private var retryLocalPlaybackButton: some View {
    secondaryActionButton("try local playback") {
      retryLocalPlayback()
    }
  }

  private func openInSafariButton(action: @escaping () -> Void) -> some View {
    secondaryActionButton("open in safari") {
      action()
    }
  }

  private func saveButton(for fileURL: URL) -> some View {
    secondaryActionButton("save...") {
      exportTarget = LocalMediaExportTarget(
        fileURL: fileURL,
        allowsPhotoSave: supportsPhotoSave(fileURL: fileURL)
      )
    }
  }

  private func secondaryActionButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    .buttonStyle(.bordered)
    .tint(LinkstrTheme.textSecondary)
  }

  private func retryLocalPlayback() {
    Task {
      localPlaybackMode = .localPreferred
      extractionState = nil
      extractionFallbackReason = nil
      await prepareMediaIfNeeded()
    }
  }

  private func mediaSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity)
      .aspectRatio(effectiveMediaAspectRatio, contentMode: .fit)
      .background(LinkstrTheme.panelSoft)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func prepareMediaIfNeeded() async {
    guard effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cached = resolveCachedLocalMedia?(playbackSourceURL) {
      extractionState = .ready(cached)
      extractionFallbackReason = nil
      return
    }

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: playbackSourceURL)
    extractionState = result

    switch result {
    case .ready(let media):
      extractionFallbackReason = nil
      if media.isLocalFile {
        persistLocalMedia?(playbackSourceURL, media)
      }
    case .cannotExtract(let reason):
      extractionFallbackReason = reason
      localPlaybackMode = .embedPreferred
    }
  }

  private var effectiveSourceURL: URL {
    canonicalSourceURL ?? sourceURL
  }

  private func resolvedOrFallbackEmbedURL(_ fallback: URL) -> URL {
    if let preferredEmbedURL {
      return preferredEmbedURL
    }

    if URLClassifier.classify(effectiveSourceURL) == .rumble {
      return effectiveSourceURL
    }

    return fallback
  }

  private var effectiveMediaStrategy: URLClassifier.MediaStrategy {
    URLClassifier.mediaStrategy(for: effectiveSourceURL)
  }

  private var effectiveMediaAspectRatio: CGFloat {
    URLClassifier.preferredMediaAspectRatio(
      for: effectiveSourceURL, strategy: effectiveMediaStrategy)
  }

  private func exportableLocalMediaURL(for media: PlayableMedia) -> URL? {
    guard media.isLocalFile else { return nil }
    let fileURL = media.playbackURL
    guard fileURL.isFileURL else { return nil }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return fileURL
  }

  private func supportsPhotoSave(fileURL: URL) -> Bool {
    guard fileURL.isFileURL else { return false }
    let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    if isDirectory { return false }
    let ext = fileURL.pathExtension.lowercased()
    return ext == "mp4" || ext == "mov" || ext == "m4v"
  }

  private func saveToPhotos(_ fileURL: URL) {
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

  private func showExportFeedback(title: String, message: String) {
    exportFeedbackTitle = title
    exportFeedbackMessage = message
  }
}

private struct LocalMediaExportTarget {
  let fileURL: URL
  let allowsPhotoSave: Bool
}

private struct LocalFileExportItem: Identifiable {
  let id = UUID()
  let fileURL: URL
}

private enum LocalFileExportResult {
  case exported
  case cancelled
  case failed(String)
}

#if canImport(UIKit)
  private struct LocalFileExportSheet: UIViewControllerRepresentable {
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
