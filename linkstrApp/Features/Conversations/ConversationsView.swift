import SwiftData
import SwiftUI

private struct SessionSummary: Identifiable {
  let id: String
  let session: SessionEntity
  let latestTimestamp: Date
  let latestPreview: String
  let latestNote: String?
  let hasUnread: Bool
}

struct ConversationsView: View {
  @Binding var isShowingArchivedSessions: Bool
  let openSession: (String) -> Void
  private let ownerPubkeyHash: String

  @Query private var sessions: [SessionEntity]

  @Query private var rootMessages: [SessionMessageEntity]

  init(
    ownerPubkey: String,
    isShowingArchivedSessions: Binding<Bool>,
    openSession: @escaping (String) -> Void
  ) {
    self._isShowingArchivedSessions = isShowingArchivedSessions
    self.openSession = openSession
    self.ownerPubkeyHash = LocalDataCrypto.shared.digestHex(ownerPubkey)

    let rootKindRaw = SessionMessageKind.root.rawValue
    _sessions = Query(
      filter: #Predicate<SessionEntity> { session in
        session.ownerPubkey == ownerPubkey
      },
      sort: [SortDescriptor(\SessionEntity.updatedAt, order: .reverse)]
    )
    _rootMessages = Query(
      filter: #Predicate<SessionMessageEntity> { message in
        message.ownerPubkey == ownerPubkey && message.kindRaw == rootKindRaw
      },
      sort: [SortDescriptor(\SessionMessageEntity.timestamp, order: .reverse)]
    )
  }

  private var summaries: [SessionSummary] {
    let summaries = makeSummaries(
      sessions: sessions,
      messages: rootMessages,
      ownerPubkeyHash: ownerPubkeyHash
    )
    return summaries.filter { summary in
      isShowingArchivedSessions ? summary.session.isArchived : !summary.session.isArchived
    }
  }

  var body: some View {
    ConversationsContentView(
      hasSessions: !sessions.isEmpty,
      summaries: summaries,
      isShowingArchivedSessions: isShowingArchivedSessions,
      openSession: openSession
    )
  }

  private func hasUnreadIncomingRootPost(
    _ post: SessionMessageEntity,
    ownerPubkeyHash: String
  ) -> Bool {
    return post.senderPubkeyHash != ownerPubkeyHash && post.readAt == nil
  }

  private func previewText(for post: SessionMessageEntity?) -> String {
    guard let post else { return "no posts yet" }
    if let title = post.metadataTitle, !title.isEmpty {
      return title
    }
    if let url = post.url, !url.isEmpty {
      return url
    }
    return "untitled post"
  }

  private func normalizedNote(_ note: String?) -> String? {
    guard let note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func makeSummaries(
    sessions: [SessionEntity],
    messages: [SessionMessageEntity],
    ownerPubkeyHash: String
  ) -> [SessionSummary] {
    var aggregates:
      [String: (
        latestPost: SessionMessageEntity?,
        hasUnread: Bool
      )] = [:]
    aggregates.reserveCapacity(max(1, sessions.count))

    for message in messages where message.kind == .root {
      let key = message.conversationID
      var aggregate = aggregates[key] ?? (latestPost: nil, hasUnread: false)

      if aggregate.latestPost == nil {
        aggregate.latestPost = message
      }

      aggregate.hasUnread =
        aggregate.hasUnread
        || hasUnreadIncomingRootPost(message, ownerPubkeyHash: ownerPubkeyHash)
      aggregates[key] = aggregate
    }

    return
      sessions
      .compactMap { sessionEntity in
        let aggregate = aggregates[sessionEntity.sessionID]
        let latestPost = aggregate?.latestPost
        let latestTimestamp = latestPost?.timestamp ?? sessionEntity.updatedAt
        let latestPreview = previewText(for: latestPost)
        let latestNote = normalizedNote(latestPost?.note)
        let hasUnread = aggregate?.hasUnread ?? false

        return SessionSummary(
          id: sessionEntity.sessionID,
          session: sessionEntity,
          latestTimestamp: latestTimestamp,
          latestPreview: latestPreview,
          latestNote: latestNote,
          hasUnread: hasUnread
        )
      }
      .sorted { $0.latestTimestamp > $1.latestTimestamp }
  }
}

