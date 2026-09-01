[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Baseline', 'Optimized')]
    [string] $Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$performanceDirectory = Join-Path $root 'database\performance'
New-Item -ItemType Directory -Path $performanceDirectory -Force | Out-Null

$imageReference = (& docker inspect --format '{{.Config.Image}}' triage-sql).Trim()
$expectedDigest = 'sha256:4bab24f36c1ecd48e85f7d37df26e6bf301641d84c3fe652f9a0dcc947d512e1'
if ($imageReference -notmatch [regex]::Escape($expectedDigest)) { throw "Unexpected SQL image: $imageReference" }

$preflight = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
SELECT CONCAT('PREFLIGHT|', CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')), '|',
    (SELECT COUNT(*) FROM dbo.Abstract), '|',
    (SELECT COUNT(*) FROM dbo.ReviewAssignment), '|',
    (SELECT COUNT(*) FROM dbo.UserAccount WHERE UserRole = 'Reviewer'));
'@
$preflightLine = ($preflight | Where-Object { $_ -match '^PREFLIGHT\|' } | Select-Object -Last 1).Trim()
if ($preflightLine -notmatch '^PREFLIGHT\|17\.0\.4075\.5\|10000\|20000\|250$') {
    throw "Performance preflight did not match the pinned dataset: $preflightLine"
}

$referenceOutput = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql @'
SET NOCOUNT ON;
;WITH Completed AS
(
    SELECT assignment.AbstractId, COUNT_BIG(*) AS CompletedReviewCount
    FROM dbo.ReviewAssignment assignment
    INNER JOIN dbo.Review reviewRow ON reviewRow.AssignmentId = assignment.AssignmentId AND reviewRow.IsFinal = 1
    GROUP BY assignment.AbstractId
), ReferencePage AS
(
    SELECT TOP (50)
        abstractRow.AbstractId,
        abstractRow.Title,
        abstractRow.Track,
        conference.RequiredReviewCount,
        CONVERT(int, ISNULL(completed.CompletedReviewCount, 0)) AS CompletedReviewCount
    FROM dbo.Abstract abstractRow
    INNER JOIN dbo.Conference conference ON conference.ConferenceId = abstractRow.ConferenceId
    LEFT JOIN Completed completed ON completed.AbstractId = abstractRow.AbstractId
    WHERE abstractRow.Status = 'Active'
      AND ISNULL(completed.CompletedReviewCount, 0) < conference.RequiredReviewCount
    ORDER BY abstractRow.AbstractId
)
SELECT CONCAT('REFERENCE|', COUNT(*), '|', CHECKSUM_AGG(BINARY_CHECKSUM(AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount)))
FROM ReferencePage;
'@
$referenceLine = ($referenceOutput | Where-Object { $_ -match '^REFERENCE\|' } | Select-Object -Last 1).Trim()
if (-not $referenceLine) { throw 'Reference queue checksum was not produced.' }
$referenceParts = $referenceLine.Split('|')
$referenceCount = [int]$referenceParts[1]
$referenceChecksum = [int]$referenceParts[2]

$procedureCall = if ($Mode -eq 'Baseline') {
    "dbo.usp_AtRiskReviewQueue_Get @AbstractId=NULL, @Track={0}, @Reviewer=NULL, @ReviewStatus=NULL"
} else {
    "dbo.usp_AtRiskReviewQueue_Get @AbstractId=NULL, @Track={0}, @Reviewer=NULL, @ReviewStatus=NULL, @PageNumber=1, @PageSize=50, @AsOfUtc='2027-03-16T12:00:00'"
}

function New-MeasurementSql([string] $TrackValue, [bool] $Cold) {
    $trackSql = if ([string]::IsNullOrEmpty($TrackValue)) { 'NULL' } else { "N'$($TrackValue.Replace("'", "''"))'" }
    $call = [string]::Format($procedureCall, $trackSql)
    $coldSql = if ($Cold) { "DECLARE @PerformanceDatabaseId int = DB_ID(); CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS; DBCC FLUSHPROCINDB (@PerformanceDatabaseId) WITH NO_INFOMSGS;" } else { '' }
    return @"
USE Triage;
SET NOCOUNT ON;
$coldSql
CREATE TABLE #Queue
(
    AbstractId int,
    Title nvarchar(300),
    Track nvarchar(80),
    RequiredReviewCount tinyint,
    CompletedReviewCount int,
    AssignmentSummary nvarchar(max),
    ActionAssignmentId int NULL
);
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
DECLARE @StartedAt datetime2(7) = SYSUTCDATETIME();
INSERT #Queue EXEC $call;
DECLARE @ElapsedMicroseconds bigint = DATEDIFF_BIG(microsecond, @StartedAt, SYSUTCDATETIME());
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
;WITH PageRows AS
(
    SELECT TOP (50) AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount
    FROM #Queue
    ORDER BY AbstractId
)
SELECT CONCAT('PERF_METRIC|', (SELECT COUNT(*) FROM #Queue), '|',
    (SELECT CHECKSUM_AGG(BINARY_CHECKSUM(AbstractId, Title, Track, RequiredReviewCount, CompletedReviewCount)) FROM PageRows), '|',
    @ElapsedMicroseconds);
"@
}

function Invoke-Measurement([string] $Scenario, [bool] $Cold, [int] $Iteration) {
    $track = if ($Scenario -eq 'Filtered') { 'Clinical Methods' } else { '' }
    $output = Invoke-TriageSqlText -Database 'Triage' -CaptureOutput -Sql (New-MeasurementSql -TrackValue $track -Cold $Cold)
    $metricLine = $output | Where-Object { $_ -match '^PERF_METRIC\|' } | Select-Object -Last 1
    if (-not $metricLine) { throw "No metric line was produced for $Scenario iteration $Iteration." }
    $parts = $metricLine.Split('|')

    $logicalReads = 0L
    foreach ($line in $output) {
        foreach ($match in [regex]::Matches([string]$line, 'logical reads\s+(\d+)', 'IgnoreCase')) {
            $logicalReads += [long]$match.Groups[1].Value
        }
    }
    $cpuValues = [System.Collections.Generic.List[int]]::new()
    foreach ($line in $output) {
        foreach ($match in [regex]::Matches([string]$line, 'CPU time =\s*(\d+)\s*ms', 'IgnoreCase')) {
            $cpuValues.Add([int]$match.Groups[1].Value)
        }
    }

    return [pscustomobject]@{
        mode = $Mode.ToLowerInvariant()
        scenario = $Scenario.ToLowerInvariant()
        temperature = if ($Cold) { 'cold' } else { 'warm' }
        iteration = $Iteration
        resultRows = [int]$parts[1]
        firstPageChecksum = [int]$parts[2]
        elapsedMilliseconds = [math]::Round(([long]$parts[3] / 1000.0), 3)
        cpuMilliseconds = if ($cpuValues.Count -gt 0) { ($cpuValues | Measure-Object -Maximum).Maximum } else { 0 }
        logicalReads = $logicalReads
    }
}

$measurements = [System.Collections.Generic.List[object]]::new()
foreach ($iteration in 1..3) { $measurements.Add((Invoke-Measurement -Scenario 'Unfiltered' -Cold $true -Iteration $iteration)) }
foreach ($iteration in 1..10) { $measurements.Add((Invoke-Measurement -Scenario 'Unfiltered' -Cold $false -Iteration $iteration)) }
foreach ($iteration in 1..10) { $measurements.Add((Invoke-Measurement -Scenario 'Filtered' -Cold $false -Iteration $iteration)) }

foreach ($measurement in $measurements) {
    if ($measurement.firstPageChecksum -ne $referenceChecksum -and $measurement.scenario -eq 'unfiltered') {
        throw "Queue checksum $($measurement.firstPageChecksum) differs from independent reference $referenceChecksum."
    }
}

function Get-Percentile([double[]] $Values, [double] $Percentile) {
    $ordered = @($Values | Sort-Object)
    $index = [math]::Max(0, [math]::Ceiling($Percentile * $ordered.Count) - 1)
    return [double]$ordered[$index]
}

$summaries = foreach ($scenario in @('unfiltered', 'filtered')) {
    $warm = @($measurements | Where-Object { $_.scenario -eq $scenario -and $_.temperature -eq 'warm' })
    [pscustomobject]@{
        scenario = $scenario
        warmMedianMilliseconds = [math]::Round((Get-Percentile -Values @($warm.elapsedMilliseconds) -Percentile 0.5), 3)
        warmP95Milliseconds = [math]::Round((Get-Percentile -Values @($warm.elapsedMilliseconds) -Percentile 0.95), 3)
        warmMedianLogicalReads = [long](Get-Percentile -Values @($warm.logicalReads) -Percentile 0.5)
        warmMedianCpuMilliseconds = [int](Get-Percentile -Values @($warm.cpuMilliseconds) -Percentile 0.5)
    }
}
$coldRuns = @($measurements | Where-Object { $_.temperature -eq 'cold' })

$summary = [ordered]@{
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    mode = $Mode.ToLowerInvariant()
    sqlImage = $imageReference
    sqlProductVersion = '17.0.4075.5'
    seed = @{ abstracts = 10000; assignments = 20000; reviewers = 250 }
    referenceFirstPage = @{ rows = $referenceCount; checksum = $referenceChecksum }
    summaries = $summaries
    coldMaximumMilliseconds = [math]::Round((($coldRuns.elapsedMilliseconds | Measure-Object -Maximum).Maximum), 3)
    measurements = $measurements
}

$modeName = $Mode.ToLowerInvariant()
$summaryPath = Join-Path $performanceDirectory "PERF-112-$modeName.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM

$planCall = [string]::Format($procedureCall, 'NULL')
$planSql = @"
USE Triage;
SET NOCOUNT ON;
CREATE TABLE #Queue(AbstractId int, Title nvarchar(300), Track nvarchar(80), RequiredReviewCount tinyint, CompletedReviewCount int, AssignmentSummary nvarchar(max), ActionAssignmentId int NULL);
SET STATISTICS XML ON;
INSERT #Queue EXEC $planCall;
SET STATISTICS XML OFF;
"@
$planOutput = $planSql | & docker exec -i triage-sql bash -lc '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -r 1 -d Triage -y 0 -Y 0' 2>&1
if ($LASTEXITCODE -ne 0) { throw "Actual plan command failed: $($planOutput -join [Environment]::NewLine)" }
$planText = $planOutput -join "`n"
$planMatch = [regex]::Match($planText, '<ShowPlanXML[\s\S]*?</ShowPlanXML>')
if (-not $planMatch.Success -or $planMatch.Value -notmatch 'RunTimeCountersPerThread') { throw 'Actual execution plan capture failed.' }
$planPath = Join-Path $performanceDirectory "PERF-112-$modeName.sqlplan"
$planMatch.Value | Set-Content -LiteralPath $planPath -Encoding utf8NoBOM

Write-Host "PERF-112 $Mode evidence captured at $summaryPath and $planPath." -ForegroundColor Green
$summaries | Format-Table -AutoSize
