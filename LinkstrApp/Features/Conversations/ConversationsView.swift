import NostrSDK
import SwiftData
import SwiftUI
import UIKit

private struct ConversationSummary: Identifiable {
  let id: String
  let name: String
  let peerNPub: String?
  let latestTimestamp: Date
  let latestPreview: String
  let latestNote: String?
  let isArchived: Bool
  let isKnownContact: Bool
  let unreadItemCount: Int
}

private struct ConversationMessageIndex {
  let postsByConversationID: [String: [SessionMessageEntity]]
  let unreadIncomingRepliesByPostID: [String: Int]

  init(messages: [SessionMessageEntity], myPubkey: String?) {
    var postsByConversationID: [String: [SessionMessageEntity]] = [:]
    var unreadIncomingRepliesByPostID: [String: Int] = [:]

    for message in messages {
      switch message.kind {
      case .root:
        postsByConversationID[message.conversationID, default: []].append(message)
      case .reply:
        if let myPubkey, message.senderPubkey != myPubkey, message.readAt == nil {
          unreadIncomingRepliesByPostID[message.rootID, default: 0] += 1
        }
      }
    }

    self.postsByConversationID = postsByConversationID
    self.unreadIncomingRepliesByPostID = unreadIncomingRepliesByPostID
  }
}

