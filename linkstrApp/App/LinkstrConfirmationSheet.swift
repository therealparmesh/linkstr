import SwiftUI

struct LinkstrConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  let message: String
  var actionTitle: String?
  var isDestructive = true
  var dismissOnConfirm = true
  let onConfirm: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      LinkstrSheetHeader(title: title, closeLabel: "cancel", close: cancel)
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          Text(message)
            .font(LinkstrTheme.font(.subheadline))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if isDestructive {
            confirmationButton.linkstrDestructiveButton()
          } else {
            confirmationButton.linkstrPrimaryButton()
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.vertical, LinkstrTheme.screenTopPadding)
        .linkstrReadableContent()
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .background(LinkstrBackgroundView())
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .accessibilityAction(.escape, cancel)
  }

  private var confirmationButton: some View {
    Button(role: isDestructive ? .destructive : nil) {
      onConfirm()
      if dismissOnConfirm { dismiss() }
    } label: {
      LinkstrActionButtonLabel(title: actionTitle ?? title)
    }
  }

  private func cancel() {
    dismiss()
  }
}
