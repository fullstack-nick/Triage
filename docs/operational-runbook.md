# Operational runbook

Use this when the local demo is reachable but review saving or reminders fail. Do not paste `.local/triage.env`, connection strings, private author fields, or raw provider state into an issue.

## First checks

1. Run `./scripts/Smoke-Test.ps1` to separate runtime availability from a workflow failure.
2. Check `docker ps --filter name=triage-sql` and the ignored logs under `.local/logs/`.
3. Run `SELECT MAX(VersionNumber) FROM dbo.SchemaVersion`; the final application expects version 6.
4. Reproduce once with a known fictional demo fixture and record UTC time, assignment ID, HTTP status, and the exact non-secret error message.

## Review saving fails

- Confirm the assignment is owned by the signed-in reviewer and remains `Assigned` or `Draft`. A foreign assignment intentionally returns the same not-found response as a missing one.
- Inspect only the assignment ID, assignment status, review ID, final flag, and timestamps. Do not select author columns.
- Confirm `UX_Review_AssignmentId` exists and is unique. Do not remove it to make a failing save pass.
- A same-value repeat after finalization is an accepted replay; a changed final review is intentionally rejected.
- If SQL reports a deadlock or transient connection failure, retry the same operation once. If the procedure consistently throws, preserve the error number and stop rather than editing rows directly.
- Run `./scripts/Test-Inc101.ps1` to isolate sequential, final-idempotency, rollback, constraint, and 20-way race behavior.

## Reminder fails or times out

- Check `http://127.0.0.1:5071/health`. If only the provider is unhealthy, use `./scripts/Restart-NotificationProvider.ps1`; its receipt database remains intact.
- Find the logical `NotificationLog` row by assignment ID and UTC-day key. Record status, attempt count, and timestamps, but do not copy recipient data.
- A timeout or 503 after the provider commit is ambiguous. Retry with the same SQL-owned idempotency key and unchanged payload; never invent a new key.
- A 409 means that key was reused with a different payload. Stop and investigate the caller instead of deleting the receipt.
- A 400 is permanent input rejection. Correct the source data before retrying. A 5xx or timeout is retryable.
- `Succeeded` is terminal in the main log even if a later observation fails. Audit rows should show each request/retry and each recorded result with the server-derived administrator actor and UTC time.
- Run `./scripts/Test-Int131.ps1` to isolate contention, validation, failure-after-commit, timeout, restart, and actual admin retry behavior.

## Escalation evidence

Capture the commit, schema version, UTC time window, assignment/notification IDs, command that failed, bounded error text, and which focused test failed. Exclude passwords, cookies, CSRF tokens, private author sentinels, local absolute paths, and the SQLite receipt file.
