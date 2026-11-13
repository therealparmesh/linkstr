import OSLog
import SwiftUI

enum LinkstrPlaybackDiagnostics {
  static let logger = Logger(subsystem: "com.parmscript.linkstr", category: "playback")
}

extension EnvironmentValues {
  @Entry var isUnderlyingMediaCovered = false
}

struct AdaptiveMediaView<LinkContent: View, OverlayContent: View>: View {
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.isUnderlyingMediaCovered) var isUnderlyingMediaCovered
  enum LocalPlaybackMode {
    case localPreferred
    case embedPreferred
  }

  let sourceURL: URL
  let reloadID: Int
  let openSourceAction: () -> Void
  let cachedCanonicalSourceURL: URL?
  let resolveCachedLocalMedia: ((URL) -> PlayableMedia?)?
  let persistLocalMedia: ((URL, PlayableMedia) -> Void)?
  let clearPersistedLocalMedia: (() -> Void)?
  let immersive: Bool
  let isCovered: Bool
  let watchInsets: EdgeInsets
  let postControlsSummary: WatchPostSummary?
  let onResolvedSource: ((URL) -> Void)?
  let linkContent: LinkContent
  let overlayContent: ((() -> Void)?) -> OverlayContent
  @State var postControlsReservedHeight = LinkstrTheme.minimumInteractiveDimension
  @State var watchControlsHeight =
    LinkstrTheme.minimumInteractiveDimension + LinkstrTheme.compactSpacing + LinkstrTheme.metaSpacing

  @State var resolvedPresentation: ResolvedPresentation?
  @State var extractionState: ExtractionState?
  @State var cachedLocalMedia: PlayableMedia?
  @State var localCacheTask: Task<Void, Never>?
  @State var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State var localPlaybackRequestID = 0
  @State var playbackCandidateIndex = 0
  @State var exportTarget: LocalMediaExportTarget?
  @State var fileExportItem: LocalFileExportItem?
  @State var exportFeedback: LocalMediaExportFeedback?
  @State var photoSaveTask: Task<Void, Never>?
  @State var embeddedContentHeight: CGFloat?
  @State var isEmbeddedContentReady = false
  @State var hasRenderedEmbeddedPost = false
  @State var detectedMediaAspectRatio: CGFloat?
  @State var embeddedLoadFailure: EmbeddedWebView.LoadFailure?
  @State var embeddedReloadID = 0
  @State var fitsEntireVideo = false

  init(
    sourceURL: URL,
    openSourceAction: @escaping () -> Void,
    reloadID: Int = 0,
    cachedCanonicalSourceURL: URL? = nil,
    resolveCachedLocalMedia: ((URL) -> PlayableMedia?)? = nil,
    persistLocalMedia: ((URL, PlayableMedia) -> Void)? = nil,
    clearPersistedLocalMedia: (() -> Void)? = nil,
    immersive: Bool = false,
    isCovered: Bool = false,
    watchInsets: EdgeInsets = EdgeInsets(),
    postControlsSummary: WatchPostSummary? = nil,
    onResolvedSource: ((URL) -> Void)? = nil,
    @ViewBuilder linkContent: () -> LinkContent = { EmptyView() },
    @ViewBuilder overlayContent: @escaping ((() -> Void)?) -> OverlayContent = { _ in EmptyView() }
  ) {
    self.sourceURL = sourceURL
    self.reloadID = reloadID
    self.openSourceAction = openSourceAction
    self.cachedCanonicalSourceURL = cachedCanonicalSourceURL
    self.resolveCachedLocalMedia = resolveCachedLocalMedia
    self.persistLocalMedia = persistLocalMedia
    self.clearPersistedLocalMedia = clearPersistedLocalMedia
    self.immersive = immersive
    self.isCovered = isCovered
    self.watchInsets = watchInsets
    self.postControlsSummary = postControlsSummary
    self.onResolvedSource = onResolvedSource
    self.linkContent = linkContent()
    self.overlayContent = overlayContent
  }

  var body: some View {
    content
      .id(playbackReloadTaskID)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) {
        if immersive, let postControlsSummary {
          WatchPostControls(
            summary: postControlsSummary,
            topInset: watchInsets.top,
            bottomInset: watchInsets.bottom,
            playbackControlsHeight: reservesNativeControlsSpace ? watchControlsHeight : 0,
            showsLinkPreview: !isResolvingPresentation && (effectiveMediaStrategy == .link || showsEmbeddedPost),
            reservesExpandedSpace: effectiveMediaStrategy == .link,
            onReservedHeightChange: { postControlsReservedHeight = $0 },
            content: {
              VStack(alignment: .leading, spacing: LinkstrTheme.rowSpacing) {
                overlayContent(saveVideoAction)
                watchPlaybackOptions
                  .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
              }
            }
          )
        }
      }
      .task(id: playbackReloadTaskID) {
        await reloadPlaybackPresentation()
      }
      .task(id: localPreparationTaskID) {
        await prepareMediaIfNeeded()
      }
      .linkstrVideoSaveDialog(
        isPresented: Binding(
          get: { exportTarget != nil },
          set: { if !$0 { exportTarget = nil } }
        ),
        target: exportTarget,
        onSaveToPhotos: saveToPhotos,
        onSaveToFiles: saveToFiles
      )
      .sheet(item: $fileExportItem) { item in
        LocalFileExportSheet(url: item.fileURL) { result in
          // iOS may clear the sheet binding before reporting a completed export.
          guard item.requestID == resolvedPresentation?.taskID,
            fileExportItem == nil || fileExportItem?.id == item.id
          else { return }
          fileExportItem = nil
          switch result {
          case .exported:
            exportFeedback = LocalMediaExportFeedback(message: "saved to files.")
          case .cancelled:
            break
          case .failed:
            exportFeedback = LocalMediaExportFeedback(
              message: "couldn’t save this video to files.", retryFileURL: item.fileURL
            )
          }
        }
      }
      .alert(
        exportFeedback?.title ?? "",
        isPresented: Binding(
          get: { exportFeedback != nil },
          set: { isPresented in
            if !isPresented {
              exportFeedback = nil
            }
          }
        ),
        presenting: exportFeedback
      ) { feedback in
        if let fileURL = feedback.retryFileURL {
          Button("save to files") { saveToFiles(fileURL) }
          Button(LinkstrBrowserAction.title, action: openSourceAction)
          Button("cancel", role: .cancel) {}
        } else {
          Button("ok", role: .cancel) {}
        }
      } message: { feedback in
        Text(feedback.message)
      }
      .onDisappear {
        cancelLocalCaching()
        cancelPhotoSave()
      }
  }
}

