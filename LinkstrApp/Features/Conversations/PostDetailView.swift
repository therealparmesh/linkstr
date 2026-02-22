import SwiftData
import SwiftUI

struct ReactionSummary: Identifiable, Hashable {
  let emoji: String
  let count: Int
  let includesCurrentUser: Bool

  var id: String { emoji }
}

struct ReactionBreakdown: Identifiable, Hashable {
  let emoji: String
  let participants: [String]

  var id: String { emoji }
  var count: Int { participants.count }
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

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if mode == .readOnly {
          ForEach(summaries) { summary in
            summaryChip(summary)
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

  private let quickEmojis = ["👍", "👎", "👀"]

  private let categories: [(title: String, emojis: [String])] = [
    (
      "People",
      [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "🙂", "😉", "😍", "😘", "😋",
        "😎", "🤓", "🤔", "😐", "😶", "🙄", "😏", "😬", "😮", "😢", "😭", "😤", "😡", "🤯",
        "🥳", "😴", "🤗", "🤝", "🙏", "👏", "🙌", "👋", "🤌", "👌", "✌️", "🤞", "🤟", "🫡",
      ]
    ),
    (
      "Reactions",
      [
        "👍", "👎", "👊", "✊", "👏", "🙌", "👌", "🤝", "🙏", "💪", "🔥", "💯", "✅", "❌", "⚡️",
        "❤️", "💙", "💚", "🧡", "💜", "🤍", "💔", "💥", "⭐️", "✨", "🎯", "🚀", "👀", "👎", "👍",
      ]
    ),
    (
      "Objects",
      [
        "📌", "📎", "📷", "🎥", "📺", "🎧", "📱", "💻", "⌚️", "🧠", "📝", "📚", "🔗", "🔒", "🔓",
        "🛠️", "⚙️", "🧪", "💡", "🧯", "🎬", "🎮", "🧩", "🗂️", "🧾", "📦", "🧭", "🛰️", "🧱", "🧲",
      ]
    ),
    (
      "Nature & Food",
      [
        "🌞", "🌙", "⭐️", "☀️", "🌧️", "⚡️", "❄️", "🌊", "🌱", "🌴", "🌸", "🍀", "🍎", "🍕", "🍔",
        "🍟", "🌮", "🍣", "🍜", "☕️", "🍺", "🍷", "🍿", "🍪", "🍫", "🍓", "🍉", "🥑", "🥐", "🍩",
      ]
    ),
  ]

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            TextField("Search emoji", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .lineLimit(1)
              .frame(minHeight: 42)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )

            LinkstrSectionHeader(title: "Quick")
            emojiGrid(quickEmojis)

            ForEach(filteredCategories, id: \.title) { category in
              LinkstrSectionHeader(title: category.title)
              emojiGrid(category.emojis)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      .navigationTitle("Add Reaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }

  @ViewBuilder
  private func emojiGrid(_ emojis: [String]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 40)), count: 7), spacing: 8) {
      ForEach(emojis, id: \.self) { emoji in
        Button {
          onPick(emoji)
          dismiss()
        } label: {
          Text(emoji)
            .font(.system(size: 28))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinkstrTheme.panelSoft)
            )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var filteredCategories: [(title: String, emojis: [String])] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return categories
    }

    return categories.map { category in
      let filteredEmojis = category.emojis.filter { emoji in
        emoji.contains(trimmed)
      }
      return (category.title, filteredEmojis)
    }
    .filter { !$0.emojis.isEmpty }
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
      return "You"
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

  private var reactionBreakdown: [ReactionBreakdown] {
    guard !scopedReactions.isEmpty else { return [] }

    let grouped = Dictionary(grouping: scopedReactions, by: \.emoji)
    let myPubkey = session.identityService.pubkeyHex

    return
      grouped
      .map { emoji, reactions in
        let participants =
          reactions
          .map { reaction -> String in
            if let myPubkey, reaction.senderMatches(myPubkey) {
              return "You"
            }
            return session.contactName(for: reaction.senderPubkey, contacts: scopedContacts)
          }
          .sorted { lhs, rhs in
            if lhs == "You" { return true }
            if rhs == "You" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
          }
        return ReactionBreakdown(emoji: emoji, participants: participants)
      }
      .sorted {
        if $0.count == $1.count {
          return $0.emoji < $1.emoji
        }
        return $0.count > $1.count
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
        Text("Sent by \(postSenderLabel)")
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
          LinkstrSectionHeader(title: "Who Reacted")

          ForEach(reactionBreakdown) { entry in
            HStack(alignment: .top, spacing: 8) {
              Text(entry.emoji)
                .font(.system(size: 17))

              Text(entry.participants.joined(separator: ", "))
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .multilineTextAlignment(.leading)

              Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
          }
        }
      }
    }
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
