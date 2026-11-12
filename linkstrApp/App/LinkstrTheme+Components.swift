import SwiftUI

struct LinkstrInsetSection<Content: View>: View {
  let title: String?
  var accessory: String?
  var footer: String?
  var contentSpacing: CGFloat = LinkstrTheme.buttonRowSpacing
  @ViewBuilder let content: Content

  init(
    title: String? = nil,
    accessory: String? = nil,
    footer: String? = nil,
    contentSpacing: CGFloat = LinkstrTheme.buttonRowSpacing,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.accessory = accessory
    self.footer = footer
    self.contentSpacing = contentSpacing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      if let title {
        let heading = Text(title)
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Group {
          if let accessory, !accessory.isEmpty {
            let detail = Text(accessory)
              .font(LinkstrTheme.font(.caption, weight: .medium))
              .foregroundStyle(LinkstrTheme.textSecondary)
            ViewThatFits(in: .horizontal) {
              HStack(spacing: LinkstrTheme.compactSpacing) {
                heading.fixedSize()
                Spacer(minLength: 0)
                detail.fixedSize()
              }
              VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
                heading
                detail
              }
            }
          } else {
            heading
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: contentSpacing) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let footer, !footer.isEmpty {
        Text(footer)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
  }
}

struct LinkstrSearchField: View {
  let prompt: String
  @Binding var text: String
  var submitLabel: SubmitLabel = .search
  var onSubmit: (() -> Void)?

  var body: some View {
    HStack(spacing: LinkstrTheme.compactSpacing) {
      Image(systemName: "magnifyingglass")
        .font(LinkstrTheme.font(.footnote, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)
        .accessibilityHidden(true)

      TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(LinkstrTheme.textSecondary.opacity(0.85)))
        .accessibilityLabel(prompt)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .submitLabel(submitLabel)
        .padding(.trailing, text.isEmpty ? 0 : LinkstrTheme.searchClearButtonTextInset)
        .onSubmit {
          onSubmit?()
        }
    }
    .linkstrInputField()
    .overlay(alignment: .trailing) {
      Button {
        text = ""
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textTertiary)
          .frame(
            width: LinkstrTheme.minimumInteractiveDimension,
            height: LinkstrTheme.minimumInteractiveDimension
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(text.isEmpty ? 0 : 1)
      .allowsHitTesting(!text.isEmpty)
      .accessibilityHidden(text.isEmpty)
      .accessibilityLabel("clear search")
    }
  }
}

struct LinkstrInputAssistRow: View {
  let showClear: Bool
  var showScan = true
  var isDisabled = false
  let onPaste: () -> Void
  var onScan: (() -> Void)?
  let onClear: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: LinkstrTheme.inputAssistButtonSpacing) {
        actions
      }
      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        actions
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, LinkstrTheme.inputAssistBottomSpacing)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.65 : 1)
    .controlSize(.small)
  }

  @ViewBuilder
  private var actions: some View {
    assistButton("paste", systemImage: "doc.on.clipboard", action: onPaste)

    if showScan, let onScan {
      assistButton("scan", systemImage: "qrcode.viewfinder", action: onScan)
    }

    if showClear {
      assistButton(
        "clear",
        systemImage: "xmark.circle",
        tint: LinkstrTheme.destructive.opacity(0.9),
        action: onClear
      )
    }
  }

  private func assistButton(
    _ title: String,
    systemImage: String,
    tint: Color = LinkstrTheme.textSecondary,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: LinkstrTheme.inputAssistIconSpacing) {
        Image(systemName: systemImage)
          .dynamicTypeSize(...DynamicTypeSize.xxLarge)
          .accessibilityHidden(true)
        Text(title)
      }
      .font(LinkstrTheme.font(.footnote, weight: .medium))
      .foregroundStyle(tint)
      .frame(minWidth: LinkstrTheme.minimumInteractiveDimension)
      .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct LinkstrSheetStatusFooter: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let message: String
  var messageColor: Color = LinkstrTheme.textSecondary

  var body: some View {
    Text(message)
      .font(LinkstrTheme.font(.caption))
      .foregroundStyle(messageColor)
      .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
      .multilineTextAlignment(.center)
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.fieldVerticalPadding)
      .padding(.bottom, LinkstrTheme.fieldVerticalPadding)
      .background(LinkstrTheme.chrome)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)
      }
      .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: message)
  }
}

struct LinkstrSheetFooterStatus {
  let message: String
  let color: Color
}

struct LinkstrSheetMutationFeedback {
  private(set) var errorMessage: String?

  mutating func clear() {
    errorMessage = nil
  }

  mutating func record(errorMessage: String?) {
    let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.errorMessage = trimmed.isEmpty ? nil : trimmed
  }

