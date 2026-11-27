<#
.SYNOPSIS
    Exporta la base de datos PostgreSQL local ("BD") a backup_BD.sql
    usando las variables configuradas en .env.
.EXAMPLE
    .\scripts\export_backup.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputFile = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Join-Path $ProjectRoot "backup_BD.sql"
}

function Find-PgDump {
    $cmd = Get-Command pg_dump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\pg_dump.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($candidates) { return $candidates[0].FullName }

    throw "No se encontró pg_dump.exe."
}

# Cargar variables de .env si existe
$envFile = Join-Path $ProjectRoot ".env"
$cfg = @{
    DB_HOST = "localhost"
    DB_PORT = "5432"
    DB_NAME = "BD"
    DB_USER = "usuario"
    DB_PASSWORD = ""
}
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $kv = $line -split "=", 2
            $k = $kv[0].Trim()
            $v = $kv[1].Trim().Trim('"').Trim("'")
            if ($cfg.ContainsKey($k)) { $cfg[$k] = $v }
        }
    }
}

$pgDump = Find-PgDump
$prevPgPass = $env:PGPASSWORD
try {
    if (-not [string]::IsNullOrEmpty($cfg.DB_PASSWORD)) {
        $env:PGPASSWORD = $cfg.DB_PASSWORD
    }
    Write-Host "Exportando `"$($cfg.DB_NAME)`" desde $($cfg.DB_HOST):$($cfg.DB_PORT) -> $OutputFile ..." -ForegroundColor Cyan
    & $pgDump -h $cfg.DB_HOST -p $cfg.DB_PORT -U $cfg.DB_USER -d $cfg.DB_NAME --encoding=UTF8 -f $OutputFile
    if ($LASTEXITCODE -ne 0) { throw "Falló pg_dump." }
    Write-Host "Respaldo actualizado correctamente en $OutputFile" -ForegroundColor Green
}
finally {
    $env:PGPASSWORD = $prevPgPass
}
