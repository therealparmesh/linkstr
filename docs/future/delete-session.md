# linkstr

## Product Behavior Spec (Future Proposal: Delete Session)

### Product model

- Sessions support destructive delete in addition to archive.
- Delete session is a session-scoped lifecycle operation.
- Delete session is distinct from archive:
  - Archive is reversible and local-facing.
  - Delete is destructive for app UX and transport state.

### Sessions

- Session rows expose `Delete Session` from a destructive action path.
- Delete requires explicit confirmation before send.
- If delete succeeds while the user is inside that session:
  - Session detail dismisses.
  - Navigation returns to the session list.
- Deleted sessions are hidden from both active and archived list modes.

### Nostr transport and ingest

- Payload transport adds accepted kind `session_delete`.
- `session_delete` payload includes:
  - `conversation_id` (target session ID).
  - `root_id` (operation identifier).
  - `timestamp`.
  - Optional `reason`.
- Ingest rules for `session_delete`:
  - Ignore undecodable or invalid payloads.
  - Verify sender authorization.
  - Record a per-session tombstone.
  - Ignore older `session_create`, `session_members`, `root`, and `reaction` events for that session.
- Event ordering remains deterministic:
  - Newer event timestamp wins.
  - Equal timestamp resolves by deterministic event-ID tie-break.

### Authorization

- Delete session is creator-managed:
  - Only the session creator can issue `session_delete`.
- Unauthorized delete events are ignored.

### Local data and storage

- Delete session removes session visibility from normal UI queries.
- Delete session purges or suppresses account-scoped session data:
  - Session entity.
  - Session members.
  - Session root posts.
  - Reactions.
  - Session unread state.
  - Cached media references for that session.
- Tombstone metadata is persisted so older backfilled events cannot resurrect deleted sessions.

### Relay deletion behavior (best effort)

- App may additionally publish NIP-09 kind `5` delete requests for known session event IDs.
- Relay-side deletion is best effort only:
  - Not all relays enforce delete requests.
  - Not all clients hide deleted events consistently.
- App-level tombstone behavior remains authoritative for Linkstr UX.

### Known non-goals

- No guarantee of global or permanent erasure across all relays.
- No automatic restore or undo flow for deleted sessions.
