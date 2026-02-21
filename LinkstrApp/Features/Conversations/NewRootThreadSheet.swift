import NostrSDK
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct LockedRecipientContext {
  let npub: String
  let displayName: String
}

struct NewPostSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contacts: [ContactEntity]
  let lockedRecipient: LockedRecipientContext?

  @State private var selectedRecipientNPub: String?
  @State private var url = ""
  @State private var note = ""
  @State private var isPresentingRecipientPicker = false
  @State private var isSending = false

  init(
    contacts: [ContactEntity],
    preselectedContactNPub: String? = nil,
    lockedRecipient: LockedRecipientContext? = nil
  ) {
    self.contacts = contacts
    self.lockedRecipient = lockedRecipient
    _selectedRecipientNPub = State(initialValue: preselectedContactNPub)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            composeCard(title: "To") {
              if let lockedRecipient {
                VStack(alignment: .leading, spacing: 6) {
                  Text(lockedRecipient.displayName)
                    .font(.custom(LinkstrTheme.bodyFont, size: 15))
                    .foregroundStyle(LinkstrTheme.textPrimary)
                    .lineLimit(1)

                  Text(lockedRecipient.npub)
                    .font(.custom(LinkstrTheme.bodyFont, size: 12))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .lineLimit(1)

                  Text("Recipient is locked for this conversation.")
                    .font(.custom(LinkstrTheme.bodyFont, size: 12))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                }
              } else {
                Button {
                  isPresentingRecipientPicker = true
                } label: {
                  HStack(spacing: 10) {
                    LinkstrPeerAvatar(name: recipientPrimaryLabel, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                      Text(recipientPrimaryLabel)
                        .font(.custom(LinkstrTheme.bodyFont, size: 15))
                        .foregroundStyle(LinkstrTheme.textPrimary)
                        .lineLimit(1)
                      if let recipientSecondaryLabel {
                        Text(recipientSecondaryLabel)
                          .font(.custom(LinkstrTheme.bodyFont, size: 12))
                          .foregroundStyle(LinkstrTheme.textSecondary)
                          .lineLimit(1)
                      }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                      .font(.system(size: 12, weight: .semibold))
                      .foregroundStyle(LinkstrTheme.textSecondary.opacity(0.8))
                  }
                }
                .buttonStyle(.plain)
                .disabled(isSending)
              }
            }

            composeCard(title: "Link") {
              TextField("https://...", text: $url)
                .font(.custom(LinkstrTheme.bodyFont, size: 14))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .disabled(isSending)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinkstrTheme.panelSoft)
                )

              LinkstrInputAssistRow(
                showClear: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showScan: false,
                onPaste: pasteURLFromClipboard,
                onClear: { url = "" }
              )

              Text(urlValidationHint ?? " ")
                .font(.custom(LinkstrTheme.bodyFont, size: 12))
                .foregroundStyle(Color.red.opacity(0.92))
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                .opacity(urlValidationHint == nil ? 0 : 1)
                .accessibilityHidden(urlValidationHint == nil)
            }

            composeCard(title: "Note") {
              ZStack(alignment: .topLeading) {
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("Optional context for your recipient")
                    .font(.custom(LinkstrTheme.bodyFont, size: 14))
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $note)
                  .font(.custom(LinkstrTheme.bodyFont, size: 14))
                  .foregroundStyle(LinkstrTheme.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 112, maxHeight: 180)
                  .padding(4)
                  .disabled(isSending)
              }
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(LinkstrTheme.panelSoft)
              )
            }

            Text("Send requires a valid link and recipient. Note is optional.")
              .font(.custom(LinkstrTheme.bodyFont, size: 12))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .padding(.horizontal, 2)
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 120)
        .scrollBounceBehavior(.basedOnSize)
      }
      .navigationTitle("New Post")
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSending)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 8) {
          Button(action: sendPost) {
            Label(isSending ? "Sending…" : "Send Post", systemImage: "paperplane.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(LinkstrPrimaryButtonStyle())
          .disabled(!canSend)

          Text(isSending ? "Waiting for relay reconnect before sending…" : " ")
            .font(.custom(LinkstrTheme.bodyFont, size: 12))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .center)
            .opacity(isSending ? 1 : 0)
            .accessibilityHidden(!isSending)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
          Rectangle()
            .fill(LinkstrTheme.bgBottom.opacity(0.95))
            .overlay(alignment: .top) {
              Rectangle()
                .fill(LinkstrTheme.textSecondary.opacity(0.18))
                .frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        )
      }
    }
    .sheet(isPresented: $isPresentingRecipientPicker) {
      RecipientSelectionSheet(
        contacts: contacts,
        selectedRecipientNPub: $selectedRecipientNPub,
        isPresented: $isPresentingRecipientPicker
      )
    }
  }

  private var activeRecipientNPub: String? {
    if let lockedRecipient {
      return lockedRecipient.npub
    }
    return selectedRecipientNPub
  }

  private var recipientPrimaryLabel: String {
    let displayName = contacts.first(where: { $0.npub == activeRecipientNPub })?.displayName
    return NewPostRecipientLabelLogic.primaryLabel(
      activeRecipientNPub: activeRecipientNPub,
      matchedContactDisplayName: displayName
    )
  }

  private var recipientSecondaryLabel: String? {
    let displayName = contacts.first(where: { $0.npub == activeRecipientNPub })?.displayName
    return NewPostRecipientLabelLogic.secondaryLabel(
      activeRecipientNPub: activeRecipientNPub,
      matchedContactDisplayName: displayName
    )
  }

  private var normalizedURL: String? {
    LinkstrURLValidator.normalizedWebURL(from: url)
  }

  private var canSend: Bool {
    !isSending && activeRecipientNPub != nil && normalizedURL != nil
  }

  private var urlValidationHint: String? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return normalizedURL == nil ? "Enter a valid http(s) URL." : nil
  }

  private func composeCard<Content: View>(title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.custom(LinkstrTheme.titleFont, size: 12))
        .foregroundStyle(LinkstrTheme.textSecondary)
      content()
    }
    .padding(12)
    .linkstrNeonCard()
  }

  private func sendPost() {
    guard let recipientNPub = activeRecipientNPub else { return }
    guard let normalizedURL else { return }
    guard !isSending else { return }

    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    isSending = true

    Task { @MainActor in
      let didCreate = await session.createPostAwaitingRelay(
        url: normalizedURL,
        note: trimmedNote.isEmpty ? nil : trimmedNote,
        recipientNPub: recipientNPub
      )
      isSending = false
      if didCreate {
        dismiss()
      }
    }
  }

  private func pasteURLFromClipboard() {
    #if canImport(UIKit)
      if let clipboardText = UIPasteboard.general.string {
        url = clipboardText
      }
    #endif
  }
}

