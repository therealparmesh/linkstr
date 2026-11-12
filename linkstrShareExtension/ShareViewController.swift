import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
  enum ShareAction {
    case shareLink
    case saveMedia
  }

  var extractedShare: ExtractedShare?
  var isOpening = false
  var isClosed = false
  var extractionTimeout: DispatchWorkItem?
  private var didStart = false
  private var host: UIHostingController<ShareExtensionScreen>?

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = UIColor(LinkstrTheme.background)
    view.tintColor = UIColor(LinkstrTheme.accent)
    let host = UIHostingController(rootView: screen(.loading("checking link…")))
    self.host = host
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    host.didMove(toParent: self)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didStart else { return }
    didStart = true
    beginShareHandoff()
  }

  func setLoading(message: String) {
    host?.rootView = screen(.loading(message))
  }

  func presentActions(for share: ExtractedShare, error: String? = nil) {
    extractedShare = share
    host?.rootView = screen(.ready(share, error: error))
  }

  func presentUnavailable(_ message: String) {
    host?.rootView = screen(.unavailable(message))
  }

  private func screen(_ state: ShareExtensionScreen.State) -> ShareExtensionScreen {
    ShareExtensionScreen(
      state: state,
      close: { [weak self] in self?.cancelShare() },
      choose: { [weak self] action in self?.openContainingApp(for: action) }
    )
  }
}

private struct ShareExtensionScreen: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  enum State {
    case loading(String)
    case ready(ExtractedShare, error: String?)
    case unavailable(String)
  }

  let state: State
  let close: () -> Void
  let choose: (ShareViewController.ShareAction) -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          LinkstrSheetTitle(title: "share with linkstr")
          switch state {
          case .loading(let message):
            HStack(spacing: LinkstrTheme.rowSpacing) {
              ProgressView()
                .tint(LinkstrTheme.accent)
                .accessibilityHidden(true)
              Text(message)
                .font(LinkstrTheme.font(.subheadline))
                .foregroundStyle(LinkstrTheme.textSecondary)
            }
          case .ready(let share, let error):
            if let error { statusCard(title: "couldn’t open linkstr", message: error) }
            linkPreview(share.url)
            VStack(spacing: 0) {
              actionRow("share to session", subtitle: "choose a session, with an optional note",
                        icon: "paperplane", action: .shareLink)
              Rectangle().fill(LinkstrTheme.separator).frame(height: 1)
                .accessibilityHidden(true)
              actionRow("save video", subtitle: "look for a downloadable video",
                        icon: "square.and.arrow.down", action: .saveMedia)
            }
            .linkstrCardSurface()
          case .unavailable(let message):
            statusCard(title: "link unavailable", message: message)
          }
        }
        .linkstrPageContentLayout()
      }
      .background(LinkstrBackgroundView())
      .linkstrNavigationBarChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          LinkstrHeaderButton(title: "close", icon: "xmark", action: close)
        }
        .linkstrFlatToolbarItem()
      }
    }
    .preferredColorScheme(.dark)
    .tint(LinkstrTheme.accent)
  }

  private func statusCard(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      Label(title, systemImage: "exclamationmark.circle")
        .font(LinkstrTheme.font(.headline))
        .foregroundStyle(LinkstrTheme.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(message)
        .font(LinkstrTheme.font(.subheadline))
        .foregroundStyle(LinkstrTheme.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(LinkstrTheme.panelPadding)
    .linkstrCardSurface()
  }

  private func linkPreview(_ url: String) -> some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
      Label(URL(string: url)?.host ?? "link", systemImage: "link")
        .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        .foregroundStyle(LinkstrTheme.accent)
      LinkstrURLText(address: url, lineLimit: 3)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(LinkstrTheme.panelPadding)
    .linkstrCardSurface()
    .accessibilityElement(children: .combine)
  }

  private func actionRow(
    _ title: String, subtitle: String, icon: String, action: ShareViewController.ShareAction
  ) -> some View {
    Button { choose(action) } label: {
      HStack(
        alignment: dynamicTypeSize.isAccessibilitySize ? .firstTextBaseline : .center,
        spacing: LinkstrTheme.rowSpacing
      ) {
        Image(systemName: icon)
          .font(LinkstrTheme.font(.title3, weight: .semibold))
          .dynamicTypeSize(...DynamicTypeSize.xLarge)
          .frame(width: 24)
          .foregroundStyle(LinkstrTheme.accent)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
          Text(title)
            .font(LinkstrTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
          Text(subtitle)
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if !dynamicTypeSize.isAccessibilitySize {
          LinkstrDisclosureIndicator()
        }
      }
      .padding(.horizontal, LinkstrTheme.panelPadding)
      .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
      .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
  }
}
