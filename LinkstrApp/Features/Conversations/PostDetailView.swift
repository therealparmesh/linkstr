import EmojiKit
import SwiftData
import SwiftUI

struct ReactionSummary: Identifiable, Hashable {
  let emoji: String
  let count: Int
  let includesCurrentUser: Bool

  var id: String { emoji }
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
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
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
                .font(.custom(LinkstrTheme.bodyFont, size: 13))
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
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      Text(summary.emoji)
        .font(.system(size: 15))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))

      if summary.count > 1 {
        Text("\(summary.count)")
          .font(.custom(LinkstrTheme.bodyFont, size: 10))
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.vertical, 1)
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
        .font(.system(size: 15))
      Text("\(summary.count)")
        .font(.custom(LinkstrTheme.bodyFont, size: 12))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(summary.includesCurrentUser ? LinkstrTheme.panelSoft : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary.includesCurrentUser
            ? LinkstrTheme.neonCyan.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
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
        .font(.system(size: 15))

      if let count = summary?.count, count > 0 {
        Text("\(count)")
          .font(.custom(LinkstrTheme.bodyFont, size: 12))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(summary?.includesCurrentUser == true ? LinkstrTheme.panelSoft : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary?.includesCurrentUser == true
            ? LinkstrTheme.neonCyan.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
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
      .navigationTitle("add reaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .searchable(text: $query, prompt: "search emoji")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("cancel") {
            dismiss()
          }
        }
      }
    }
  }
}

struct PostDetailView: View {
  @EnvironmentObject private var session: AppSession
  @Environment(\.openURL) private var openURL

  let post: SessionMessageEntity
  let sessionName: String

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @Query(sort: [SortDescriptor(\SessionReactionEntity.updatedAt, order: .reverse)])
  private var allReactions: [SessionReactionEntity]

  @State private var isPresentingEmojiPicker = false

  private var scopedContacts: [ContactEntity] {
    session.scopedContacts(from: contacts)
  }

  private var scopedReactions: [SessionReactionEntity] {
    session.scopedReactions(from: allReactions)
      .filter {
        $0.sessionID == post.conversationID
          && $0.postID == post.rootID
          && $0.isActive
      }
  }

  private var postSenderLabel: String {
    if isOutgoing(post) {
      return "you"
    }
    return session.contactName(for: post.senderPubkey, contacts: scopedContacts)
  }

  private var reactionSummaries: [ReactionSummary] {
    guard !scopedReactions.isEmpty else { return [] }
    let grouped = Dictionary(grouping: scopedReactions, by: \.emoji)
    let myPubkey = session.identityService.pubkeyHex

    return
      grouped
      .map { emoji, reactions -> ReactionSummary in
        ReactionSummary(
          emoji: emoji,
          count: reactions.count,
          includesCurrentUser: reactions.contains { reaction in
            guard let myPubkey else { return false }
            return reaction.senderMatches(myPubkey)
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

  private var reactionBreakdown: [ReactionParticipantBreakdown] {
    guard !scopedReactions.isEmpty else { return [] }

    let grouped = Dictionary(grouping: scopedReactions) { reaction -> String in
      let myPubkey = session.identityService.pubkeyHex
      if let myPubkey, reaction.senderMatches(myPubkey) {
        return "you"
      }
      return session.contactName(for: reaction.senderPubkey, contacts: scopedContacts)
    }

    return
      grouped.map { displayName, reactions in
        let emojis = Array(Set(reactions.map(\.emoji))).sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return ReactionParticipantBreakdown(displayName: displayName, emojis: emojis)
      }
      .sorted {
        if $0.displayName == "you" { return true }
        if $1.displayName == "you" { return false }
        return
          $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
          == .orderedAscending
      }
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 10) {
        postCard
      }
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 12)
    }
    .background(LinkstrBackgroundView())
    .navigationTitle(sessionName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      session.markRootPostRead(postID: post.rootID)
    }
    .sheet(isPresented: $isPresentingEmojiPicker) {
      LinkstrEmojiPickerSheet { emoji in
        toggleReaction(emoji)
      }
      .presentationDetents([.fraction(0.92)])
    }
  }

  private var postCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("sent by \(postSenderLabel)")
          .font(.caption2)
          .foregroundStyle(LinkstrTheme.textSecondary)

        Spacer()

        Text(post.timestamp.linkstrMessageTimestampLabel)
          .font(.caption)
          .foregroundStyle(LinkstrTheme.textSecondary)
      }

      if let title = post.metadataTitle, !title.isEmpty {
        Text(title)
          .font(.custom(LinkstrTheme.titleFont, size: 18))
          .foregroundStyle(LinkstrTheme.textPrimary)
      }

      if let url = post.url, let parsedURL = URL(string: url) {
        Button {
          openURL(parsedURL)
        } label: {
          Text(url)
            .font(.custom(LinkstrTheme.bodyFont, size: 13))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else if let url = post.url {
        Text(url)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .textSelection(.enabled)
      }

      if let note = post.note, !note.isEmpty {
        Text(note)
          .font(.custom(LinkstrTheme.bodyFont, size: 13))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.94))
      }

      mediaBlock

      LinkstrReactionRow(
        summaries: reactionSummaries,
        mode: .interactive,
        onToggleEmoji: { emoji in
          toggleReaction(emoji)
        },
        onAddReaction: {
          isPresentingEmojiPicker = true
        }
      )

      if !reactionBreakdown.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          LinkstrSectionHeader(title: "who reacted")

          ForEach(reactionBreakdown) { entry in
            HStack(alignment: .center, spacing: 6) {
              Text("\(entry.displayName):")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)

              Text(entry.emojis.joined(separator: " "))
                .font(.system(size: 15))
                .foregroundStyle(LinkstrTheme.textPrimary)

              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 2)
  }

  @ViewBuilder
  private var mediaBlock: some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      AdaptiveVideoPlaybackView(
        sourceURL: url,
        showOpenSourceButtonInEmbedMode: true,
        openSourceAction: { openURL(url) },
        resolveCachedLocalMedia: { sourceURL in
          guard let path = post.cachedMediaPath,
            post.cachedMediaSourceURL == sourceURL.absoluteString
          else {
            return nil
          }
          let localURL = URL(fileURLWithPath: path)
          guard FileManager.default.fileExists(atPath: localURL.path) else {
            post.cachedMediaPath = nil
            post.cachedMediaSourceURL = nil
            return nil
          }
          return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
        },
        persistLocalMedia: { sourceURL, media in
          guard media.isLocalFile else { return }
          post.cachedMediaPath = media.playbackURL.path
          post.cachedMediaSourceURL = sourceURL.absoluteString
        }
      )
    }
  }

  private func toggleReaction(_ emoji: String) {
    Task { @MainActor in
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
    }
  }

  private func isOutgoing(_ message: SessionMessageEntity) -> Bool {
    guard let myPubkey = session.identityService.pubkeyHex else { return false }
    return message.senderPubkey == myPubkey
  }
}
