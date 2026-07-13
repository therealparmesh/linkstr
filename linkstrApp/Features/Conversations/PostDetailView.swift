import EmojiKit
import SwiftData
import SwiftUI

struct ReactionSummary: Identifiable, Hashable {
  let emoji: String
  let count: Int
  let includesCurrentUser: Bool

  var id: String { emoji }

  var badgeText: String {
    count > 10 ? "10+" : "\(count)"
  }

  var readOnlyBadgeText: String? {
    guard count > 1 else { return nil }
    return badgeText
  }

  static func summaries(from reactions: [SessionReactionEntity], myPubkey: String?)
    -> [ReactionSummary] {
    guard !reactions.isEmpty else { return [] }

    let myPubkeyHash = myPubkey.map { LocalDataCrypto.shared.digestHex($0) }
    return
      Dictionary(grouping: reactions, by: \.emoji)
      .map { emoji, groupedReactions -> ReactionSummary in
        ReactionSummary(
          emoji: emoji,
          count: groupedReactions.count,
          includesCurrentUser: groupedReactions.contains { reaction in
            guard let myPubkeyHash else { return false }
            return reaction.senderMatchesHash(myPubkeyHash)
          }
        )
      }
      .sorted {
        if $0.count == $1.count {
          return $0.emoji < $1.emoji
        }
        return $0.count > $1.count
      }
  }
}

struct ReactionParticipantBreakdown: Identifiable, Hashable {
  let displayName: String
  let emojis: [String]

  var id: String { displayName }
}

struct LinkstrReactionRow: View {
  enum Mode {
    case interactive
    case readOnly
  }

  let summaries: [ReactionSummary]
  var mode: Mode = .interactive
  let onToggleEmoji: ((String) -> Void)?
  let onAddReaction: (() -> Void)?

  private let quickEmojis = ["👍", "👎", "👀"]
  private let readOnlyMaxEmojiCount = 10

  private var quickSummariesByEmoji: [String: ReactionSummary] {
    Dictionary(
      uniqueKeysWithValues:
        summaries
        .filter { quickEmojis.contains($0.emoji) }
        .map { ($0.emoji, $0) }
    )
  }

  private var extraSummaries: [ReactionSummary] {
    summaries.filter { !quickEmojis.contains($0.emoji) }
  }

  private var readOnlyVisibleSummaries: [ReactionSummary] {
    Array(summaries.prefix(readOnlyMaxEmojiCount))
  }

