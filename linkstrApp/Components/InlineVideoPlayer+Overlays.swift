import Photos

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

// MARK: - AdaptiveVideoPlaybackView Export & Overlay Helpers

extension AdaptiveVideoPlaybackView {
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
