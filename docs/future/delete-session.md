# Future Proposal: Delete Session

Status: Proposal only. Not implemented.

## Goals

- Support destructive session delete in addition to archive.
- Keep delete distinct from archive (`archive` reversible, `delete` destructive).

## UX shape

- Expose destructive `Delete Session` with confirmation.
- If delete succeeds while viewing the session, dismiss detail and return to list.
- Hide deleted sessions from active and archived views.

## Protocol shape (proposed)

- Add payload kind `session_delete`.
- Include `conversation_id`, `root_id`, `timestamp`, and optional `reason`.
- Accept only authorized deletes (session creator).
- Preserve deterministic ordering (`created_at`, then event-ID tie-break for equal timestamps).

## Data behavior

- Persist a tombstone per deleted session.
- Ignore older session lifecycle/content events once tombstoned.
- Purge or suppress account-scoped session data (session row, members, roots, reactions, unread state, cached media references).

## Relay behavior (best effort)

- Optionally publish NIP-09 kind `5` requests for known session event IDs.
- Treat relay deletion as non-authoritative; local tombstone logic remains authoritative for Linkstr UX.

## Non-goals

- No guarantee of global/permanent relay erasure.
- No automatic restore/undo flow.