struct ConversationsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.displayName)])
  private var contacts: [ContactEntity]

  private var messageIndex: ConversationMessageIndex {
    ConversationMessageIndex(
      messages: allMessages,
      myPubkey: session.identityService.pubkeyHex
    )
  }

  private var summaries: [ConversationSummary] {
    messageIndex.postsByConversationID
      .compactMap { conversationID, conversationPosts in
        guard let latestPost = conversationPosts.max(by: { $0.timestamp < $1.timestamp }) else {
          return nil
        }

        let peerPubkey = otherPubkey(for: latestPost)
        let peerNPub = PublicKey(hex: peerPubkey)?.npub
        let knownContact = contacts.contains { PublicKey(npub: $0.npub)?.hex == peerPubkey }
        let name =
          knownContact
          ? session.contactName(for: peerPubkey, contacts: contacts)
          : (peerNPub ?? session.contactName(for: peerPubkey, contacts: contacts))
        let isArchived = conversationPosts.allSatisfy(\.isArchived)
        let myPubkey = session.identityService.pubkeyHex
        let unreadItemCount = conversationPosts.reduce(0) { partial, post in
          let hasUnreadPost: Bool
          if let myPubkey {
            hasUnreadPost = post.senderPubkey != myPubkey && post.readAt == nil
          } else {
            hasUnreadPost = false
          }
          let hasUnreadReplies = (messageIndex.unreadIncomingRepliesByPostID[post.rootID] ?? 0) > 0
          return partial + ((hasUnreadPost || hasUnreadReplies) ? 1 : 0)
        }

        return ConversationSummary(
          id: conversationID,
          name: name,
          peerNPub: peerNPub,
          latestTimestamp: latestPost.timestamp,
          latestPreview: previewText(for: latestPost),
          latestNote: normalizedNote(latestPost.note),
          isArchived: isArchived,
          isKnownContact: knownContact,
          unreadItemCount: unreadItemCount
        )
      }
      .sorted { $0.latestTimestamp > $1.latestTimestamp }
  }

  private var activeConversations: [ConversationSummary] {
    summaries.filter { !$0.isArchived }
  }

  private var archivedConversations: [ConversationSummary] {
    summaries.filter(\.isArchived)
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .scrollContentBackground(.hidden)
  }

  @ViewBuilder
  private var content: some View {
    if summaries.isEmpty {
      ContentUnavailableView(
        "No Sessions", systemImage: "bubble.left.and.bubble.right",
        description: Text("Share a link to start a session.")
      )
      .padding(.top, 64)
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(activeConversations) { summary in
            NavigationLink {
              SessionPostsView(
                conversationID: summary.id,
                conversationName: summary.name,
                peerNPub: summary.peerNPub,
                isKnownContact: summary.isKnownContact
              )
            } label: {
              ConversationRowView(summary: summary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              Button("Archive") {
                session.setConversationArchived(conversationID: summary.id, archived: true)
              }
              .tint(.orange)
            }
          }

          if !archivedConversations.isEmpty {
            LinkstrSectionHeader(title: "Archived")
            ForEach(archivedConversations) { summary in
              NavigationLink {
                SessionPostsView(
                  conversationID: summary.id,
                  conversationName: summary.name,
                  peerNPub: summary.peerNPub,
                  isKnownContact: summary.isKnownContact
                )
              } label: {
                ConversationRowView(summary: summary)
              }
              .buttonStyle(.plain)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
              .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Unarchive") {
                  session.setConversationArchived(conversationID: summary.id, archived: false)
                }
                .tint(.green)
              }
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  private func previewText(for post: SessionMessageEntity) -> String {
    if let title = post.metadataTitle, !title.isEmpty { return title }
    if let url = post.url, !url.isEmpty { return url }
    return "Link"
  }

  private func normalizedNote(_ note: String?) -> String? {
    guard let note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func otherPubkey(for post: SessionMessageEntity) -> String {
    guard let myPubkey = session.identityService.pubkeyHex else {
      return post.senderPubkey
    }
    return post.senderPubkey == myPubkey ? post.receiverPubkey : post.senderPubkey
  }
}

private struct ConversationRowView: View {
  let summary: ConversationSummary

  private var subtitleText: String {
    if let note = summary.latestNote {
      return note
    }
    return summary.latestPreview
  }

  var body: some View {
    HStack(spacing: 12) {
      LinkstrPeerAvatar(name: summary.name)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline) {
          Text(summary.name)
            .font(.custom(LinkstrTheme.titleFont, size: 16))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(summary.latestTimestamp.linkstrListTimestampLabel)
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
        }

        Text(subtitleText)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !summary.isKnownContact {
        Text("Unknown Contact")
          .font(.custom(LinkstrTheme.bodyFont, size: 10))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(LinkstrTheme.neonAmber, in: Capsule())
      }

      if summary.unreadItemCount > 0 {
        Text("\(summary.unreadItemCount)")
          .font(.custom(LinkstrTheme.bodyFont, size: 11))
          .foregroundStyle(Color.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(LinkstrTheme.neonAmber, in: Capsule())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .padding(.horizontal, 4)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider()
    }
  }
}

private struct SessionPostsView: View {
  @EnvironmentObject private var session: AppSession

  @Query(sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)])
  private var allMessages: [SessionMessageEntity]

  @Query(sort: [SortDescriptor(\ContactEntity.displayName)])
  private var contacts: [ContactEntity]

  let conversationID: String
  let conversationName: String
  let peerNPub: String?
  let isKnownContact: Bool

  @State private var isPresentingNewPost = false
  @State private var isPresentingAddContact = false

  private var messageIndex: ConversationMessageIndex {
    ConversationMessageIndex(
      messages: allMessages,
      myPubkey: session.identityService.pubkeyHex
    )
  }

  private var posts: [SessionMessageEntity] {
    messageIndex.postsByConversationID[conversationID] ?? []
  }

  private var repliesByPostID: [String: [SessionMessageEntity]] {
    let postRootIDs = Set(posts.map(\.rootID))
    let replies = allMessages.filter { message in
      message.kind == .reply && postRootIDs.contains(message.rootID)
    }
    return Dictionary(grouping: replies, by: \.rootID)
  }

  private var sortedPosts: [SessionMessageEntity] {
    posts.sorted { $0.timestamp > $1.timestamp }
  }

  private var unreadIncomingReplyCountByPostID: [String: Int] {
    let rootIDs = Set(posts.map(\.rootID))
    return messageIndex.unreadIncomingRepliesByPostID.filter { rootIDs.contains($0.key) }
  }

  private var sessionComposerContext:
    (preselectedContactNPub: String?, lockedRecipient: LockedRecipientContext?)
  {
    if isKnownContact {
      return (peerNPub, nil)
    }
    if let peerNPub {
      return (
        nil,
        LockedRecipientContext(npub: peerNPub, displayName: conversationName)
      )
    }
    return (nil, nil)
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if sortedPosts.isEmpty {
          ContentUnavailableView(
            "No Posts Yet", systemImage: "link.badge.plus",
            description: Text("Share a link in this session.")
          )
          .padding(.top, 24)
        } else {
          LinkstrSectionHeader(title: "Posts")
          ForEach(sortedPosts) { post in
            NavigationLink {
              ThreadView(post: post)
            } label: {
              PostCardView(
                post: post,
                replyCount: repliesByPostID[post.rootID]?.count ?? 0,
                unreadReplyCount: unreadIncomingReplyCountByPostID[post.rootID] ?? 0,
                latestReplyTimestamp: repliesByPostID[post.rootID]?.max(by: {
                  $0.timestamp < $1.timestamp
                })?.timestamp
              )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
    }
    .scrollContentBackground(.hidden)
    .background(LinkstrBackgroundView())
    .controlSize(.small)
    .navigationTitle(conversationName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if !isKnownContact, peerNPub != nil {
          Button {
            isPresentingAddContact = true
          } label: {
            Label("Add Contact", systemImage: "person.badge.plus")
          }
          .tint(LinkstrTheme.neonCyan)
        }

        Button {
          isPresentingNewPost = true
        } label: {
          Label("New Post", systemImage: "plus")
        }
        .tint(LinkstrTheme.neonCyan)
      }
    }
    .sheet(isPresented: $isPresentingNewPost) {
      NewPostSheet(
        contacts: contacts,
        preselectedContactNPub: sessionComposerContext.preselectedContactNPub,
        lockedRecipient: sessionComposerContext.lockedRecipient
      )
      .environmentObject(session)
    }
    .sheet(isPresented: $isPresentingAddContact) {
      AddContactSheet(prefilledNPub: peerNPub)
        .environmentObject(session)
    }
    .task(id: conversationID) {
      session.markConversationPostsRead(conversationID: conversationID)
    }
    .onChange(of: posts.count) { _, _ in
      session.markConversationPostsRead(conversationID: conversationID)
    }
  }

}

private struct PostCardView: View {
  let post: SessionMessageEntity
  let replyCount: Int
  let unreadReplyCount: Int
  let latestReplyTimestamp: Date?

  var body: some View {
    HStack(spacing: 10) {
      thumbnailView

      VStack(alignment: .leading, spacing: 6) {
        Text(contentKindLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)

        Text(primaryText)
          .font(.custom(LinkstrTheme.titleFont, size: 15))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(2)

        if let noteText {
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: "note.text")
              .font(.caption)
              .foregroundStyle(LinkstrTheme.neonAmber.opacity(0.9))
              .padding(.top, 2)
            Text(noteText)
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
              .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.92))
              .lineLimit(2)
          }
        }

        HStack(spacing: 8) {
          Text(replyCountLabel)
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
          if unreadReplyCount > 0 {
            Text(unreadReplyCountLabel)
              .font(.caption)
              .foregroundStyle(LinkstrTheme.neonAmber)
          }
          Text(post.timestamp.linkstrListTimestampLabel)
            .font(.caption)
            .foregroundStyle(LinkstrTheme.textSecondary)
          if let latestReplyTimestamp {
            Text("Updated \(latestReplyTimestamp.linkstrListTimestampLabel)")
              .font(.caption)
              .foregroundStyle(LinkstrTheme.textSecondary)
              .lineLimit(1)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .linkstrNeonCard()
  }

  private var primaryText: String {
    if let title = post.metadataTitle, !title.isEmpty { return title }
    if let url = post.url, !url.isEmpty { return url }
    return "Untitled post"
  }

  private var noteText: String? {
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var contentKindLabel: String {
    URLClassifier.mediaStrategy(for: post.url).contentKindLabel
  }

  private var replyCountLabel: String {
    replyCount == 1 ? "1 reply" : "\(replyCount) replies"
  }

  private var unreadReplyCountLabel: String {
    unreadReplyCount == 1 ? "1 unread" : "\(unreadReplyCount) unread"
  }

  @ViewBuilder
  private var thumbnailView: some View {
    if let thumbnailURL = post.thumbnailURL,
      let image = UIImage(contentsOfFile: thumbnailURL)
    {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(LinkstrTheme.panelSoft)
        .frame(width: 52, height: 52)
        .overlay {
          Image(systemName: "link")
            .font(.body)
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
    }
  }
}
