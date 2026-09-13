import Foundation

enum SessionRoute: Hashable {
  case session(String)
  case post(sessionID: String, postID: String)
}

struct SessionNavigationRequest: Identifiable, Equatable {
  let id = UUID()
  let sessionID: String
  let postID: String?

  var path: [SessionRoute] {
    var routes: [SessionRoute] = [.session(sessionID)]
    if let postID {
      routes.append(.post(sessionID: sessionID, postID: postID))
    }
    return routes
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
