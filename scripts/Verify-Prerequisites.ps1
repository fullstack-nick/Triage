[CmdletBinding()]
param([switch] $SkipPortCheck)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures = [System.Collections.Generic.List[string]]::new()

function Require-Command([string] $Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { $failures.Add("Command not found: $Name") }
}

Require-Command 'dotnet'
Require-Command 'docker'
Require-Command 'git'
Require-Command 'gh'

if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    $sdkVersion = (& dotnet --version).Trim()
    if ($sdkVersion -notlike '10.0.*') { $failures.Add("Expected .NET SDK 10.0.x; found $sdkVersion") }
}

$requiredFiles = @(
    'C:\Program Files\IIS Express\iisexpress.exe',
    'C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8.1\mscorlib.dll',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Microsoft\VisualStudio\v17.0\WebApplications\Microsoft.WebApplication.targets',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
)
foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Required file not found: $path") }
}

$providerRegistered = Test-Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\MSOLEDBSQL19'
if (-not $providerRegistered) { $providerRegistered = Test-Path 'Registry::HKEY_CLASSES_ROOT\MSOLEDBSQL19' }
if (-not $providerRegistered) { $failures.Add('OLE DB provider MSOLEDBSQL19 is not registered.') }

& docker info --format '{{.OSType}}/{{.Architecture}}' *> $null
if ($LASTEXITCODE -ne 0) { $failures.Add('Docker Desktop is not running.') }

$expectedImage = 'mcr.microsoft.com/mssql/server:2025-CU8-ubuntu-24.04@sha256:4bab24f36c1ecd48e85f7d37df26e6bf301641d84c3fe652f9a0dcc947d512e1'
& docker image inspect $expectedImage *> $null
if ($LASTEXITCODE -ne 0) { $failures.Add('The pinned SQL Server 2025 CU8 image is unavailable.') }

if (-not $SkipPortCheck) {
    foreach ($port in @(5070, 5071)) {
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { $failures.Add("Port $port is already in use.") }
    }
    $sqlListening = Get-NetTCPConnection -State Listen -LocalPort 14333 -ErrorAction SilentlyContinue
    if ($sqlListening) {
        $sqlContainerRunning = (& docker inspect --format '{{.State.Running}}' triage-sql 2>$null) -eq 'true'
        if (-not $sqlContainerRunning) { $failures.Add('Port 14333 is in use by something other than the Triage SQL container.') }
    }
}

$driveName = ([System.IO.Path]::GetPathRoot($root)).TrimEnd('\').TrimEnd(':')
$freeBytes = (Get-PSDrive -Name $driveName).Free
if ($freeBytes -lt 8GB) { $failures.Add('Less than 8 GB of free workspace disk remains.') }

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { $failures.Add('GitHub CLI authentication is unavailable.') }

if ($failures.Count -gt 0) {
    $message = "Prerequisite verification failed:`n - " + ($failures -join "`n - ")
    throw $message
}

Write-Host 'Triage prerequisite verification passed.' -ForegroundColor Green
