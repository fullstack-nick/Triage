# PERF-112 — bounded at-risk queue

## Method

Both captures used SQL Server 17.0.4075.5 from the pinned SQL Server 2025 CU8 image, the same 10,000 abstracts, 20,000 assignments, 250 reviewers, parameters, and reference query. `scripts/Capture-Performance.ps1` captured three isolated cold runs, ten warm unfiltered runs, ten warm track-filtered runs, `STATISTICS IO/TIME`, an actual XML execution plan, result rows, and a first-page checksum.

Cold runs issue a checkpoint and clear caches only inside the isolated local Triage SQL container. Times are measured in SQL around `INSERT ... EXEC`, excluding network rendering. The reference page contains 50 rows with checksum `601941113` before and after.

## Original query and plan

The baseline selected every incomplete abstract and evaluated correlated subqueries for final-review count, assignment summary, reminder assignment, reviewer filter, status filter, and risk predicate. Its essential shape was:

```sql
SELECT abstractRow.AbstractId, ...,
       (SELECT COUNT(*) FROM ReviewAssignment ... Review ...
        WHERE ...AbstractId = abstractRow.AbstractId) AS CompletedReviewCount,
       (SELECT STRING_AGG(...) FROM ReviewAssignment ...
        WHERE ...AbstractId = abstractRow.AbstractId) AS AssignmentSummary
FROM Abstract abstractRow
WHERE (SELECT COUNT(*) FROM ReviewAssignment ... Review ...
       WHERE ...AbstractId = abstractRow.AbstractId) < RequiredReviewCount
ORDER BY abstractRow.AbstractId;
```

It returned all 10,000 at-risk rows even though the page rendered only a small prefix. The actual plan shows repeated assignment access under nested loops; the warm unfiltered measurement consumed a median 205,817 logical reads. See the captured [baseline plan](../database/performance/PERF-112-baseline.sqlplan) and [baseline measurements](../database/performance/PERF-112-baseline.json).

## Final query

Migration 003 pre-aggregates final counts once, filters and materializes only the requested page, then builds assignment summaries and reminder candidates over at most 100 abstracts. It uses a fixed `AbstractId` business order, a 50-row default, a hard 100-row maximum, and `OPTION (RECOMPILE)` so optional filters do not force one unsuitable cached plan.

The final actual plan has no spill warning. See the [optimized plan](../database/performance/PERF-112-optimized.sqlplan), [optimized measurements](../database/performance/PERF-112-optimized.json), and the migration containing the full query.

## Index decisions

| Candidate | Decision | Evidence |
| --- | --- | --- |
| `ReviewAssignment(AbstractId, Status, DueAtUtc, AssignmentId) INCLUDE (ReviewerUserId)` | Accepted | Serves the page-local summary, open-assignment ordering, reviewer join, and status existence checks. |
| `Review(IsFinal, AssignmentId)` | Accepted | Supports the single set-based final-count aggregation without changing the INC-101 uniqueness index. |
| `Abstract(Status, Track, AbstractId)` | Rejected | The deterministic 10,000-row abstract scan is small; an extra wide index did not address the observed repeated assignment reads. |
| `UserAccount(DisplayName)` | Rejected | The supported reviewer filter is a leading-wildcard contains search, so this index would not provide a reliable seek. |

## Results

| Scenario | Baseline | Optimized | Change |
| --- | ---: | ---: | ---: |
| Unfiltered warm median elapsed | 205.407 ms | 8.249 ms | 95.98% lower |
| Unfiltered warm p95 elapsed | 225.988 ms | 12.360 ms | 94.53% lower |
| Unfiltered median logical reads | 205,817 | 1,897 | 99.08% lower |
| Unfiltered median CPU | 444 ms | 9 ms | 97.97% lower |
| Filtered warm median elapsed | 94.563 ms | 12.398 ms | 86.89% lower |
| Filtered warm p95 elapsed | 193.163 ms | 32.946 ms | 82.94% lower |
| Isolated cold maximum | 517.862 ms | 32.819 ms | 93.66% lower |

The optimized results pass the local targets: unfiltered warm p95 is below 750 ms, filtered warm p95 is below 500 ms, and every cold run is below two seconds. `database/tests/perf-112-queue.sql` also proves page bounds, reference equivalence, uniqueness, and literal handling of an injection-shaped filter.
