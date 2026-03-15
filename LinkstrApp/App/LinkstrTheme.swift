import SwiftUI

enum LinkstrTheme {
  static let background = Color(red: 0.09, green: 0.10, blue: 0.16)
  static let chrome = background
  static let panel = Color(red: 0.13, green: 0.15, blue: 0.22)
  static let panelElevated = Color(red: 0.16, green: 0.18, blue: 0.26)
  static let panelMuted = Color(red: 0.11, green: 0.13, blue: 0.20)
  static let separator = Color.white.opacity(0.06)
  static let accent = Color(red: 0.49, green: 0.67, blue: 0.99)
  static let accentSoft = Color(red: 0.31, green: 0.44, blue: 0.67)
  static let accentPink = Color(red: 0.72, green: 0.60, blue: 0.93)
  static let amber = Color(red: 0.90, green: 0.74, blue: 0.47)
  static let destructive = Color(red: 0.96, green: 0.42, blue: 0.48)
  static let statusSuccess = Color(red: 0.55, green: 0.79, blue: 0.45)
  static let textPrimary = Color(red: 0.92, green: 0.94, blue: 0.99)
  static let textSecondary = Color(red: 0.66, green: 0.71, blue: 0.84)
  static let textTertiary = Color(red: 0.48, green: 0.53, blue: 0.67)

  static let sectionStackSpacing: CGFloat = 18
  static let listBlockSpacing: CGFloat = 14
  static let compactSpacing: CGFloat = 8
  static let metaSpacing: CGFloat = 4
  static let rowSpacing: CGFloat = 12
  static let buttonRowSpacing: CGFloat = 10
  static let listRowVerticalPadding: CGFloat = 10
  static let inputControlMinHeight: CGFloat = 44
  static let tabBarContentBottomInset: CGFloat = 92
  static let screenHorizontalPadding: CGFloat = 16
  static let screenTopPadding: CGFloat = 16
  static let screenBottomPadding: CGFloat = 24
  static let sheetBottomPadding: CGFloat = 120
  static let panelPadding: CGFloat = 18
  static let toastTopPadding: CGFloat = 10
  static let fieldHorizontalPadding: CGFloat = 14
  static let fieldVerticalPadding: CGFloat = 12
  static let inputAssistButtonSpacing: CGFloat = 14
  static let inputAssistIconSpacing: CGFloat = 6
  static let inputAssistBottomSpacing: CGFloat = 6
  static let actionButtonLabelSpacing: CGFloat = 8
  static let actionButtonIconWidth: CGFloat = 18
  static let fieldCornerRadius: CGFloat = 12

  static func title(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight)
  }

  static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }

  static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
}

struct LinkstrBackgroundView: View {
  var body: some View {
    Rectangle()
      .fill(LinkstrTheme.background)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
  }
}

private struct LinkstrSurfaceCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)
      }
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(LinkstrTheme.separator)
          .frame(height: 1)
      }
  }
}

private struct LinkstrFieldChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
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
        .stroke(LinkstrTheme.separator.opacity(1.4), lineWidth: 1)
      }
  }
}

private struct LinkstrInputField: ViewModifier {
  var minHeight: CGFloat? = LinkstrTheme.inputControlMinHeight
  var alignment: Alignment = .leading

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
      .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
      .linkstrFieldChrome()
  }
}

private enum LinkstrActionButtonTone {
  case primary
  case secondary
  case caution
  case cautionProminent
  case destructive
  case destructiveProminent
}

private struct LinkstrActionButtonChrome: ViewModifier {
  let tone: LinkstrActionButtonTone

