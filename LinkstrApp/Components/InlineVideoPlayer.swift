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
            .scopedPlaybackAudioSession()
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
          .font(LinkstrTheme.system(14, weight: .semibold))
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
          .scopedPlaybackAudioSession()
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

private struct ScopedPlaybackAudioSessionModifier: ViewModifier {
  @State private var hasAcquiredPlaybackAudioSession = false

  func body(content: Content) -> some View {
    content
      .onAppear {
        guard !hasAcquiredPlaybackAudioSession else { return }
        MediaAudioSessionController.shared.acquirePlayback()
        hasAcquiredPlaybackAudioSession = true
      }
      .onDisappear {
        guard hasAcquiredPlaybackAudioSession else { return }
        MediaAudioSessionController.shared.releasePlayback()
        hasAcquiredPlaybackAudioSession = false
      }
  }
}

extension View {
  fileprivate func scopedPlaybackAudioSession() -> some View {
    modifier(ScopedPlaybackAudioSessionModifier())
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
  @State private var preferredEmbedSource: EmbeddedWebSource?
  @State private var resolvedMediaStrategy: URLClassifier.MediaStrategy?
  @State private var isResolvingPresentation = false
  @State private var extractionState: ExtractionState?
  @State private var cachedLocalMedia: PlayableMedia?
  @State private var localCacheTask: Task<Void, Never>?
  @State private var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State private var extractionFallbackReason: String?
  @State private var exportTarget: LocalMediaExportTarget?
  @State private var fileExportItem: LocalFileExportItem?
  @State private var exportFeedbackTitle = ""
  @State private var exportFeedbackMessage: String?
  @State private var embeddedContentHeight: CGFloat?
  @State private var isEmbeddedContentReady = false

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
        localCacheTask?.cancel()
        localCacheTask = nil
        cachedLocalMedia = nil
        preferredEmbedSource = nil
        resolvedMediaStrategy = nil
        let canonical = await URLCanonicalizationService.shared.canonicalPlaybackURL(for: sourceURL)
        canonicalSourceURL = canonical
        isResolvingPresentation = SocialURLHeuristics.isTwitterStatusURL(canonical)
        if isResolvingPresentation {
          let twitterPresentation =
            await TwitterStatusResolutionService.shared.resolvedPresentation(for: canonical)
          resolvedMediaStrategy = twitterPresentation?.strategy ?? .link
          if let document = twitterPresentation?.embedHTMLDocument {
            preferredEmbedSource = .html(
              document: document,
              baseURL: URL(string: "https://publish.twitter.com")
            )
          }
        }
        if preferredEmbedSource == nil,
          let preferredEmbedURL = await URLCanonicalizationService.shared.preferredEmbedURL(
            for: canonical)
        {
          preferredEmbedSource = .url(preferredEmbedURL)
        }
        isResolvingPresentation = false
        embeddedContentHeight = nil
        isEmbeddedContentReady = false
        extractionState = nil
        extractionFallbackReason = nil
        localPlaybackMode = .localPreferred
        await prepareMediaIfNeeded()
      }
      .alert(
        "save local media",
        isPresented: Binding(
          get: { exportTarget != nil },
          set: { isPresented in
            if !isPresented {
              exportTarget = nil
            }
          }
        ),
        presenting: exportTarget
      ) { target in
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
        Button("cancel", role: .cancel) {
          exportTarget = nil
        }
      } message: { _ in
        Text("choose where to save this video.")
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
      .onDisappear {
        localCacheTask?.cancel()
        localCacheTask = nil
      }
  }

