import SwiftUI

struct LinkstrContactIdentityView: View {
  let identity: LinkstrResolvedIdentity
  var primaryFont: Font = LinkstrTheme.title(16)
  var secondaryFont: Font = LinkstrTheme.body(12)
  var npubFont: Font = LinkstrTheme.body(12)
  var primaryColor: Color = LinkstrTheme.textPrimary
  var aliasedNostrNameColor: Color = LinkstrTheme.accentPink
  var npubColor: Color = LinkstrTheme.textSecondary
  var spacing: CGFloat = LinkstrTheme.metaSpacing
  var lineLimit: Int = 1

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      Text(identity.displayName)
        .font(primaryFont)
        .foregroundStyle(primaryColor)
        .lineLimit(lineLimit)

      if let aliasedNostrName = identity.aliasedChosenName {
        Text(aliasedNostrName)
          .font(secondaryFont)
          .foregroundStyle(aliasedNostrNameColor.opacity(0.88))
          .lineLimit(lineLimit)
      }

      if identity.showsNPubLine {
        Text(identity.npub)
          .font(npubFont)
          .foregroundStyle(npubColor)
          .lineLimit(lineLimit)
      }
    }
  }
}
