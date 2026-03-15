import AVFoundation
import SwiftData
import SwiftUI

struct ContactsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @State private var selectedContact: ContactEntity?
  @State private var pendingContactRemoval: ContactEntity?
  @State private var isRemovingContact = false
  @State private var query = ""

  private var scopedContacts: [ContactEntity] {
    return
      OwnerScopedCollections.contacts(contacts, ownerPubkey: session.identityService.pubkeyHex)
      .sorted {
        session.resolvedIdentity(for: $0).displayName.localizedCaseInsensitiveCompare(
          session.resolvedIdentity(for: $1).displayName
        ) == .orderedAscending
      }
  }

  private var visibleContacts: [ContactEntity] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return scopedContacts }
    return RecipientSearchLogic.filteredContacts(
      scopedContacts,
      query: normalizedQuery,
      displayName: { session.resolvedIdentity(for: $0).displayName },
      npub: \.npub,
      additionalNames: { session.searchableNames(for: $0) }
    )
  }

  private var profileLookupPubkeys: [String] {
    scopedContacts.map(\.targetPubkey)
  }

  private var profileLookupRequestID: String {
    profileLookupPubkeys.sorted().joined(separator: ",")
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .alert("remove contact", isPresented: isPresentingRemovalConfirmation) {
      Button("cancel", role: .cancel) {}
      Button(isRemovingContact ? "removing..." : "remove", role: .destructive) {
        removePendingContact()
      }
    } message: {
      Text(removeContactConfirmationMessage)
    }
    .task(id: profileLookupRequestID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .navigationDestination(item: $selectedContact) { contact in
      EditContactView(contact: contact)
    }
  }

  @ViewBuilder
  private var content: some View {
    if scopedContacts.isEmpty {
      LinkstrCenteredEmptyStateView(
        title: "no contacts",
        systemImage: "person.2.slash",
        description: "add a contact. invite them when you start a session."
      )
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          LinkstrSearchField(prompt: "search contacts", text: $query)

          if visibleContacts.isEmpty {
            LinkstrCenteredEmptyStateView(
              title: "no contacts found",
              systemImage: "magnifyingglass",
              description: "try another search."
            )
            .frame(maxWidth: .infinity, minHeight: 220)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visibleContacts) { contact in
                Button {
                  selectedContact = contact
                } label: {
                  ContactRowView(contact: contact)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                  Button(role: .destructive) {
                    pendingContactRemoval = contact
                  } label: {
                    Label("remove contact", systemImage: "person.crop.circle.badge.minus")
                  }
                }
                .accessibilityHint("long press for contact actions.")
                .accessibilityAction(named: Text("remove contact")) {
                  pendingContactRemoval = contact
                }
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
      }
      .linkstrTabBarContentInset()
    }
  }

  private var isPresentingRemovalConfirmation: Binding<Bool> {
    Binding(
      get: { pendingContactRemoval != nil },
      set: { isPresented in
        if !isPresented {
          pendingContactRemoval = nil
        }
      }
    )
  }

  private var removeContactConfirmationMessage: String {
    guard let pendingContactRemoval else {
      return "this updates your follow list on relays and removes this contact locally."
    }

    return
      "this updates your follow list on relays, removes \(session.resolvedIdentity(for: pendingContactRemoval).displayName) from your contacts, and removes the contact locally."
  }

  private func removePendingContact() {
    guard !isRemovingContact, let pendingContactRemoval else { return }

    isRemovingContact = true
    Task { @MainActor in
      let didRemove = await session.removeContact(pendingContactRemoval)
      isRemovingContact = false
      if didRemove {
        self.pendingContactRemoval = nil
      }
    }
  }
}

private struct ContactRowView: View {
  @EnvironmentObject private var session: AppSession
  let contact: ContactEntity

  var body: some View {
    let identity = session.resolvedIdentity(for: contact)
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrContactAvatar(name: identity.displayName, size: 48)

      LinkstrContactIdentityView(
        identity: identity,
        primaryFont: LinkstrTheme.body(15, weight: .medium)
      )
      .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "chevron.right")
        .font(LinkstrTheme.system(12, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)
    }
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider(leadingInset: 62)
    }
  }
}

