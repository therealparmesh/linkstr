import Foundation

struct LinkstrDeepLinkPayload: Codable, Equatable {
  let url: String
  let timestamp: Int64
  let messageGUID: String
}
