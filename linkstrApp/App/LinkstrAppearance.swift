import SwiftUI

enum LinkstrTheme {
  static let background = Color(red: 0.09, green: 0.10, blue: 0.16)
  static let chrome = background
  static let mediaButtonBackground = background.opacity(0.56)
  static let panel = Color(red: 0.13, green: 0.15, blue: 0.22)
  static let panelElevated = Color(red: 0.16, green: 0.18, blue: 0.26)
  static let panelMuted = Color(red: 0.11, green: 0.13, blue: 0.20)
  static let separator = textPrimary.opacity(0.06)
  static let accent = Color(red: 0.49, green: 0.67, blue: 0.99)
  static let accentPink = Color(red: 0.72, green: 0.60, blue: 0.93)
  static let amber = Color(red: 0.90, green: 0.74, blue: 0.47)
  static let destructive = Color(red: 0.96, green: 0.42, blue: 0.48)
  static let statusSuccess = Color(red: 0.55, green: 0.79, blue: 0.45)
  static let textPrimary = Color(red: 0.92, green: 0.94, blue: 0.99)
  static let textSecondary = Color(
    red: secondaryTextRGB.red, green: secondaryTextRGB.green, blue: secondaryTextRGB.blue
  )
  static let textTertiary = Color(red: 0.48, green: 0.53, blue: 0.67)

  private static let secondaryTextRGB = (red: 0.66, green: 0.71, blue: 0.84)
  static let secondaryTextCSS =
    "rgb(\(secondaryTextRGB.red * 100)% \(secondaryTextRGB.green * 100)% \(secondaryTextRGB.blue * 100)%)"

  static let sectionStackSpacing: CGFloat = 22
  static let listBlockSpacing: CGFloat = 14
  static let compactSpacing: CGFloat = 8
  static let tightSpacing: CGFloat = 6
  static let metaSpacing: CGFloat = 4
  static let rowSpacing: CGFloat = 12
  static let buttonRowSpacing: CGFloat = 10
  static let listRowVerticalPadding: CGFloat = 10
  static let screenHorizontalPadding: CGFloat = 18
  static let screenTopPadding: CGFloat = 16
  static let pageHeaderTopPadding: CGFloat = 8
  static let pinnedPageContentTopPadding = listBlockSpacing - compactSpacing
  static let screenBottomPadding: CGFloat = 24
  static let panelPadding: CGFloat = 18
  static let toastTopPadding = pageHeaderTopPadding + minimumInteractiveDimension + compactSpacing
  static let fieldHorizontalPadding: CGFloat = 14
  static let fieldVerticalPadding: CGFloat = 12
  static let inputAssistButtonSpacing: CGFloat = 14
  static let inputAssistIconSpacing: CGFloat = 6
  static let inputAssistBottomSpacing: CGFloat = 6
  static let fieldCornerRadius: CGFloat = 14
  static let cardCornerRadius: CGFloat = 20
  static let thumbnailCornerRadius: CGFloat = 10
  static let minimumInteractiveDimension: CGFloat = 44
  static let actionButtonMinHeight: CGFloat = 48
  static let contactAvatarSize: CGFloat = 48
  static let memberAvatarSize: CGFloat = 38
  static let searchClearButtonTextInset = minimumInteractiveDimension - fieldHorizontalPadding
  static let readableContentMaxWidth: CGFloat = 680

  static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
    .system(style, design: .default, weight: weight)
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

struct LinkstrURLText: View {
  let address: String
  var lineLimit: Int?

  var body: some View {
    Text(verbatim: address)
      .font(LinkstrTheme.font(.footnote))
      .foregroundStyle(LinkstrTheme.textSecondary)
      .lineLimit(lineLimit)
      .truncationMode(.middle)
  }
}

extension View {
  func linkstrPageContentLayout(topPadding: CGFloat = LinkstrTheme.screenTopPadding) -> some View {
    padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, topPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
      .linkstrReadableContent()
  }

  func linkstrReadableContent() -> some View {
    frame(maxWidth: LinkstrTheme.readableContentMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
  }

  func linkstrCardSurface(
    fill: Color = LinkstrTheme.panel,
    border: Color = LinkstrTheme.separator
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: LinkstrTheme.cardCornerRadius, style: .continuous)
    return background(fill, in: shape)
      .clipShape(shape)
      .overlay { shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false) }
  }
}
