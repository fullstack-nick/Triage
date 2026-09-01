# PERF-112 — bounded review queue

Problem: the legacy procedure performed correlated work and returned every matching abstract to a page that displayed only a prefix.

Business impact: queue latency and reads grew with the entire event rather than the requested page, increasing operational delay and database load.

Acceptance criteria: comparable actual plans and statistics, independent checksum equality, 50-row default and 100-row hard bound, warm p95 targets, no spill, and typed optional filters.

Technical approach: pre-aggregate final counts, materialize one ordered page, aggregate assignment details only for that page, and add two evidence-backed indexes.

Risks: optional filters can produce different access paths; `OPTION (RECOMPILE)` trades a small compile cost for predictable local plans. Paging must preserve stable order.

Test evidence: `scripts/Capture-Performance.ps1`, `scripts/Test-Perf112.ps1`, raw JSON statistics, actual `.sqlplan` files, and `docs/performance-PERF-112.md`.

Deployment notes: migration 003 creates two nonclustered indexes and replaces one procedure. Rollback removes only these additions and restores the prior procedure on a disposable release test database.