  func footerStatus(
    isRunning: Bool,
    progressMessage: String,
    validationMessage: String? = nil,
    validationColor: Color = LinkstrTheme.textSecondary
  ) -> LinkstrSheetFooterStatus? {
    if isRunning {
      return LinkstrSheetFooterStatus(
        message: progressMessage,
        color: LinkstrTheme.textSecondary
      )
    }

    if let errorMessage {
      return LinkstrSheetFooterStatus(
        message: errorMessage,
        color: LinkstrTheme.destructive.opacity(0.9)
      )
    }

    guard let validationMessage, !validationMessage.isEmpty else { return nil }
    return LinkstrSheetFooterStatus(message: validationMessage, color: validationColor)
  }
}

struct LinkstrCenteredEmptyStateView: View {
  let title: String
  let systemImage: String?
  let description: String
  var actionTitle: String?
  var actionSystemImage: String?
  var action: (() -> Void)?

  init(
    title: String,
    systemImage: String?,
    description: String,
    actionTitle: String? = nil,
    actionSystemImage: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.description = description
    self.actionTitle = actionTitle
    self.actionSystemImage = actionSystemImage
    self.action = action
  }

  var body: some View {
    VStack(spacing: LinkstrTheme.rowSpacing) {
      if let systemImage {
        Circle()
          .fill(LinkstrTheme.panelElevated)
          .frame(width: 60, height: 60)
          .overlay {
            Image(systemName: systemImage)
              .font(LinkstrTheme.font(.title2, weight: .semibold))
              .foregroundStyle(LinkstrTheme.accent)
          }
          .accessibilityHidden(true)
      }
      Text(title)
        .font(LinkstrTheme.font(.headline, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .multilineTextAlignment(.center)

      Text(description)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)

      if let actionTitle, let action {
        Button(action: action) {
          LinkstrActionButtonLabel(title: actionTitle, systemImage: actionSystemImage)
        }
        .linkstrPrimaryButton()
        .frame(maxWidth: 280)
        .padding(.top, LinkstrTheme.metaSpacing)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.horizontal, 24)
  }
}

struct LinkstrReadOnlyBanner: View {
  var message: String = "you're no longer a member. this session is read-only."

  var body: some View {
    HStack(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing) {
      Image(systemName: "person.crop.circle.badge.xmark")
        .font(LinkstrTheme.font(.footnote, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textSecondary)

      Text(message)
        .font(LinkstrTheme.font(.caption))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
    .background(
      RoundedRectangle(
        cornerRadius: LinkstrTheme.fieldCornerRadius,
        style: .continuous
      )
      .fill(LinkstrTheme.panelMuted)
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: LinkstrTheme.fieldCornerRadius,
        style: .continuous
      )
      .stroke(LinkstrTheme.separator.opacity(2), lineWidth: 1)
    }
  }
}

enum LinkstrAvatarStyleResolver {
  static func contactInitials(for name: String) -> String {
    let parts =
      name
      .split(whereSeparator: \.isWhitespace)
      .filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }

    guard let firstPart = parts.first else { return "?" }
    if parts.count == 1 {
      let singleWordInitials = String(firstPart.prefix(2))
      return singleWordInitials.isEmpty ? "?" : singleWordInitials.uppercased()
    }

    let lastPart = parts[parts.count - 1]
    let combined = String(firstPart.prefix(1)) + String(lastPart.prefix(1))
    return combined.isEmpty ? "?" : combined.uppercased()
  }

  static func colorIndex(for seed: String, paletteSize: Int) -> Int {
    Int(stableHash(for: seed) % UInt64(paletteSize))
  }

  private static func stableHash(for seed: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for scalar in seed.unicodeScalars {
      hash ^= UInt64(scalar.value)
      hash &*= 1_099_511_628_211
    }
    return hash
  }
}

struct LinkstrContactAvatar: View {
  let name: String
  var size: CGFloat = 42
  var seed: String?

  var body: some View {
    Circle()
      .fill(avatarColor)
      .frame(width: size, height: size)
      .overlay {
        Text(String(LinkstrAvatarStyleResolver.contactInitials(for: name).prefix(size < 32 ? 1 : 2)))
          .font(.system(size: size * 0.32, weight: .semibold))
          .foregroundStyle(LinkstrTheme.background)
          .lineLimit(1)
      }
      .accessibilityHidden(true)
  }

  private var avatarColor: Color {
    let colors = [LinkstrTheme.accent, LinkstrTheme.accentPink, LinkstrTheme.textSecondary]
    return colors[LinkstrAvatarStyleResolver.colorIndex(for: seed ?? name, paletteSize: colors.count)]
  }
}
