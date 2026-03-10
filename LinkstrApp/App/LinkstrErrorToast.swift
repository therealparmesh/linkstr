import SwiftUI

struct LinkstrErrorToast: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.circle.fill")
        .font(LinkstrTheme.system(15, weight: .semibold))
        .foregroundStyle(LinkstrTheme.amber)
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