private struct ConversationsContentView: View {
  let hasSessions: Bool
  let summaries: [SessionSummary]
  let isShowingArchivedSessions: Bool
  let openSession: (String) -> Void

  @State private var query = ""

  private var visibleSummaries: [SessionSummary] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    guard !normalizedQuery.isEmpty else { return summaries }
    return summaries.filter { summary in
      summary.session.name.localizedLowercase.contains(normalizedQuery)
        || summary.latestPreview.localizedLowercase.contains(normalizedQuery)
        || (summary.latestNote?.localizedLowercase.contains(normalizedQuery) ?? false)
    }
  }

  var body: some View {
    ZStack {
      LinkstrBackgroundView()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .scrollContentBackground(.hidden)
  }

  @ViewBuilder
  private var content: some View {
    if !hasSessions {
      VStack(spacing: 0) {
        LinkstrScreenTitle(title: "sessions")
          .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
          .padding(.top, LinkstrTheme.screenTopPadding)
        LinkstrCenteredEmptyStateView(
          title: "no sessions",
          systemImage: "rectangle.stack.badge.plus",
          description: "start a session. links you share will show up here."
        )
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
          LinkstrScreenTitle(title: isShowingArchivedSessions ? "archived" : "sessions")

          LinkstrSearchField(
            prompt: isShowingArchivedSessions ? "search archived sessions" : "search sessions",
            text: $query
          )

          if visibleSummaries.isEmpty {
            LinkstrCenteredEmptyStateView(
              title: isShowingArchivedSessions ? "no archived sessions" : "no sessions found",
              systemImage: isShowingArchivedSessions ? "archivebox" : "magnifyingglass",
              description: isShowingArchivedSessions
                ? "archive a session to move it here."
                : "try a different search or create a new session."
            )
            .frame(maxWidth: .infinity, minHeight: 220)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visibleSummaries) { summary in
                Button {
                  openSession(summary.session.sessionID)
                } label: {
                  SessionRowView(summary: summary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
        .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
        .padding(.top, LinkstrTheme.screenTopPadding)
        .padding(.bottom, LinkstrTheme.screenBottomPadding)
      }
      .linkstrTabBarContentInset()
    }
  }
}

private struct SessionRowView: View {
  let summary: SessionSummary

  private var subtitle: String {
    if let latestNote = summary.latestNote {
      return latestNote
    }
    return summary.latestPreview
  }

  var body: some View {
    HStack(spacing: LinkstrTheme.rowSpacing) {
      LinkstrSessionAvatar(
        seed: summary.session.sessionID,
        size: 50
      )

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        HStack(alignment: .firstTextBaseline, spacing: LinkstrTheme.buttonRowSpacing) {
          Text(summary.session.name)
            .font(LinkstrTheme.title(16, weight: .semibold))
            .foregroundStyle(LinkstrTheme.textPrimary)
            .lineLimit(1)

          Spacer(minLength: 8)

          HStack(spacing: 6) {
            Text(summary.latestTimestamp.linkstrListTimestampLabel)
              .font(LinkstrTheme.body(11, weight: .medium))
              .foregroundStyle(LinkstrTheme.textTertiary)
              .lineLimit(1)
          }
        }

        HStack(alignment: .center, spacing: 8) {
          Text(subtitle)
            .font(LinkstrTheme.body(13))
            .foregroundStyle(LinkstrTheme.textSecondary)
            .lineLimit(2)

          Spacer(minLength: 6)

          if summary.hasUnread {
            Circle()
              .fill(LinkstrTheme.accent)
              .frame(width: 8, height: 8)
              .accessibilityLabel("unread")
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .padding(.vertical, LinkstrTheme.listRowVerticalPadding)
    .overlay(alignment: .bottom) {
      LinkstrListRowDivider(leadingInset: 62)
    }
  }
}
