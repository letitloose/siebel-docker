# Full setup: build images, start the database, and bootstrap Siebel.
# Safe to re-run — all steps are idempotent.
#
# First run takes ~3 hours (DB creation ~20 min + schema import ~2 hrs + bootstrap ~35 min).
#
# Note: Docker Desktop on Windows handles bind-mount permissions automatically via WSL2.
# If you see permission errors on data/dumps/ or siebel-volumes/, run:
#   docker compose exec oracle19c chown -R oracle:oinstall /opt/oracle/dumps
#   docker compose exec mde chown -R 29263:29263 /persistent /sfs
#
#   .\scripts\start.ps1
#
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

# Load .env into the current process environment
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.*)\s*$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}

Write-Host "==> 1/2  Building Oracle Instant Client base image"
docker compose build instantclient

Write-Host "==> 2/2  Building Siebel MDE (all-in-one Gateway + Server + AI)"
docker compose build mde

Write-Host "==> Starting Oracle database"
Write-Host "    First run: DB creation (~20 min) + schema import (~2 hrs)"
Write-Host "    Subsequent runs: starts the already-provisioned database in seconds"
docker compose up -d oracle19c

Write-Host "==> Bootstrapping Siebel (waits for database health, then configures the enterprise)"
& "$PSScriptRoot\bootstrap-mde.ps1"
