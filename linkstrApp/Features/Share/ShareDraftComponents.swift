import SwiftUI
import UIKit

struct LinkstrShareDraftFields: View {
  enum Field: Hashable {
    case link
    case note
  }

  @Binding var link: String
  @Binding var note: String
  let normalizedURL: String?
  let isSending: Bool
  var focusedField: FocusState<Field?>.Binding

  var body: some View {
    LinkstrInsetSection(title: "link") {
      TextField("link", text: $link, prompt: Text("example.com"))
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        .autocorrectionDisabled(true)
        .disabled(isSending)
        .focused(focusedField, equals: .link)
        .lineLimit(1)
        .submitLabel(.next)
        .onSubmit { focusedField.wrappedValue = .note }
        .accessibilityLabel("link")
        .linkstrInputField()
        .id(Field.link)

      LinkstrInputAssistRow(
        showClear: !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        showScan: false,
        isDisabled: isSending,
        onPaste: {
          if let text = UIPasteboard.general.string {
            link = text.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        },
        onClear: { link = "" }
      )

      if let normalizedURL {
        LinkstrDraftPreview(url: normalizedURL, loadsRichPreview: focusedField.wrappedValue != .link)
      }
    }

    LinkstrInsetSection(title: "note", accessory: "optional") {
      LinkstrNoteEditor(note: $note, isDisabled: isSending, focusedField: focusedField, field: .note)
        .id(Field.note)
    }
  }
}

// Keep the editing target visible when the viewport or text size changes.
struct LinkstrFocusedFieldScrolling<Field: Hashable>: ViewModifier {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let focusedField: Field?

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .onScrollGeometryChange(for: CGSize.self) { geometry in
          geometry.visibleRect.size
        } action: { _, _ in
          guard let focusedField else { return }
          proxy.scrollTo(focusedField, anchor: .bottom)
        }
        .onChange(of: dynamicTypeSize) { _, _ in
          guard let focusedField else { return }
          proxy.scrollTo(focusedField, anchor: .bottom)
        }
    }
  }
}

struct LinkstrNoteEditor<Field: Hashable>: View {
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @ScaledMetric(relativeTo: .subheadline) private var scaledMinimumHeight = 112.0

  @Binding var note: String
  let isDisabled: Bool
  let focusedField: FocusState<Field?>.Binding
  let field: Field

  var body: some View {
    let isCompact = verticalSizeClass == .compact
    let minimumHeight = min(scaledMinimumHeight, isCompact ? 72 : 180)
    ZStack(alignment: .topLeading) {
      if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("add context about this link")
          .font(LinkstrTheme.font(.subheadline))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .padding(.top, LinkstrTheme.fieldVerticalPadding)
          .padding(.leading, LinkstrTheme.fieldHorizontalPadding)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }

      TextEditor(text: $note)
        .font(LinkstrTheme.font(.subheadline))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .scrollContentBackground(.hidden)
        .frame(minHeight: minimumHeight, maxHeight: isCompact ? minimumHeight : minimumHeight + 68)
        .padding(.vertical, LinkstrTheme.metaSpacing)
        // TextEditor supplies a 5-point inset for the text itself.
        .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding - 5)
        .focused(focusedField, equals: field)
        .accessibilityLabel("note")
        .disabled(isDisabled)
    }
    .linkstrFieldChrome()
  }
}

struct LinkstrDraftPreview: View {
  private struct Preview {
    let url: String
    let destination: URL
    let title: String?
    let image: UIImage?
  }

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let url: String
  let loadsRichPreview: Bool
  @State private var preview: Preview?

  private func previewStrategy(for address: String) -> URLClassifier.MediaStrategy {
    guard let sourceURL = URL(string: address),
      !SocialURLHeuristics.isTwitterStatusURL(sourceURL),
      !SocialURLHeuristics.isTikTokShortURL(sourceURL) else {
      return .link
    }
    return URLClassifier.mediaStrategy(for: sourceURL)
  }

