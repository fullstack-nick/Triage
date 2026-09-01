# FEAT-124 — audited review reassignment

Problem: an overdue unfinished evaluation needs a replacement reviewer without erasing the original assignment or assigning someone with a conflict.

Business impact: overwriting the reviewer loses operational history, while a conflicted, inactive, or already-used reviewer creates an invalid evaluation workflow.

Acceptance criteria: eligible candidates only; rejection of no-op, inactive, conflicted, prior, completed, and already-reassigned targets; one linked replacement under concurrent requests; complete actor/time audit; and full rollback after a forced mid-transaction failure.

Technical approach: lock the predecessor row, recheck every invariant in SQL, mark it `Reassigned`, insert a child with `ReassignedFromAssignmentId`, and write an ID-only JSON audit event in one transaction. Unique indexes remain the final race-safe invariants.

Risks: a stale UI candidate can become ineligible before confirmation, so the write procedure revalidates rather than trusting the select. Index creation and reassignment take short locks on assignment keys.

Test evidence: `database/tests/feat-124-reassignment.sql`, `scripts/Test-Feat124.ps1`, and the Classic ASP confirmation-flow smoke test.

Deployment notes: migration 004 adds two unique indexes and two procedures. The application can be rolled back while retaining the stronger invariants; schema rollback is exercised only against a disposable release database.
