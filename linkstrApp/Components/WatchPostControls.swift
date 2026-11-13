import SwiftUI

struct WatchPostSummary {
  let author: String
  let timestamp: String
  let caption: String?
  let note: String?
  let reactions: [ReactionSummary]
  let toggleReaction: ((String) -> Void)?
  let pickReaction: (() -> Void)?
  let openReactions: (String?) -> Void
  let shareLink: (() -> Void)?
}

/// A separate handle keeps post actions out of the player's tap and paging gestures.
struct WatchPostControls<Content: View>: View {
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
  @ViewBuilder let content: () -> Content
  @State private var isExpanded = false
  @State private var handleHeight = LinkstrTheme.minimumInteractiveDimension
  @State private var contentHeight: CGFloat = 240
  @State private var pullStartedAtTop = true

  var body: some View {
    GeometryReader { proxy in
      let bottom = bottomInset + playbackControlsHeight
      let availableHeight = max(1, proxy.size.height - topInset - bottom - LinkstrTheme.screenTopPadding)
      VStack(spacing: 0) {
        if isExpanded, verticalSizeClass == .compact {
          detailsScrollView(availableHeight: availableHeight, includesHeader: true)
        } else {
          controlsHeader
          if isExpanded {
            detailsScrollView(availableHeight: max(1, availableHeight - handleHeight), includesHeader: false)
          }
        }
      }
      .padding(.bottom, playbackControlsHeight == 0 ? LinkstrTheme.metaSpacing : 0)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
        if !isExpanded || reservesExpandedSpace { onReservedHeightChange(height) }
      }
      .linkstrReadableContent()
      .background(LinkstrTheme.background.opacity(isExpanded ? 0.98 : 0.82))
      .clipShape(.rect(
        topLeadingRadius: LinkstrTheme.cardCornerRadius, topTrailingRadius: LinkstrTheme.cardCornerRadius
      ))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .padding(.bottom, bottom)
    }
    .accessibilityAction(.escape) { setExpanded(false) }
  }

  private var controlsHeader: some View {
    VStack(spacing: 0) {
      handle
      quickActions
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
      handleHeight = height
    }
  }

  private func detailsScrollView(availableHeight: CGFloat, includesHeader: Bool) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        if includesHeader { controlsHeader }
        content().padding(.vertical, LinkstrTheme.compactSpacing)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
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
    let preview = showsLinkPreview ? summary.note : summary.caption
    let caption = isExpanded ? nil : preview.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    let textLayout = verticalSizeClass == .compact
      ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LinkstrTheme.rowSpacing))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
    return Button { setExpanded(!isExpanded) } label: {
      HStack(spacing: LinkstrTheme.rowSpacing) {
        textLayout {
          Text(summary.author)
            .font(LinkstrTheme.font(.caption, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact ? 2 : 1)
          if let caption {
            Text(caption)
              .font(LinkstrTheme.font(.subheadline))
              .foregroundStyle(LinkstrTheme.textPrimary)
              .lineLimit(verticalSizeClass == .compact ? 1 : 2)
              .fixedSize(horizontal: false, vertical: true)
          } else if dynamicTypeSize.isAccessibilitySize {
            Text(summary.timestamp)
              .font(LinkstrTheme.font(.caption))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if caption == nil && !dynamicTypeSize.isAccessibilitySize {
          Text(summary.timestamp)
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(1)
        }
        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .dynamicTypeSize(...DynamicTypeSize.xxLarge)
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(width: LinkstrTheme.minimumInteractiveDimension)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.vertical, LinkstrTheme.metaSpacing)
      .frame(maxWidth: .infinity, minHeight: LinkstrTheme.minimumInteractiveDimension)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .top) {
      if isExpanded {
        Capsule()
          .fill(LinkstrTheme.textSecondary.opacity(0.45))
          .frame(width: 24, height: 3)
          .padding(.top, 4)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .accessibilityLabel("\(summary.author), \(caption ?? summary.timestamp)")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityHint(isExpanded ? "hide post details" : "show post details")
    .highPriorityGesture(
      expansionGesture, including: isExpanded && verticalSizeClass == .compact ? .subviews : .all
    )
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
          onOpenReaction: { summary.openReactions($0) }
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
      if !summary.reactions.isEmpty {
        Button {
          summary.openReactions(nil)
        } label: {
          postActionIcon("person.2", size: 23, offset: CGSize(width: 0.75, height: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("view reactions")
      }
      if let shareLink = summary.shareLink {
        Button(action: shareLink) {
          postActionIcon("square.and.arrow.up", size: 21, offset: CGSize(width: 0.25, height: -0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("share link")
      }
    }
    // The emoji hit targets already inset their glyphs. Keep the trailing actions aligned with the toolbar.
    .padding(.leading, LinkstrTheme.tightSpacing)
    .padding(.trailing, LinkstrTheme.screenHorizontalPadding)
  }

  private func postActionIcon(_ systemName: String, size: CGFloat, offset: CGSize) -> some View {
    Image(systemName: systemName)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      // Center the visible symbol within the hit target despite its built-in padding.
      .offset(offset)
      .linkstrToolbarIconLabel()
      .foregroundStyle(LinkstrTheme.textPrimary)
  }

  private func setExpanded(_ expanded: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      isExpanded = expanded
    }
  }
}