private struct RecipientSelectionSheet: View {
  let contacts: [ContactEntity]
  @Binding var selectedRecipientNPub: String?
  @Binding var isPresented: Bool
  @State private var recipientQuery: String
  @State private var isPresentingScanner = false

  init(
    contacts: [ContactEntity],
    selectedRecipientNPub: Binding<String?>,
    isPresented: Binding<Bool>
  ) {
    self.contacts = contacts
    _selectedRecipientNPub = selectedRecipientNPub
    _isPresented = isPresented
    let selectedDisplayName =
      contacts
      .first(where: { $0.npub == selectedRecipientNPub.wrappedValue })?
      .displayName
    _recipientQuery = State(
      initialValue: RecipientSearchLogic.selectedQuery(
        selectedRecipientNPub: selectedRecipientNPub.wrappedValue,
        selectedDisplayName: selectedDisplayName
      ))
  }

  var body: some View {
    NavigationStack {
      List {
        Section("To") {
          TextField("Name or Contact Key (npub...)", text: $recipientQuery)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

          LinkstrInputAssistRow(
            showClear: selectedRecipientNPub != nil
              || !recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onPaste: pasteFromClipboard,
            onScan: { isPresentingScanner = true },
            onClear: {
              recipientQuery = ""
              selectedRecipientNPub = nil
            }
          )
        }

        if let customQueryNPub {
          Section("Use Contact Key") {
            Button {
              selectedRecipientNPub = customQueryNPub
              isPresented = false
            } label: {
              HStack(spacing: 10) {
                LinkstrPeerAvatar(name: customQueryNPub, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                  Text(customQueryNPub)
                    .foregroundStyle(LinkstrTheme.textPrimary)
                    .lineLimit(1)
                  Text(customQueryNPub)
                    .font(.footnote)
                    .foregroundStyle(LinkstrTheme.textSecondary)
                    .lineLimit(1)
                }
                Spacer()
                if selectedRecipientNPub == customQueryNPub {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LinkstrTheme.neonCyan)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }

        Section("Contacts") {
          if filteredContacts.isEmpty {
            Text("No contacts match. Enter, paste, or scan a Contact Key (npub).")
              .font(.footnote)
              .foregroundStyle(LinkstrTheme.textSecondary)
          } else {
            ForEach(filteredContacts) { contact in
              Button {
                selectedRecipientNPub = contact.npub
                isPresented = false
              } label: {
                HStack(spacing: 10) {
                  LinkstrPeerAvatar(name: displayName(for: contact), size: 32)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: contact))
                      .foregroundStyle(LinkstrTheme.textPrimary)
                      .lineLimit(1)
                    Text(contact.npub)
                      .font(.footnote)
                      .foregroundStyle(LinkstrTheme.textSecondary)
                      .lineLimit(1)
                  }
                  Spacer()
                  if selectedRecipientNPub == contact.npub {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(LinkstrTheme.neonCyan)
                  }
                }
              }
              .buttonStyle(.plain)
            }
          }
        }

        if selectedRecipientNPub != nil {
          Section {
            Button("Clear Recipient", role: .destructive) {
              selectedRecipientNPub = nil
            }
          }
        }
      }
      .navigationTitle("Select Recipient")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            isPresented = false
          }
        }
      }
      .sheet(isPresented: $isPresentingScanner) {
        LinkstrQRScannerSheet { scannedValue in
          if let scannedNPub = ContactKeyParser.extractNPub(from: scannedValue) {
            recipientQuery = scannedNPub
          }
        }
      }
    }
  }

  private var filteredContacts: [ContactEntity] {
    RecipientSearchLogic.filteredContacts(
      contacts,
      query: recipientQuery,
      displayName: \.displayName,
      npub: \.npub
    )
  }

  private var customQueryNPub: String? {
    RecipientSelectionLogic.customRecipientNPub(
      from: recipientQuery,
      knownNPubs: contacts.map(\.npub)
    )
  }

  private func displayName(for contact: ContactEntity) -> String {
    RecipientSearchLogic.displayNameOrNPub(displayName: contact.displayName, npub: contact.npub)
  }

  private func pasteFromClipboard() {
    #if canImport(UIKit)
      if let clipboardText = UIPasteboard.general.string {
        recipientQuery = clipboardText
      }
    #endif
  }
}

