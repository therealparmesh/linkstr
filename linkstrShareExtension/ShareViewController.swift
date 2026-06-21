import Foundation
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  enum ShareAction {
    case shareLink
    case saveMedia
  }

  private enum Style {
    static let background = UIColor(red: 0.09, green: 0.10, blue: 0.16, alpha: 1)
    static let panel = UIColor(red: 0.13, green: 0.15, blue: 0.22, alpha: 1)
    static let panelMuted = UIColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1)
    static let separator = UIColor.white.withAlphaComponent(0.06)
    static let accent = UIColor(red: 0.49, green: 0.67, blue: 0.99, alpha: 1)
    static let textPrimary = UIColor(red: 0.92, green: 0.94, blue: 0.99, alpha: 1)
    static let textSecondary = UIColor(red: 0.66, green: 0.71, blue: 0.84, alpha: 1)
    static let textTertiary = UIColor(red: 0.48, green: 0.53, blue: 0.67, alpha: 1)

    static let screenHorizontalPadding: CGFloat = 16
    static let screenTopPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let compactSpacing: CGFloat = 8
    static let fieldHorizontalPadding: CGFloat = 14
    static let fieldVerticalPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 58
    static let fieldCornerRadius: CGFloat = 12
  }

  static let separatorColor = UIColor.white.withAlphaComponent(0.06)

  let activityIndicator = UIActivityIndicatorView(style: .medium)
  let titleLabel = UILabel()
  let statusLabel = UILabel()
  let loadingStack = UIStackView()
  let linkSectionLabel = UILabel()
  let linkLabel = UILabel()
  let linkFieldView = UIView()
  let actionSectionLabel = UILabel()
  let actionListView = UIStackView()
  let shareButton = UIButton(type: .system)
  let saveButton = UIButton(type: .system)
  let closeButton = UIButton(type: .system)

  var extractedShare: ExtractedShare?
  private var didStart = false

  override func viewDidLoad() {
    super.viewDidLoad()
    configureView()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didStart else { return }
    didStart = true
    beginShareHandoff()
  }

  private func configureView() {
    view.backgroundColor = Style.background
    configureCloseButton()
    configureTitleLabel()
    configureLoadingStack()
    configureLinkField()
    configureActionList()
    configureLayout()
    setLoading(message: "preparing share...")
  }

  private func configureCloseButton() {
    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = Style.textSecondary
    closeButton.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.accessibilityLabel = "close"
  }

  private func configureTitleLabel() {
    titleLabel.text = "share"
    titleLabel.textColor = Style.textPrimary
    titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
  }

  private func configureLoadingStack() {
    activityIndicator.color = Style.accent
    activityIndicator.startAnimating()
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.text = "preparing share..."
    statusLabel.textColor = Style.textSecondary
    statusLabel.font = .systemFont(ofSize: 14, weight: .regular)
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .left
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    loadingStack.axis = .horizontal
    loadingStack.alignment = .center
    loadingStack.spacing = Style.rowSpacing
    loadingStack.translatesAutoresizingMaskIntoConstraints = false
    loadingStack.addArrangedSubview(activityIndicator)
    loadingStack.addArrangedSubview(statusLabel)
  }

  private func configureLinkField() {
    linkSectionLabel.text = "link"
    configureSectionLabel(linkSectionLabel)

    linkLabel.textColor = Style.textPrimary
    linkLabel.font = .systemFont(ofSize: 14, weight: .regular)
    linkLabel.numberOfLines = 3
    linkLabel.textAlignment = .left
    linkLabel.translatesAutoresizingMaskIntoConstraints = false

    linkFieldView.backgroundColor = Style.panelMuted
    linkFieldView.layer.cornerRadius = Style.fieldCornerRadius
    linkFieldView.layer.cornerCurve = .continuous
    linkFieldView.layer.borderColor = Style.separator.cgColor
    linkFieldView.layer.borderWidth = 1
    linkFieldView.translatesAutoresizingMaskIntoConstraints = false
    linkFieldView.addSubview(linkLabel)
  }

  private func configureActionList() {
    actionSectionLabel.text = "action"
    configureSectionLabel(actionSectionLabel)

    configureActionRow(
      shareButton,
      title: "share link",
      subtitle: "choose a session and add an optional note",
      systemImage: "paperplane.fill",
      action: #selector(performShareLink)
    )
    configureActionRow(
      saveButton,
      title: "save media",
      subtitle: "save supported media to your photo library",
      systemImage: "arrow.down.circle.fill",
      action: #selector(performSaveMedia)
    )

    actionListView.axis = .vertical
    actionListView.alignment = .fill
    actionListView.spacing = 0
    actionListView.backgroundColor = Style.panel
    actionListView.layer.cornerRadius = Style.fieldCornerRadius
    actionListView.layer.cornerCurve = .continuous
    actionListView.layer.borderColor = Style.separator.cgColor
    actionListView.layer.borderWidth = 1
    actionListView.clipsToBounds = true
    actionListView.translatesAutoresizingMaskIntoConstraints = false
    actionListView.addArrangedSubview(shareButton)
    actionListView.addArrangedSubview(makeDivider())
    actionListView.addArrangedSubview(saveButton)
  }

  private func configureLayout() {
    let stack = UIStackView(
      arrangedSubviews: [
        titleLabel,
        loadingStack,
        linkSectionLabel,
        linkFieldView,
        actionSectionLabel,
        actionListView
      ])
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = Style.compactSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setCustomSpacing(Style.sectionSpacing, after: titleLabel)
    stack.setCustomSpacing(Style.sectionSpacing, after: loadingStack)
    stack.setCustomSpacing(Style.sectionSpacing, after: linkFieldView)

    view.addSubview(closeButton)
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      closeButton.leadingAnchor.constraint(
        equalTo: view.leadingAnchor, constant: Style.screenHorizontalPadding),
      closeButton.widthAnchor.constraint(equalToConstant: 30),
      closeButton.heightAnchor.constraint(equalToConstant: 30),

      stack.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 18),
      stack.leadingAnchor.constraint(
        equalTo: view.leadingAnchor, constant: Style.screenHorizontalPadding),
      stack.trailingAnchor.constraint(
        equalTo: view.trailingAnchor, constant: -Style.screenHorizontalPadding),

      linkLabel.topAnchor.constraint(
        equalTo: linkFieldView.topAnchor, constant: Style.fieldVerticalPadding),
      linkLabel.leadingAnchor.constraint(
        equalTo: linkFieldView.leadingAnchor, constant: Style.fieldHorizontalPadding),
      linkLabel.trailingAnchor.constraint(
        equalTo: linkFieldView.trailingAnchor, constant: -Style.fieldHorizontalPadding),
      linkLabel.bottomAnchor.constraint(
        equalTo: linkFieldView.bottomAnchor, constant: -Style.fieldVerticalPadding),

      shareButton.heightAnchor.constraint(equalToConstant: Style.rowHeight),
      saveButton.heightAnchor.constraint(equalToConstant: Style.rowHeight)
    ])
  }

  private func configureSectionLabel(_ label: UILabel) {
    label.textColor = Style.textSecondary
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.translatesAutoresizingMaskIntoConstraints = false
  }

  private func configureActionRow(
    _ button: UIButton,
    title: String,
    subtitle: String,
    systemImage: String,
    action: Selector
  ) {
    var configuration = UIButton.Configuration.plain()
    configuration.title = title
    configuration.subtitle = subtitle
    configuration.image = UIImage(systemName: systemImage)
    configuration.imagePadding = Style.rowSpacing
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0,
      leading: Style.fieldHorizontalPadding,
      bottom: 0,
      trailing: Style.fieldHorizontalPadding
    )
    configuration.baseForegroundColor = Style.textPrimary
    configuration.titleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = .systemFont(ofSize: 15, weight: .semibold)
        return attributes
      }
    configuration.subtitleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = .systemFont(ofSize: 12, weight: .regular)
        attributes.foregroundColor = Style.textSecondary
        return attributes
      }
    button.configuration = configuration
    button.contentHorizontalAlignment = .leading
    button.addTarget(self, action: action, for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
  }
}
