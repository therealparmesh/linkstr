import SwiftData
import SwiftUI
import UIKit

struct AddedYouView: View {
  @EnvironmentObject private var session: AppSession
  @ObservedObject var discovery: ContactDiscovery
  let ownerPubkey: String
  @Query private var contacts: [ContactEntity]
  let addContact: () -> Void
  @State private var query = ""
  @State private var pendingContactAddition: ContactPresentation?
  @Query private var relationships: [FollowRelationshipEntity]

  init(
    ownerPubkey: String, discovery: ContactDiscovery, addContact: @escaping () -> Void
  ) {
    self.ownerPubkey = ownerPubkey
    self.discovery = discovery
    self.addContact = addContact
    _contacts = Query(
      filter: #Predicate<ContactEntity> { $0.ownerPubkey == ownerPubkey },
      sort: [SortDescriptor(\ContactEntity.createdAt)]
    )
    _relationships = Query(
      filter: #Predicate<FollowRelationshipEntity> {
        $0.ownerPubkey == ownerPubkey && $0.followsOwner
      }, sort: [
        SortDescriptor(\FollowRelationshipEntity.updatedAt, order: .reverse),
        SortDescriptor(\FollowRelationshipEntity.followerPubkey)
      ])
  }

  private var rows: [ContactPresentation] {
    let index = Dictionary(
      contacts.map { ($0.targetPubkey, $0) }, uniquingKeysWith: { first, _ in first })
    return relationships.map { relationship in
      let key = relationship.followerPubkey
      return ContactPresentation(
        pubkey: key,
        identity: index[key].map { session.resolvedIdentity(for: $0) }
          ?? session.resolvedIdentity(for: key, contacts: []),
        contact: index[key]
      )
    }
  }

  var body: some View {
    let visibleRows = ContactPresentation.filtered(rows, query: query)
    let hasSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
        LinkstrSearchField(prompt: "search people", text: $query)
        if visibleRows.isEmpty, discovery.loadState == .unavailable {
          LinkstrCenteredEmptyStateView(
            title: "couldn’t load people",
            systemImage: "wifi.exclamationmark",
            description: "check your connection and try again.",
            actionTitle: "try again",
            actionSystemImage: "arrow.clockwise",
            action: {
              session.startNostrIfPossible()
              discovery.refresh()
            }
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else if visibleRows.isEmpty, hasSearch, discovery.loadState == .ready {
          LinkstrCenteredEmptyStateView(
            title: discovery.canLoadMore ? "no matches yet" : "no people found",
            systemImage: "magnifyingglass",
            description: discovery.canLoadMore ? "load more people or try another search." : "try another search.",
            actionTitle: "clear search",
            actionSystemImage: "xmark.circle",
            action: { query = "" }
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else if visibleRows.isEmpty, discovery.loadState == .ready {
          LinkstrCenteredEmptyStateView(
            title: "no one found yet",
            systemImage: "person.2.slash",
            description: "people who add you to their contacts appear here after syncing."
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else if visibleRows.isEmpty {
          LinkstrLoadingStateView(title: "loading people")
        }
        LazyVStack(spacing: 0) {
          ForEach(visibleRows) { row in
            HStack(spacing: LinkstrTheme.rowSpacing) {
              LinkstrContactAvatar(name: row.identity.displayName, size: LinkstrTheme.contactAvatarSize)
                .accessibilityHidden(true)
              LinkstrContactIdentityView(
                identity: row.identity,
                primaryFont: LinkstrTheme.font(.subheadline, weight: .medium)
              )
              .frame(maxWidth: .infinity, alignment: .leading)
              if row.contact != nil {
                Image(systemName: "checkmark")
                  .font(LinkstrTheme.font(.caption, weight: .medium))
                  .dynamicTypeSize(...DynamicTypeSize.xLarge)
                  .foregroundStyle(LinkstrTheme.textSecondary)
                  .frame(width: LinkstrTheme.minimumInteractiveDimension)
                  .accessibilityLabel("\(row.identity.displayName) is in your contacts")
              } else {
                LinkstrHeaderButton(
                  title: "add \(row.identity.displayName) to contacts", icon: "person.badge.plus"
                ) {
                  pendingContactAddition = row
                }
              }
            }
            .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { LinkstrListRowDivider(leadingInset: 62) }
            .contextMenu {
              Button("copy public key", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = row.identity.npub
              }
            }
            .accessibilityAction(named: Text("copy public key")) { UIPasteboard.general.string = row.identity.npub }
            .onAppear {
              discovery.watch(row.pubkey, visible: true)
            }
            .onDisappear { discovery.watch(row.pubkey, visible: false) }
          }
        }
        if discovery.isLoading, !visibleRows.isEmpty {
          ProgressView("loading people")
            .font(LinkstrTheme.font(.subheadline))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .tint(LinkstrTheme.accent)
            .frame(maxWidth: .infinity, minHeight: LinkstrTheme.actionButtonMinHeight)
        } else if discovery.canLoadMore {
          Button { discovery.loadMore() } label: {
            LinkstrActionButtonLabel(title: "load more")
          }
          .linkstrSecondaryButton()
          .disabled(discovery.isLoading)
        }
      }
      .linkstrPageContentLayout(topPadding: LinkstrTheme.pinnedPageContentTopPadding)
    }
    .contactAddition(pending: $pendingContactAddition)
    .linkstrPinnedPageHeader {
      LinkstrPageHeader(title: "added you", backLabel: "back to contacts") {
        LinkstrHeaderButton(title: "add contact", icon: "person.badge.plus", action: addContact)
      }
    }
    .linkstrKeyboardDismissal()
    .refreshable { discovery.refresh() }
    .task(id: visibleRows.map(\.pubkey).stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: visibleRows.map(\.pubkey))
    }
    .onAppear { discovery.show(ownerPubkey: ownerPubkey) }
    .onDisappear { discovery.hide() }
  }
}
