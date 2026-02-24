# Future Proposal: Leave Session

Status: Proposal only. Not implemented.

## Goals

- Let any current member remove themself from a session.
- Keep leave scoped to the acting member only.
- Keep leave separate from delete session.

## UX shape

- Expose destructive `Leave Session` only for signed-in users.
- Require confirmation.
- On success, dismiss open session detail and remove the session from active surfaces for that account.

## Protocol shape (proposed)

- Add payload kind `session_leave`.
- Include `conversation_id`, `root_id`, and `timestamp`.
- Accept only self-authored leave events (sender can only remove themself).
- Preserve deterministic ordering (`created_at`, then event-ID tie-break for equal timestamps).

## Membership semantics

- `session_members` remains the source of truth for full snapshots.
- A newer snapshot that includes a leaver reactivates membership.
- A newer snapshot that excludes a leaver keeps them inactive.
- Outbound posting/reactions remain blocked while inactive.

## Non-goals

- No "leave and delete for everyone" combined action.
- No implicit auto-rejoin without a newer valid membership update.
