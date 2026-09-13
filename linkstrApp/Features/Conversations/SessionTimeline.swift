import SwiftUI

struct SessionPostsContentState {
  let canCreatePosts: Bool
  let postCount: Int
  let timelineRows: [SessionTimelineRow]
  let profileLookupPubkeys: [String]

  var postCountLabel: String {
    postCount == 1 ? "1 post" : "\(postCount) posts"
  }
}

struct PostListRow: Identifiable {
  let post: SessionMessageEntity
  let senderLabel: String
  let isOutgoing: Bool
  let showsSenderHeader: Bool
  let isFollowedBySameSender: Bool
  let hasUnreadPost: Bool
  let reactionSummaries: [ReactionSummary]

  var id: String { post.rootID }
}

struct SessionMembershipChangeRow: Identifiable {
  let change: SessionMembershipTimelineChange
  let displayName: String

  var id: String { change.id }
}

enum SessionTimelineEntry {
  case post(SessionMessageEntity)
  case membershipChange(SessionMembershipChangeRow)

  var timestamp: Date {
    switch self {
    case .post(let post):
      return post.timestamp
    case .membershipChange(let row):
      return row.change.timestamp
    }
  }

  var sortPriority: Int {
    switch self {
    case .membershipChange:
      return 0
    case .post:
      return 1
    }
  }

  var post: SessionMessageEntity? {
    guard case .post(let post) = self else { return nil }
    return post
  }
}

enum SessionTimelineRow: Identifiable {
  case post(PostListRow)
  case membershipChange(SessionMembershipChangeRow)

  var id: String {
    switch self {
    case .post(let row):
      return row.id
    case .membershipChange(let row):
      return row.id
    }
  }
}

struct SessionMembershipChangeRowView: View {
  let row: SessionMembershipChangeRow

  private var markerLabel: String {
    switch row.change.kind {
    case .joined:
      return "in: \(row.displayName)"
    case .left:
      return "out: \(row.displayName)"
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      Rectangle()
        .fill(LinkstrTheme.separator)
        .frame(height: 1)

      Text(markerLabel)
        .font(LinkstrTheme.font(.caption, weight: .semibold))
        .foregroundStyle(LinkstrTheme.textTertiary)
        .lineLimit(1)

      Rectangle()
        .fill(LinkstrTheme.separator)
        .frame(height: 1)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(markerLabel)
    .accessibilityValue(row.change.timestamp.linkstrMessageTimestampLabel)
  }
}

struct SessionMembershipTimelineInterval: Equatable {
  let memberPubkey: String
  let startAt: Date
  let endAt: Date?
}

struct SessionMembershipTimelineChange: Identifiable, Equatable {
  enum Kind: String {
    case joined
    case left

    fileprivate var sortPriority: Int {
      switch self {
      case .joined:
        return 0
      case .left:
        return 1
      }
    }
  }

  let memberPubkey: String
  let timestamp: Date
  let kind: Kind

  var id: String {
    "\(memberPubkey):\(kind.rawValue):\(timestamp.timeIntervalSince1970)"
  }
}

enum SessionMembershipTimelineBuilder {
  static func changes(
    from intervals: [SessionMembershipTimelineInterval]
  ) -> [SessionMembershipTimelineChange] {
    guard let baselineTimestamp = intervals.map(\.startAt).min() else { return [] }

    var changes: [SessionMembershipTimelineChange] = []
    changes.reserveCapacity(intervals.count * 2)

    for interval in intervals {
      if interval.startAt > baselineTimestamp {
        changes.append(
          SessionMembershipTimelineChange(
            memberPubkey: interval.memberPubkey,
            timestamp: interval.startAt,
            kind: .joined
          )
        )
      }
      if let endAt = interval.endAt, endAt > baselineTimestamp {
        changes.append(
          SessionMembershipTimelineChange(
            memberPubkey: interval.memberPubkey,
            timestamp: endAt,
            kind: .left
          )
        )
      }
    }

    return changes.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp < rhs.timestamp
      }
      if lhs.kind != rhs.kind {
        return lhs.kind.sortPriority < rhs.kind.sortPriority
      }
      return lhs.memberPubkey < rhs.memberPubkey
    }
  }
}