private struct EditContactView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contact: ContactEntity

  @State private var alias: String

  init(contact: ContactEntity) {
    self.contact = contact
    _alias = State(initialValue: contact.localAlias ?? "")
  }

  var body: some View {
    let identity = session.resolvedIdentity(for: contact)
    ZStack {
      LinkstrBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          LinkstrInsetSection(
            title: "contact",
            footer: "only you see this alias. the public key (npub) stays the real identity."
          ) {
            HStack(spacing: LinkstrTheme.rowSpacing) {
              LinkstrContactAvatar(name: identity.displayName, size: 54)
              LinkstrContactIdentityView(identity: identity, lineLimit: 2)
            }
          }

          LinkstrInsetSection(title: "alias") {
            TextField("alias", text: $alias)
              .font(LinkstrTheme.body(15))
              .textInputAutocapitalization(.words)
              .linkstrInputField()
          }

          if let nostrChosenName = identity.chosenName {
            LinkstrInsetSection(title: "published nostr name") {
              Text(nostrChosenName)
                .font(LinkstrTheme.body(14))
                .foregroundStyle(
                  contact.localAlias == nil
                    ? LinkstrTheme.textPrimary : LinkstrTheme.accentPink.opacity(0.88)
                )
                .lineLimit(3)
                .textSelection(.enabled)
                .linkstrInputField()
            }
          }

          LinkstrInsetSection(title: "public key (npub)") {
            Text(contact.npub)
              .font(LinkstrTheme.body(13))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .lineLimit(1)
              .textSelection(.enabled)
              .linkstrInputField()
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
      }
      .linkstrTabBarContentInset()
    }
    .navigationTitle("edit contact")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .linkstrBarChrome()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("cancel")
        .tint(LinkstrTheme.textSecondary)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          saveAlias()
        } label: {
          Image(systemName: "checkmark")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("save contact")
        .tint(LinkstrTheme.accent)
        .disabled(canSaveAlias == false)
      }
    }
  }

  private func saveAlias() {
    guard canSaveAlias else { return }
    let didSave = session.updateContactAlias(contact, alias: alias)
    if didSave {
      dismiss()
    }
  }

  private var canSaveAlias: Bool {
    normalizedAlias != persistedAlias
  }

  private var normalizedAlias: String {
    alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var persistedAlias: String {
    contact.localAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}

struct AddContactSheet: View {
  private enum Field: Hashable {
    case npub
    case alias
  }

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  @State private var npub = ""
  @State private var alias = ""
  @State private var isSubmitting = false
  @State private var isPresentingScanner = false
  @State private var scannerErrorMessage: String?
  @FocusState private var focusedField: Field?
  private let isNPubPrefilled: Bool

  init(prefilledNPub: String? = nil) {
    _npub = State(initialValue: prefilledNPub ?? "")
    isNPubPrefilled = !(prefilledNPub ?? "").isEmpty
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            LinkstrInsetSection(title: "public key (npub)") {
              TextField("public key (npub...)", text: $npub)
                .font(LinkstrTheme.body(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .npub)
                .disabled(isSubmitting || isNPubPrefilled)
                .linkstrInputField()

              if !isNPubPrefilled {
                LinkstrInputAssistRow(
                  showClear: !npub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isDisabled: isSubmitting,
                  onPaste: {
                    pasteFromClipboard()
                    scannerErrorMessage = nil
                  },
                  onScan: {
                    scannerErrorMessage = nil
                    isPresentingScanner = true
                  },
                  onClear: {
                    npub = ""
                    scannerErrorMessage = nil
                  }
                )
              }
            }

            if let previewIdentity {
              LinkstrInsetSection(title: "preview") {
                HStack(spacing: LinkstrTheme.rowSpacing) {
                  LinkstrContactAvatar(name: previewIdentity.displayName, size: 50)
                  LinkstrContactIdentityView(
                    identity: previewIdentity,
                    primaryFont: LinkstrTheme.body(15, weight: .medium),
                    lineLimit: 2
                  )
                  .frame(maxWidth: .infinity, alignment: .leading)
                }

                if previewIdentity.chosenName == nil && normalizedAliasPreview == nil {
                  Text("looking up published nostr name...")
                    .font(LinkstrTheme.body(12))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                }
              }
            }

            LinkstrInsetSection(title: "alias", footer: "optional. only you see this alias.") {
              TextField("alias", text: $alias)
                .font(LinkstrTheme.body(15))
                .textInputAutocapitalization(.words)
                .focused($focusedField, equals: .alias)
                .disabled(isSubmitting)
                .linkstrInputField()
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(
            .bottom,
            isKeyboardPresented ? LinkstrTheme.screenBottomPadding : LinkstrTheme.sheetBottomPadding
          )
          .scrollDismissesKeyboard(.interactively)
        }
      }
      .task(id: previewLookupRequestID) {
        guard let previewPubkeyHex else { return }
        session.requestRemoteProfilesIfNeeded(pubkeyHexes: [previewPubkeyHex])
      }
      .navigationTitle("add contact")
      .navigationBarTitleDisplayMode(.inline)
      .linkstrBarChrome()
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("cancel")
          .tint(LinkstrTheme.textSecondary)
          .disabled(isSubmitting)
        }

        if isKeyboardPresented {
          ToolbarItemGroup(placement: .keyboard) {
            Spacer()

            Button {
              submitFollow()
            } label: {
              Label(
                isSubmitting ? "adding contact..." : "add contact",
                systemImage: "person.crop.circle.badge.plus"
              )
            }
            .disabled(!canSubmit)
          }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !isKeyboardPresented {
          LinkstrSheetActionFooter(
            title: isSubmitting ? "adding contact..." : "add contact",
            systemImage: "person.crop.circle.badge.plus",
            isDisabled: !canSubmit,
            message: footerMessage,
            messageColor: footerMessageColor,
            action: submitFollow
          )
        }
      }
      .sheet(isPresented: $isPresentingScanner) {
        LinkstrQRScannerSheet { scannedValue in
          if let scannedNPub = ContactKeyParser.extractNPub(from: scannedValue) {
            npub = scannedNPub
            scannerErrorMessage = nil
          } else {
            scannerErrorMessage = "no valid public key (npub) found in that qr code."
          }
        }
      }
      .onChange(of: npub) { _, _ in
        guard normalizedScannerErrorMessage.isEmpty == false else { return }
        scannerErrorMessage = nil
      }
    }
  }

  private var canSubmit: Bool {
    !isSubmitting && previewPubkeyHex != nil
  }

  private var isKeyboardPresented: Bool {
    focusedField != nil
  }

  private var footerMessage: String {
    if isSubmitting {
      return "waiting for relay reconnect before adding..."
    }

    if normalizedScannerErrorMessage.isEmpty == false {
      return normalizedScannerErrorMessage
    }

    let trimmedNPub = npub.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedNPub.isEmpty == false && previewPubkeyHex == nil {
      return "enter a valid public key."
    }

    return ""
  }

  private var footerMessageColor: Color {
    if isSubmitting {
      return LinkstrTheme.textSecondary
    }

    let trimmedNPub = npub.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedScannerErrorMessage.isEmpty == false
      || (!trimmedNPub.isEmpty && previewPubkeyHex == nil)
    {
      return LinkstrTheme.destructive.opacity(0.9)
    }

    return LinkstrTheme.textSecondary
  }

  private func pasteFromClipboard() {
    if let clipboardText = UIPasteboard.general.string {
      npub = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func submitFollow() {
    guard canSubmit else { return }
    isSubmitting = true
    Task { @MainActor in
      let didAdd = await session.addContact(npub: npub, alias: alias)
      isSubmitting = false
      if didAdd {
        dismiss()
      }
    }
  }

  private var normalizedScannerErrorMessage: String {
    guard let scannerErrorMessage else { return "" }
    return scannerErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedAliasPreview: String? {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var previewPubkeyHex: String? {
    let candidate = ContactKeyParser.extractNPub(from: npub) ?? npub
    return NostrValueNormalizer.normalizedPubkeyHex(fromAnyPublicKeyString: candidate)
  }

  private var previewLookupRequestID: String {
    previewPubkeyHex ?? ""
  }

  private var previewIdentity: LinkstrResolvedIdentity? {
    guard let previewPubkeyHex else { return nil }
    let resolvedIdentity = session.resolvedIdentity(for: previewPubkeyHex, contacts: [])
    return LinkstrResolvedIdentity(
      localAlias: normalizedAliasPreview,
      chosenName: resolvedIdentity.chosenName,
      pubkeyHex: previewPubkeyHex
    )
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
          Spacer()
          Button("close") {
            dismiss()
          }
          .font(LinkstrTheme.body(16))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.black.opacity(0.45), in: Capsule())
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

private struct LinkstrQRScannerAccessDeniedView: View {
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
