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
        VStack(alignment: .leading, spacing: 14) {
          if let qrImage = QRCodeGenerator.image(for: npub) {
            VStack(spacing: 10) {
              Image(uiImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)
                .padding(16)
                .background(
                  RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinkstrTheme.panel)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LinkstrTheme.textSecondary.opacity(0.25), lineWidth: 0.8)
                )

              Text("Scan to add this Contact Key (npub)")
                .font(.custom(LinkstrTheme.bodyFont, size: 13))
                .foregroundStyle(LinkstrTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
          }

          LinkstrSectionHeader(title: "Your Contact Key (npub)")
          Text("Others use this key to send links to you or add you as a contact.")
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
            Label("Copy Contact Key (npub)", systemImage: "doc.on.doc")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrPrimaryButtonStyle())
        }
        .padding(12)
      }
      .scrollBounceBehavior(.basedOnSize)
    } else {
      ContentUnavailableView(
        "No Identity",
        systemImage: "person.crop.circle.badge.exclamationmark",
        description: Text("Create an account or sign in with a Secret Key (nsec) in Settings.")
      )
      .padding(.top, 44)
    }
  }
}