  static func availabilityHint(for strategy: URLClassifier.MediaStrategy) -> String? {
    switch strategy {
    case .extractionPreferred, .directVideo: "play or save this video when available"
    case .embedOnly: "view the official embed when available"
    case .link: nil
    }
  }

  var body: some View {
    let currentPreview = preview?.url == url ? preview : nil
    let previewAddress = currentPreview?.destination.absoluteString ?? url
    let strategy = previewStrategy(for: previewAddress)
    let source = LinkstrPostPreview.source(for: previewAddress)
    let title = currentPreview?.title
    VStack(alignment: .leading, spacing: 0) {
      if !dynamicTypeSize.isAccessibilitySize, let image = currentPreview?.image {
        Rectangle()
          .fill(LinkstrTheme.panelElevated)
          .overlay { Image(uiImage: image).resizable().scaledToFill() }
          .frame(height: 142)
          .clipped()
          .accessibilityHidden(true)
      }

      HStack(spacing: LinkstrTheme.buttonRowSpacing) {
        Image(systemName: previewIcon(for: strategy, address: previewAddress))
          .font(LinkstrTheme.font(.title3))
          .dynamicTypeSize(...DynamicTypeSize.xxLarge)
          .foregroundStyle(LinkstrTheme.accent)
          .frame(width: 38, height: 38)
          .background(LinkstrTheme.panelElevated, in: .rect(cornerRadius: LinkstrTheme.thumbnailCornerRadius))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
          Text(title ?? source ?? "shared link")
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
          if let title, let source, title != source {
            Text(source)
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
          if let hint = Self.availabilityHint(for: strategy) {
            Text(hint)
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(10)
    }
    .linkstrCardSurface()
    .task(id: loadsRichPreview ? url : nil) { await loadPreview() }
  }

  private func loadPreview() async {
    guard loadsRichPreview, let sourceURL = URL(string: url) else { return }
    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
    let destination = SocialURLHeuristics.isTikTokShortURL(sourceURL)
      ? await URLCanonicalizationService.shared.canonicalPlaybackURL(for: sourceURL)
      : sourceURL
    guard !Task.isCancelled else { return }
    if preview?.url != url || preview?.destination != destination {
      preview = Preview(url: url, destination: destination, title: nil, image: nil)
    }

    let address = destination.absoluteString
    guard let metadata = await URLMetadataService.shared.fetchPreview(for: address), !Task.isCancelled else { return }
    let title = LinkstrPostPreview.displayTitle(metadata.title, for: address)
    preview = Preview(url: url, destination: destination, title: title, image: nil)
    if let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: metadata.thumbnailPath)?.path {
      let image = await ThumbnailImageCache.shared.loadImageAsync(at: path)
      guard !Task.isCancelled else { return }
      preview = Preview(url: url, destination: destination, title: title, image: image)
    }
  }

  private func previewIcon(for strategy: URLClassifier.MediaStrategy, address: String) -> String {
    if LinkstrPostPreview.kind(for: address) == "photo post" { return "photo" }
    return strategy == .link ? "link" : "play.rectangle"
  }
}

struct LinkstrShareFooter: View {
  let status: LinkstrSheetFooterStatus?
  let canSend: Bool
  let isSending: Bool
  let send: () -> Void

  var body: some View {
    VStack(spacing: LinkstrTheme.compactSpacing) {
      if let status {
        Text(status.message)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(status.color)
          .multilineTextAlignment(.center)
      }

      Button(action: send) {
        if isSending {
          Label {
            Text("sharing link…")
          } icon: {
            ProgressView()
              .controlSize(.small)
              .tint(LinkstrTheme.textSecondary)
              .accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity)
        } else {
          LinkstrActionButtonLabel(title: "share to session")
        }
      }
      .linkstrPrimaryButton()
      .disabled(!canSend)
    }
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
    .linkstrReadableContent()
    .background(LinkstrTheme.background)
    .overlay(alignment: .top) { LinkstrListRowDivider(leadingInset: 0) }
  }
}
