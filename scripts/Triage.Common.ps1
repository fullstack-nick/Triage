Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TriageRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:TriageLocal = Join-Path $script:TriageRoot '.local'
$script:TriageEnvironmentFile = Join-Path $script:TriageLocal 'triage.env'

function Get-TriageRoot {
    return $script:TriageRoot
}

function Get-TriageLocalPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $ChildPath)
    if ([string]::IsNullOrEmpty($ChildPath)) { return $script:TriageLocal }
    return Join-Path $script:TriageLocal $ChildPath
}

function Read-TriageEnvironment {
    if (-not (Test-Path -LiteralPath $script:TriageEnvironmentFile -PathType Leaf)) {
        throw "Local settings are missing. Run scripts/Initialize-Triage.ps1 first."
    }

    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $script:TriageEnvironmentFile) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -eq 2) { $settings[$parts[0]] = $parts[1] }
    }
    return $settings
}

function Set-TriageProcessEnvironment {
    param([Parameter(Mandatory)][hashtable] $Settings)
    foreach ($entry in $Settings.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }
}

function Invoke-TriageSqlText {
    param(
        [Parameter(Mandatory)][string] $Sql,
        [string] $Database = 'master',
        [switch] $CaptureOutput
    )

    $arguments = @(
        'exec', '-i', 'triage-sql',
        'bash', '-lc',
        "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P `"`$MSSQL_SA_PASSWORD`" -C -I -b -r 1 -d $Database"
    )

    if ($CaptureOutput) {
        $result = $Sql | & docker @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "SQL command failed: $($result -join [Environment]::NewLine)" }
        return $result
    }

    $Sql | & docker @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'SQL command failed.' }
}

function Invoke-TriageSqlFile {
    param([Parameter(Mandatory)][string] $Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Write-Host "Applying $([System.IO.Path]::GetFileName($resolved))..."
    Invoke-TriageSqlText -Sql (Get-Content -LiteralPath $resolved -Raw)
}

function Wait-TriageSql {
    param([int] $TimeoutSeconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = (& docker inspect --format '{{.State.Health.Status}}' triage-sql 2>$null)
        if ($LASTEXITCODE -eq 0 -and $state -eq 'healthy') { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'SQL Server did not become healthy before the timeout.'
}

function New-TriageIisConfiguration {
    $baseConfiguration = 'C:\Program Files\IIS Express\AppServer\applicationhost.config'
    $templatePath = Join-Path $script:TriageRoot '.iis\applicationhost.config.template'
    $iisDirectory = Get-TriageLocalPath -ChildPath 'iis'
    $outputPath = Join-Path $iisDirectory 'applicationhost.config'
    New-Item -ItemType Directory -Path $iisDirectory -Force | Out-Null

    [xml]$configuration = Get-Content -LiteralPath $baseConfiguration -Raw
    $siteCollection = $configuration.configuration.'system.applicationHost'.sites
    @($siteCollection.site) | ForEach-Object { [void]$siteCollection.RemoveChild($_) }

    $fragmentText = Get-Content -LiteralPath $templatePath -Raw
    $fragmentText = $fragmentText.Replace('__LEGACY_ADMIN_ROOT__', (Join-Path $script:TriageRoot 'src\LegacyAdmin'))
    $fragmentText = $fragmentText.Replace('__REVIEWER_WEB_ROOT__', (Join-Path $script:TriageRoot 'src\ReviewerWeb'))
    [xml]$fragment = $fragmentText
    $siteNode = $configuration.ImportNode($fragment.DocumentElement, $true)
    [void]$siteCollection.PrependChild($siteNode)

    $siteDefaults = $siteCollection.siteDefaults
    $siteDefaults.logFile.enabled = 'true'
    $siteDefaults.logFile.directory = (Get-TriageLocalPath -ChildPath 'logs\iis')
    $configuration.Save($outputPath)
    return $outputPath
}

function Test-TriagePortAvailable {
    param([Parameter(Mandatory)][int] $Port)
    return -not [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Wait-TriageHttp {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [int] $TimeoutSeconds = 45,
        [int[]] $AcceptedStatus = @(200)
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 4
            if ($AcceptedStatus -contains [int]$response.StatusCode) { return $response }
        } catch {
            # The process may still be starting.
        }
        Start-Sleep -Milliseconds 750
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The local endpoint did not become ready: $Uri"
}
