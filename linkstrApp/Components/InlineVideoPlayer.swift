import AVFoundation
import AVKit
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct InlineVideoPlayer: View {
  let media: PlayableMedia
  var onPlaybackReady: (() -> Void)?
  var onPlaybackFailed: (() -> Void)?
  var onAspectRatioChange: ((CGFloat) -> Void)?
  @State private var player: AVPlayer?
  @State private var isShowingFullscreenPlayer = false
  @State private var statusObservation: NSKeyValueObservation?
  @State private var presentationSizeObservation: NSKeyValueObservation?

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let player {
          VideoPlayer(player: player)
            .scopedPlaybackAudioSession()
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

      if player != nil {
        Button {
          isShowingFullscreenPlayer = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(LinkstrTheme.font(.footnote, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .frame(
              width: LinkstrTheme.minimumInteractiveDimension,
              height: LinkstrTheme.minimumInteractiveDimension)
            .background(Circle().fill(LinkstrTheme.panel.opacity(0.84)))
        }
        .accessibilityLabel("open video fullscreen")
        .padding(8)
      }
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
      presentationSizeObservation?.invalidate()
      presentationSizeObservation = nil
      player?.pause()
      player = nil

      let options = media.headers.isEmpty
        ? nil
        : ["AVURLAssetHTTPHeaderFieldsKey": media.headers]
      let asset = AVURLAsset(url: media.playbackURL, options: options)
      do {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !Task.isCancelled else { return }
        guard !videoTracks.isEmpty else {
          onPlaybackFailed?()
          return
        }
      } catch {
        guard !Task.isCancelled else { return }
        onPlaybackFailed?()
        return
      }
      onPlaybackReady?()

      let item = AVPlayerItem(asset: asset)
      statusObservation = item.observe(\.status, options: [.new]) { observed, _ in
        if observed.status == .failed {
          Task { @MainActor in onPlaybackFailed?() }
        }
      }
      presentationSizeObservation = item.observe(
        \.presentationSize,
        options: [.initial, .new]
      ) { observed, _ in
        guard let aspectRatio = MediaPresentationGeometry.aspectRatio(
          for: observed.presentationSize
        ) else { return }
        Task { @MainActor in onAspectRatioChange?(aspectRatio) }
      }
      let newPlayer = AVPlayer(playerItem: item)
      player = newPlayer
      newPlayer.play()
    }
    .onDisappear {
      guard !isShowingFullscreenPlayer else { return }
      player?.pause()
      player = nil
      statusObservation?.invalidate()
      statusObservation = nil
      presentationSizeObservation?.invalidate()
      presentationSizeObservation = nil
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
  func scopedPlaybackAudioSession() -> some View {
    modifier(ScopedPlaybackAudioSessionModifier())
  }
}

struct AdaptiveVideoPlaybackView: View {
  enum LocalPlaybackMode {
    case localPreferred
    case embedPreferred
  }

  let sourceURL: URL
  let showOpenSourceButtonInEmbedMode: Bool
  let openSourceAction: (() -> Void)?
  let resolveCachedLocalMedia: ((URL) -> PlayableMedia?)?
  let persistLocalMedia: ((URL, PlayableMedia) -> Void)?
  let clearPersistedLocalMedia: (() -> Void)?
  let reloadID: Int

  @State var canonicalSourceURL: URL?
  @State var preferredEmbedSource: EmbeddedWebSource?
  @State var resolvedMediaStrategy: URLClassifier.MediaStrategy?
  @State var isResolvingPresentation = false
  @State var extractionState: ExtractionState?
  @State var cachedLocalMedia: PlayableMedia?
  @State var localCacheTask: Task<Void, Never>?
  @State var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State var playbackCandidateIndex = 0
  @State var extractionFallbackReason: String?
  @State var exportTarget: LocalMediaExportTarget?
  @State var fileExportItem: LocalFileExportItem?
  @State var exportFeedbackTitle = ""
  @State var exportFeedbackMessage: String?
  @State var embeddedContentHeight: CGFloat?
  @State var isEmbeddedContentReady = false
  @State var detectedMediaAspectRatio: CGFloat?
  @State var embeddedLoadFailed = false

  init(
    sourceURL: URL,
    showOpenSourceButtonInEmbedMode: Bool = true,
    openSourceAction: (() -> Void)? = nil,
    resolveCachedLocalMedia: ((URL) -> PlayableMedia?)? = nil,
    persistLocalMedia: ((URL, PlayableMedia) -> Void)? = nil,
    clearPersistedLocalMedia: (() -> Void)? = nil,
    reloadID: Int = 0
  ) {
    self.sourceURL = sourceURL
    self.showOpenSourceButtonInEmbedMode = showOpenSourceButtonInEmbedMode
    self.openSourceAction = openSourceAction
    self.resolveCachedLocalMedia = resolveCachedLocalMedia
    self.persistLocalMedia = persistLocalMedia
    self.clearPersistedLocalMedia = clearPersistedLocalMedia
    self.reloadID = reloadID
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .task(id: playbackReloadTaskID) {
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
        if isRumble, preferredEmbedSource == nil,
          let rumbleEmbedURL = await URLCanonicalizationService.shared.preferredRumbleEmbedURL(
            for: canonical) {
          preferredEmbedSource = .url(rumbleEmbedURL)
        }
        isResolvingPresentation = false
        embeddedContentHeight = nil
        isEmbeddedContentReady = false
        detectedMediaAspectRatio = nil
        embeddedLoadFailed = false
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
}

extension AdaptiveVideoPlaybackView {
  var playbackReloadTaskID: String {
    "\(sourceURL.absoluteString)#\(reloadID)"
  }

  func scheduleLocalCachingIfNeeded(sourceURL: URL, media: PlayableMedia) {
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

  func clearFailedLocalPlaybackState() {
    localCacheTask?.cancel()
    localCacheTask = nil

    if clearPersistedLocalMedia == nil,
      let cachedLocalMedia,
      cachedLocalMedia.isLocalFile {
      try? FileManager.default.removeItem(at: cachedLocalMedia.playbackURL)
    }

    cachedLocalMedia = nil
    clearPersistedLocalMedia?()
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