enum RecipientSelectionLogic {
  static func normalizedNPub(from query: String) -> String? {
    guard
      let extractedNPub = ContactKeyParser.extractNPub(from: query),
      let normalized = PublicKey(npub: extractedNPub)?.npub
    else {
      return nil
    }
    return normalized
  }

  static func customRecipientNPub(from query: String, knownNPubs: [String]) -> String? {
    guard let normalized = normalizedNPub(from: query) else { return nil }
    return knownNPubs.contains(normalized) ? nil : normalized
  }
}

struct LinkstrInputAssistRow: View {
  let showClear: Bool
  var showScan = true
  let onPaste: () -> Void
  var onScan: (() -> Void)? = nil
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      actionButton("Paste", systemImage: "doc.on.clipboard", action: onPaste)
      if showScan, let onScan {
        actionButton("Scan", systemImage: "qrcode.viewfinder", action: onScan)
      }
      Spacer()

      if showClear {
        Button("Clear", action: onClear)
          .buttonStyle(.plain)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
  }

  private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void)
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
      .foregroundStyle(LinkstrTheme.textPrimary)
    }
    .buttonStyle(.plain)
  }
}

enum NewPostRecipientLabelLogic {
  static func primaryLabel(activeRecipientNPub: String?, matchedContactDisplayName: String?)
    -> String
  {
    guard let activeRecipientNPub else {
      return "Choose recipient"
    }
    let trimmedName =
      matchedContactDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedName.isEmpty ? activeRecipientNPub : trimmedName
  }

  static func secondaryLabel(
    activeRecipientNPub: String?,
    matchedContactDisplayName: String?
  ) -> String? {
    guard let activeRecipientNPub else {
      return "Choose a contact or enter a Contact Key (npub)."
    }
    let trimmedName =
      matchedContactDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedName.isEmpty ? nil : activeRecipientNPub
  }
}
