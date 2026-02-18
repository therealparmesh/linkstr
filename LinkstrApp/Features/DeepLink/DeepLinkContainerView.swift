import SwiftUI

struct DeepLinkContainerView: View {
  let payload: LinkstrDeepLinkPayload

  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler

  var body: some View {
    NavigationStack {
      DeepLinkVideoView(payload: payload)
        .navigationTitle("Watch Video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done") {
              deepLinkHandler.clear()
            }
          }
        }
    }
    .preferredColorScheme(.dark)
  }
}
