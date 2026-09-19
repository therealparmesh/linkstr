import SwiftData
import SwiftUI
import UIKit

struct AddedYouView: View {
  @EnvironmentObject private var session: AppSession
  @ObservedObject var discovery: ContactDiscovery
  let ownerPubkey: String
  let contacts: [ContactEntity]
  @Binding var query: String
  @Query private var relationships: [FollowRelationshipEntity]

  init(
    ownerPubkey: String, contacts: [ContactEntity], query: Binding<String>,
    discovery: ContactDiscovery
  ) {
    self.ownerPubkey = ownerPubkey
    self.contacts = contacts
    self._query = query
    self.discovery = discovery
    _relationships = Query(
      filter: #Predicate<FollowRelationshipEntity> {
        $0.ownerPubkey == ownerPubkey && $0.followsOwner
      }, sort: [SortDescriptor(\FollowRelationshipEntity.followerPubkey)])
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
    }.sorted(by: ContactPresentation.ordered)
  }

  var body: some View {
    let visibleRows = ContactPresentation.filtered(rows, query: query)
    let hasSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
        LinkstrScreenTitle(title: "added you")
        LinkstrSearchField(prompt: "search people", text: $query)
        HStack {
          if discovery.isLoading { ProgressView() }
          Text(discovery.status)
            .font(LinkstrTheme.font(.caption))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        if visibleRows.isEmpty, hasSearch {
          LinkstrCenteredEmptyStateView(
            title: "no people found",
            systemImage: "magnifyingglass",
            description: "try another search.",
            actionTitle: "clear search",
            actionSystemImage: "xmark.circle",
            action: { query = "" }
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else if visibleRows.isEmpty, !discovery.isLoading {
          LinkstrCenteredEmptyStateView(
            title: "no one found yet",
            systemImage: "person.2.slash",
            description: "people who added you to their contacts appear here when found on your relays."
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        }
        LazyVStack(spacing: 0) {
          ForEach(visibleRows) { row in
            HStack(spacing: LinkstrTheme.rowSpacing) {
              LinkstrContactAvatar(name: row.identity.displayName, size: 48)
              LinkstrContactIdentityView(
                identity: row.identity,
                primaryFont: LinkstrTheme.font(.subheadline, weight: .medium)
              )
              .frame(maxWidth: .infinity, alignment: .leading)
              AddContactButton(
                pubkey: row.pubkey, displayName: row.identity.displayName,
                isAdded: row.contact != nil, title: "add back"
              )
            }
            .padding(.vertical, LinkstrTheme.fieldVerticalPadding)
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
        if discovery.canLoadMore {
          Button("load more") { discovery.loadMore() }
            .disabled(discovery.isLoading)
            .tint(LinkstrTheme.accent)
        }
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.screenTopPadding)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
      .linkstrReadableContent()
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
