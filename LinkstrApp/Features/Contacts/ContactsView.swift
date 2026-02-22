import AVFoundation
import SwiftData
import SwiftUI

struct ContactsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  private var scopedContacts: [ContactEntity] {
    session.scopedContacts(from: contacts)
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var content: some View {
    if scopedContacts.isEmpty {
      LinkstrCenteredEmptyStateView(
        title: "No Contacts",
        systemImage: "person.2.slash",
        description: "Add at least one contact to start sharing links."
      )
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(scopedContacts) { contact in
            NavigationLink {
              ContactDetailView(contact: contact)
            } label: {
              ContactRowView(contact: contact)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }
}

private struct ContactRowView: View {
  let contact: ContactEntity

  var body: some View {
    HStack(spacing: 12) {
      LinkstrPeerAvatar(name: contact.displayName)

      VStack(alignment: .leading, spacing: 3) {
        Text(contact.displayName)
          .font(.custom(LinkstrTheme.titleFont, size: 16))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(1)
        Text(contact.npub)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textSecondary.opacity(0.8))
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider()
    }
  }
}

private struct ContactDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contact: ContactEntity

  @State private var npub: String
  @State private var displayName: String
  @State private var isPresentingDeleteConfirmation = false

  init(contact: ContactEntity) {
    self.contact = contact
    _npub = State(initialValue: contact.npub)
    _displayName = State(initialValue: contact.displayName)
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          LinkstrSectionHeader(title: "Display Name")
          TextField("Display Name", text: $displayName)
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: LinkstrTheme.inputControlMinHeight)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )

          LinkstrSectionHeader(title: "Contact Key (npub)")
          TextField("Contact Key (npub...)", text: $npub)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: LinkstrTheme.inputControlMinHeight)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )

          Button(role: .destructive) {
            isPresentingDeleteConfirmation = true
          } label: {
            Label("Delete Contact", systemImage: "trash")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrDangerButtonStyle())
          .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .navigationTitle("Contact")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar(.visible, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") {
          dismiss()
        }
        .tint(LinkstrTheme.textSecondary)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") {
          if session.updateContact(contact, npub: npub, displayName: displayName) {
            dismiss()
          }
        }
        .tint(LinkstrTheme.neonCyan)
      }
    }
    .alert("Delete this contact?", isPresented: $isPresentingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        session.removeContact(contact)
        dismiss()
      }
    } message: {
      Text("This removes the contact from linkstr.")
    }
  }
}

struct AddContactSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  @State private var npub = ""
  @State private var displayName = ""
  @State private var isPresentingScanner = false
  @State private var scannerErrorMessage: String?
  private let isNPubPrefilled: Bool

  init(prefilledNPub: String? = nil) {
    _npub = State(initialValue: prefilledNPub ?? "")
    isNPubPrefilled = !(prefilledNPub ?? "").isEmpty
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        VStack(spacing: 12) {
          if !isNPubPrefilled {
            LinkstrInputAssistRow(
              showClear: !npub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              onPaste: {
                pasteFromClipboard()
                scannerErrorMessage = nil
              },
              onScan: {
                scannerErrorMessage = nil
                isPresentingScanner = true
              },
              onClear: { npub = "" }
            )
          }

          TextField("Contact Key (npub...)", text: $npub)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .disabled(isNPubPrefilled)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: LinkstrTheme.inputControlMinHeight)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )
          TextField("Display Name", text: $displayName)
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: LinkstrTheme.inputControlMinHeight)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )

          Text(normalizedScannerErrorMessage.isEmpty ? " " : normalizedScannerErrorMessage)
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(Color.red.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .opacity(normalizedScannerErrorMessage.isEmpty ? 0 : 1)
            .accessibilityHidden(normalizedScannerErrorMessage.isEmpty)

          Spacer()
        }
        .padding(14)
      }
      .navigationTitle("Add Contact")
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            if session.addContact(npub: npub, displayName: displayName) {
              dismiss()
            }
          }
          .disabled(
            npub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
          .tint(LinkstrTheme.neonCyan)
        }
      }
      .sheet(isPresented: $isPresentingScanner) {
        LinkstrQRScannerSheet { scannedValue in
          if let scannedNPub = ContactKeyParser.extractNPub(from: scannedValue) {
            npub = scannedNPub
            scannerErrorMessage = nil
          } else {
            scannerErrorMessage = "No valid Contact Key (npub) found in that QR code."
          }
        }
      }
    }
  }

  private func pasteFromClipboard() {
    if let clipboardText = UIPasteboard.general.string {
      npub = clipboardText
    }
  }

  private var normalizedScannerErrorMessage: String {
    guard let scannerErrorMessage else { return "" }
    return scannerErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

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
          Text("Scanner Error")
            .font(.custom(LinkstrTheme.titleFont, size: 18))
            .foregroundStyle(.white)
          Text(message)
            .font(.custom(LinkstrTheme.bodyFont, size: 14))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
      }

      VStack {
        HStack {
          Spacer()
          Button("Close") {
            dismiss()
          }
          .font(.custom(LinkstrTheme.bodyFont, size: 16))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.black.opacity(0.45), in: Capsule())
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
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
        "Camera capture is unavailable in this simulator. Use a physical iPhone to scan QR codes."
    #else
      return "Unable to read QR codes from the camera."
    #endif
  }
}

private struct LinkstrQRScannerAccessDeniedView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "camera.fill")
        .font(.system(size: 28))
        .foregroundStyle(.white)
      Text("Camera Access Required")
        .font(.custom(LinkstrTheme.titleFont, size: 18))
        .foregroundStyle(.white)
      Text("Enable camera access in Settings to scan a Contact Key (npub) QR code.")
        .font(.custom(LinkstrTheme.bodyFont, size: 14))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
      Button("Open Settings") {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
      }
      .buttonStyle(LinkstrPrimaryButtonStyle())
      .padding(.top, 8)
    }
    .padding(.horizontal, 16)
  }
}

private struct LinkstrQRScannerRepresentable: UIViewRepresentable {
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

private final class ScannerPreviewView: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
      return AVCaptureVideoPreviewLayer()
    }
    return previewLayer
  }
}
