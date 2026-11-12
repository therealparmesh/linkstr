import Foundation

enum AppRoute: Hashable {
  case session(String, scrollToPostID: String? = nil)
  case addedYou
  case settings(showRelays: Bool = false)
}

struct SessionNavigationRequest: Identifiable, Equatable {
  let id = UUID()
  let sessionID: String
  let postID: String?

  var path: [AppRoute] {
    [.session(sessionID, scrollToPostID: postID)]
  }

  init(sessionID: String, postID: String? = nil) {
    self.sessionID = sessionID
    self.postID = postID
  }

  init?(notification userInfo: [AnyHashable: Any]) {
    guard let rawSessionID = userInfo["conversation_id"] as? String else { return nil }
    let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else { return nil }
    let postID = (userInfo["post_id"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      sessionID: sessionID,
      postID: userInfo["type"] as? String == "new_emoji_reaction" && postID?.isEmpty == false
        ? postID : nil
    )
  }
}