  func body(content: Content) -> some View {
    switch tone {
    case .primary:
      content
        .font(LinkstrTheme.body(15, weight: .semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.accent)
    case .secondary:
      content
        .font(LinkstrTheme.body(15, weight: .semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.textSecondary)
    case .caution:
      content
        .font(LinkstrTheme.body(15, weight: .semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.amber)
    case .cautionProminent:
      content
        .font(LinkstrTheme.body(15, weight: .semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.amber)
    case .destructive:
      content
        .font(LinkstrTheme.body(15, weight: .semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.destructive)
    case .destructiveProminent:
      content
        .font(LinkstrTheme.body(15, weight: .semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: LinkstrTheme.fieldCornerRadius))
        .tint(LinkstrTheme.destructive)
    }
  }
}

extension View {
  func linkstrSurfaceCard() -> some View {
    modifier(LinkstrSurfaceCard())
  }

  func linkstrFieldChrome() -> some View {
    modifier(LinkstrFieldChrome())
  }

  func linkstrInputField(
    minHeight: CGFloat? = LinkstrTheme.inputControlMinHeight,
    alignment: Alignment = .leading
  ) -> some View {
    modifier(LinkstrInputField(minHeight: minHeight, alignment: alignment))
  }

  func linkstrPrimaryButton() -> some View {
    modifier(LinkstrActionButtonChrome(tone: .primary))
  }

  func linkstrSecondaryButton() -> some View {
    modifier(LinkstrActionButtonChrome(tone: .secondary))
  }

  func linkstrCautionButton(prominent: Bool = false) -> some View {
    modifier(LinkstrActionButtonChrome(tone: prominent ? .cautionProminent : .caution))
  }

  func linkstrDestructiveButton(prominent: Bool = false) -> some View {
    modifier(LinkstrActionButtonChrome(tone: prominent ? .destructiveProminent : .destructive))
  }

  func linkstrTabBarContentInset() -> some View {
    safeAreaInset(edge: .bottom) {
      Color.clear
        .frame(height: LinkstrTheme.tabBarContentBottomInset)
    }
  }

  func linkstrToolbarIconLabel() -> some View {
    font(LinkstrTheme.system(17, weight: .semibold))
      .frame(width: 30, height: 30, alignment: .center)
  }

  func linkstrBarChrome() -> some View {
    toolbarBackground(.visible, for: .navigationBar)
      .toolbarBackground(.visible, for: .tabBar)
      .toolbarBackground(LinkstrTheme.chrome.opacity(0.88), for: .navigationBar)
      .toolbarBackground(LinkstrTheme.chrome.opacity(0.88), for: .tabBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .tabBar)
  }
}

struct LinkstrActionButtonLabel: View {
  let title: String
  var systemImage: String? = nil

  var body: some View {
    if let systemImage {
      HStack(spacing: LinkstrTheme.actionButtonLabelSpacing) {
        Image(systemName: systemImage)
          .frame(width: LinkstrTheme.actionButtonIconWidth, alignment: .center)

        Text(title)
          .lineLimit(2)
          .multilineTextAlignment(.center)

        Color.clear
          .frame(width: LinkstrTheme.actionButtonIconWidth, height: 1)
      }
      .frame(maxWidth: .infinity)
    } else {
      Text(title)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
  }
}

struct LinkstrInsetSection<Content: View>: View {
  let title: String?
  var accessory: String? = nil
  var footer: String? = nil
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
            .font(LinkstrTheme.body(11, weight: .medium))
            .foregroundStyle(LinkstrTheme.textSecondary)

          Spacer(minLength: 0)

          if let accessory, !accessory.isEmpty {
            Text(accessory)
              .font(LinkstrTheme.body(11, weight: .medium))
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
          .font(LinkstrTheme.body(12))
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
  var onSubmit: (() -> Void)? = nil
  private let clearButtonSize: CGFloat = 18

  var body: some View {
    HStack(spacing: LinkstrTheme.compactSpacing) {
      Image(systemName: "magnifyingglass")
        .font(LinkstrTheme.system(13, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)

      TextField(prompt, text: $text)
        .font(LinkstrTheme.body(13))
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
          .font(LinkstrTheme.system(13))
          .foregroundStyle(LinkstrTheme.textTertiary)
          .frame(width: clearButtonSize, height: clearButtonSize)
      }
      .buttonStyle(.plain)
      .opacity(text.isEmpty ? 0 : 1)
      .allowsHitTesting(!text.isEmpty)
      .accessibilityHidden(text.isEmpty)
    }
    .linkstrInputField()
  }
}

struct LinkstrInputAssistRow: View {
  let showClear: Bool
  var showScan = true
  var isDisabled = false
  let onPaste: () -> Void
  var onScan: (() -> Void)? = nil
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
      .font(LinkstrTheme.body(12))
      .foregroundStyle(tint)
    }
    .buttonStyle(.plain)
  }
}

struct LinkstrSheetActionFooter: View {
  let title: String
  let systemImage: String
  let isDisabled: Bool
  let message: String?
  var messageColor: Color = LinkstrTheme.textSecondary
  let action: () -> Void

  var body: some View {
    VStack(spacing: LinkstrTheme.buttonRowSpacing) {
      Button(action: action) {
        LinkstrActionButtonLabel(title: title, systemImage: systemImage)
      }
      .linkstrPrimaryButton()
      .disabled(isDisabled)

      Text(message ?? " ")
        .font(LinkstrTheme.body(12))
        .foregroundStyle(messageColor)
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
        .opacity((message ?? "").isEmpty ? 0 : 1)
        .accessibilityHidden((message ?? "").isEmpty)
    }
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .padding(.top, LinkstrTheme.fieldVerticalPadding)
    .padding(.bottom, LinkstrTheme.fieldVerticalPadding)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(LinkstrTheme.separator)
        .frame(height: 1)
    }
  }
}

struct LinkstrCenteredEmptyStateView: View {
  let title: String
  let systemImage: String
  let description: String

  var body: some View {
    VStack(spacing: 12) {
      Circle()
        .fill(LinkstrTheme.panelElevated)
        .frame(width: 60, height: 60)
        .overlay {
          Image(systemName: systemImage)
            .font(LinkstrTheme.system(22, weight: .semibold))
            .foregroundStyle(LinkstrTheme.accent)
        }

      Text(title)
        .font(LinkstrTheme.title(17))
        .foregroundStyle(LinkstrTheme.textPrimary)

      Text(description)
        .font(LinkstrTheme.body(13))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.horizontal, 24)
  }
}

struct LinkstrAppIconBadge: View {
  var size: CGFloat = 72

  private var imageSize: CGFloat {
    size - 10
  }

  var body: some View {
    Circle()
      .fill(LinkstrTheme.panelElevated)
      .frame(width: size, height: size)
      .overlay {
        Image("LinkstrSplashIcon")
          .resizable()
          .scaledToFill()
          .frame(width: imageSize, height: imageSize)
          .clipShape(Circle())
      }
      .overlay {
        Circle()
          .stroke(LinkstrTheme.separator.opacity(1.4), lineWidth: 1)
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
    Color(red: 0.88, green: 0.52, blue: 0.63),
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
          .font(LinkstrTheme.body(max(12, size * 0.34), weight: .semibold))
          .foregroundStyle(Color.white)
      }
      .overlay {
        Circle()
          .stroke(Color.white.opacity(0.1), lineWidth: 1)
      }
  }
}

struct LinkstrSessionAvatar: View {
  let seed: String
  var size: CGFloat = 42

  var body: some View {
    Circle()
      .fill(LinkstrAvatarStyleResolver.sessionColor(for: seed))
      .frame(width: size, height: size)
      .overlay {
        Circle()
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
      }
  }
}

struct LinkstrListRowDivider: View {
  var leadingInset: CGFloat = 74
  var trailingInset: CGFloat = 0

  var body: some View {
    Rectangle()
      .fill(LinkstrTheme.separator)
      .frame(height: 1)
      .padding(.leading, leadingInset)
      .padding(.trailing, trailingInset)
  }
}
