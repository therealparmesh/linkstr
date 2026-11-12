import SwiftUI
import UIKit

private struct LinkstrFieldChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(
          cornerRadius: LinkstrTheme.fieldCornerRadius,
          style: .continuous
        )
        .fill(LinkstrTheme.panel)
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: LinkstrTheme.fieldCornerRadius,
          style: .continuous
        )
        .stroke(LinkstrTheme.separator.opacity(2), lineWidth: 1)
      }
  }
}

private struct LinkstrInputField: ViewModifier {
  var minHeight: CGFloat? = LinkstrTheme.minimumInteractiveDimension
  var alignment: Alignment = .leading

  func body(content: Content) -> some View {
    content
      .font(LinkstrTheme.font(.subheadline))
      .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
      .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
      .linkstrFieldChrome()
  }
}

private struct LinkstrKeyboardDismissal: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scrollDismissesKeyboard(.immediately)
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()

          Button("done") {
            UIApplication.shared.sendAction(
              #selector(UIResponder.resignFirstResponder),
              to: nil,
              from: nil,
              for: nil
            )
          }
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
          .tint(LinkstrTheme.accent)
        }
      }
  }
}

private struct LinkstrActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  let tint: Color
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: LinkstrTheme.fieldCornerRadius)
    let foreground = prominent ? LinkstrTheme.background : tint
    let fill = prominent ? tint : tint.opacity(0.18)
    return configuration.label
      .font(LinkstrTheme.font(.subheadline, weight: .semibold))
      .foregroundStyle(isEnabled ? foreground : LinkstrTheme.textSecondary)
      .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
      .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
      .frame(minHeight: LinkstrTheme.actionButtonMinHeight)
      .background(isEnabled ? fill : LinkstrTheme.panelElevated, in: shape)
      .contentShape(shape)
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

extension View {
  func linkstrFieldChrome() -> some View {
    modifier(LinkstrFieldChrome())
  }

  func linkstrInputField(
    minHeight: CGFloat? = LinkstrTheme.minimumInteractiveDimension,
    alignment: Alignment = .leading
  ) -> some View {
    modifier(LinkstrInputField(minHeight: minHeight, alignment: alignment))
  }

  func linkstrKeyboardDismissal() -> some View {
    modifier(LinkstrKeyboardDismissal())
  }

  func linkstrPrimaryButton() -> some View {
    buttonStyle(LinkstrActionButtonStyle(tint: LinkstrTheme.accent, prominent: true))
  }

  func linkstrSecondaryButton() -> some View {
    buttonStyle(LinkstrActionButtonStyle(tint: LinkstrTheme.textSecondary))
  }

  func linkstrCautionButton(prominent: Bool = false) -> some View {
    buttonStyle(LinkstrActionButtonStyle(tint: LinkstrTheme.amber, prominent: prominent))
  }

  func linkstrDestructiveButton(prominent: Bool = false) -> some View {
    buttonStyle(LinkstrActionButtonStyle(tint: LinkstrTheme.destructive, prominent: prominent))
  }

  func linkstrPinnedPageHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      header()
        .linkstrPageHeaderLayout()
        .background(LinkstrTheme.chrome)
    }
    .modifier(LinkstrEdgeBackGesture())
  }

  func linkstrBarChrome() -> some View {
    linkstrNavigationBarChrome()
      .toolbarBackground(.visible, for: .tabBar)
      .toolbarBackground(LinkstrTheme.chrome, for: .tabBar)
      .toolbarColorScheme(.dark, for: .tabBar)
  }
}

private struct LinkstrEdgeBackGesture: ViewModifier {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.layoutDirection) private var layoutDirection

  func body(content: Content) -> some View {
    content.overlay(alignment: .leading) {
      Color.clear
        .frame(width: 16)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 18).onEnded { value in
            let direction: CGFloat = layoutDirection == .leftToRight ? 1 : -1
            let horizontal = direction * value.translation.width
            if horizontal >= 55, horizontal > abs(value.translation.height) {
              dismiss()
            }
          }
        )
        .accessibilityHidden(true)
    }
  }
}

struct LinkstrActionButtonLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let title: String
  var systemImage: String?

  var body: some View {
    Group {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }
}

enum LinkstrBrowserAction {
  static let title = "open in browser"
  static let icon = "arrow.up.right.square"
}

struct LinkstrBrowserButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      LinkstrActionButtonLabel(title: LinkstrBrowserAction.title, systemImage: LinkstrBrowserAction.icon)
    }
    .linkstrSecondaryButton()
  }
}

struct LinkstrListRowDivider: View {
  var leadingInset: CGFloat = 74
  var trailingInset: CGFloat = 0

  var body: some View {
    Rectangle()
      .fill(LinkstrTheme.separator)
      .frame(height: 1)
      .padding(.leading, leadingInset)
      .padding(.trailing, trailingInset)
  }
}

struct LinkstrAppIconBadge: View {
  var size: CGFloat = 72

  private var imageSize: CGFloat {
    size - 10
  }

  var body: some View {
    Circle()
      .fill(LinkstrTheme.panelElevated)
      .frame(width: size, height: size)
      .overlay {
        Image("LinkstrSplashIcon")
          .resizable()
          .scaledToFill()
          .frame(width: imageSize, height: imageSize)
          .clipShape(Circle())
      }
      .overlay {
        Circle()
          .stroke(LinkstrTheme.separator.opacity(2), lineWidth: 1)
      }
  }
}

struct LinkstrLoadingStateView: View {
  let title: String

  var body: some View {
    ProgressView {
      Text(title)
        .font(LinkstrTheme.font(.subheadline))
        .foregroundStyle(LinkstrTheme.textSecondary)
    }
    .tint(LinkstrTheme.accent)
    .frame(maxWidth: .infinity, minHeight: 220)
  }
}

struct LinkstrDiagnosticDisclosure: View {
  let details: String

  var body: some View {
    DisclosureGroup("technical details") {
      Text(details)
        .font(LinkstrTheme.font(.footnote))
        .foregroundStyle(LinkstrTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, LinkstrTheme.compactSpacing)
    }
    .font(LinkstrTheme.font(.subheadline, weight: .medium))
    .foregroundStyle(LinkstrTheme.textPrimary)
    .tint(LinkstrTheme.accent)
  }
}
