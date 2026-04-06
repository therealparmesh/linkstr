import AVFoundation
import AVKit
import Photos
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct InlineVideoPlayer: View {
  let media: PlayableMedia
  var onPlaybackFailed: (() -> Void)?
  @State private var player: AVPlayer?
  @State private var isShowingFullscreenPlayer = false
  @State private var statusObservation: NSKeyValueObservation?

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
    .task(id: media.playbackURL) {
      statusObservation?.invalidate()
      statusObservation = nil
      player?.pause()

      let item: AVPlayerItem
      if media.headers.isEmpty {
        item = AVPlayerItem(url: media.playbackURL)
      } else {
        let asset = AVURLAsset(
          url: media.playbackURL, options: ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
        item = AVPlayerItem(asset: asset)
      }
      statusObservation = item.observe(\.status, options: [.new]) { observed, _ in
        if observed.status == .failed {
          Task { @MainActor in onPlaybackFailed?() }
        }
      }
      player = AVPlayer(playerItem: item)
    }
    .onDisappear {
      player?.pause()
      player = nil
      statusObservation?.invalidate()
      statusObservation = nil
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
  let clearPersistedLocalMedia: (() -> Void)?

  @State private var canonicalSourceURL: URL?
  @State private var preferredEmbedSource: EmbeddedWebSource?
  @State private var resolvedMediaStrategy: URLClassifier.MediaStrategy?
  @State private var isResolvingPresentation = false
  @State private var extractionState: ExtractionState?
  @State private var cachedLocalMedia: PlayableMedia?
  @State private var localCacheTask: Task<Void, Never>?
  @State private var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State private var playbackCandidateIndex = 0
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
    persistLocalMedia: ((URL, PlayableMedia) -> Void)? = nil,
    clearPersistedLocalMedia: (() -> Void)? = nil
  ) {
    self.sourceURL = sourceURL
    self.showOpenSourceButtonInEmbedMode = showOpenSourceButtonInEmbedMode
    self.openSourceAction = openSourceAction
    self.resolveCachedLocalMedia = resolveCachedLocalMedia
    self.persistLocalMedia = persistLocalMedia
    self.clearPersistedLocalMedia = clearPersistedLocalMedia
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
        let isTwitter = SocialURLHeuristics.isTwitterStatusURL(canonical)
        let isRumble = URLClassifier.classify(canonical) == .rumble
        isResolvingPresentation = isTwitter || isRumble
        if isTwitter {
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
        playbackCandidateIndex = 0
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
            LinkstrActionButtonLabel(title: "open in browser")
          }
          .frame(maxWidth: .infinity)
          .linkstrSecondaryButton()
        } else {
          EmptyView()
        }
      }
    }
  }

  @ViewBuilder
  private func extractionPlaybackBlock(embedSource: EmbeddedWebSource) -> some View {
    switch extractionState {
    case .ready(let candidates):
      if let media = currentPlaybackCandidate(from: candidates) {
        let exportFileURL = exportableLocalMediaURL(for: cachedLocalMedia ?? media)
        VStack(alignment: .leading, spacing: 8) {
          mediaSurface {
            InlineVideoPlayer(
              media: media,
              onPlaybackFailed: {
                handlePlaybackFailure(currentMedia: media, candidates: candidates)
              })
          }
          extractionReadyActions(exportFileURL: exportFileURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        embedPlaybackBlock(embedSource: embedSource, allowsTryLocalPlayback: true)
      }

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
          openInBrowserButton(action: openSourceAction)
        }
      } else if allowsTryLocalPlayback {
        retryLocalPlaybackButton
      } else if canOpenSource, let openSourceAction {
        openInBrowserButton(action: openSourceAction)
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
          openInBrowserButton(action: openSourceAction)
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

  private func openInBrowserButton(action: @escaping () -> Void) -> some View {
    secondaryActionButton("open in browser") {
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
      LinkstrActionButtonLabel(title: title)
    }
    .frame(maxWidth: .infinity)
    .linkstrSecondaryButton()
  }

  private func retryLocalPlayback() {
    Task {
      if extractionFallbackReason != nil {
        clearFailedLocalPlaybackState()
      }
      localPlaybackMode = .localPreferred
      playbackCandidateIndex = 0
      embeddedContentHeight = nil
      isEmbeddedContentReady = false
      extractionState = nil
      extractionFallbackReason = nil
      await prepareMediaIfNeeded()
    }
  }

  private func handlePlaybackFailure(currentMedia: PlayableMedia, candidates: [PlayableMedia]) {
    if currentMedia.isLocalFile {
      clearFailedLocalPlaybackState()
      retryLocalPlayback()
      return
    }

    advancePlaybackCandidate(candidates: candidates)
  }

  private func currentPlaybackCandidate(from candidates: [PlayableMedia]) -> PlayableMedia? {
    guard playbackCandidateIndex < candidates.count else { return nil }
    return candidates[playbackCandidateIndex]
  }

  private func advancePlaybackCandidate(candidates: [PlayableMedia]) {
    let nextIndex = playbackCandidateIndex + 1
    if nextIndex < candidates.count {
      playbackCandidateIndex = nextIndex
      let newMedia = candidates[nextIndex]
      if !newMedia.isLocalFile {
        scheduleLocalCachingIfNeeded(sourceURL: effectiveSourceURL, media: newMedia)
      }
    } else {
      extractionFallbackReason = "none of the extracted video streams were playable."
      localPlaybackMode = .embedPreferred
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
    .background(LinkstrTheme.panelMuted)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func prepareMediaIfNeeded() async {
    guard !isResolvingPresentation else { return }
    guard effectiveMediaStrategy.allowsLocalPlaybackToggle else { return }
    guard localPlaybackMode == .localPreferred else { return }

    let playbackSourceURL = effectiveSourceURL

    if let cached = resolveCachedLocalMedia?(playbackSourceURL) {
      if cached.isLocalFile {
        Task {
          await VideoCacheService.shared.touchCachedMedia(at: cached.playbackURL)
        }
      }
      cachedLocalMedia = cached
      extractionState = .ready([cached])
      extractionFallbackReason = nil
      return
    }

    if let cachedLocalMedia {
      extractionState = .ready([cachedLocalMedia])
      extractionFallbackReason = nil
      return
    }

    let result = await SocialVideoExtractionService.shared.extractPlayableMedia(
      from: playbackSourceURL)
    playbackCandidateIndex = 0
    extractionState = result

    switch result {
    case .ready(let candidates):
      extractionFallbackReason = nil
      if let media = candidates.first {
        if media.isLocalFile {
          Task {
            await VideoCacheService.shared.touchCachedMedia(at: media.playbackURL)
          }
          cachedLocalMedia = media
          persistLocalMedia?(playbackSourceURL, media)
        } else {
          scheduleLocalCachingIfNeeded(sourceURL: playbackSourceURL, media: media)
        }
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

  private func clearFailedLocalPlaybackState() {
    localCacheTask?.cancel()
    localCacheTask = nil

    if clearPersistedLocalMedia == nil,
      let cachedLocalMedia,
      cachedLocalMedia.isLocalFile
    {
      try? FileManager.default.removeItem(at: cachedLocalMedia.playbackURL)
    }

    cachedLocalMedia = nil
    clearPersistedLocalMedia?()
  }

  private var effectiveSourceURL: URL {
    canonicalSourceURL ?? sourceURL
  }

  private func resolvedOrFallbackEmbedSource(_ fallback: URL) -> EmbeddedWebSource {
    if let preferredEmbedSource {
      return preferredEmbedSource
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
