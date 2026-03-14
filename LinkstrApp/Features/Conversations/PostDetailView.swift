import EmojiKit
import SwiftData
import SwiftUI

struct ReactionSummary: Identifiable, Hashable {
  let emoji: String
  let count: Int
  let includesCurrentUser: Bool

  var id: String { emoji }

  var badgeText: String {
    count > 10 ? "10+" : "\(count)"
  }

  var readOnlyBadgeText: String? {
    guard count > 1 else { return nil }
    return badgeText
  }

  static func summaries(from reactions: [SessionReactionEntity], myPubkey: String?)
    -> [ReactionSummary]
  {
    guard !reactions.isEmpty else { return [] }

    return
      Dictionary(grouping: reactions, by: \.emoji)
      .map { emoji, groupedReactions -> ReactionSummary in
        ReactionSummary(
          emoji: emoji,
          count: groupedReactions.count,
          includesCurrentUser: groupedReactions.contains { reaction in
            guard let myPubkey else { return false }
            return reaction.senderMatches(myPubkey)
          }
        )
      }
      .sorted {
        if $0.count == $1.count {
          return $0.emoji < $1.emoji
        }
        return $0.count > $1.count
      }
  }
}

struct ReactionParticipantBreakdown: Identifiable, Hashable {
  let displayName: String
  let emojis: [String]

  var id: String { displayName }
}

struct LinkstrReactionRow: View {
  enum Mode {
    case interactive
    case readOnly
  }

  let summaries: [ReactionSummary]
  var mode: Mode = .interactive
  let onToggleEmoji: ((String) -> Void)?
  let onAddReaction: (() -> Void)?

  private let quickEmojis = ["👍", "👎", "👀"]
  private let readOnlyMaxEmojiCount = 10

  private var quickSummariesByEmoji: [String: ReactionSummary] {
    Dictionary(
      uniqueKeysWithValues:
        summaries
        .filter { quickEmojis.contains($0.emoji) }
        .map { ($0.emoji, $0) }
    )
  }

  private var extraSummaries: [ReactionSummary] {
    summaries.filter { !quickEmojis.contains($0.emoji) }
  }

  private var readOnlyVisibleSummaries: [ReactionSummary] {
    Array(summaries.prefix(readOnlyMaxEmojiCount))
  }

