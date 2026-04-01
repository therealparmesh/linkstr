# Delete Session

Status: Implemented.

## Product shape

- Delete is destructive and stays distinct from archive (`archive` reversible, `delete` permanent for linkstr UX).
- `Delete Session` lives in the creator-only manage session sheet and requires confirmation.
- If a session disappears while you are viewing it, session detail dismisses back to the list.
- Deleted sessions are removed from both active and archived views because the local session row is purged.

## Protocol shape

- Adds payload kind `session_delete`.
- Uses `conversation_id` as the session identifier.
- Uses `root_id` as the delete operation identifier for parity with other session lifecycle payloads.
- Applies only when authored by the session creator.
- Multiple delete notices for the same session resolve deterministically by `created_at`, then lexicographic event-ID tiebreak.

## Local data behavior

- Persist one tombstone per deleted session and owner scope.
- Applying delete purges the local session row, active/inactive members, membership intervals, posts, reactions, post-delete watermarks, unread state, archive state, and managed media references for that session.
- Managed thumbnail and cached-media files tied to deleted session posts are removed after the local save succeeds.
- Pending in-memory events for that session are discarded immediately.
- Tombstoned sessions are not recreated by later `session_create`, `session_members`, `root`, `reaction`, or `root_delete` traffic. There is no restore path.

## Relay behavior

- Outbound delete sends an encrypted `session_delete` notice to known current and former session members.
- The app also makes a best-effort NIP-09 `kind:5` deletion request for stored root-post gift-wrap IDs in that session when those relay event IDs are known.
- Relay-side deletion is secondary. If it is unavailable, the local tombstone still remains authoritative for linkstr UX and the app surfaces a warning instead of rolling back the delete.

## Test coverage

- Payload validation for `session_delete`.
- Outbound mutation coverage for local purge, member fanout, and relay-deletion warning behavior.
- Inbound ingest coverage for creator-only authorization, session purge, and pending delete ordering before the session snapshot arrives.

## Non-goals

- No guarantee of global or permanent relay erasure.
- No automatic restore or undo flow.
- No retrospective deletion of lifecycle wrappers whose relay-visible event IDs were never stored locally.
