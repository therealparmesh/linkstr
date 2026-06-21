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

  static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }

  static func title(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    font(size, weight: weight)
  }

  static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    font(size, weight: weight)
  }

  static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    font(size, weight: weight)
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
        .stroke(LinkstrTheme.separator.opacity(2), lineWidth: 1)
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
    toolbarBackground(.hidden, for: .navigationBar)
      .toolbarBackground(.visible, for: .tabBar)
      .toolbarBackground(LinkstrTheme.chrome.opacity(0.88), for: .tabBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .tabBar)
  }
}

struct LinkstrActionButtonLabel: View {
  let title: String
  var systemImage: String?

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
      .accessibilityLabel("session avatar")
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
