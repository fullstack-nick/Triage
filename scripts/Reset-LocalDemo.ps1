[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([switch] $Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

$root = Get-TriageRoot
$gitRoot = (& git -C $root rev-parse --show-toplevel 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or [System.IO.Path]::GetFullPath($gitRoot) -ne [System.IO.Path]::GetFullPath($root)) {
    throw 'Refusing reset because the script is not inside the Triage repository root.'
}

$message = 'Stop Triage, delete only the triage-sql-data Docker volume, and clear generated provider/test data'
if (-not $Force -and -not $PSCmdlet.ShouldProcess($root, $message)) { return }

& (Join-Path $PSScriptRoot 'Stop-Triage.ps1')
Push-Location $root
try {
    $environmentPath = Get-TriageLocalPath -ChildPath 'triage.env'
    if (Test-Path -LiteralPath $environmentPath) {
        & docker compose --env-file $environmentPath down
    }
    $volumeName = (& docker volume ls --format '{{.Name}}' --filter 'name=^triage-sql-data$').Trim()
    if ($volumeName -eq 'triage-sql-data') { & docker volume rm 'triage-sql-data' | Out-Null }

    foreach ($relative in @('provider', 'test-results', 'performance')) {
        $target = [System.IO.Path]::GetFullPath((Get-TriageLocalPath -ChildPath $relative))
        $localRoot = [System.IO.Path]::GetFullPath((Get-TriageLocalPath -ChildPath ''))
        if (-not $target.StartsWith($localRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe reset target: $target" }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
} finally {
    Pop-Location
}

Write-Host 'Local Triage demo data was removed. Run scripts/Initialize-Triage.ps1 to recreate it.' -ForegroundColor Yellow
