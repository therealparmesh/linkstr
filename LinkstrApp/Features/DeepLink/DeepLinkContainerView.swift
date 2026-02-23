import SwiftUI

struct DeepLinkContainerView: View {
  let payload: LinkstrDeepLinkPayload

  @EnvironmentObject private var deepLinkHandler: DeepLinkHandler

  var body: some View {
    NavigationStack {
      DeepLinkVideoView(payload: payload)
        .navigationTitle("watch video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("done") {
              deepLinkHandler.clear()
            }
          }
        }
    }
    .preferredColorScheme(.dark)
  }
}
