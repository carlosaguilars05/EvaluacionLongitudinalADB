<#
.SYNOPSIS
    Configura la base de datos PostgreSQL local ("BD") y el rol "usuario"
    restaurando backup_BD.sql, y genera el archivo .env local.
.DESCRIPTION
    Script idempotente para Windows con PostgreSQL 16/17.
    Solicita de forma oculta la contraseña de "postgres" (sin guardarla) y
    configura el rol "usuario" con la contraseña local deseada para cumplir
    con scram-sha-256 y las variables de entorno compatibles con Cloud SQL.
.EXAMPLE
    .\scripts\setup_db.ps1
    .\scripts\setup_db.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$DbHost = "localhost",
    [int]$DbPort = 5432,
    [string]$DbName = "BD",
    [string]$AppUser = "usuario",
    [string]$AdminUser = "postgres",
    [string]$BackupFile = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BackupFile)) {
    $BackupFile = Join-Path $ProjectRoot "backup_BD.sql"
}

function Find-Psql {
    $cmd = Get-Command psql -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    if ($candidates) { return $candidates[0].FullName }

    throw "No se encontró psql.exe. Instala PostgreSQL o agrega la carpeta bin al PATH."
}

function Convert-SecureToPlain([System.Security.SecureString]$Sec) {
    return [System.Net.NetworkCredential]::new("", $Sec).Password
}

function New-RandomSecretKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace "-", "").ToLowerInvariant()
}

Write-Host "=== Configuración de PostgreSQL Local — Sistema de Gestión Clínica ===" -ForegroundColor Cyan

if (-not (Test-Path $BackupFile)) {
    throw "No se encontró el archivo de respaldo: $BackupFile"
}

# Verificar servicio de PostgreSQL en Windows
$pgService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pgService -and $pgService.Status -ne "Running") {
    Write-Warning "El servicio $($pgService.Name) está en estado '$($pgService.Status)'. Inícialo antes de continuar."
    exit 1
}

$psql = Find-Psql
Write-Host "Usando psql: $psql" -ForegroundColor Gray
Write-Host "Respaldo a restaurar: $BackupFile" -ForegroundColor Gray

# Solicitar credenciales de forma segura (ocultas en terminal)
$adminSec = Read-Host -Prompt "Contraseña del superusuario PostgreSQL ($AdminUser)" -AsSecureString
$adminPass = Convert-SecureToPlain $adminSec
if ([string]::IsNullOrEmpty($adminPass)) {
    throw "La contraseña de '$AdminUser' no puede estar vacía."
}

$defaultAppPass = "usuario_local_2026"
Write-Host ""
Write-Host "Nota: Tu PostgreSQL local usa scram-sha-256 (exige contraseña)." -ForegroundColor Yellow
Write-Host "Se guardará automáticamente en tu archivo .env local (ignorado por Git) para que no tengas que escribirla de nuevo." -ForegroundColor Yellow
$appSec = Read-Host -Prompt "Contraseña local para el rol '$AppUser' [Enter = $defaultAppPass]" -AsSecureString
$appPass = Convert-SecureToPlain $appSec
if ([string]::IsNullOrWhiteSpace($appPass)) {
    $appPass = $defaultAppPass
}

$prevPgPass = $env:PGPASSWORD
try {
    $env:PGPASSWORD = $adminPass

    Write-Host "`n[1/5] Verificando conexión como '$AdminUser'..." -ForegroundColor Cyan
    $ver = & $psql -h $DbHost -p $DbPort -U $AdminUser -d postgres -tAc "SELECT version();" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo conectar como '$AdminUser'. Verifica la contraseña. Detalle: $ver"
    }
    Write-Host "  Conectado: $($ver.Trim())" -ForegroundColor Green

    Write-Host "[2/5] Creando/actualizando rol '$AppUser'..." -ForegroundColor Cyan
    $escapedPass = $appPass.Replace("'", "''")
    $escapedUser = $AppUser.Replace("'", "''")
    $roleSql = @"
DO `$`$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$escapedUser') THEN
        CREATE ROLE "$AppUser" WITH LOGIN PASSWORD '$escapedPass';
    ELSE
        ALTER ROLE "$AppUser" WITH LOGIN PASSWORD '$escapedPass';
    END IF;
