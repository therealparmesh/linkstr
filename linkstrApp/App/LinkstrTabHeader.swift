import SwiftUI

struct LinkstrTabHeader<Actions: View>: View {
  let title: String
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("linkstr")
        .font(LinkstrTheme.font(.headline, weight: .bold))
        .foregroundStyle(LinkstrTheme.accentPink)
        .accessibilityHidden(true)

      HStack(spacing: 6) {
        LinkstrScreenTitle(title: title)
        actions
      }
    }
  }
}

struct LinkstrHeaderButton: View {
  let title: String
  let icon: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(LinkstrTheme.font(.title3, weight: .semibold))
        .foregroundStyle(LinkstrTheme.accent)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}
