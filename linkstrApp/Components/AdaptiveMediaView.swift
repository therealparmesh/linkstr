import SwiftUI

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
  let openSourceAction: () -> Void
  let resolveCachedLocalMedia: ((URL) -> PlayableMedia?)?
  let persistLocalMedia: ((URL, PlayableMedia) -> Void)?
  let clearPersistedLocalMedia: (() -> Void)?
  let reloadID: Int
  let immersive: Bool
  let isCovered: Bool
  let watchInsets: EdgeInsets
  let linkContent: LinkContent
  let overlayContent: ((() -> Void)?, Bool) -> OverlayContent
  @State var overlayHeight: CGFloat = 240

  @State var resolvedPresentation: ResolvedPresentation?
  @State var extractionState: ExtractionState?
  @State var cachedLocalMedia: PlayableMedia?
  @State var localCacheTask: Task<Void, Never>?
  @State var localPlaybackMode: LocalPlaybackMode = .localPreferred
  @State var localPlaybackRequestID = 0
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
  @State var isPresentingSystemPlayer = false

  init(
    sourceURL: URL,
    openSourceAction: @escaping () -> Void,
    resolveCachedLocalMedia: ((URL) -> PlayableMedia?)? = nil,
    persistLocalMedia: ((URL, PlayableMedia) -> Void)? = nil,
    clearPersistedLocalMedia: (() -> Void)? = nil,
    reloadID: Int = 0,
    immersive: Bool = false,
    isCovered: Bool = false,
    watchInsets: EdgeInsets = EdgeInsets(),
    @ViewBuilder linkContent: () -> LinkContent = { EmptyView() },
    @ViewBuilder overlayContent: @escaping ((() -> Void)?, Bool) -> OverlayContent = { _, _ in EmptyView() }
  ) {
    self.sourceURL = sourceURL
    self.openSourceAction = openSourceAction
    self.resolveCachedLocalMedia = resolveCachedLocalMedia
    self.persistLocalMedia = persistLocalMedia
    self.clearPersistedLocalMedia = clearPersistedLocalMedia
    self.reloadID = reloadID
    self.immersive = immersive
    self.isCovered = isCovered
    self.watchInsets = watchInsets
    self.linkContent = linkContent()
    self.overlayContent = overlayContent
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) {
        overlayContent(saveVideoAction, isShowingNativePlayer)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overlayHeight = $0 }
      }
      .task(id: playbackReloadTaskID) {
        await reloadPlaybackPresentation()
      }
      .task(id: localPreparationTaskID) {
        await prepareMediaIfNeeded()
      }
      .alert(
        "save video",
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
        cancelLocalCaching()
      }
  }
}

extension AdaptiveMediaView {
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

    if clearPersistedLocalMedia == nil,
      let cachedLocalMedia,
      cachedLocalMedia.isLocalFile {
      try? FileManager.default.removeItem(at: cachedLocalMedia.playbackURL)
    }

    cachedLocalMedia = nil
    clearPersistedLocalMedia?()
  }
}
