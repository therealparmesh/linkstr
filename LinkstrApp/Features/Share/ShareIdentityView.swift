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
            VStack(alignment: .leading, spacing: 10) {
              LinkstrSectionHeader(title: "qr code")
              Text("scan to add this contact key (npub)")
                .font(LinkstrTheme.body(12))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 2)
              Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity, alignment: .center)
            }
          }

          VStack(alignment: .leading, spacing: 10) {
            Text("your contact key (npub)")
              .linkstrPrimarySectionTitleTextStyle()
              .padding(.horizontal, 2)
            Text("others use this key to send links to you or add you as a contact.")
              .font(LinkstrTheme.body(13))
              .foregroundStyle(LinkstrTheme.textSecondary)
            Text(npub)
              .font(LinkstrTheme.body(13))
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
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 28)
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
