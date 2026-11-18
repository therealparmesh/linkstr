import SwiftUI

extension EnvironmentValues {
  @Entry var watchPanelBackground = LinkstrTheme.watchOverlay
}

struct WatchPostSummary {
  let author: String
  let timestamp: String
  let editNote: (() -> Void)?
  let caption: String?
  let note: String?
  let reactions: [ReactionSummary]
  let toggleReaction: ((String) -> Void)?
  let pickReaction: (() -> Void)?
  @Binding var expanded: Bool
}

/// Post details and actions stay separate from playback and post paging.
struct WatchPostControls<Content: View>: View {
  @Environment(\.watchPanelBackground) private var panelBackground
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  let summary: WatchPostSummary
  let topInset: CGFloat
  let bottomInset: CGFloat
  let playbackControlsHeight: CGFloat
  var showsLinkPreview = false
  var reservesExpandedSpace = false
  var onReservedHeightChange: (CGFloat) -> Void = { _ in }
  @ViewBuilder let content: (WatchReactionActions) -> Content
  private var isExpanded: Bool { summary.expanded }
  @State private var headerHeight = LinkstrTheme.minimumInteractiveDimension
  @State private var contentHeight: CGFloat = 240
  @State private var detailsPosition = ScrollPosition(edge: .top)
  @State private var opensAtReactions = true

  var body: some View {
    GeometryReader { proxy in
      let bottom = bottomInset + playbackControlsHeight
      let availableHeight = max(1, proxy.size.height - topInset - bottom - LinkstrTheme.screenTopPadding)
      VStack(spacing: 0) {
        handle
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            headerHeight = $0
          }
        if isExpanded {
          detailsScrollView(availableHeight: max(1, min(proxy.size.height / 2, availableHeight - headerHeight)))
        } else {
          quickActions
        }
      }
      .padding(.bottom, playbackControlsHeight == 0 ? LinkstrTheme.metaSpacing : 0)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: { height in
        if !isExpanded || reservesExpandedSpace { onReservedHeightChange(height) }
      }
      .linkstrReadableContent()
      .background(panelBackground)
      .clipShape(
        .rect(
          topLeadingRadius: LinkstrTheme.cardCornerRadius, topTrailingRadius: LinkstrTheme.cardCornerRadius
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .padding(.bottom, bottom)
    }
    .background(alignment: .bottom) {
      if playbackControlsHeight == 0 {
        panelBackground
          .frame(height: bottomInset)
          .allowsHitTesting(false)
      }
    }
    .accessibilityAction(.escape) { setExpanded(false) }
  }

  private func detailsScrollView(availableHeight: CGFloat) -> some View {
    ScrollView {
      content(quickActions)
        .padding(.bottom, LinkstrTheme.compactSpacing)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .scrollPosition($detailsPosition)
    .scrollBounceBehavior(.basedOnSize)
    .onAppear {
      if opensAtReactions {
        detailsPosition.scrollTo(id: WatchReactionActions.anchor, anchor: .top)
      } else {
        detailsPosition.scrollTo(edge: .top)
      }
    }
    .frame(height: min(contentHeight, availableHeight))
    .contentShape(Rectangle())
    .transition(.opacity)
  }

  private var handle: some View {
    let preview = summary.note ?? (showsLinkPreview ? nil : summary.caption)
    let caption = isExpanded ? nil : preview.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    return Button {
      opensAtReactions = false
      setExpanded(!isExpanded)
    } label: {
      HStack(spacing: LinkstrTheme.rowSpacing) {
        VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
          let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LinkstrTheme.compactSpacing))
          layout {
            Text(summary.author).font(LinkstrTheme.font(.caption, weight: .semibold)).lineLimit(1)
            Text(summary.timestamp).font(LinkstrTheme.font(.caption)).lineLimit(1)
          }
          .foregroundStyle(LinkstrTheme.textSecondary)
          if let caption {
            Text(caption)
              .font(LinkstrTheme.font(.subheadline))
              .foregroundStyle(LinkstrTheme.textPrimary)
              .lineLimit(verticalSizeClass == .compact ? 1 : 2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .dynamicTypeSize(...DynamicTypeSize.xxLarge)
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(width: LinkstrTheme.minimumInteractiveDimension)
          .accessibilityHidden(true)
      }
      .padding(.leading, LinkstrTheme.screenHorizontalPadding)
      .padding(.trailing, LinkstrTheme.controlHorizontalPadding)
      .padding(.top, LinkstrTheme.rowSpacing)
      .padding(.bottom, LinkstrTheme.compactSpacing)
      .frame(maxWidth: .infinity, minHeight: LinkstrTheme.minimumInteractiveDimension)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(summary.author), \(summary.timestamp), \(caption ?? "post details")")
    .accessibilityIdentifier("post details")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityHint(isExpanded ? "hide post details" : "show post details")
    .contextMenu {
      if !isExpanded, summary.note != nil, let editNote = summary.editNote {
        Button("edit note", systemImage: "pencil", action: editNote)
      }
    }
    .accessibilityAction(.escape) { setExpanded(false) }
  }

  private var quickActions: WatchReactionActions {
    WatchReactionActions(summary: summary) {
      opensAtReactions = true
      if isExpanded {
        detailsPosition.scrollTo(id: WatchReactionActions.anchor, anchor: .top)
      } else {
        setExpanded(true)
      }
    }
  }

  private func setExpanded(_ expanded: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      summary.expanded = expanded
    }
  }
}

struct WatchReactionActions: View {
  static let anchor = "post reactions"
  let summary: WatchPostSummary
  let showReactions: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      if summary.toggleReaction != nil || !summary.reactions.isEmpty {
        LinkstrReactionRow(
          summaries: summary.reactions,
          mode: .watch,
          onToggleEmoji: summary.toggleReaction,
          onShowBreakdown: showReactions
        )
        .padding(.trailing, LinkstrTheme.metaSpacing)
      }
      Spacer(minLength: 0)
      if let pickReaction = summary.pickReaction {
        Button(action: pickReaction) {
          Image(systemName: "face.smiling")
            .overlay(alignment: .topTrailing) {
              Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
                .padding(2)
                .background(LinkstrTheme.background, in: Circle())
                .offset(x: 4, y: -3)
            }
            .linkstrToolbarIconLabel()
            .foregroundStyle(LinkstrTheme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("add reaction")
      }
    }
    .foregroundStyle(LinkstrTheme.textPrimary)
    .padding(.leading, LinkstrTheme.screenHorizontalPadding)
    .padding(.trailing, LinkstrTheme.controlHorizontalPadding)
    .id(Self.anchor)
  }
}
