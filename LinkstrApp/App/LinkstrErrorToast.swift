import SwiftUI

struct LinkstrErrorToast: View {
  let message: String
  var isSuccess: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(LinkstrTheme.system(15, weight: .semibold))
        .foregroundStyle(isSuccess ? LinkstrTheme.statusSuccess : LinkstrTheme.amber)
        .padding(.top, 1)

      Text(message)
        .font(LinkstrTheme.body(14))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(LinkstrTheme.separator, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
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
