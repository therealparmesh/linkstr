import SwiftUI

struct LinkstrContactIdentityView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let identity: LinkstrResolvedIdentity
  var primaryFont: Font = LinkstrTheme.font(.headline, weight: .semibold)
  var secondaryFont: Font = LinkstrTheme.font(.caption)
  var npubFont: Font = LinkstrTheme.font(.caption)
  var primaryColor: Color = LinkstrTheme.textPrimary
  var aliasedNostrNameColor: Color = LinkstrTheme.accentPink
  var npubColor: Color = LinkstrTheme.textSecondary
  var spacing: CGFloat = LinkstrTheme.metaSpacing
  var nameLineLimit: Int = 1
  var keyLineLimit: Int? = 1

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      if identity.showsNPubLine {
        Text(identity.displayName)
          .font(primaryFont)
          .foregroundStyle(primaryColor)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : nameLineLimit)
      }

      if let aliasedNostrName = identity.aliasedChosenName {
        Text(aliasedNostrName)
          .font(secondaryFont)
          .foregroundStyle(aliasedNostrNameColor.opacity(0.88))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : nameLineLimit)
      }

      Text(identity.npub)
        .typesettingLanguage(.init(languageCode: .unavailable))
        .font(identity.showsNPubLine ? npubFont : primaryFont)
        .foregroundStyle(identity.showsNPubLine ? npubColor : primaryColor)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : keyLineLimit)
        .truncationMode(.middle)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }
}
