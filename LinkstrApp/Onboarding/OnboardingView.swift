import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var session: AppSession
  @State private var nsec = ""

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Text("linkstr")
              .font(.custom(LinkstrTheme.titleFont, size: 42))
              .foregroundStyle(LinkstrTheme.textPrimary)
            Text("Private link sessions over Nostr.")
              .font(.custom(LinkstrTheme.bodyFont, size: 14))
              .foregroundStyle(LinkstrTheme.textSecondary)

            VStack(alignment: .leading, spacing: 10) {
              LinkstrSectionHeader(title: "Sign In")
              TextField("nsec1...", text: $nsec)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(12)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )
              Button {
                session.importNsec(nsec)
              } label: {
                Label("Sign In", systemImage: "arrow.right.circle.fill")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(LinkstrPrimaryButtonStyle())
              .disabled(nsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .linkstrNeonCard()

            VStack(alignment: .leading, spacing: 10) {
              LinkstrSectionHeader(title: "Create Account")
              Button {
                session.ensureIdentity()
              } label: {
                Label("Create Account", systemImage: "sparkles")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(LinkstrSecondaryButtonStyle())
            }
            .padding(12)
            .linkstrNeonCard()
          }
          .padding(16)
          .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      .navigationTitle("Welcome")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
