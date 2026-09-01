[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Triage.Common.ps1')

& (Join-Path $PSScriptRoot 'Verify-Prerequisites.ps1')

$root = Get-TriageRoot
$local = Get-TriageLocalPath -ChildPath ''
New-Item -ItemType Directory -Path $local -Force | Out-Null
New-Item -ItemType Directory -Path (Get-TriageLocalPath -ChildPath 'logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Get-TriageLocalPath -ChildPath 'provider') -Force | Out-Null
New-Item -ItemType Directory -Path (Get-TriageLocalPath -ChildPath 'test-results') -Force | Out-Null

$environmentPath = Get-TriageLocalPath -ChildPath 'triage.env'
if (-not (Test-Path -LiteralPath $environmentPath)) {
    function New-LocalPassword([int] $Length = 32) {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%_-'
        $characters = for ($index = 0; $index -lt ($Length - 4); $index++) {
            $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]
        }
        return ('Aa1!' + ($characters -join ''))
    }

    $saPassword = New-LocalPassword
    $appPassword = New-LocalPassword
    $adminPassword = New-LocalPassword 24
    $reviewerPassword = New-LocalPassword 24
    $providerDatabase = (Get-TriageLocalPath -ChildPath 'provider\triage-provider.db').Replace('\', '/')

    @(
        "TRIAGE_SA_PASSWORD=$saPassword"
        "TRIAGE_APP_PASSWORD=$appPassword"
        "TRIAGE_ADMIN_PASSWORD=$adminPassword"
        "TRIAGE_REVIEWER_PASSWORD=$reviewerPassword"
        "TRIAGE_DB_CONNECTION=Server=127.0.0.1,14333;Database=Triage;User ID=triage_app;Password=$appPassword;Encrypt=True;TrustServerCertificate=True;"
        "TRIAGE_DB_CONNECTION_ADO=Provider=MSOLEDBSQL19;Server=127.0.0.1,14333;Database=Triage;UID=triage_app;PWD=$appPassword;Use Encryption for Data=Mandatory;Trust Server Certificate=True;"
        'TRIAGE_NOTIFICATION_API_URL=http://127.0.0.1:5071/api/review-reminders'
        "TRIAGE_PROVIDER_DB=$providerDatabase"
        'TRIAGE_PROVIDER_TEST_MODE=0'
    ) | Set-Content -LiteralPath $environmentPath -Encoding utf8NoBOM
    Write-Host "Generated ignored local credentials at $environmentPath."
}

$settings = Read-TriageEnvironment
Set-TriageProcessEnvironment -Settings $settings

Push-Location $root
try {
    & docker compose --env-file $environmentPath up -d sqlserver
    if ($LASTEXITCODE -ne 0) { throw 'Unable to start the local SQL container.' }
    Wait-TriageSql

    foreach ($schemaFile in Get-ChildItem -LiteralPath (Join-Path $root 'database\schema') -Filter '*.sql' | Sort-Object Name) {
        Invoke-TriageSqlFile -Path $schemaFile.FullName
    }
    foreach ($migrationFile in Get-ChildItem -LiteralPath (Join-Path $root 'database\migrations') -Filter '*.sql' -ErrorAction SilentlyContinue | Sort-Object Name) {
        Invoke-TriageSqlFile -Path $migrationFile.FullName
    }
    foreach ($seedFile in Get-ChildItem -LiteralPath (Join-Path $root 'database\seed') -Filter '*.sql' | Sort-Object Name) {
        Invoke-TriageSqlFile -Path $seedFile.FullName
    }

    $escapedPassword = $settings.TRIAGE_APP_PASSWORD.Replace("'", "''")
    $securitySql = @"
USE master;
IF SUSER_ID(N'triage_app') IS NULL
    CREATE LOGIN [triage_app] WITH PASSWORD=N'$escapedPassword', CHECK_POLICY=ON, CHECK_EXPIRATION=OFF;
ELSE
    ALTER LOGIN [triage_app] WITH PASSWORD=N'$escapedPassword';
GO
USE Triage;
IF USER_ID(N'triage_app_user') IS NULL CREATE USER [triage_app_user] FOR LOGIN [triage_app];
GRANT EXECUTE TO [triage_app_user];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO [triage_app_user];
GO
"@
    Invoke-TriageSqlText -Sql $securitySql

    & dotnet restore (Join-Path $root 'src\NotificationApi\Triage.NotificationApi.csproj') --use-lock-file
    if ($LASTEXITCODE -ne 0) { throw 'Notification API restore failed.' }
    & dotnet build (Join-Path $root 'src\NotificationApi\Triage.NotificationApi.csproj') -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw 'Notification API build failed.' }

    $msbuild = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
    & $msbuild (Join-Path $root 'src\ReviewerWeb\Triage.Reviewer.Web.vbproj') /restore /p:Configuration=Release /v:minimal
    if ($LASTEXITCODE -ne 0) { throw 'Reviewer Web Forms build failed.' }

    [void](New-TriageIisConfiguration)
    Write-Host 'Triage initialization completed. No application process was left running.' -ForegroundColor Green
    Write-Host 'Start with: .\scripts\Start-Triage.ps1'
} finally {
    Pop-Location
}