  @ViewBuilder
  private var content: some View {
    if isResolvingPresentation {
      mediaSurface {
        VStack(spacing: 8) {
          ProgressView()
          Text("loading post...")
            .font(LinkstrTheme.body(12))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    } else {
      switch effectiveMediaStrategy {
      case .extractionPreferred(let embedURL):
        let resolvedEmbedSource = resolvedOrFallbackEmbedSource(embedURL)
        if localPlaybackMode == .embedPreferred {
          embedPlaybackBlock(embedSource: resolvedEmbedSource, allowsTryLocalPlayback: true)
        } else {
          extractionPlaybackBlock(embedSource: resolvedEmbedSource)
        }
      case .embedOnly(let embedURL):
        embedPlaybackBlock(
          embedSource: resolvedOrFallbackEmbedSource(embedURL), allowsTryLocalPlayback: false)
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
  }

  @ViewBuilder
  private func extractionPlaybackBlock(embedSource: EmbeddedWebSource) -> some View {
    switch extractionState {
    case .ready(let media):
      let exportFileURL = exportableLocalMediaURL(for: cachedLocalMedia ?? media)
      VStack(alignment: .leading, spacing: 8) {
        mediaSurface {
          InlineVideoPlayer(media: media)
        }
        extractionReadyActions(exportFileURL: exportFileURL)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

    case .cannotExtract:
      embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)

    case nil:
      mediaSurface {
        VStack(spacing: 8) {
          ProgressView()
          Text("preparing video playback...")
            .font(LinkstrTheme.body(12))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
  }

  private func embedPlaybackBlock(
    embedSource: EmbeddedWebSource,
    allowsTryLocalPlayback: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      mediaSurface(explicitHeight: embedSurfaceHeight(for: embedSource)) {
        ZStack {
          EmbeddedWebView(
            source: embedSource,
            onIntrinsicHeightChange: { height in
              guard embedSource.usesManagedHTMLDocument else { return }
              embeddedContentHeight = normalizedEmbedHeight(height)
            },
            onContentReadyChange: { isReady in
              guard embedSource.usesManagedHTMLDocument else { return }
              isEmbeddedContentReady = isReady
            }
          )
          .scopedPlaybackAudioSession()
          .opacity(shouldDeferEmbedReveal(for: embedSource) && !isEmbeddedContentReady ? 0 : 1)

          if shouldDeferEmbedReveal(for: embedSource) && !isEmbeddedContentReady {
            VStack(spacing: 8) {
              ProgressView()
              Text("loading post...")
                .font(LinkstrTheme.body(12))
                .foregroundStyle(LinkstrTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
          }
        }
      }

      if let extractionFallbackReason {
        Text("video playback unavailable: \(extractionFallbackReason)")
          .font(LinkstrTheme.body(12))
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
      embeddedContentHeight = nil
      isEmbeddedContentReady = false
      extractionState = nil
      extractionFallbackReason = nil
      await prepareMediaIfNeeded()
    }
  }

  private func mediaSurface<Content: View>(
    explicitHeight: CGFloat? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Group {
      if let explicitHeight {
        content()
          .frame(maxWidth: .infinity)
          .frame(height: explicitHeight)
      } else {
        content()
          .frame(maxWidth: .infinity)
          .aspectRatio(effectiveMediaAspectRatio, contentMode: .fit)
      }
    }
    .background(LinkstrTheme.panelSoft)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func prepareMediaIfNeeded() async {
    guard !isResolvingPresentation else { return }
    guard effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cached = resolveCachedLocalMedia?(playbackSourceURL) {
      cachedLocalMedia = cached
      extractionState = .ready(cached)
      extractionFallbackReason = nil
      return
    }

    if let cachedLocalMedia {
      extractionState = .ready(cachedLocalMedia)
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
        cachedLocalMedia = media
        persistLocalMedia?(playbackSourceURL, media)
      } else {
        scheduleLocalCachingIfNeeded(sourceURL: playbackSourceURL, media: media)
      }
    case .cannotExtract(let reason):
      extractionFallbackReason = reason
      localPlaybackMode = .embedPreferred
    }
  }

  private func scheduleLocalCachingIfNeeded(sourceURL: URL, media: PlayableMedia) {
    guard !media.isLocalFile else { return }
    guard cachedLocalMedia == nil else { return }

    localCacheTask?.cancel()
    localCacheTask = Task {
      guard
        let localMedia = await SocialVideoExtractionService.shared.cachePlayableMediaLocally(media)
      else { return }
      guard !Task.isCancelled else { return }

      await MainActor.run {
        cachedLocalMedia = localMedia
        persistLocalMedia?(sourceURL, localMedia)
      }
    }
  }

  private var effectiveSourceURL: URL {
    canonicalSourceURL ?? sourceURL
  }

  private func resolvedOrFallbackEmbedSource(_ fallback: URL) -> EmbeddedWebSource {
    if let preferredEmbedSource {
      return preferredEmbedSource
    }

    if URLClassifier.classify(effectiveSourceURL) == .rumble {
      return .url(effectiveSourceURL)
    }

    return .url(fallback)
  }

  private func shouldDeferEmbedReveal(for embedSource: EmbeddedWebSource) -> Bool {
    embedSource.usesManagedHTMLDocument
  }

  private func embedSurfaceHeight(for embedSource: EmbeddedWebSource) -> CGFloat? {
    guard embedSource.usesManagedHTMLDocument else { return nil }
    return embeddedContentHeight
  }

  private func normalizedEmbedHeight(_ height: CGFloat) -> CGFloat {
    guard height.isFinite else { return 220 }
    return max(height.rounded(.up), 220)
  }

  private var effectiveMediaStrategy: URLClassifier.MediaStrategy {
    resolvedMediaStrategy ?? URLClassifier.mediaStrategy(for: effectiveSourceURL)
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
