# Local deployment and recovery runbook

This runbook applies only to the local `Triage` demo database. Migration commands never drop or recreate it. Keep the application stopped while changing schema.

## Deployment checklist

1. Confirm the repository is on the intended commit and `git status --short` is clean.
2. Run `./scripts/Verify-Prerequisites.ps1` and confirm Docker Desktop is running.
3. Start only SQL Server, then take and verify a copy-only backup as described below.
4. Run `./scripts/Stop-Triage.ps1` so the web applications cannot start new work.
5. Run `./scripts/Initialize-Triage.ps1`. It detects an existing database and applies only ordered forward migrations through version 6.
6. Run `./scripts/Start-Triage.ps1` and then `./scripts/Smoke-Test.ps1`.
7. Run `./scripts/Test-Triage.ps1` for the complete local release gate.
8. Confirm `SELECT MAX(VersionNumber) FROM dbo.SchemaVersion` returns `6` and retain the local test report under `.local/test-results/`.

`sqlcmd` is invoked with fail-on-error behavior. Each migration checks its expected prior version and records its own version only after its required objects exist.

## Backup and restore notes

Create `.local/backups/`, then make a SQL Server `COPY_ONLY` backup to a fixed container path. Verify it before copying it to the ignored local directory:

```powershell
New-Item -ItemType Directory -Force .local/backups | Out-Null
docker exec triage-sql bash -lc '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -Q "BACKUP DATABASE [Triage] TO DISK=N''/var/opt/mssql/data/triage-before-release.bak'' WITH COPY_ONLY, INIT, CHECKSUM; RESTORE VERIFYONLY FROM DISK=N''/var/opt/mssql/data/triage-before-release.bak'' WITH CHECKSUM;"'
docker cp triage-sql:/var/opt/mssql/data/triage-before-release.bak .local/backups/triage-before-release.bak
```

Before any restore, stop Triage, verify the backup again, and prefer restoring under a temporary database name first. Replacing the main local database is destructive and should be a deliberate manual recovery action, never part of migration or rollback automation. The release rehearsal executes `BACKUP ... WITH CHECKSUM` and `RESTORE VERIFYONLY` against its disposable database.

## Rollback

Roll back application files and database contracts together. Apply scripts from the active version downward, one at a time, using the migration account and container `sqlcmd -b`. Every script refuses an unexpected version.

```powershell
. ./scripts/Triage.Common.ps1
Invoke-TriageSqlFile ./database/rollback/006-rel-139-release-safety.sql
```

Continue with 005, 004, 003, and 002 only when that older application version is actually required. These scripts never restore quarantined duplicate reviews and intentionally retain safe unique indexes. Reapply the corresponding forward migrations to return to version 6, then run the smoke and full test commands.

## Five-minute smoke

`./scripts/Smoke-Test.ps1` checks the provider, both web runtimes, seeded cardinalities, final schema, review uniqueness, reminder uniqueness, and a bounded queue call. The database-only form is:

```sql
EXEC dbo.usp_Triage_ReleaseSmokeTest;
```

A passing result contains `REL139_SMOKE_OK`. Any thrown SQL error is a failed release gate.
