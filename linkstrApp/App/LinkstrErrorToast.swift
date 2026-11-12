import SwiftUI

struct LinkstrErrorToast: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let message: String
  var isSuccess: Bool = false
  var opensRelaySettings: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing) {
      Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .foregroundStyle(isSuccess ? LinkstrTheme.statusSuccess : LinkstrTheme.amber)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(message)
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)

        if opensRelaySettings {
          Text("open relay settings")
            .font(LinkstrTheme.font(.footnote, weight: .semibold))
            .foregroundStyle(LinkstrTheme.accent)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !opensRelaySettings {
        Image(systemName: "xmark")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .dynamicTypeSize(...DynamicTypeSize.xLarge)
          .foregroundStyle(LinkstrTheme.textSecondary)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
    .linkstrCardSurface(fill: LinkstrTheme.panelElevated)
    .shadow(color: LinkstrTheme.background.opacity(0.32), radius: 18, y: 8)
  }
}

extension Notification.Name {
  static let linkstrSuccessToast = Notification.Name("linkstrSuccessToast")
}

enum LinkstrToast {
  @MainActor
  static func showSuccess(_ message: String) {
    NotificationCenter.default.post(name: .linkstrSuccessToast, object: message)
  }
}
