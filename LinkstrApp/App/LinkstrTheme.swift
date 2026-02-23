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
  static let sectionStackSpacing: CGFloat = 26
  static let inputControlMinHeight: CGFloat = 44
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

extension View {
  func linkstrNeonCard() -> some View {
    modifier(LinkstrNeonCard())
  }
}

struct LinkstrSectionHeader: View {
  let title: String

  var body: some View {
    HStack {
      Text(title)
        .font(.custom(LinkstrTheme.titleFont, size: 12))
        .foregroundStyle(LinkstrTheme.textSecondary)
      Spacer()
    }
    .padding(.top, 2)
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

struct LinkstrPeerAvatar: View {
  let name: String
  var size: CGFloat = 42

  var body: some View {
    Circle()
      .fill(LinkstrTheme.neonCyan.opacity(0.9))
      .frame(width: size, height: size)
      .overlay {
        Text(initials(for: name))
          .font(.custom(LinkstrTheme.titleFont, size: max(12, size * 0.38)))
          .foregroundStyle(Color.white)
      }
  }

  private func initials(for name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
    let text = parts.compactMap { $0.first }.map(String.init).joined()
    return text.isEmpty ? "?" : text.uppercased()
  }
}

struct LinkstrListRowDivider: View {
  var body: some View {
    Rectangle()
      .fill(LinkstrTheme.textSecondary.opacity(0.16))
      .frame(height: 1)
  }
}
