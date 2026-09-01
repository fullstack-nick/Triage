# Requirements

## Operations queue

An authenticated administrator can filter active abstracts by ID, track, reviewer, and status; inspect required versus completed evaluations and current assignments; reassign one unfinished assignment; and send or retry one reminder. Results use server-side paging with a 50-row default and 100-row maximum. State changes are POST requests protected by a server-side session and anti-CSRF token.

## Evaluation workspace

An authenticated reviewer can read only an owned assignment, save a draft, submit a final score from 1 through 5, and declare a conflict after confirmation. Final evaluations are read-only. A repeated identical final request is an idempotent success; a changed request after finalization is rejected. The database projection never returns private author fields.

## Data and audit rules

- Each assignment has at most one review.
- Each abstract/reviewer pair has at most one assignment across history and at most one conflict declaration.
- A predecessor assignment can have only one replacement.
- Reassignment closes rather than overwrites the predecessor and records actor, old/new IDs, and UTC time.
- One reminder exists per assignment per UTC calendar day. Attempts reuse its server-derived key and record a bounded result.
- Scores, states, roles, JSON audit details, relationships, and uniqueness are database constrained.

## Operational requirements

All services bind to loopback. Runtime secrets, logs, generated IIS configuration, provider data, and test output are ignored. The single verification entry point is `scripts/Test-Triage.ps1`. Destructive demo reset is separate, named, validated, and confirmation-gated.
