import AVFoundation
import SwiftUI

struct LinkstrQRScannerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let onScanned: (String) -> Void

  @State private var cameraAccessState: CameraAccessState = .checking

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      switch cameraAccessState {
      case .checking:
        ProgressView()
          .tint(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      case .authorized:
        LinkstrQRScannerRepresentable(
          onScanned: { value in
            onScanned(value)
            dismiss()
          },
          onFailure: {
            cameraAccessState = .failed(unavailableCameraMessage)
          }
        )
        .ignoresSafeArea()
      case .denied:
        LinkstrQRScannerAccessDeniedView()
      case .failed(let message):
        VStack(spacing: 12) {
          Text("scanner error")
            .font(LinkstrTheme.title(18))
            .foregroundStyle(.white)
          Text(message)
            .font(LinkstrTheme.body(14))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
      }

      VStack {
        HStack {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(LinkstrTheme.system(15, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 36, height: 36)
              .background(.black.opacity(0.45), in: Circle())
          }
          .accessibilityLabel("close")
          Spacer()
        }
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        Spacer()
      }
    }
    .task {
      await requestCameraAccessIfNeeded()
    }
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
    case failed(String)
  }

  private var unavailableCameraMessage: String {
    #if targetEnvironment(simulator)
      return
        "camera capture is unavailable in this simulator. use a physical iphone to scan qr codes."
    #else
      return "unable to read qr codes from the camera."
    #endif
  }
}

struct LinkstrQRScannerAccessDeniedView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "camera.fill")
        .font(LinkstrTheme.system(28))
        .foregroundStyle(.white)
      Text("camera access required")
        .font(LinkstrTheme.title(18))
        .foregroundStyle(.white)
      Text("enable camera access in settings to scan a public key (npub) qr code.")
        .font(LinkstrTheme.body(14))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
      Button("open settings") {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
      }
      .linkstrPrimaryButton()
      .padding(.top, 8)
    }
    .padding(.horizontal, 16)
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

      self.session = session
      DispatchQueue.global(qos: .userInitiated).async {
        session.startRunning()
      }
    }

    func stop() {
      session?.stopRunning()
      session = nil
    }

    func metadataOutput(
      _ output: AVCaptureMetadataOutput,
      didOutput metadataObjects: [AVMetadataObject],
      from connection: AVCaptureConnection
    ) {
      guard !didEmitValue else { return }
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
