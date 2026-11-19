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
      TextField("link", text: $link, prompt: LinkstrTheme.placeholder("example.com"))
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

      LinkstrInputAssistRow(text: $link, isDisabled: isSending)

      if let normalizedURL {
        DraftLinkPreview(url: normalizedURL, isEditing: focusedField.wrappedValue == .link)
          .id(normalizedURL)
      }
    }

    LinkstrInsetSection(title: "note", accessory: "optional") {
      LinkstrNoteEditor(note: $note, isDisabled: isSending, focusedField: focusedField, field: .note)
        .id(Field.note)
    }
  }
}

private struct DraftLinkPreview: View {
  let url: String
  let isEditing: Bool
  @State private var title: String?
  @State private var thumbnail: UIImage?

  private var availability: String? {
    switch URLClassifier.mediaStrategy(for: url) {
    case .directVideo, .extractionPreferred: "viewable in-app. some videos can be saved."
    case .embedOnly: "viewable in-app."
    case .link: nil
    }
  }

  var body: some View {
    let source = LinkstrPostPreview.source(for: url) ?? url
    HStack(spacing: LinkstrTheme.buttonRowSpacing) {
      Rectangle()
        .fill(LinkstrTheme.panelElevated)
        .overlay {
          if let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFill()
          } else {
            Image(systemName: "link").foregroundStyle(LinkstrTheme.textSecondary)
          }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: LinkstrTheme.thumbnailCornerRadius))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(title ?? source)
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
          .lineLimit(2)
        if title != nil {
          Text(source).font(LinkstrTheme.font(.caption)).foregroundStyle(LinkstrTheme.textSecondary)
        }
        if let availability {
          Text(availability).font(LinkstrTheme.font(.caption)).foregroundStyle(LinkstrTheme.accent)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(LinkstrTheme.compactSpacing)
    .linkstrCardSurface()
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .task(id: isEditing) {
      guard !isEditing, let preview = await URLMetadataService.shared.fetchPreview(for: url), !Task.isCancelled else {
        return
      }
      title = LinkstrPostPreview.displayTitle(preview.title, for: url)
      if let path = ManagedLocalFileScope.shared.managedFileURL(fromPath: preview.thumbnailPath)?.path {
        let image = await ThumbnailImageCache.shared.loadImageAsync(at: path, size: .listRow)
        if !Task.isCancelled { thumbnail = image }
      }
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
          LinkstrActionButtonLabel(title: "share to session", systemImage: "paperplane")
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
