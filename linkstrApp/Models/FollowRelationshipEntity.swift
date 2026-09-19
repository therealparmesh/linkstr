import Foundation
import SwiftData

@Model
final class FollowRelationshipEntity {
  @Attribute(.unique) var storageID: String
  var ownerPubkey: String
  var followerPubkey: String
  var followsOwner: Bool
  var updatedAt: Date
  var eventID: String
  #Index<FollowRelationshipEntity>([\.ownerPubkey, \.followerPubkey])

  init(ownerPubkey: String, incoming: ReceivedFollowList) {
    self.storageID = "\(ownerPubkey):\(incoming.authorPubkey)"
    self.ownerPubkey = ownerPubkey
    self.followerPubkey = incoming.authorPubkey
    self.followsOwner = incoming.followedPubkeys.contains(ownerPubkey)
    self.updatedAt = incoming.createdAt
    self.eventID = incoming.eventID
  }
}
