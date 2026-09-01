[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$api = Invoke-WebRequest -Uri 'http://127.0.0.1:5071/health' -TimeoutSec 10
if ($api.StatusCode -ne 200 -or $api.Content -notmatch 'healthy') { throw 'Notification API health check failed.' }

$admin = Invoke-WebRequest -Uri 'http://127.0.0.1:5070/admin/dev-login.asp' -TimeoutSec 15
if ($admin.StatusCode -ne 200 -or $admin.Content -notmatch 'Triage administrator') { throw 'Classic ASP login smoke check failed.' }

$reviewer = Invoke-WebRequest -Uri 'http://127.0.0.1:5070/reviewer/dev-login.aspx' -TimeoutSec 15
if ($reviewer.StatusCode -ne 200 -or $reviewer.Content -notmatch 'Evaluation Workspace') { throw 'Web Forms login smoke check failed.' }

$sqlResult = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
DECLARE @AssignmentCount int = (SELECT COUNT(*) FROM dbo.ReviewAssignment);
SELECT CASE
    WHEN (SELECT COUNT(*) FROM dbo.Abstract) = 10000
     AND @AssignmentCount BETWEEN 20000 AND 20010
    THEN 'SMOKE_OK'
    ELSE 'SMOKE_FAILED'
END;
'@
if (($sqlResult -join "`n") -notmatch 'SMOKE_OK') { throw 'Database smoke check failed.' }

Write-Host 'Triage five-minute smoke checks passed.' -ForegroundColor Green
