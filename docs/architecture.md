# Architecture and trust boundaries

IIS Express hosts a Classic ASP root application and a Web Forms child application on `127.0.0.1:5070`. Both call allowlisted stored procedures through a least-privilege SQL login. SQL Server 2025 Developer runs in a pinned Linux container bound to `127.0.0.1:14333`. The Classic ASP queue calls a fixed .NET provider URL on `127.0.0.1:5071`; the provider owns a separate ignored receipt file.

The browser is untrusted. User IDs, roles, actors, redirects, idempotency keys, and provider URLs do not come from request-controlled identity fields. Login establishes server-side session identity; stored procedures enforce administrator intent or reviewer ownership again at the data boundary. Every dynamic database parameter is typed, and every untrusted HTML value is context encoded.

Private author name and email fields exist in the seeded main database to make leakage tests meaningful. Reviewer procedures use an explicit projection that omits them; they must not appear in HTML, ViewState, hidden fields, API payloads, audit details, or logs.

The reminder boundary treats transport outcome as uncertain. Main SQL owns the logical request and stable key, while the provider independently commits a payload fingerprint and receipt under that key. A timeout after the provider commit is recovered by replaying the same request, never by inventing another key.

Reassignment also treats the browser's candidate list as stale and untrusted. The write procedure locks the predecessor and rechecks administrator role, open state, target activity, conflicts, prior assignment history, and existing children. Closing the predecessor, inserting the linked replacement, and writing the ID-only audit event commit or roll back together.

Generated IIS configuration, credentials, provider state, process IDs, and logs live under `.local/`. Tracked configuration contains only tokens and placeholders.
