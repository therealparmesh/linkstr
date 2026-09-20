import SwiftUI

struct EditContactView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var session: AppSession

  let contact: ContactEntity

  @State private var pendingRemoval: ContactEntity?
  @State private var alias: String

  init(contact: ContactEntity) {
    self.contact = contact
    _alias = State(initialValue: contact.localAlias ?? "")
  }

  var body: some View {
    let identity = session.resolvedIdentity(for: contact)
    ZStack {
      LinkstrBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
          LinkstrScreenTitle(title: "edit contact")

          LinkstrInsetSection(
            title: "contact",
            footer: "only you see this alias. the public key (npub) stays the real identity."
          ) {
            HStack(spacing: LinkstrTheme.rowSpacing) {
              LinkstrContactAvatar(name: identity.displayName, size: 54)
              LinkstrContactIdentityView(identity: identity, nameLineLimit: 2)
            }
          }

          LinkstrInsetSection(title: "alias") {
            TextField("alias", text: $alias)
              .font(LinkstrTheme.font(.subheadline))
              .textInputAutocapitalization(.words)
              .submitLabel(.done)
              .onSubmit(saveAlias)
              .linkstrInputField()
          }

          if let nostrChosenName = identity.chosenName {
            LinkstrInsetSection(title: "published nostr name") {
              Text(nostrChosenName)
                .font(LinkstrTheme.font(.footnote))
                .foregroundStyle(
                  contact.localAlias == nil
                    ? LinkstrTheme.textPrimary : LinkstrTheme.accentPink.opacity(0.88)
                )
                .lineLimit(3)
                .textSelection(.enabled)
                .linkstrInputField()
            }
          }

          LinkstrInsetSection(title: "public key (npub)") {
            Text(contact.npub)
              .typesettingLanguage(.init(languageCode: .unavailable))
              .font(LinkstrTheme.font(.footnote))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .linkstrInputField()
          }

          Button(role: .destructive) { pendingRemoval = contact } label: {
            LinkstrActionButtonLabel(title: "remove contact", systemImage: "person.crop.circle.badge.minus")
          }
          .linkstrDestructiveButton()
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
        .linkstrReadableContent()
      }
      .linkstrKeyboardDismissal()
    }
    .contactRemoval(pending: $pendingRemoval) { dismiss() }
    .navigationBarBackButtonHidden(true)
    .linkstrBarChrome()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("back")
        .tint(LinkstrTheme.accent)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          saveAlias()
        } label: {
          Image(systemName: "checkmark")
            .linkstrToolbarIconLabel()
        }
        .accessibilityLabel("save contact")
        .tint(LinkstrTheme.accent)
        .disabled(canSaveAlias == false)
      }
    }
  }

  private func saveAlias() {
    guard canSaveAlias else { return }
    let didSave = session.updateContactAlias(contact, alias: alias)
    if didSave {
      dismiss()
    }
  }

  private var canSaveAlias: Bool {
    normalizedAlias != persistedAlias
  }

  private var normalizedAlias: String {
    alias.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var persistedAlias: String {
    contact.localAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