  private var hasReadOnlyOverflow: Bool {
    summaries.count > readOnlyMaxEmojiCount
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .center, spacing: mode == .readOnly ? 6 : 8) {
        if mode == .readOnly {
          ForEach(readOnlyVisibleSummaries) { summary in
            readOnlySummaryText(summary)
          }

          if hasReadOnlyOverflow {
            Text("...")
              .font(LinkstrTheme.body(12))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        } else {
          ForEach(extraSummaries) { summary in
            summaryChip(summary)
          }

          ForEach(quickEmojis, id: \.self) { emoji in
            quickEmojiButton(emoji)
          }

          if let onAddReaction {
            Button(action: onAddReaction) {
              Text("...")
                .font(LinkstrTheme.body(13))
                .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  Capsule()
                    .fill(LinkstrTheme.panel)
                )
                .overlay(
                  Capsule()
                    .stroke(LinkstrTheme.textSecondary.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(minHeight: mode == .readOnly ? 18 : nil, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func readOnlySummaryText(_ summary: ReactionSummary) -> some View {
    ZStack(alignment: .bottomTrailing) {
      Text(summary.emoji)
        .font(LinkstrTheme.system(17))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))

      if let badgeText = summary.readOnlyBadgeText {
        Text(badgeText)
          .font(LinkstrTheme.body(9))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(
            Capsule()
              .fill(LinkstrTheme.panel)
          )
          .overlay(
            Capsule()
              .stroke(LinkstrTheme.textSecondary.opacity(0.22), lineWidth: 1)
          )
          .offset(x: 7, y: 5)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.vertical, 4)
    .padding(.trailing, 8)
    .accessibilityLabel(
      "\(summary.count) \(summary.emoji) reaction\(summary.count == 1 ? "" : "s")")
  }

  private func summaryChip(_ summary: ReactionSummary) -> some View {
    Group {
      if let onToggleEmoji, mode == .interactive {
        Button {
          onToggleEmoji(summary.emoji)
        } label: {
          summaryChipLabel(summary)
        }
        .buttonStyle(.plain)
      } else {
        summaryChipLabel(summary)
      }
    }
  }

  private func summaryChipLabel(_ summary: ReactionSummary) -> some View {
    HStack(spacing: 6) {
      Text(summary.emoji)
        .font(LinkstrTheme.system(15))
      Text(summary.badgeText)
        .font(LinkstrTheme.body(12))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(summary.includesCurrentUser ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary.includesCurrentUser
            ? LinkstrTheme.accent.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
          lineWidth: 1
        )
    )
  }

  private func quickEmojiButton(_ emoji: String) -> some View {
    let summary = quickSummariesByEmoji[emoji]
    return Group {
      if let onToggleEmoji, mode == .interactive {
        Button {
          onToggleEmoji(emoji)
        } label: {
          quickEmojiButtonLabel(emoji: emoji, summary: summary)
        }
        .buttonStyle(.plain)
      } else {
        quickEmojiButtonLabel(emoji: emoji, summary: summary)
      }
    }
  }

  private func quickEmojiButtonLabel(
    emoji: String,
    summary: ReactionSummary?
  ) -> some View {
    HStack(spacing: 6) {
      Text(emoji)
        .font(LinkstrTheme.system(15))

      if let count = summary?.count, count > 0 {
        Text(summary?.badgeText ?? "\(count)")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(
          summary?.includesCurrentUser == true ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary?.includesCurrentUser == true
            ? LinkstrTheme.accent.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
          lineWidth: 1
        )
    )
  }

}

struct LinkstrEmojiPickerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let onPick: (String) -> Void

  @State private var query = ""
  @State private var category: EmojiCategory?
  @State private var selection: Emoji.GridSelection?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        VStack(spacing: 0) {
          LinkstrScreenTitle(title: "add reaction")
            .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
            .padding(.top, LinkstrTheme.screenTopPadding)
          EmojiGridScrollView(
            axis: .vertical,
            category: $category,
            selection: $selection,
            query: query,
            action: { emoji in
              onPick(emoji.char)
              dismiss()
            },
            sectionTitle: { $0.view },
            gridItem: { $0.view }
          )
          .emojiGridStyle(.medium)
          .padding(.horizontal, 8)
          .padding(.vertical, 8)
        }
      }
      .linkstrBarChrome()
      .searchable(text: $query, prompt: "search emoji")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("close emoji picker")
          .tint(LinkstrTheme.textSecondary)
        }
      }
    }
  }
}

struct PostDetailView: View {
  @EnvironmentObject var session: AppSession
  @Environment(\.modelContext) var modelContext
  @Environment(\.openURL) var openURL

  let ownerPubkey: String
  let sessionID: String
  let postID: String
  let sessionName: String

  @State var isPresentingEmojiPicker = false
  @State var post: SessionMessageEntity?
  @State var contacts: [ContactEntity] = []
  @State var reactions: [SessionReactionEntity] = []
  @State var members: [SessionMemberEntity] = []
  @State var remotePostText: String?
  @State var isRefreshingMetadata = false
  @State var mediaReloadID = 0

  init(
    ownerPubkey: String,
    sessionID: String,
    postID: String,
    sessionName: String
  ) {
    self.ownerPubkey = ownerPubkey
    self.sessionID = sessionID
    self.postID = postID
    self.sessionName = sessionName
  }

  var body: some View {
    Group {
      if let post {
        ScrollView {
          VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
            postCardContent(post)
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
          .padding(.bottom, LinkstrTheme.screenBottomPadding)
        }
      } else {
        ContentUnavailableView(
          "post unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text("this post is no longer available.")
        )
      }
    }
    .linkstrTabBarContentInset()
    .task(id: loadRequestID) {
      await loadContent()
    }
    .task(id: profileLookupPubkeys.stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .background(LinkstrBackgroundView())
    .linkstrBarChrome()
    .toolbar {
      if let post {
        ToolbarItemGroup(placement: .topBarTrailing) {
          metadataRefreshButton(for: post)
          if let shareDeepLinkURL {
            shareDeepLinkButton(for: shareDeepLinkURL)
          }
        }
      } else if let shareDeepLinkURL {
        ToolbarItem(placement: .topBarTrailing) {
          shareDeepLinkButton(for: shareDeepLinkURL)
        }
      }
    }
    .task(id: post?.storageID) {
      guard let post else { return }
      session.markRootPostRead(postID: post.rootID)
      session.refreshMetadataForVisiblePostIfNeeded(post)
    }
    .task(id: remotePostTextRequestID) {
      remotePostText = await resolvedRemotePostText()
    }
    .sheet(isPresented: $isPresentingEmojiPicker) {
      LinkstrEmojiPickerSheet { emoji in
        toggleReaction(emoji)
      }
      .presentationDetents([.fraction(0.92)])
    }
  }
}
