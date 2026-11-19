import EmojiKit
import SwiftUI

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

          if compactSearch { LinkstrToastOutlet() }

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
        let title =
          $0.category.id == EmojiCategory.Persisted.frequent.id
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
    .emojiGridStyle(
      .init(
        font: .system(size: emojiSize), itemSize: max(LinkstrTheme.minimumInteractiveDimension, emojiSize + 14),
        itemSpacing: LinkstrTheme.compactSpacing, padding: 0, sectionSpacing: LinkstrTheme.listBlockSpacing
      )
    )
    .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
    .padding(.vertical, LinkstrTheme.compactSpacing)
    .linkstrReadableContent()
  }

  private func pickEmoji(_ emoji: String) {
    onPick(emoji)
    dismiss()
  }
}
