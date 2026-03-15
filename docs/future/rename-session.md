# Future Proposal: Rename Session

Status: Proposal only. Not implemented.

## Goals

- Let the session creator rename a session after creation.
- Keep rename compatible with the existing session-first model.
- Avoid introducing a second competing source of truth for session state.

## UX shape

- Expose session-name editing in the existing creator-only members sheet.
- Let the creator save name-only edits, membership-only edits, or both together.
- Reflect the updated name in session list rows, session detail titles, and post detail titles.

## Protocol shape (proposed)

- Keep using `session_members` as the canonical owner-authored session snapshot.
- Treat `session_name` plus the full member set as one state update.
- A name-only edit publishes a `session_members` snapshot with the unchanged member list.
- A combined name-and-members edit publishes one `session_members` snapshot.
- Preserve deterministic ordering (`created_at`, then event-ID tie-break for equal timestamps).

## Ingest semantics

- Apply incoming rename only when the containing `session_members` snapshot wins the existing recency/tie-break check.
- Do not let an older snapshot rename the session backward just because it carries a different `session_name`.
- Keep `session_members` self-contained so newly added members can still materialize the session from a single accepted snapshot.

## Mixed-version behavior

- Older clients remain able to decode the payload shape because `session_name` already exists in session payloads.
- Older clients may continue showing the previous local name for already-known sessions until they upgrade.
- An older creator device can still resend a stale name later if it publishes membership changes without rename-aware logic.

## Non-goals

- No separate `session_rename` event unless rename needs independent ordering or authorization semantics later.
- No per-user private alias in this proposal; that would be a separate local-only feature.
