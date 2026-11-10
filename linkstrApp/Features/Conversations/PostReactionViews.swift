import EmojiKit
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
  let id: String
  let displayName: String
  let emojis: [String]
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
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        } else {
          ForEach(quickEmojis, id: \.self) { emoji in
            quickEmojiButton(emoji)
          }

          if let onAddReaction {
            Button(action: onAddReaction) {
              Image(systemName: "plus")
                .font(LinkstrTheme.font(.footnote, weight: .semibold))
                .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(
                  minWidth: LinkstrTheme.minimumInteractiveDimension,
                  minHeight: LinkstrTheme.minimumInteractiveDimension)
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
            .accessibilityLabel("more reactions")
          }

          ForEach(extraSummaries) { summary in
            summaryChip(summary)
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
        .font(LinkstrTheme.font(.body))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))

      if let badgeText = summary.readOnlyBadgeText {
        Text(badgeText)
          .font(LinkstrTheme.font(.caption2))
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
        .accessibilityLabel("\(summary.emoji), \(summary.count) reaction\(summary.count == 1 ? "" : "s")")
        .accessibilityValue(summary.includesCurrentUser ? "you reacted" : "")
      } else {
        summaryChipLabel(summary)
      }
    }
  }

  private func summaryChipLabel(_ summary: ReactionSummary) -> some View {
    HStack(spacing: 6) {
      Text(summary.emoji)
        .font(LinkstrTheme.font(.subheadline))
      Text(summary.badgeText)
        .font(LinkstrTheme.font(.caption))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
    }
    .padding(.horizontal, 10)
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
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
        .accessibilityLabel("\(emoji), \(summary?.count ?? 0) reaction\((summary?.count ?? 0) == 1 ? "" : "s")")
        .accessibilityValue(summary?.includesCurrentUser == true ? "you reacted" : "")
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
        .font(LinkstrTheme.font(.subheadline))

      if let count = summary?.count, count > 0 {
        Text(summary?.badgeText ?? "\(count)")
          .font(LinkstrTheme.font(.caption))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
      }
    }
    .padding(.horizontal, 10)
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
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

extension PostDetailView {
  @ViewBuilder
  var postCardReactionBreakdown: some View {
    if !reactionBreakdown.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        LinkstrListRowDivider(leadingInset: 0)
        Text("who reacted")
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        reactionFilters
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(filteredReactionParticipants) { entry in
            HStack(alignment: .center, spacing: 8) {
              LinkstrContactAvatar(name: entry.displayName, size: 32, seed: entry.id)

              Text(entry.displayName)
                .font(LinkstrTheme.font(.footnote, weight: .medium))
                .foregroundStyle(LinkstrTheme.textSecondary)

              Spacer(minLength: 0)

              Text(selectedReactionEmoji ?? entry.emojis.joined(separator: " "))
                .font(LinkstrTheme.font(.body))
                .foregroundStyle(LinkstrTheme.textPrimary)
            }
          }
        }
      }
    }
  }

  private var reactionFilters: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        reactionFilter("all", emoji: nil)
        ForEach(reactionSummaries) { summary in
          reactionFilter("\(summary.emoji) \(summary.count)", emoji: summary.emoji)
        }
      }
    }
    .onChange(of: reactionSummaries.map(\.emoji), initial: true) { _, emojis in
      if let selectedReactionEmoji, !emojis.contains(selectedReactionEmoji) {
        self.selectedReactionEmoji = nil
      }
    }
  }

  private func reactionFilter(_ title: String, emoji: String?) -> some View {
    let isSelected = selectedReactionEmoji == emoji
    return Button {
      selectedReactionEmoji = emoji
    } label: {
      Text(title)
        .font(LinkstrTheme.font(.subheadline, weight: .medium))
        .foregroundStyle(isSelected ? LinkstrTheme.textPrimary : LinkstrTheme.textSecondary)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(isSelected ? LinkstrTheme.panelElevated : LinkstrTheme.panel, in: Capsule())
        .overlay {
          Capsule().stroke(isSelected ? LinkstrTheme.accent : LinkstrTheme.separator, lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(emoji.map { "show people who reacted \($0)" } ?? "show all reactions")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var filteredReactionParticipants: [ReactionParticipantBreakdown] {
    guard let selectedReactionEmoji else { return reactionBreakdown }
    return reactionBreakdown.filter { $0.emojis.contains(selectedReactionEmoji) }
  }
}
