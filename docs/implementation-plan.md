# Triage implementation plan

This public plan is independent project documentation. It contains only the decisions needed to reproduce the local build.

## Constraints

- Local Windows runtime only: no cloud deployment, telemetry, hosted demo, or infrastructure automation.
- No pipeline configuration; build, test, migration, and smoke evidence is produced by local PowerShell commands.
- Preserve the mixed-generation boundary: Classic ASP operations page, Web Forms/VB.NET reviewer page, stored-procedure SQL layer, and one .NET reminder endpoint.
- Keep secrets and generated absolute paths under ignored `.local/` state.
- Use fictional event data and reserved `.test` addresses throughout code, documentation, history, and screenshots.

## Delivery sequence

1. Build and tag a working `legacy-baseline` with only three planned defects.
2. INC-101: archive deterministic surplus review rows, add a unique assignment invariant, and make save/finalization atomic and idempotent.
3. PERF-112: capture baseline evidence, replace correlated work with set-based pre-aggregation and bounded paging, and capture comparable final evidence.
4. FEAT-124: add conflict-aware reassignment that preserves predecessor history and writes its audit event atomically.
5. INT-131: add durable provider receipts, stable idempotency keys, mismatch protection, and deterministic after-commit failure tests.
6. REL-139: verify baseline upgrade, paired rollback on a disposable database, forward reapply, release notes, and a five-minute smoke procedure.
7. Run the complete clean-start suite, capture fictional final screenshots, and audit all pushed refs for secrets and unrelated identifiers.

Each ticket uses its own branch and pull request. Local test evidence, risk notes, rollback notes, and an automated self-review are recorded without claiming independent human approval.

## Completion gates

- One logical review per assignment under sequential and concurrent requests.
- Ownership and blind-data rules hold for reads and writes.
- Reassignment preserves history, rejects conflicts and races, and audits the actor and UTC time.
- Reminder retries and concurrent calls produce one logical main notification and one durable provider receipt.
- Queue output matches an independent reference query and remains bounded to 100 rows, defaulting to 50.
- An existing baseline database upgrades without being dropped or recreated.
- Initialize, start, test, stop, reset, migration, rollback, and smoke commands are documented and exercised locally.
