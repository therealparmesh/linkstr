import Messages
import SwiftUI

struct MessagesExtensionView: View {
  @ObservedObject var viewModel: MessagesExtensionViewModel
  let onSend: (MSMessage) -> Void
  let onOpenInLinkstr: (URL) -> Void
  let onCloseSelected: () -> Void

  var body: some View {
    ZStack {
      Color(red: 0.08, green: 0.09, blue: 0.12)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 14) {
        header

        if isShowingSelectedSurface {
          selectedMessageSurface
        } else {
          composeSurface
        }
      }
      .padding(14)
    }
  }

  private var header: some View {
    HStack {
      Text("linkstr")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
      Spacer()

      if !isShowingSelectedSurface {
        sendButton
      }
    }
  }

  private var composeSurface: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Paste a supported video URL")
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.68))

      inputCard

      validationStatus

      if let sendError = viewModel.sendError {
        Text(sendError)
          .font(.caption)
          .foregroundStyle(Color.red.opacity(0.9))
      }
    }
  }

  private var selectedMessageSurface: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let payload = viewModel.selectedPayload {
        Text("Selected Linkstr message")
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.75))

        Text(payload.url)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.9))
          .lineLimit(3)

        if let selectionError = viewModel.selectionError {
          Text(selectionError)
            .font(.caption)
            .foregroundStyle(Color.red.opacity(0.9))
        }

        HStack(spacing: 8) {
          Button("Close") {
            onCloseSelected()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white.opacity(0.75))

          Spacer()

          Button {
            guard let url = viewModel.makeOpenInLinkstrURL() else { return }
            onOpenInLinkstr(url)
          } label: {
            Text("Open in Linkstr")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.black)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .background(
                Capsule(style: .continuous)
                  .fill(Color(red: 0.47, green: 0.90, blue: 0.92))
              )
          }
        }
      } else if let selectionError = viewModel.selectionError {
        Text(selectionError)
          .font(.caption)
          .foregroundStyle(Color.red.opacity(0.9))

        Button("Back to Composer") {
          onCloseSelected()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.78))
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.08))
    )
  }

  private var inputCard: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        if viewModel.urlInput.isEmpty {
          Text("https://...")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }

        TextEditor(text: $viewModel.urlInput)
          .scrollContentBackground(.hidden)
          .background(Color.clear)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .keyboardType(.URL)
          .font(.system(size: 24, weight: .regular))
          .foregroundStyle(.white.opacity(0.95))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      }
      .frame(minHeight: 74, maxHeight: 138)

      Divider()
        .overlay(Color.white.opacity(0.16))

      HStack(spacing: 14) {
        assistButton(title: "Paste", systemImage: "doc.on.clipboard") {
          viewModel.pasteFromClipboard()
        }
        Spacer()

        if !viewModel.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button("Clear") {
            viewModel.clearInput()
          }
          .buttonStyle(.plain)
          .font(.footnote)
          .foregroundStyle(.red.opacity(0.95))
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)
    }
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(Color(red: 0.16, green: 0.17, blue: 0.20))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(Color.white.opacity(0.10), lineWidth: 1)
    )
  }

  private func assistButton(title: String, systemImage: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 16, height: 16)
        Text(title)
          .font(.footnote)
      }
      .foregroundStyle(Color(red: 0.79, green: 0.83, blue: 0.97))
    }
    .buttonStyle(.plain)
  }

  private var sendButton: some View {
    Button {
      Task {
        guard let message = await viewModel.createMessage() else { return }
        onSend(message)
      }
    } label: {
      HStack(spacing: 8) {
        if viewModel.isPreparingMessage {
          ProgressView()
            .tint(.black)
            .scaleEffect(0.8)
          Text("Preparing…")
            .font(.system(size: 14, weight: .semibold))
        } else {
          Text("Send")
            .font(.system(size: 14, weight: .semibold))
        }
      }
      .foregroundStyle(.black)
      .padding(.horizontal, 15)
      .padding(.vertical, 9)
      .background(
        Capsule(style: .continuous).fill(
          canSend ? Color(red: 0.47, green: 0.90, blue: 0.92) : Color.gray.opacity(0.65)
        )
      )
    }
    .buttonStyle(.plain)
    .disabled(!canSend)
  }

  @ViewBuilder
  private var validationStatus: some View {
    switch viewModel.validationState {
    case .empty:
      EmptyView()
    case .invalid:
      Label("Link not supported", systemImage: "xmark.circle.fill")
        .font(.footnote)
        .foregroundStyle(Color.red.opacity(0.92))
    case .valid(let category):
      Label(category.title, systemImage: category.iconName)
        .font(.footnote)
        .foregroundStyle(Color(red: 0.47, green: 0.90, blue: 0.92))
    }
  }

  private var isShowingSelectedSurface: Bool {
    viewModel.selectedPayload != nil || viewModel.selectionError != nil
  }

  private var canSend: Bool {
    guard !viewModel.isPreparingMessage else { return false }
    if case .valid = viewModel.validationState {
      return true
    }
    return false
  }
}
