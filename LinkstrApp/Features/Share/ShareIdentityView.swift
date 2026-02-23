import SwiftUI
import UIKit

struct ShareIdentityView: View {
  @EnvironmentObject private var session: AppSession

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var content: some View {
    if let npub = session.identityService.npub {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          if let qrImage = QRCodeGenerator.image(for: npub) {
            VStack(spacing: 10) {
              Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)

              Text("scan to add this contact key (npub)")
                .font(.custom(LinkstrTheme.bodyFont, size: 13))
                .foregroundStyle(LinkstrTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
          }

          VStack(alignment: .leading, spacing: 10) {
            LinkstrSectionHeader(title: "your contact key (npub)")
            Text("others use this key to send links to you or add you as a contact.")
              .font(.custom(LinkstrTheme.bodyFont, size: 13))
              .foregroundStyle(LinkstrTheme.textSecondary)
            Text(npub)
              .font(.custom(LinkstrTheme.bodyFont, size: 13))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .textSelection(.enabled)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )

            Button {
              UIPasteboard.general.string = npub
            } label: {
              Label("copy contact key (npub)", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LinkstrTheme.neonCyan)
          }
        }
        .padding(12)
      }
      .scrollBounceBehavior(.basedOnSize)
      .linkstrTabBarContentInset()
    } else {
      LinkstrCenteredEmptyStateView(
        title: "no identity",
        systemImage: "person.crop.circle.badge.exclamationmark",
        description: "create an account or sign in with a secret key (nsec) in settings."
      )
    }
  }
}
