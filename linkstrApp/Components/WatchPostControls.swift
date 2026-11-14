import SwiftUI

struct WatchPostSummary {
  let caption: String?
  let note: String?
  let reactions: [ReactionSummary]
  let toggleReaction: ((String) -> Void)?
  let pickReaction: (() -> Void)?
  let openReactions: (String?) -> Void
  let shareLink: (() -> Void)?
}

/// Post details and actions stay separate from playback and post paging.
struct WatchPostControls<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  let summary: WatchPostSummary
  let topInset: CGFloat
  let bottomInset: CGFloat
  let playbackControlsHeight: CGFloat
  var showsLinkPreview = false
  var reservesExpandedSpace = false
  var onReservedHeightChange: (CGFloat) -> Void = { _ in }
  @ViewBuilder let content: () -> Content
  @State private var isExpanded = false
  @State private var headerHeight = LinkstrTheme.minimumInteractiveDimension
  @State private var actionsHeight = LinkstrTheme.minimumInteractiveDimension
  @State private var contentHeight: CGFloat = 240
  @State private var pullStartedAtTop = true

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
          detailsScrollView(availableHeight: max(1, availableHeight - headerHeight - actionsHeight))
        }
        quickActions
          .highPriorityGesture(expansionGesture)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            actionsHeight = $0
          }
      }
      .padding(.bottom, playbackControlsHeight == 0 ? LinkstrTheme.metaSpacing : 0)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: { height in
        if !isExpanded || reservesExpandedSpace { onReservedHeightChange(height) }
      }
      .linkstrReadableContent()
      .background(LinkstrTheme.background.opacity(isExpanded ? 0.98 : 0.82))
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
        LinkstrTheme.background.opacity(isExpanded ? 0.98 : 0.82)
          .frame(height: bottomInset)
          .allowsHitTesting(false)
      }
    }
    .accessibilityAction(.escape) { setExpanded(false) }
  }

  private func detailsScrollView(availableHeight: CGFloat) -> some View {
    ScrollView {
      content()
        .padding(.bottom, LinkstrTheme.compactSpacing)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .scrollBounceBehavior(.basedOnSize)
    .onScrollPhaseChange { _, phase, context in
      if phase == .interacting {
        pullStartedAtTop = context.geometry.contentOffset.y + context.geometry.contentInsets.top <= 1
      }
    }
    .frame(height: min(contentHeight, availableHeight))
    .contentShape(Rectangle())
    .highPriorityGesture(expansionGesture, including: contentHeight <= availableHeight ? .all : .subviews)
    .simultaneousGesture(scrollDismissGesture, including: contentHeight > availableHeight ? .all : .subviews)
    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
  }

  private var handle: some View {
    let preview = summary.note ?? (showsLinkPreview ? nil : summary.caption)
    let caption = isExpanded ? nil : preview.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    return Button {
      setExpanded(!isExpanded)
    } label: {
      HStack(spacing: LinkstrTheme.rowSpacing) {
        Text(caption ?? "post details")
          .font(LinkstrTheme.font(.subheadline))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(verticalSizeClass == .compact ? 1 : 2)
          .fixedSize(horizontal: false, vertical: true)
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
    .accessibilityLabel(caption ?? "post details")
    .accessibilityIdentifier("post details")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityHint(isExpanded ? "hide post details" : "show post details")
    .highPriorityGesture(expansionGesture)
    .accessibilityAction(.escape) { setExpanded(false) }
  }

  private var expansionGesture: some Gesture {
    DragGesture(minimumDistance: 12)
      .onEnded { value in
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        setExpanded(value.translation.height < 0)
      }
  }

  private var scrollDismissGesture: some Gesture {
    DragGesture(minimumDistance: 16)
      .onEnded { value in
        if pullStartedAtTop, value.translation.height > max(56, abs(value.translation.width)) {
          setExpanded(false)
        }
      }
  }

  private var quickActions: some View {
    HStack(spacing: 0) {
      if summary.toggleReaction != nil || !summary.reactions.isEmpty {
        LinkstrReactionRow(
          summaries: summary.reactions,
          mode: .watch,
          onToggleEmoji: summary.toggleReaction,
          onOpenReaction: { summary.openReactions($0) },
          onOpenAllReactions: { summary.openReactions(nil) }
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
      if isExpanded, !summary.reactions.isEmpty {
        Button {
          summary.openReactions(nil)
        } label: {
          Image(systemName: "person.2").linkstrToolbarIconLabel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("view reactions")
      }
      if let shareLink = summary.shareLink {
        Button(action: shareLink) {
          Image(systemName: "square.and.arrow.up").linkstrToolbarIconLabel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("share link")
      }
    }
    .foregroundStyle(LinkstrTheme.textPrimary)
    .padding(.horizontal, LinkstrTheme.controlHorizontalPadding)
  }

  private func setExpanded(_ expanded: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      isExpanded = expanded
    }
  }
}
