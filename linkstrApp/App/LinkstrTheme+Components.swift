import SwiftUI

struct LinkstrInsetSection<Content: View>: View {
  let title: String?
  var accessory: String?
  var footer: String?
  var contentSpacing: CGFloat = 10
  @ViewBuilder let content: Content

  init(
    title: String? = nil,
    accessory: String? = nil,
    footer: String? = nil,
    contentSpacing: CGFloat = 10,
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
        HStack(alignment: .center, spacing: LinkstrTheme.compactSpacing) {
          Text(title)
            .font(LinkstrTheme.font(.caption, weight: .medium))
            .foregroundStyle(LinkstrTheme.textSecondary)

          Spacer(minLength: 0)

          if let accessory, !accessory.isEmpty {
            Text(accessory)
              .font(LinkstrTheme.font(.caption, weight: .medium))
              .foregroundStyle(LinkstrTheme.textTertiary)
          }
        }
        .padding(.horizontal, 2)
      }

      VStack(alignment: .leading, spacing: contentSpacing) {
        content
      }
      .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
      .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)

      if let footer, !footer.isEmpty {
        Text(footer)
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .padding(.horizontal, 2)
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

      TextField(prompt, text: $text)
        .font(LinkstrTheme.font(.footnote))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .submitLabel(submitLabel)
        .onSubmit {
          onSubmit?()
        }

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
    .linkstrInputField()
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
    HStack(spacing: LinkstrTheme.inputAssistButtonSpacing) {
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, LinkstrTheme.inputAssistBottomSpacing)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.65 : 1)
    .controlSize(.small)
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
        Text(title)
      }
      .font(LinkstrTheme.font(.caption))
      .foregroundStyle(tint)
      .frame(minWidth: LinkstrTheme.minimumInteractiveDimension)
      .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct LinkstrSheetStatusFooter: View {
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
      .background(.ultraThinMaterial)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .animation(.easeInOut(duration: 0.2), value: message)
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
  let systemImage: String
  let description: String
  var actionTitle: String?
  var actionSystemImage: String?
  var action: (() -> Void)?

  init(
    title: String,
    systemImage: String,
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
    VStack(spacing: 12) {
      Circle()
        .fill(LinkstrTheme.panelElevated)
        .frame(width: 60, height: 60)
        .overlay {
          Image(systemName: systemImage)
            .font(LinkstrTheme.font(.title2, weight: .semibold))
            .foregroundStyle(LinkstrTheme.accent)
        }

      Text(title)
        .font(LinkstrTheme.font(.headline, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textPrimary)

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

struct LinkstrScreenTitle: View {
  let title: String

  var body: some View {
    Text(title)
      .font(LinkstrTheme.font(.largeTitle, weight: .bold))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct LinkstrReadOnlyBanner: View {
  var message: String = "you're no longer a member. this session is read-only."

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
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
    .padding(.vertical, 10)
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
  private static let sessionPalette: [Color] = [
    Color(red: 0.47, green: 0.63, blue: 0.98),
    Color(red: 0.45, green: 0.75, blue: 0.79),
    Color(red: 0.89, green: 0.70, blue: 0.44),
    Color(red: 0.74, green: 0.57, blue: 0.91),
    Color(red: 0.56, green: 0.79, blue: 0.50),
    Color(red: 0.88, green: 0.52, blue: 0.63)
  ]

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

  static func sessionColor(for seed: String) -> Color {
    sessionPalette[sessionColorIndex(for: seed)]
  }

  static func sessionColorIndex(for seed: String) -> Int {
    guard sessionPalette.isEmpty == false else { return 0 }
    return Int(stableHash(for: seed) % UInt64(sessionPalette.count))
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

  var body: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [LinkstrTheme.accent, LinkstrTheme.accentSoft],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .frame(width: size, height: size)
      .overlay {
        Text(LinkstrAvatarStyleResolver.contactInitials(for: name))
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
          .foregroundStyle(Color.white)
      }
      .overlay {
        Circle()
          .stroke(Color.white.opacity(0.1), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }
}
