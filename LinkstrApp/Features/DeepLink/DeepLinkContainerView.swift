import SwiftUI

struct DeepLinkContainerView: View {
  let urlString: String

  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler

  var body: some View {
    NavigationStack {
      DeepLinkDetailView(urlString: urlString)
        .navigationTitle("shared link")
        .navigationBarTitleDisplayMode(.inline)
        .linkstrBarChrome()
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              deepLinkHandler.clear()
            } label: {
              Image(systemName: "xmark")
                .linkstrToolbarIconLabel()
            }
            .accessibilityLabel("close shared link")
            .tint(LinkstrTheme.textSecondary)
          }
        }
    }
    .preferredColorScheme(.dark)
  }
}
