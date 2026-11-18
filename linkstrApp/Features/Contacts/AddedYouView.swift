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
      },
      sort: [
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
        if rows.isEmpty, discovery.loadState == .unavailable {
          LinkstrCenteredEmptyStateView(
            title: "couldn’t load people",
            systemImage: "wifi.exclamationmark",
            description: "check your connection, then tap refresh to try again."
          )
          .frame(maxWidth: .infinity, minHeight: 220)
        } else if visibleRows.isEmpty, hasSearch, !rows.isEmpty || discovery.loadState == .ready {
          LinkstrCenteredEmptyStateView(
            title: "no people found",
            systemImage: "magnifyingglass",
            description: "try another search.",
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
          Text("checking who added you…")
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        if !rows.isEmpty, discovery.loadState == .unavailable {
          Text("couldn’t update this list. tap refresh to try again.")
            .font(LinkstrTheme.font(.footnote))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        if !rows.isEmpty, discovery.loadState == .ready, discovery.checksOlderPages {
          Text("check complete")
            .font(LinkstrTheme.font(.footnote))
            .foregroundStyle(LinkstrTheme.textSecondary)
        }
        LazyVStack(spacing: 0) {
          ForEach(visibleRows) { row in
            HStack(spacing: LinkstrTheme.rowSpacing) {
              LinkstrContactAvatar(
                name: row.identity.avatarName, size: LinkstrTheme.contactAvatarSize, seed: row.identity.npub
              )
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
      }
      .linkstrPageContentLayout(topPadding: LinkstrTheme.pinnedPageContentTopPadding)
    }
    .contactAddition(pending: $pendingContactAddition)
    .linkstrPinnedPageHeader {
      LinkstrPageHeader(title: "added you", backLabel: "back to contacts") {
        LinkstrHeaderButton(title: "add contact", icon: "person.badge.plus", action: addContact)
        if discovery.isLoading {
          ProgressView()
            .tint(LinkstrTheme.accent)
            .frame(width: LinkstrTheme.minimumInteractiveDimension, height: LinkstrTheme.minimumInteractiveDimension)
            .accessibilityLabel("checking who added you")
        } else {
          LinkstrHeaderButton(title: "check who added you", icon: "arrow.clockwise") {
            if discovery.loadState == .unavailable { session.startNostrIfPossible() }
            discovery.refresh(includingHistory: true)
          }
        }
      }
    }
    .linkstrEdgeBack()
    .linkstrKeyboardDismissal()
    .task(id: visibleRows.map(\.pubkey).stableTaskID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: visibleRows.map(\.pubkey))
    }
    .onAppear { discovery.show(ownerPubkey: ownerPubkey) }
    .onDisappear { discovery.hide() }
  }
}
