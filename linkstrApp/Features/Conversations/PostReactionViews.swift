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

  static func summaries(from reactions: [SessionReactionEntity], myPubkey: String?) -> [ReactionSummary] {
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

struct ReactionParticipantBreakdown: Identifiable {
  let id: String
  let displayName: String
  let emojis: [String]
}

struct LinkstrReactionRow: View {
  enum Mode {
    case interactive
    case readOnly
    case watch
  }

  let summaries: [ReactionSummary]
  var mode: Mode = .interactive
  let onToggleEmoji: ((String) -> Void)?
  var onShowBreakdown: (() -> Void)?

  private let quickEmojis = ["❤️", "👀"]
  private let readOnlyMaxEmojiCount = 10

  private var readOnlyOverflowCount: Int {
    max(0, summaries.count - readOnlyMaxEmojiCount)
  }

  var body: some View {
    if mode == .watch {
      ViewThatFits(in: .horizontal) {
        watchReactions(limit: 3)
        watchReactions(limit: 2)
        watchReactions(limit: 1)
        watchReactions(limit: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      scrollingReactions
    }
  }

  private func watchReactions(limit: Int) -> some View {
    HStack(spacing: LinkstrTheme.metaSpacing) {
      ForEach(summaries.prefix(limit)) { summaryChip($0) }
      suggestions
      if summaries.count > limit, let onShowBreakdown {
        Button(action: onShowBreakdown) {
          Text("+\(summaries.count - limit)")
            .font(LinkstrTheme.font(.caption, weight: .medium).monospacedDigit())
            .linkstrReactionChip(compact: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("view all reactions, \(summaries.count - limit) more emoji types")
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var scrollingReactions: some View {
    ScrollView(.horizontal) {
      HStack(
        alignment: .center,
        spacing: LinkstrTheme.tightSpacing
      ) {
        if mode == .readOnly {
          ForEach(summaries.prefix(readOnlyMaxEmojiCount)) { summary in
            readOnlySummaryText(summary)
          }

          if readOnlyOverflowCount > 0 {
            Text("+\(readOnlyOverflowCount)")
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .accessibilityLabel(
                readOnlyOverflowCount == 1
                  ? "1 more emoji type" : "\(readOnlyOverflowCount) more emoji types"
              )
          }
        } else {
          ForEach(summaries) { summaryChip($0) }
          suggestions
        }
      }
    }
    .scrollIndicators(.hidden)
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var suggestions: some View {
    if onToggleEmoji != nil {
      ForEach(quickEmojis.filter { emoji in !summaries.contains { $0.emoji == emoji } }, id: \.self) {
        quickEmojiButton($0)
      }
    }
  }

  private func readOnlySummaryText(_ summary: ReactionSummary) -> some View {
    ReactionChipLabel(emoji: summary.emoji, count: summary.readOnlyBadgeText)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(summary.count) \(summary.emoji) reaction\(summary.count == 1 ? "" : "s")")
  }

  private func summaryChip(_ summary: ReactionSummary) -> some View {
    Button {
      if let onToggleEmoji { onToggleEmoji(summary.emoji) } else { onShowBreakdown?() }
    } label: {
      quickEmojiButtonLabel(emoji: summary.emoji, summary: summary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(summary.emoji), \(summary.count) reaction\(summary.count == 1 ? "" : "s")"
    )
    .accessibilityValue(summary.includesCurrentUser ? "you reacted" : "")
    .accessibilityHint(
      onToggleEmoji == nil ? "view people who reacted" : "add or remove your reaction"
    )
    .accessibilityActions {
      if let onShowBreakdown {
        Button("view people who reacted", action: onShowBreakdown)
      }
    }
  }

  private func quickEmojiButton(_ emoji: String) -> some View {
    Button {
      onToggleEmoji?(emoji)
    } label: {
      quickEmojiButtonLabel(emoji: emoji, summary: nil)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("react with \(emoji)")
  }

  private func quickEmojiButtonLabel(
    emoji: String,
    summary: ReactionSummary?
  ) -> some View {
    ReactionChipLabel(emoji: emoji, count: summary.map { String($0.count) })
      .linkstrReactionChip(
        isSelected: summary?.includesCurrentUser == true, compact: mode == .watch)
  }
}

private struct ReactionChipLabel: View {
  let emoji: String
  let count: String?

  var body: some View {
    HStack(spacing: LinkstrTheme.metaSpacing) {
      Text(emoji)
        .font(LinkstrTheme.font(.title3))
        .foregroundStyle(LinkstrTheme.textPrimary)

      if let count {
        Text(count)
          .font(LinkstrTheme.font(.caption, weight: .medium).monospacedDigit())
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

private extension View {
  func linkstrReactionChip(isSelected: Bool = false, compact: Bool = false) -> some View {
    padding(.horizontal, compact ? LinkstrTheme.tightSpacing : 10)
      .padding(.vertical, LinkstrTheme.metaSpacing)
      .background {
        if compact {
          Capsule().fill(.thinMaterial)
            .overlay {
              if isSelected { Capsule().strokeBorder(LinkstrTheme.accent, lineWidth: 1) }
            }
        }
      }
      .frame(
        minWidth: LinkstrTheme.minimumInteractiveDimension,
        minHeight: LinkstrTheme.minimumInteractiveDimension
      )
      .background {
        if !compact {
          Capsule().fill(isSelected ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
        }
      }
      .overlay {
        if !compact {
          Capsule().stroke(isSelected ? LinkstrTheme.accent : LinkstrTheme.separator, lineWidth: 1)
        }
      }
      .contentShape(Rectangle())
  }
}
