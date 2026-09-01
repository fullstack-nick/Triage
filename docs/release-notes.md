# Triage local release notes

## Version 1.0

This release turns the educational `legacy-baseline` into a safe local review-operations demo without replacing its Classic ASP, Web Forms/VB.NET, stored-procedure, or loopback-service boundaries.

### Delivered changes

- INC-101 quarantines the surplus seeded review, enforces one review per assignment, and makes draft/final saves atomic and idempotent.
- PERF-112 bounds the at-risk queue, replaces repeated correlated work with set-based aggregation, and adds measured supporting indexes.
- FEAT-124 preserves the original assignment while creating one audited replacement only after server-side eligibility checks.
- INT-131 gives each assignment/day reminder one SQL identity and one durable provider receipt across retries, failures, contention, and restart.
- REL-139 adds ordered release preflights, one rollback per migration, a stored five-minute smoke test, and an automated disposable release rehearsal.

### Database path

The final schema is version 6. Versions 2–6 apply in order to the existing version-1 database; they do not drop or recreate it. Migration 002 preserves removed surplus review rows in `ReviewDuplicateArchive`. Rollback scripts preserve that archive and the uniqueness constraints that prevent known corruption from returning.

### Verification

The local suite builds both web runtimes and the provider, runs xUnit and direct SQL tests, drives actual Classic ASP and Web Forms requests, exercises concurrency and failure recovery, and rehearses baseline upgrade, backup verification, complete rollback, and a second forward upgrade. Performance evidence is recorded separately in `docs/performance-PERF-112.md`.

### Known limits

Authentication is development-only, reminders are accepted by a local mock rather than sent as email, there is one review round, and operation is loopback-only. There is no cloud deployment or CI/CD.
