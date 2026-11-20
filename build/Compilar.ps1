<#
    Compila src\SoporteTecnico.ps1 a SoporteTecnico.exe con ps2exe.
    Uso (desde cualquier carpeta):
        powershell -NoProfile -ExecutionPolicy Bypass -File build\Compilar.ps1
    Ejecutar con Windows PowerShell 5.1 (el mismo motor que usarán los equipos de los clientes).
#>

$ErrorActionPreference = 'Stop'

$raiz   = Split-Path -Path $PSScriptRoot -Parent
$fuente = Join-Path $raiz 'src\SoporteTecnico.ps1'
$salida = Join-Path $raiz 'SoporteTecnico.exe'
$icono  = Join-Path $raiz 'icon.ico'

if (-not (Test-Path -LiteralPath $fuente)) {
    Write-Host "No se encontró el script: $fuente" -ForegroundColor Red
    exit 1
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor DarkGray
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host 'Aviso: se recomienda compilar con Windows PowerShell 5.1 para validar la sintaxis contra el motor real.' -ForegroundColor Yellow
}

# ---------- 1. Validar sintaxis ----------
Write-Host 'Validando sintaxis...' -ForegroundColor Cyan
$tokens = $null
$errores = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$tokens, [ref]$errores)
if ($errores -and $errores.Count -gt 0) {
    Write-Host ("Se encontraron {0} error(es) de sintaxis. No se compila." -f $errores.Count) -ForegroundColor Red
    foreach ($e in $errores) {
        Write-Host ("  Línea {0}, columna {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) -ForegroundColor Red
    }
    exit 1
}
Write-Host 'Sintaxis OK.' -ForegroundColor Green

if ([System.IO.File]::ReadAllText($fuente) -match "(?m)^\`$Script:ClaveHash\s*=\s*''") {
    Write-Host 'Aviso: no hay contraseña configurada. Para ponerla: build\CambiarContrasena.ps1' -ForegroundColor Yellow
}

# ---------- 2. Verificar codificación (UTF-8 con BOM) ----------
$bytes = [System.IO.File]::ReadAllBytes($fuente)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    Write-Host 'El script NO está guardado en UTF-8 con BOM: las tildes se verán mal. Guárdelo con BOM y vuelva a compilar.' -ForegroundColor Red
    exit 1
}

# ---------- 3. Instalar ps2exe si falta ----------
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando el módulo ps2exe (solo la primera vez)...' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

# ---------- 4. Versión (se toma de $Script:Version en el script) ----------
$version = '1.0.0.0'
$contenido = [System.IO.File]::ReadAllText($fuente)
if ($contenido -match "\`$Script:Version\s*=\s*'(\d+)\.(\d+)'") {
    $version = '{0}.{1}.0.0' -f $Matches[1], $Matches[2]
}

# ---------- 5. Compilar las dos versiones ----------
# SoporteTecnico.exe          -> interfaz gráfica (sin ventana de consola)
# SoporteTecnico-Consola.exe  -> menú de texto (para sesiones remotas lentas o si la interfaz falla)
$salidaConsola = Join-Path $raiz 'SoporteTecnico-Consola.exe'
$fuenteConsola = Join-Path $env:TEMP 'SoporteTecnico_consola.ps1'
$marca = "`$Script:ModoInterfaz = 'Grafica'"
if (-not $contenido.Contains($marca)) {
    Write-Host "No se encontró la línea $marca en el script." -ForegroundColor Red
    exit 1
}
[System.IO.File]::WriteAllText($fuenteConsola, $contenido.Replace($marca, "`$Script:ModoInterfaz = 'Consola'"), (New-Object System.Text.UTF8Encoding($true)))

$comunes = @{
    requireAdmin = $true
    x64          = $true
    STA          = $true
    title        = 'Soporte Técnico'
    product      = 'Soporte Técnico'
    description  = 'Herramienta de diagnóstico y reparación para Windows 10/11'
    version      = $version
}
if (Test-Path -LiteralPath $icono) {
    $comunes['iconFile'] = $icono
}
else {
    Write-Host 'No hay icon.ico; se compila sin icono.' -ForegroundColor DarkGray
}

$grafica = $comunes.Clone()
$grafica['inputFile'] = $fuente
$grafica['outputFile'] = $salida
$grafica['noConsole'] = $true
$grafica['noOutput'] = $true
$grafica['noError'] = $true

$consola = $comunes.Clone()
$consola['inputFile'] = $fuenteConsola
$consola['outputFile'] = $salidaConsola

# Se borran los .exe anteriores: si la compilación falla, no debe quedar uno viejo que parezca nuevo
foreach ($exe in @($salida, $salidaConsola)) {
    if (Test-Path -LiteralPath $exe) {
        try { Remove-Item -LiteralPath $exe -Force -ErrorAction Stop }
        catch {
            Write-Host "No se pudo borrar $exe (¿está abierto?). Ciérrelo y vuelva a compilar." -ForegroundColor Red
            Remove-Item -LiteralPath $fuenteConsola -Force -ErrorAction SilentlyContinue
            exit 1
        }
    }
}

try {
    Write-Host "Compilando versión $version (interfaz gráfica)..." -ForegroundColor Cyan
    Invoke-ps2exe @grafica
    Write-Host "Compilando versión $version (consola)..." -ForegroundColor Cyan
    Invoke-ps2exe @consola
}
finally {
    Remove-Item -LiteralPath $fuenteConsola -Force -ErrorAction SilentlyContinue
}

$faltan = @(@($salida, $salidaConsola) | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($faltan.Count -gt 0) {
    Write-Host ("No se generó: {0}. Revise los mensajes anteriores." -f ($faltan -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host "Listo:" -ForegroundColor Green
Write-Host "  $salida  (interfaz gráfica)" -ForegroundColor Green
Write-Host "  $salidaConsola  (consola)" -ForegroundColor Green
