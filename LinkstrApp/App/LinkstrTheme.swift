import SwiftUI

enum LinkstrTheme {
  static let bgTop = Color(red: 0.10, green: 0.11, blue: 0.15)
  static let bgBottom = Color(red: 0.07, green: 0.08, blue: 0.12)
  static let panel = Color(red: 0.15, green: 0.17, blue: 0.24)
  static let panelSoft = Color(red: 0.19, green: 0.21, blue: 0.30)
  static let neonCyan = Color(red: 0.48, green: 0.64, blue: 0.97)
  static let neonPink = Color(red: 0.73, green: 0.60, blue: 0.97)
  static let neonAmber = Color(red: 0.88, green: 0.69, blue: 0.41)
  static let destructive = Color(red: 0.97, green: 0.46, blue: 0.56)
  static let statusSuccess = Color(red: 0.62, green: 0.81, blue: 0.42)
  static let textPrimary = Color(red: 0.75, green: 0.79, blue: 0.96)
  static let textSecondary = Color(red: 0.60, green: 0.65, blue: 0.81)

  static let titleFont = "HelveticaNeue-Medium"
  static let bodyFont = "HelveticaNeue"
  static let textScaleDelta: CGFloat = 1
  static let sectionStackSpacing: CGFloat = 26
  static let inputControlMinHeight: CGFloat = 44
  static let tabBarContentBottomInset: CGFloat = 96

  static func scaledTextSize(_ base: CGFloat) -> CGFloat {
    base + textScaleDelta
  }

  static func title(_ size: CGFloat) -> Font {
    .custom(titleFont, size: scaledTextSize(size))
  }

  static func body(_ size: CGFloat) -> Font {
    .custom(bodyFont, size: scaledTextSize(size))
  }

  static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: scaledTextSize(size), weight: weight)
  }
}

struct LinkstrBackgroundView: View {
  var body: some View {
    ZStack {
      Rectangle()
        .fill(
          LinearGradient(
            colors: [LinkstrTheme.bgTop, LinkstrTheme.bgBottom],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      RadialGradient(
        colors: [LinkstrTheme.neonCyan.opacity(0.12), .clear],
        center: .topTrailing,
        startRadius: 8,
        endRadius: 360
      )
      RadialGradient(
        colors: [LinkstrTheme.neonPink.opacity(0.08), .clear],
        center: .bottomLeading,
        startRadius: 8,
        endRadius: 360
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
  }
}

struct LinkstrNeonCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(LinkstrTheme.panel)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            LinkstrTheme.textSecondary.opacity(0.25),
            lineWidth: 0.8
          )
      )
      .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
  }
}

private struct LinkstrPrimarySectionTitleTextStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(LinkstrTheme.title(14))
      .foregroundStyle(LinkstrTheme.textPrimary)
  }
}

extension View {
  func linkstrNeonCard() -> some View {
    modifier(LinkstrNeonCard())
  }

  func linkstrPrimarySectionTitleTextStyle() -> some View {
    modifier(LinkstrPrimarySectionTitleTextStyle())
  }

  func linkstrTabBarContentInset() -> some View {
    safeAreaInset(edge: .bottom) {
      Color.clear
        .frame(height: LinkstrTheme.tabBarContentBottomInset)
    }
  }

  func linkstrToolbarIconLabel() -> some View {
    font(LinkstrTheme.system(16, weight: .semibold))
      .frame(width: 28, height: 28, alignment: .center)
  }
}

struct LinkstrSectionHeader: View {
  let title: String

  var body: some View {
    HStack {
      Text(title)
        .font(LinkstrTheme.title(12))
        .foregroundStyle(LinkstrTheme.textSecondary)
      Spacer()
    }
    .padding(.top, 2)
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
    VStack(spacing: 8) {
      Button(action: action) {
        Label(title, systemImage: systemImage)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(LinkstrTheme.neonCyan)
      .disabled(isDisabled)

      Text(message ?? " ")
        .font(LinkstrTheme.body(12))
        .foregroundStyle(messageColor)
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
        .opacity((message ?? "").isEmpty ? 0 : 1)
        .accessibilityHidden((message ?? "").isEmpty)
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Divider()
        .overlay(LinkstrTheme.textSecondary.opacity(0.18))
    }
  }
}

struct LinkstrCenteredEmptyStateView: View {
  let title: String
  let systemImage: String
  let description: String

  var body: some View {
    ContentUnavailableView(
      title,
      systemImage: systemImage,
      description: Text(description)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .padding(.horizontal, 24)
  }
}

enum LinkstrAvatarStyleResolver {
  private static let sessionPalette: [Color] = [
    Color(red: 0.48, green: 0.64, blue: 0.97),
    Color(red: 0.73, green: 0.60, blue: 0.97),
    Color(red: 0.88, green: 0.69, blue: 0.41),
    Color(red: 0.62, green: 0.81, blue: 0.42),
    Color(red: 0.38, green: 0.78, blue: 0.72),
    Color(red: 0.91, green: 0.51, blue: 0.66),
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
      .fill(LinkstrTheme.neonCyan.opacity(0.9))
      .frame(width: size, height: size)
      .overlay {
        Text(LinkstrAvatarStyleResolver.contactInitials(for: name))
          .font(LinkstrTheme.title(max(12, size * 0.38)))
          .foregroundStyle(Color.white)
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
          .stroke(Color.white.opacity(0.16), lineWidth: 1)
      }
  }
}

struct LinkstrListRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(LinkstrTheme.textSecondary.opacity(0.16))
      .frame(height: 1)
  }
}
