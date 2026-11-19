import SwiftUI

private struct LinkstrErrorToast: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let message: String
  var isSuccess: Bool = false
  var opensRelaySettings: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: LinkstrTheme.buttonRowSpacing) {
      Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(LinkstrTheme.font(.subheadline, weight: .semibold))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .foregroundStyle(isSuccess ? LinkstrTheme.statusSuccess : LinkstrTheme.amber)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(message)
          .font(LinkstrTheme.font(.footnote))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)

        if opensRelaySettings {
          Text("open relay settings")
            .font(LinkstrTheme.font(.footnote, weight: .semibold))
            .foregroundStyle(LinkstrTheme.accent)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !opensRelaySettings {
        Image(systemName: "xmark")
          .font(LinkstrTheme.font(.caption, weight: .semibold))
          .dynamicTypeSize(...DynamicTypeSize.xLarge)
          .foregroundStyle(LinkstrTheme.textSecondary)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
    .frame(minHeight: LinkstrTheme.minimumInteractiveDimension)
    .background(.regularMaterial, in: .rect(cornerRadius: LinkstrTheme.cardCornerRadius))
  }
}

extension Notification.Name {
  static let linkstrSuccessToast = Notification.Name("linkstrSuccessToast")
}

enum LinkstrToast {
  @MainActor
  static func showSuccess(_ message: String) {
    NotificationCenter.default.post(name: .linkstrSuccessToast, object: message)
  }
}

@MainActor
@Observable
final class LinkstrToastPresenter {
  struct Message: Identifiable {
    let id = UUID()
    let text: String
    let isSuccess: Bool
    let opensRelaySettings: Bool
  }

  private(set) var message: Message?
  private(set) var relaySettingsRequest: UUID?
  private(set) var headers: [UUID] = []

  func register(_ id: UUID) {
    headers.removeAll { $0 == id }
    headers.append(id)
  }

  func unregister(_ id: UUID) {
    headers.removeAll { $0 == id }
  }

  func show(_ text: String, isSuccess: Bool, opensRelaySettings: Bool = false) {
    message = Message(text: text, isSuccess: isSuccess, opensRelaySettings: opensRelaySettings)
    UIAccessibility.post(notification: .announcement, argument: text)
  }

  func dismiss(_ id: UUID, tapped: Bool = false) {
    guard let message, message.id == id else { return }
    self.message = nil
    if tapped && message.opensRelaySettings { relaySettingsRequest = UUID() }
  }
}

/// Only the frontmost app header presents the scene's current notification.
struct LinkstrToastOutlet: View {
  @Environment(LinkstrToastPresenter.self) private var presenter: LinkstrToastPresenter?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var id = UUID()

  var body: some View {
    VStack(spacing: 0) {
      if let presenter, presenter.headers.last == id, let message = presenter.message {
        Button {
          presenter.dismiss(message.id, tapped: true)
        } label: {
          LinkstrErrorToast(
            message: message.text, isSuccess: message.isSuccess, opensRelaySettings: message.opensRelaySettings)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(message.opensRelaySettings ? "opens relay settings" : "dismisses notification")
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.bottom, LinkstrTheme.compactSpacing)
        .linkstrReadableContent()
        .transition(.opacity)
        .task(id: message.id) {
          guard message.isSuccess else { return }
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          presenter.dismiss(message.id)
        }
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presenter?.message?.id)
    .onAppear { presenter?.register(id) }
    .onDisappear { presenter?.unregister(id) }
  }
}