END
`$`$;
"@
    $roleSql | & $psql -h $DbHost -p $DbPort -U $AdminUser -d postgres -v ON_ERROR_STOP=1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Error al crear/actualizar el rol '$AppUser'." }
    Write-Host "  Rol '$AppUser' listo." -ForegroundColor Green

    Write-Host "[3/5] Preparando base de datos `"$DbName`"..." -ForegroundColor Cyan
    $escapedDb = $DbName.Replace("'", "''")
    $dbExistsRaw = "SELECT 1 FROM pg_database WHERE datname = '$escapedDb';" | & $psql -h $DbHost -p $DbPort -U $AdminUser -d postgres -tA
    $dbExists = ("$dbExistsRaw").Trim()
    if ($dbExists -eq "1") {
        if (-not $Force) {
            $confirm = Read-Host "La base de datos `"$DbName`" ya existe. ¿Deseas recrearla desde backup_BD.sql? (s/N)"
            if ($confirm -notin @("s", "S", "si", "SI", "y", "Y")) {
                Write-Host "Operación cancelada por el usuario." -ForegroundColor Yellow
                exit 0
            }
        }
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$escapedDb' AND pid <> pg_backend_pid();" | & $psql -h $DbHost -p $DbPort -U $AdminUser -d postgres -v ON_ERROR_STOP=1 | Out-Null
        "DROP DATABASE `"$DbName`";" | & $psql -h $DbHost -p $DbPort -U $AdminUser -d postgres -v ON_ERROR_STOP=1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Error al eliminar la base de datos existente `"$DbName`"." }
    }

    "CREATE DATABASE `"$DbName`" OWNER `"$AppUser`" ENCODING 'UTF8';" | & $psql -h $DbHost -p $DbPort -U $AdminUser -d postgres -v ON_ERROR_STOP=1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Error al crear la base de datos `"$DbName`"." }
    Write-Host "  Base de datos `"$DbName`" creada con owner '$AppUser'." -ForegroundColor Green

    Write-Host "[4/5] Restaurando respaldo $BackupFile..." -ForegroundColor Cyan
    & $psql -h $DbHost -p $DbPort -U $AdminUser -d $DbName -v ON_ERROR_STOP=1 -f $BackupFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Error al restaurar $BackupFile." }
    Write-Host "  Respaldo restaurado exitosamente." -ForegroundColor Green

    Write-Host "[5/5] Verificando conexión con el rol '$AppUser' y validando objetos..." -ForegroundColor Cyan
    $env:PGPASSWORD = $appPass
    $summaryQuery = @"
SELECT
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') AS tablas,
    (SELECT count(*) FROM information_schema.views WHERE table_schema = 'public') AS vistas,
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'public' AND p.prokind = 'p') AS procedimientos;
"@
    $counts = (& $psql -h $DbHost -p $DbPort -U $AppUser -d $DbName -tAF "," -c $summaryQuery).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Falló la conexión de verificación como '$AppUser'." }
    $parts = $counts -split ","
    Write-Host "  Tablas: $($parts[0]) | Vistas: $($parts[1]) | Stored Procedures: $($parts[2])" -ForegroundColor Green

    $metrics = (& $psql -h $DbHost -p $DbPort -U $AppUser -d $DbName -tAc "CALL sp_consultar_metricas_dashboard(NULL, NULL, NULL, NULL);").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Falló la prueba de ejecución del SP sp_consultar_metricas_dashboard." }
    Write-Host "  Prueba CALL sp_consultar_metricas_dashboard -> $metrics" -ForegroundColor Green

    # Generar o actualizar .env local
    $envPath = Join-Path $ProjectRoot ".env"
    $secretKey = New-RandomSecretKey
    $envContent = @"
# Archivo generado localmente por scripts/setup_db.ps1 (NO subir a Git)
FLASK_SECRET_KEY=$secretKey
FLASK_DEBUG=true
FLASK_HOST=127.0.0.1
FLASK_PORT=5000

DB_HOST=$DbHost
DB_PORT=$DbPort
DB_NAME=$DbName
DB_USER=$AppUser
DB_PASSWORD=$appPass
DB_SSLMODE=prefer

MONGO_URI=mongodb://localhost:27017
MONGO_DB_NAME=clinica_salud_mental
"@
    if (Test-Path $envPath) {
        if ($Force) {
            [System.IO.File]::WriteAllText($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))
            Write-Host "`nArchivo .env actualizado." -ForegroundColor Green
        } else {
            Write-Host "`nYa existe un archivo .env local (se conservó sin cambios). Verifica que DB_PASSWORD coincida." -ForegroundColor Yellow
        }
    } else {
        [System.IO.File]::WriteAllText($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "`nArchivo .env creado automáticamente (protegido por .gitignore)." -ForegroundColor Green
    }

    Write-Host "`n¡Listo! Base de datos PostgreSQL levantada y verificada." -ForegroundColor Green
}
finally {
    $env:PGPASSWORD = $prevPgPass
    $adminPass = $null
    $appPass = $null
}
