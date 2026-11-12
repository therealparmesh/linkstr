import AVFoundation
import SwiftUI

struct LinkstrQRScannerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  let onScanned: (String) -> Void

  @State private var cameraAccessState: CameraAccessState = .checking

  var body: some View {
    ZStack {
      LinkstrBackgroundView()

      switch cameraAccessState {
      case .checking:
        ProgressView()
          .tint(LinkstrTheme.accent)
          .accessibilityLabel("checking camera access")
      case .authorized:
        LinkstrQRScannerRepresentable(
          onScanned: { value in
            onScanned(value)
            dismiss()
          },
          onFailure: { cameraAccessState = .failed }
        )
      case .denied:
        scannerStatus(
          title: "camera access required",
          description: "allow camera access in settings to scan a public key.",
          actionTitle: "open settings"
        ) {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
          }
        }
      case .failed:
        scannerStatus(
          title: "camera unavailable",
          description: "close the scanner and paste the public key to add this contact."
        )
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      LinkstrSheetHeader(title: "scan public key", closeLabel: "close scanner") { dismiss() }
    }
    .task {
      await requestCameraAccessIfNeeded()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active, cameraAccessState == .denied,
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
        cameraAccessState = .authorized
      }
    }
  }

  private func scannerStatus(
    title: String,
    description: String,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) -> some View {
    ScrollView {
      LinkstrCenteredEmptyStateView(
        title: title,
        systemImage: "camera",
        description: description,
        actionTitle: actionTitle,
        actionSystemImage: "gearshape",
        action: action
      )
      .padding(.vertical, LinkstrTheme.screenBottomPadding)
    }
    .linkstrReadableContent()
  }

  private func requestCameraAccessIfNeeded() async {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      cameraAccessState = .authorized
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      cameraAccessState = granted ? .authorized : .denied
    case .denied, .restricted:
      cameraAccessState = .denied
    @unknown default:
      cameraAccessState = .denied
    }
  }

  private enum CameraAccessState: Equatable {
    case checking
    case authorized
    case denied
    case failed
  }
}

struct LinkstrQRScannerRepresentable: UIViewRepresentable {
  let onScanned: (String) -> Void
  let onFailure: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScanned: onScanned, onFailure: onFailure)
  }

  func makeUIView(context: Context) -> ScannerPreviewView {
    let view = ScannerPreviewView()
    context.coordinator.configure(view: view)
    return view
  }

  func updateUIView(_ uiView: ScannerPreviewView, context: Context) {}

  static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.parmscript.linkstr.qr-camera", qos: .userInitiated)
    private var didEmitValue = false
    private let onScanned: (String) -> Void
    private let onFailure: () -> Void

    init(onScanned: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
      self.onScanned = onScanned
      self.onFailure = onFailure
    }

    func configure(view: ScannerPreviewView) {
      let session = AVCaptureSession()
      session.beginConfiguration()

      guard
        let device = AVCaptureDevice.default(for: .video),
        let input = try? AVCaptureDeviceInput(device: device),
        session.canAddInput(input)
      else {
        onFailure()
        return
      }
      session.addInput(input)

      let output = AVCaptureMetadataOutput()
      guard session.canAddOutput(output) else {
        onFailure()
        return
      }
      session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      output.metadataObjectTypes = [.qr]

      session.commitConfiguration()
      view.previewLayer.session = session
      view.previewLayer.videoGravity = .resizeAspectFill

      start(session)
    }

    func start(_ session: AVCaptureSession) {
      self.session = session
      sessionQueue.async { session.startRunning() }
    }

    func stop() {
      guard let session else { return }
      self.session = nil
      sessionQueue.async { session.stopRunning() }
    }

    func metadataOutput(
      _ output: AVCaptureMetadataOutput,
      didOutput metadataObjects: [AVMetadataObject],
      from connection: AVCaptureConnection
    ) {
      guard session != nil, !didEmitValue else { return }
      guard
        let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
        let value = object.stringValue
      else {
        return
      }

      didEmitValue = true
      stop()
      onScanned(value)
    }
  }
}

final class ScannerPreviewView: UIView {
  override static var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
      return AVCaptureVideoPreviewLayer()
    }
    return previewLayer
  }
}
