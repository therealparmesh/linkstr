import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct OnboardingView: View {
  @EnvironmentObject private var session: AppSession
  @State private var secretKey = ""
  private let formRowSpacing: CGFloat = 12

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Text("welcome to linkstr.")
              .font(LinkstrTheme.title(36))
              .foregroundStyle(LinkstrTheme.textPrimary)
            Text("share videos and links privately with people who don’t use social media.")
              .font(LinkstrTheme.body(14))
              .foregroundStyle(LinkstrTheme.textSecondary)

            VStack(alignment: .leading, spacing: formRowSpacing) {
              LinkstrSectionHeader(title: "sign in")
              TextField("secret key (nsec...)", text: $secretKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(12)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )

              LinkstrInputAssistRow(
                showClear: !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showScan: false,
                onPaste: {
                  pasteSecretKeyFromClipboard()
                },
                onClear: {
                  secretKey = ""
                }
              )

              Button {
                session.importNsec(secretKey)
              } label: {
                Label("sign in with secret key (nsec)", systemImage: "arrow.right.circle.fill")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .tint(LinkstrTheme.neonCyan)
              .disabled(secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

              HStack(spacing: 10) {
                Rectangle()
                  .fill(LinkstrTheme.textSecondary.opacity(0.26))
                  .frame(height: 1)
                Text("or")
                  .font(LinkstrTheme.title(13))
                  .foregroundStyle(LinkstrTheme.textSecondary)
                Rectangle()
                  .fill(LinkstrTheme.textSecondary.opacity(0.26))
                  .frame(height: 1)
              }
              .padding(.vertical, LinkstrTheme.sectionStackSpacing - formRowSpacing)

              LinkstrSectionHeader(title: "create account")
              Button {
                session.ensureIdentity()
              } label: {
                Label("create account", systemImage: "sparkles")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .tint(LinkstrTheme.textSecondary)
            }
            .padding(.top, 6)
          }
          .padding(16)
          .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func pasteSecretKeyFromClipboard() {
    #if canImport(UIKit)
      if let clipboardText = UIPasteboard.general.string {
        secretKey = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    #endif
  }
}
