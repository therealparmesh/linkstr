# linkstr

## Product Behavior Spec (Future Proposal: Leave Session)

### Product model

- Session members can remove themselves from sessions they were invited to.
- Leave session is member-scoped:
  - It removes only the acting member.
  - It does not delete the session for other members.
- Leave session is distinct from delete session.

### Session members UX

- Session member management exposes a destructive `Leave Session` action for the signed-in user.
- Leave requires explicit confirmation before send.
- On successful leave:
  - Session detail dismisses if open.
  - Session is removed from the signed-in account's active session list.
- Leave is not available when signed out.

### Nostr transport and ingest

- Payload transport adds accepted kind `session_leave`.
- `session_leave` payload includes:
  - `conversation_id` (target session ID).
  - `root_id` (operation identifier).
  - `timestamp`.
- Ingest rules for `session_leave`:
  - Ignore undecodable or invalid payloads.
  - Accept only self-authored leave events (sender leaves themself).
  - Mark sender as inactive for the session.
  - Keep session data hidden for that owner scope unless re-invited later.
- Event ordering remains deterministic:
  - Newer event timestamp wins.
  - Equal timestamp resolves by deterministic event-ID tie-break.

### Membership semantics

- Member updates remain snapshot-based with `session_members`.
- Re-invite behavior:
  - If a newer valid `session_members` snapshot includes the prior leaver again, membership becomes active again.
  - If a snapshot does not include the prior leaver, leave state remains effective.
- Outbound posting/reaction from a left account is blocked until membership is active again.

### Authorization

- Leave session is self-authorized only:
  - Sender pubkey must match the member being removed.
- Events attempting to remove a different member via `session_leave` are ignored.
- Membership manager operations continue to be handled through membership snapshot events.

### Local data and storage

- After leave, the signed-in account suppresses the session from active UX surfaces.
- Local data retention after leave is privacy-preserving and implementation-defined:
  - Existing local session data may be kept or trimmed.
  - New inbound content is ignored unless membership is restored.
- Leave state metadata is persisted so older backfilled events do not re-activate membership.

### Known non-goals

- No "leave and delete for everyone" combined action.
- No automatic rejoin without a newer valid membership event.
