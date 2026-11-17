import SwiftUI

struct LinkstrPageHeader<Actions: View>: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  var backLabel: String?
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.tightSpacing) {
      LinkstrPageTopBar(hasBackButton: backLabel != nil) {
        if let backLabel {
          LinkstrHeaderButton(title: backLabel, icon: "chevron.backward") {
            dismiss()
          }
        }
      } actions: {
        actions
      }
      LinkstrScreenTitle(title: title)
        .lineLimit(3)
    }
  }
}

struct LinkstrPageTopBar<Leading: View, Actions: View>: View {
  var hasBackButton = false
  @ViewBuilder let leading: Leading
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(spacing: LinkstrTheme.metaSpacing) {
      leading.padding(.leading, hasBackButton ? -LinkstrTheme.toolbarOpticalInset : 0)
      LinkstrBrandLabel()
        .dynamicTypeSize(...DynamicTypeSize.large)
      Spacer(minLength: 0)
      HStack(spacing: 0) { actions }
        .padding(.trailing, -LinkstrTheme.toolbarOpticalInset)
    }
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
  }
}

struct LinkstrHeaderButton: View {
  @Environment(\.isEnabled) private var isEnabled

  let title: String
  let icon: String
  var foreground: Color = LinkstrTheme.accent
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: LinkstrTheme.toolbarSymbolSize, weight: .semibold))
        .frame(
          width: LinkstrTheme.toolbarSymbolSize, height: LinkstrTheme.toolbarSymbolSize,
          alignment: icon == "chevron.backward" ? .leading : .center
        )
        .linkstrToolbarIconLabel()
        .foregroundStyle(foreground)
        .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}

struct LinkstrPageShortcut: View {
  let title: String
  let icon: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: LinkstrTheme.buttonRowSpacing) {
        Image(systemName: icon)
          .dynamicTypeSize(...DynamicTypeSize.xLarge)
          .foregroundStyle(LinkstrTheme.accent)
          .accessibilityHidden(true)
        Text(title)
          .frame(maxWidth: .infinity, alignment: .leading)
        LinkstrDisclosureIndicator()
      }
      .font(LinkstrTheme.font(.subheadline, weight: .semibold))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
      .padding(.vertical, LinkstrTheme.compactSpacing)
      .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
      .background(LinkstrTheme.panel, in: .rect(cornerRadius: LinkstrTheme.fieldCornerRadius))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct LinkstrDisclosureIndicator: View {
  var body: some View {
    Image(systemName: "chevron.forward")
      .font(LinkstrTheme.font(.caption, weight: .semibold))
      .dynamicTypeSize(...DynamicTypeSize.xLarge)
      .foregroundStyle(LinkstrTheme.textSecondary)
      .accessibilityHidden(true)
  }
}

struct LinkstrScreenTitle: View {
  let title: String

  var body: some View {
    Text(title)
      .font(LinkstrTheme.font(.largeTitle, weight: .bold))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Secondary surfaces use a compact title without repeating the app branding.
struct LinkstrSheetTitle: View {
  let title: String

  var body: some View {
    Text(title)
      .font(LinkstrTheme.font(.title2, weight: .bold))
      .foregroundStyle(LinkstrTheme.textPrimary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
  }
}

struct LinkstrSheetHeader: View {
  let title: String
  let closeLabel: String
  let close: () -> Void

  var body: some View {
    LinkstrSheetBar(title: title) {
      LinkstrHeaderButton(title: closeLabel, icon: "xmark", action: close)
    } actions: {
      EmptyView()
    }
  }
}

private struct LinkstrSheetBar<Leading: View, Actions: View>: View {
  let title: String
  @ViewBuilder let leading: Leading
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(spacing: LinkstrTheme.compactSpacing) {
      leading
      LinkstrSheetTitle(title: title)
      actions
    }
    .padding(.horizontal, -LinkstrTheme.toolbarOpticalInset)
    .linkstrPageHeaderLayout()
    .background(LinkstrTheme.chrome)
  }
}

private struct LinkstrBrandLabel: View {
  var body: some View {
    Text("linkstr")
      .font(LinkstrTheme.font(.headline, weight: .bold))
      .foregroundStyle(LinkstrTheme.accentPink)
      .accessibilityHidden(true)
  }
}

extension View {
  func linkstrSheetHeader<Leading: View, Actions: View>(
    title: String,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    toolbarVisibility(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        LinkstrSheetBar(title: title, leading: leading, actions: actions)
      }
  }

  func linkstrPinnedPageHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      header()
        .linkstrPageHeaderLayout()
        .background(LinkstrTheme.chrome)
    }
  }

  func linkstrPageHeaderLayout() -> some View {
    padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.pageHeaderTopPadding)
      .padding(.bottom, LinkstrTheme.compactSpacing)
      .linkstrReadableContent()
  }

  func linkstrNavigationBarChrome() -> some View {
    toolbarBackground(.visible, for: .navigationBar)
      .toolbarBackground(LinkstrTheme.chrome, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
  }

  func linkstrToolbarIconLabel() -> some View {
    font(.system(size: LinkstrTheme.toolbarSymbolSize, weight: .semibold))
      .frame(width: LinkstrTheme.minimumInteractiveDimension, height: LinkstrTheme.minimumInteractiveDimension)
      .contentShape(Rectangle())
  }

  func linkstrMediaOverlayIconLabel() -> some View {
    linkstrToolbarIconLabel()
      .foregroundStyle(LinkstrTheme.textPrimary)
      .background(LinkstrTheme.mediaButtonBackground, in: Circle())
  }
}