extension AdaptiveMediaView {
  private func saveToFiles(_ fileURL: URL) {
    fileExportItem = LocalFileExportItem(fileURL: fileURL, requestID: playbackReloadTaskID)
  }

  private var showsEmbeddedPost: Bool {
    guard isEmbeddedContentReady, hasRenderedEmbeddedPost,
      embeddedLoadFailure == nil,
      let presentation = activeResolvedPresentation, case .embedOnly = presentation.mediaStrategy
    else { return false }
    return SocialURLHeuristics.isTwitterStatusURL(presentation.canonicalSourceURL)
  }

  var playbackReloadTaskID: String {
    "\(sourceURL.absoluteString)#\(reloadID)"
  }

  func scheduleLocalCachingIfNeeded(sourceURL: URL, media: PlayableMedia) {
    guard !media.isLocalFile else { return }
    guard cachedLocalMedia == nil else { return }

    cancelLocalCaching()
    localCacheTask = Task {
      guard
        let localMedia = await SocialVideoExtractionService.shared.cachePlayableMediaLocally(media)
      else { return }
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard !Task.isCancelled else { return }
        cachedLocalMedia = localMedia
        persistLocalMedia?(sourceURL, localMedia)
      }
    }
  }

  func cancelLocalCaching() {
    localCacheTask?.cancel()
    localCacheTask = nil
  }

  func clearFailedLocalPlaybackState() {
    cancelLocalCaching()

    // A failed file must not be reused by the cache, even when another post references it.
    if let cachedLocalMedia, cachedLocalMedia.isLocalFile {
      try? FileManager.default.removeItem(at: cachedLocalMedia.playbackURL)
    }

    cachedLocalMedia = nil
    clearPersistedLocalMedia?()
  }
}
