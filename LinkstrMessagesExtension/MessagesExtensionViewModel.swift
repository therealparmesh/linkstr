import Foundation
import Messages
import UIKit

@MainActor
final class MessagesExtensionViewModel: ObservableObject {
  enum ValidationState: Equatable {
    case empty
    case invalid
    case valid(LinkCategory)
  }

  enum LinkCategory: Equatable {
    case extractable(LinkType)
    case embeddable(LinkType)

    var iconName: String {
      switch self {
      case .extractable:
        return "play.circle.fill"
      case .embeddable:
        return "play.rectangle.fill"
      }
    }

    var title: String {
      switch self {
      case .extractable(let linkType):
        return "\(displayName(for: linkType)) • Direct Playback"
      case .embeddable(let linkType):
        return "\(displayName(for: linkType)) • Embedded"
      }
    }

    private func displayName(for linkType: LinkType) -> String {
      switch linkType {
      case .tiktok:
        return "TikTok"
      case .instagram:
        return "Instagram"
      case .facebook:
        return "Facebook"
      case .youtube:
        return "YouTube"
      case .rumble:
        return "Rumble"
      case .twitter:
        return "X"
      case .generic:
        return "Video"
      }
    }
  }

  @Published var urlInput: String = "" {
    didSet { validateInput() }
  }
  @Published private(set) var validationState: ValidationState = .empty
  @Published private(set) var selectedPayload: LinkstrDeepLinkPayload?
  @Published private(set) var isPreparingMessage = false
  @Published var selectionError: String?
  @Published var sendError: String?

  func pasteFromClipboard() {
    guard let clipboardText = UIPasteboard.general.string else { return }
    urlInput = clipboardText
  }

  func clearInput() {
    urlInput = ""
    validationState = .empty
    sendError = nil
  }

  func clearSelection() {
    selectedPayload = nil
    selectionError = nil
  }

  func selectMessage(_ message: MSMessage?) {
    guard let message else {
      clearSelection()
      return
    }

    guard let url = message.url,
      let payload = LinkstrMessagePayloadCodec.parsePayload(fromMessageURL: url)
    else {
      selectedPayload = nil
      selectionError = "This message wasn't created by Linkstr or is no longer valid."
      return
    }

    selectedPayload = payload
    selectionError = nil
  }

  func createMessage() async -> MSMessage? {
    guard !isPreparingMessage else { return nil }
    guard case .valid = validationState else { return nil }
    guard let normalizedURL = LinkstrURLValidator.normalizedWebURL(from: urlInput) else {
      return nil
    }

    sendError = nil
    isPreparingMessage = true
    defer { isPreparingMessage = false }

    let message = await LinkMessageBuilder.createMessage(normalizedURL: normalizedURL)
    if message == nil {
      sendError = "Couldn't load link preview. Try again."
    }
    return message
  }

  func makeOpenInLinkstrURL() -> URL? {
    guard let selectedPayload else { return nil }
    return LinkstrMessagePayloadCodec.makeAppDeepLink(payload: selectedPayload)
  }

  private func validateInput() {
    let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      validationState = .empty
      return
    }

    guard let normalized = LinkstrURLValidator.normalizedWebURL(from: trimmed),
      let url = URL(string: normalized)
    else {
      validationState = .invalid
      return
    }

    let strategy = URLClassifier.mediaStrategy(for: url)
    let linkType = URLClassifier.classify(url)

    switch strategy {
    case .extractionPreferred:
      validationState = .valid(.extractable(linkType))
    case .embedOnly:
      validationState = .valid(.embeddable(linkType))
    case .link:
      validationState = .invalid
    }
  }
}
