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
    case watch
  }

  let summaries: [ReactionSummary]
  var mode: Mode = .interactive
  let onToggleEmoji: ((String) -> Void)?
  var onOpenReaction: ((String) -> Void)?

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

  private var readOnlyOverflowCount: Int {
    max(0, summaries.count - readOnlyMaxEmojiCount)
  }

  var body: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .center, spacing: mode == .watch ? 0 : LinkstrTheme.tightSpacing) {
        if mode == .readOnly {
          ForEach(readOnlyVisibleSummaries) { summary in
            readOnlySummaryText(summary)
          }

          if readOnlyOverflowCount > 0 {
            Text("+\(readOnlyOverflowCount)")
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .accessibilityLabel(
                readOnlyOverflowCount == 1 ? "1 more emoji type" : "\(readOnlyOverflowCount) more emoji types"
              )
          }
        } else {
          if onToggleEmoji != nil {
            ForEach(quickEmojis, id: \.self) { emoji in
              quickEmojiButton(emoji)
            }
          }

          ForEach(onToggleEmoji == nil ? summaries : extraSummaries) { summary in
            summaryChip(summary)
          }
        }
      }
      .frame(minHeight: mode == .readOnly ? 18 : nil, alignment: .leading)
    }
    .scrollIndicators(mode == .watch ? .visible : .hidden)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func readOnlySummaryText(_ summary: ReactionSummary) -> some View {
    HStack(spacing: LinkstrTheme.metaSpacing) {
      Text(summary.emoji)
        .font(LinkstrTheme.font(.body))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))

      if let badgeText = summary.readOnlyBadgeText {
        Text(badgeText)
          .font(LinkstrTheme.font(.caption2, weight: .medium).monospacedDigit())
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.vertical, LinkstrTheme.metaSpacing)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(summary.count) \(summary.emoji) reaction\(summary.count == 1 ? "" : "s")")
  }

  private func summaryChip(_ summary: ReactionSummary) -> some View {
    Button {
      (onOpenReaction ?? onToggleEmoji)?(summary.emoji)
    } label: {
      quickEmojiButtonLabel(emoji: summary.emoji, summary: summary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(summary.emoji), \(summary.count) reaction\(summary.count == 1 ? "" : "s")")
    .accessibilityValue(summary.includesCurrentUser ? "you reacted" : "")
    .accessibilityHint(onOpenReaction == nil ? "select emoji" : "view people who reacted")
  }

  private func quickEmojiButton(_ emoji: String) -> some View {
    let summary = quickSummariesByEmoji[emoji]
    return Button {
      onToggleEmoji?(emoji)
    } label: {
      quickEmojiButtonLabel(emoji: emoji, summary: summary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "react with \(emoji), \(summary?.count ?? 0) reaction\((summary?.count ?? 0) == 1 ? "" : "s")"
    )
    .accessibilityValue(summary?.includesCurrentUser == true ? "you reacted" : "")
    .accessibilityActions {
      if summary != nil, let onOpenReaction {
        Button("view people who reacted") { onOpenReaction(emoji) }
      }
    }
  }

  private func quickEmojiButtonLabel(
    emoji: String,
    summary: ReactionSummary?
  ) -> some View {
    HStack(spacing: LinkstrTheme.metaSpacing) {
      Text(emoji)
        .font(LinkstrTheme.font(mode == .watch ? .footnote : .subheadline))

      if let count = summary?.count, count > 0 {
        Text("\(count)")
          .font(LinkstrTheme.font(.caption, weight: .medium).monospacedDigit())
          .foregroundStyle(LinkstrTheme.textSecondary)
      }
    }
    .linkstrReactionChip(isSelected: summary?.includesCurrentUser == true, compact: mode == .watch)
  }
}

private extension View {
  func linkstrReactionChip(isSelected: Bool = false, compact: Bool = false) -> some View {
    padding(.horizontal, compact ? LinkstrTheme.tightSpacing : 10)
      .padding(.vertical, LinkstrTheme.metaSpacing)
      .background(isSelected && compact ? LinkstrTheme.accent.opacity(0.17) : .clear, in: Capsule())
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

struct LinkstrEmojiPickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @ScaledMetric(relativeTo: .body) private var scaledEmojiSize = 30.0

  let summaries: [ReactionSummary]
  let onPick: (String) -> Void

  @FocusState private var isSearchFocused: Bool
  @State private var query = ""
  @State private var category: EmojiCategory?
  @State private var selection: Emoji.GridSelection?

  var body: some View {
    let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let searchCategory = searchTerm.isEmpty ? nil : EmojiCategory.search(query: searchTerm)
    let compactSearch = isSearchFocused && verticalSizeClass == .compact
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        VStack(spacing: 0) {
          if !compactSearch {
            LinkstrSheetHeader(title: "add reaction", closeLabel: "close emoji picker") { dismiss() }
          }
          VStack(spacing: LinkstrTheme.compactSpacing) {
            if searchTerm.isEmpty && !compactSearch {
              LinkstrReactionRow(summaries: summaries, onToggleEmoji: pickEmoji)
            }
            HStack(spacing: LinkstrTheme.compactSpacing) {
              if compactSearch {
                LinkstrHeaderButton(title: "close emoji picker", icon: "xmark") { dismiss() }
              }
              LinkstrSearchField(prompt: "search emoji", text: $query) { isSearchFocused = false }
                .focused($isSearchFocused)
            }
          }
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, compactSearch ? LinkstrTheme.pageHeaderTopPadding : 0)
          .padding(.bottom, LinkstrTheme.compactSpacing)
          .linkstrReadableContent()

          if let searchCategory, searchCategory.emojis.isEmpty {
            ScrollView {
              Text("no emoji found. try another search.")
                .font(LinkstrTheme.font(.subheadline))
                .foregroundStyle(LinkstrTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
                .padding(.vertical, LinkstrTheme.compactSpacing)
                .linkstrReadableContent()
            }
            .scrollBounceBehavior(.basedOnSize)
          } else {
            emojiGrid(categories: searchCategory.map { [$0] })
          }
        }
      }
      .toolbarVisibility(.hidden, for: .navigationBar)
      .scrollDismissesKeyboard(.immediately)
    }
  }

  private func emojiGrid(categories: [EmojiCategory]?) -> some View {
    let emojiSize = min(48, scaledEmojiSize)
    return EmojiGridScrollView(
      axis: .vertical,
      categories: categories,
      category: $category,
      selection: $selection,
      action: { pickEmoji($0.char) },
      sectionTitle: {
        let title = $0.category.id == EmojiCategory.Persisted.frequent.id
          ? "frequently used"
          : $0.category.labelText.lowercased(with: .current)
        Text(title)
          .font(LinkstrTheme.font(.subheadline, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .accessibilityAddTraits(.isHeader)
      },
      gridItem: {
        $0.view
          .contentShape(Rectangle())
          .accessibilityAddTraits(.isButton)
      }
    )
    .emojiGridStyle(.init(
      font: .system(size: emojiSize), itemSize: max(LinkstrTheme.minimumInteractiveDimension, emojiSize + 14),
      itemSpacing: LinkstrTheme.compactSpacing, padding: 0, sectionSpacing: LinkstrTheme.listBlockSpacing
    ))
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .padding(.vertical, LinkstrTheme.compactSpacing)
    .linkstrReadableContent()
  }

  private func pickEmoji(_ emoji: String) {
    onPick(emoji)
    dismiss()
  }
}

extension PostDetailView {
  func postCardReactionBreakdown(_ participants: [ReactionParticipantBreakdown]) -> some View {
    let visibleParticipants = selectedReactionEmoji.map { emoji in
      participants.filter { $0.emojis.contains(emoji) }
    } ?? participants
    return VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      reactionFilters
      LazyVStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
        ForEach(visibleParticipants) { entry in
          HStack(alignment: .center, spacing: LinkstrTheme.compactSpacing) {
            LinkstrContactAvatar(name: entry.displayName, size: 32, seed: entry.id)
              .accessibilityHidden(true)

            let name = Text(entry.displayName)
              .font(LinkstrTheme.font(.subheadline, weight: .medium))
              .foregroundStyle(LinkstrTheme.textPrimary)
              .lineLimit(2)
              .truncationMode(.middle)
              .accessibilityLabel(entry.displayName)
            let emojis = Text(selectedReactionEmoji ?? entry.emojis.joined(separator: " "))
              .font(LinkstrTheme.font(.body))
              .foregroundStyle(LinkstrTheme.textPrimary)

            ViewThatFits(in: .horizontal) {
              HStack {
                name.fixedSize()
                Spacer(minLength: LinkstrTheme.compactSpacing)
                emojis.fixedSize()
              }
              VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
                name
                emojis
              }
              .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private var reactionFilters: some View {
    HStack(spacing: LinkstrTheme.compactSpacing) {
      reactionFilter("all", accessibilityTitle: "show all reactions", emoji: nil)
        .fixedSize(horizontal: true, vertical: false)
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: LinkstrTheme.compactSpacing) {
            ForEach(reactionSummaries) { summary in
              let count = summary.count == 1 ? "1 reaction" : "\(summary.count) reactions"
              reactionFilter(
                "\(summary.emoji) \(summary.count)",
                accessibilityTitle: "filter by \(summary.emoji), \(count)",
                emoji: summary.emoji
              )
              .id(summary.emoji)
            }
          }
        }
        .onChange(of: selectedReactionEmoji, initial: true) { _, emoji in
          if let emoji { proxy.scrollTo(emoji, anchor: .center) }
        }
      }
    }
    .onChange(of: reactionSummaries.map(\.emoji), initial: true) { _, emojis in
      if let selectedReactionEmoji, !emojis.contains(selectedReactionEmoji) {
        self.selectedReactionEmoji = nil
      }
    }
  }

  private func reactionFilter(_ title: String, accessibilityTitle: String, emoji: String?) -> some View {
    let isSelected = selectedReactionEmoji == emoji
    return Button {
      selectedReactionEmoji = emoji
    } label: {
      Text(title)
        .font(LinkstrTheme.font(.subheadline, weight: .medium))
        .foregroundStyle(isSelected ? LinkstrTheme.textPrimary : LinkstrTheme.textSecondary)
        .linkstrReactionChip(isSelected: isSelected)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityTitle)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
