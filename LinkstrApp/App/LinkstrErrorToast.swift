import SwiftUI

struct LinkstrErrorToast: View {
  let message: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(LinkstrTheme.neonAmber)

      Text(message)
        .font(.custom(LinkstrTheme.bodyFont, size: 13))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(LinkstrTheme.panel.opacity(0.96))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.red.opacity(0.35), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
  }
}