  private var hasReadOnlyOverflow: Bool {
    summaries.count > readOnlyMaxEmojiCount
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .center, spacing: mode == .readOnly ? 6 : 8) {
        if mode == .readOnly {
          ForEach(readOnlyVisibleSummaries) { summary in
            readOnlySummaryText(summary)
          }

          if hasReadOnlyOverflow {
            Text("...")
              .font(LinkstrTheme.body(12))
              .foregroundStyle(LinkstrTheme.textSecondary)
          }
        } else {
          ForEach(extraSummaries) { summary in
            summaryChip(summary)
          }

          ForEach(quickEmojis, id: \.self) { emoji in
            quickEmojiButton(emoji)
          }

          if let onAddReaction {
            Button(action: onAddReaction) {
              Text("...")
                .font(LinkstrTheme.body(13))
                .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                  Capsule()
                    .fill(LinkstrTheme.panel)
                )
                .overlay(
                  Capsule()
                    .stroke(LinkstrTheme.textSecondary.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(minHeight: mode == .readOnly ? 18 : nil, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func readOnlySummaryText(_ summary: ReactionSummary) -> some View {
    ZStack(alignment: .bottomTrailing) {
      Text(summary.emoji)
        .font(LinkstrTheme.system(17))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))

      if let badgeText = summary.readOnlyBadgeText {
        Text(badgeText)
          .font(LinkstrTheme.body(9))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(
            Capsule()
              .fill(LinkstrTheme.panel)
          )
          .overlay(
            Capsule()
              .stroke(LinkstrTheme.textSecondary.opacity(0.22), lineWidth: 1)
          )
          .offset(x: 7, y: 5)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.vertical, 4)
    .padding(.trailing, 8)
  }

  private func summaryChip(_ summary: ReactionSummary) -> some View {
    Group {
      if let onToggleEmoji, mode == .interactive {
        Button {
          onToggleEmoji(summary.emoji)
        } label: {
          summaryChipLabel(summary)
        }
        .buttonStyle(.plain)
      } else {
        summaryChipLabel(summary)
      }
    }
  }

  private func summaryChipLabel(_ summary: ReactionSummary) -> some View {
    HStack(spacing: 6) {
      Text(summary.emoji)
        .font(LinkstrTheme.system(15))
      Text(summary.badgeText)
        .font(LinkstrTheme.body(12))
        .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(summary.includesCurrentUser ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary.includesCurrentUser
            ? LinkstrTheme.accent.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
          lineWidth: 1
        )
    )
  }

  private func quickEmojiButton(_ emoji: String) -> some View {
    let summary = quickSummariesByEmoji[emoji]
    return Group {
      if let onToggleEmoji, mode == .interactive {
        Button {
          onToggleEmoji(emoji)
        } label: {
          quickEmojiButtonLabel(emoji: emoji, summary: summary)
        }
        .buttonStyle(.plain)
      } else {
        quickEmojiButtonLabel(emoji: emoji, summary: summary)
      }
    }
  }

  private func quickEmojiButtonLabel(
    emoji: String,
    summary: ReactionSummary?
  ) -> some View {
    HStack(spacing: 6) {
      Text(emoji)
        .font(LinkstrTheme.system(15))

      if let count = summary?.count, count > 0 {
        Text(summary?.badgeText ?? "\(count)")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textPrimary.opacity(0.95))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      Capsule()
        .fill(
          summary?.includesCurrentUser == true ? LinkstrTheme.panelElevated : LinkstrTheme.panel)
    )
    .overlay(
      Capsule()
        .stroke(
          summary?.includesCurrentUser == true
            ? LinkstrTheme.accent.opacity(0.45) : LinkstrTheme.textSecondary.opacity(0.2),
          lineWidth: 1
        )
    )
  }

}

struct LinkstrEmojiPickerSheet: View {
  @Environment(\.dismiss) private var dismiss

  let onPick: (String) -> Void

  @State private var query = ""
  @State private var category: EmojiCategory?
  @State private var selection: Emoji.GridSelection?

  var body: some View {
    NavigationStack {
      ZStack {
        LinkstrBackgroundView()
        EmojiGridScrollView(
          axis: .vertical,
          category: $category,
          selection: $selection,
          query: query,
          action: { emoji in
            onPick(emoji.char)
            dismiss()
          },
          sectionTitle: { $0.view },
          gridItem: { $0.view }
        )
        .emojiGridStyle(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      }
      .navigationTitle("add reaction")
      .navigationBarTitleDisplayMode(.inline)
      .linkstrBarChrome()
      .searchable(text: $query, prompt: "search emoji")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("close emoji picker")
          .tint(LinkstrTheme.textSecondary)
        }
      }
    }
  }
}

struct PostDetailView: View {
  @EnvironmentObject private var session: AppSession
  @Environment(\.openURL) private var openURL

  let post: SessionMessageEntity
  let sessionName: String

  @Query(sort: [SortDescriptor(\ContactEntity.createdAt)])
  private var contacts: [ContactEntity]

  @Query(sort: [SortDescriptor(\SessionReactionEntity.updatedAt, order: .reverse)])
  private var allReactions: [SessionReactionEntity]

  @State private var isPresentingEmojiPicker = false
  @State private var remotePostText: String?

  private var scopedContacts: [ContactEntity] {
    OwnerScopedCollections.contacts(contacts, ownerPubkey: session.identityService.pubkeyHex)
  }

  private var scopedReactions: [SessionReactionEntity] {
    OwnerScopedCollections.reactions(
      allReactions,
      ownerPubkey: session.identityService.pubkeyHex
    )
    .filter {
      $0.sessionID == post.conversationID
        && $0.postID == post.rootID
        && $0.isActive
    }
  }

  private var reactionSummaries: [ReactionSummary] {
    ReactionSummary.summaries(
      from: scopedReactions,
      myPubkey: session.identityService.pubkeyHex
    )
  }

  private var reactionBreakdown: [ReactionParticipantBreakdown] {
    guard !scopedReactions.isEmpty else { return [] }

    let grouped = Dictionary(grouping: scopedReactions) { reaction -> String in
      let myPubkey = session.identityService.pubkeyHex
      if let myPubkey, reaction.senderMatches(myPubkey) {
        return "you"
      }
      return session.displayName(for: reaction.senderPubkey, contacts: scopedContacts)
    }

    return
      grouped.map { displayName, reactions in
        let emojis = Array(Set(reactions.map(\.emoji))).sorted {
          $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return ReactionParticipantBreakdown(displayName: displayName, emojis: emojis)
      }
      .sorted {
        if $0.displayName == "you" { return true }
        if $1.displayName == "you" { return false }
        return
          $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
          == .orderedAscending
      }
  }

  private var profileLookupPubkeys: [String] {
    var pubkeys = scopedContacts.map(\.targetPubkey)
    pubkeys.append(post.senderPubkey)
    pubkeys.append(contentsOf: scopedReactions.map(\.senderPubkey))
    return NostrValueNormalizer.dedupedNormalizedPubkeyHexes(pubkeys)
  }

  private var profileLookupRequestID: String {
    profileLookupPubkeys.sorted().joined(separator: ",")
  }

  private var canReactToPost: Bool {
    session.isCurrentUserActiveMember(
      sessionID: post.conversationID,
      ownerPubkey: post.ownerPubkey
    )
  }

  private var shareDeepLinkURL: URL? {
    LinkstrDeepLinkCodec.makeAppDeepLink(url: post.url)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LinkstrTheme.sectionStackSpacing) {
        postCardContent
      }
      .padding(.horizontal, LinkstrTheme.screenHorizontalPadding)
      .padding(.top, LinkstrTheme.compactSpacing)
      .padding(.bottom, LinkstrTheme.screenBottomPadding)
    }
    .linkstrTabBarContentInset()
    .task(id: profileLookupRequestID) {
      session.requestRemoteProfilesIfNeeded(pubkeyHexes: profileLookupPubkeys)
    }
    .background(LinkstrBackgroundView())
    .navigationTitle(sessionName)
    .navigationBarTitleDisplayMode(.inline)
    .linkstrBarChrome()
    .toolbar {
      if let shareDeepLinkURL {
        ToolbarItem(placement: .topBarTrailing) {
          ShareLink(item: shareDeepLinkURL) {
            Image(systemName: "square.and.arrow.up")
              .linkstrToolbarIconLabel()
          }
          .accessibilityLabel("share deep link")
          .tint(LinkstrTheme.accent)
        }
      }
    }
    .task {
      session.markRootPostRead(postID: post.rootID)
      session.refreshMetadataForVisiblePostIfNeeded(post)
    }
    .task(id: remotePostTextRequestID) {
      remotePostText = await resolvedRemotePostText()
    }
    .sheet(isPresented: $isPresentingEmojiPicker) {
      LinkstrEmojiPickerSheet { emoji in
        toggleReaction(emoji)
      }
      .presentationDetents([.fraction(0.92)])
    }
  }

  private var postCardContent: some View {
    VStack(alignment: .leading, spacing: LinkstrTheme.listBlockSpacing) {
      HStack(spacing: 12) {
        Spacer(minLength: 0)

        Text(post.timestamp.linkstrMessageTimestampLabel)
          .font(LinkstrTheme.body(11, weight: .medium))
          .foregroundStyle(LinkstrTheme.textTertiary)
      }

      if let title = post.metadataTitle, !title.isEmpty {
        Text(title)
          .font(LinkstrTheme.title(17, weight: .semibold))
          .foregroundStyle(LinkstrTheme.textPrimary)
          .lineLimit(3)
      }

      if let url = post.url {
        Text(url)
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .multilineTextAlignment(.leading)
          .textSelection(.enabled)
      }

      if noteText != nil || remotePostText != nil {
        VStack(alignment: .leading, spacing: LinkstrTheme.compactSpacing) {
          if let noteText {
            accentTextBlock(label: "note", text: noteText)
          }

          if let remotePostText {
            Text(remotePostText)
              .font(LinkstrTheme.body(13))
              .foregroundStyle(LinkstrTheme.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
      }

      mediaBlock

      if !canReactToPost {
        Text("you're no longer a member of this session. reactions are read-only.")
          .font(LinkstrTheme.body(12))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      LinkstrReactionRow(
        summaries: reactionSummaries,
        mode: canReactToPost ? .interactive : .readOnly,
        onToggleEmoji: canReactToPost
          ? { emoji in
            toggleReaction(emoji)
          } : nil,
        onAddReaction: canReactToPost
          ? {
            isPresentingEmojiPicker = true
          } : nil
      )

      if !reactionBreakdown.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          LinkstrListRowDivider(leadingInset: 0)
          VStack(alignment: .leading, spacing: 10) {
            ForEach(reactionBreakdown) { entry in
              HStack(alignment: .center, spacing: 8) {
                Text(entry.displayName)
                  .font(LinkstrTheme.body(13, weight: .medium))
                  .foregroundStyle(LinkstrTheme.textSecondary)

                Text(entry.emojis.joined(separator: " "))
                  .font(LinkstrTheme.system(16))
                  .foregroundStyle(LinkstrTheme.textPrimary)

                Spacer(minLength: 0)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LinkstrTheme.fieldHorizontalPadding)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var mediaBlock: some View {
    if let urlString = post.url, let url = URL(string: urlString) {
      AdaptiveVideoPlaybackView(
        sourceURL: url,
        showOpenSourceButtonInEmbedMode: true,
        openSourceAction: { openURL(url) },
        resolveCachedLocalMedia: { sourceURL in
          guard
            let localURL = ManagedLocalFileScope.shared.managedFileURL(
              fromPath: post.cachedMediaPath),
            post.cachedMediaSourceURL == sourceURL.absoluteString
          else {
            return nil
          }
          guard FileManager.default.fileExists(atPath: localURL.path) else {
            post.cachedMediaPath = nil
            post.cachedMediaSourceURL = nil
            return nil
          }
          return PlayableMedia(playbackURL: localURL, headers: [:], isLocalFile: true)
        },
        persistLocalMedia: { sourceURL, media in
          guard media.isLocalFile else { return }
          guard
            let managedURL = ManagedLocalFileScope.shared.managedFileURL(
              fromPath: media.playbackURL.path
            )
          else {
            post.cachedMediaPath = nil
            post.cachedMediaSourceURL = nil
            return
          }
          post.cachedMediaPath = managedURL.path
          post.cachedMediaSourceURL = sourceURL.absoluteString
        }
      )
    }
  }

  private func toggleReaction(_ emoji: String) {
    Task { @MainActor in
      _ = await session.toggleReactionAwaitingRelay(emoji: emoji, post: post)
    }
  }

  private var noteText: String? {
    guard let note = post.note else { return nil }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var remotePostTextRequestID: String? {
    guard let urlString = post.url else { return nil }
    return shouldLoadRemotePostText(for: urlString) ? urlString : nil
  }

  private func shouldLoadRemotePostText(for urlString: String) -> Bool {
    guard let url = URL(string: urlString) else { return false }
    guard URLClassifier.classify(url) == .twitter else { return false }
    return URLClassifier.mediaStrategy(for: url).allowsLocalPlaybackToggle
  }

  private func resolvedRemotePostText() async -> String? {
    guard let urlString = post.url, shouldLoadRemotePostText(for: urlString) else { return nil }
    guard let url = URL(string: urlString) else { return nil }
    return await TwitterStatusResolutionService.shared.preview(for: url)?.bodyText
  }

  private func accentTextBlock(label: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Capsule(style: .continuous)
        .fill(LinkstrTheme.accent)
        .frame(width: 4)

      VStack(alignment: .leading, spacing: LinkstrTheme.metaSpacing) {
        Text(label)
          .font(LinkstrTheme.body(11, weight: .semibold))
          .foregroundStyle(LinkstrTheme.accent)

        Text(text)
          .font(LinkstrTheme.body(13))
          .foregroundStyle(LinkstrTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 2)
  }
}
