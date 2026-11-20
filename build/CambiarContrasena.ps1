<#
    Configura (o quita) la contraseña de acceso de la herramienta.
    Uso:
        powershell -NoProfile -ExecutionPolicy Bypass -File build\CambiarContrasena.ps1
    Guarda en src\SoporteTecnico.ps1 solo una sal y un hash PBKDF2, nunca la contraseña.
    Después vuelva a compilar con build\Compilar.ps1.
#>

$ErrorActionPreference = 'Stop'

$raiz   = Split-Path -Path $PSScriptRoot -Parent
$fuente = Join-Path $raiz 'src\SoporteTecnico.ps1'
$iteraciones = 100000

function Leer-Clave {
    param([string]$Texto)
    $seguro = Read-Host $Texto -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

if (-not (Test-Path -LiteralPath $fuente)) {
    Write-Host "No se encontró el script: $fuente" -ForegroundColor Red
    exit 1
}

Write-Host 'Deje la contraseña vacía y presione Enter para QUITAR la contraseña.' -ForegroundColor DarkGray
$clave1 = Leer-Clave 'Nueva contraseña'

if ($clave1) {
    if ($clave1.Length -lt 6) {
        Write-Host 'La contraseña debe tener al menos 6 caracteres.' -ForegroundColor Red
        exit 1
    }
    $clave2 = Leer-Clave 'Repita la contraseña'
    if ($clave1 -cne $clave2) {
        Write-Host 'Las contraseñas no coinciden.' -ForegroundColor Red
        exit 1
    }
    $sal = New-Object byte[] 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($sal)
    $rng.Dispose()
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($clave1, $sal, $iteraciones)
    $hash = [Convert]::ToBase64String($kdf.GetBytes(32))
    $kdf.Dispose()
    $salTexto = [Convert]::ToBase64String($sal)
}
else {
    $hash = ''
    $salTexto = ''
}
$clave1 = $null
$clave2 = $null

$texto = [System.IO.File]::ReadAllText($fuente)
$cambios = @(
    @{ Patron = '(?m)^\$Script:ClaveSal\s*=[^\r\n]*';  Nuevo = "`$Script:ClaveSal = '$salTexto'" },
    @{ Patron = '(?m)^\$Script:ClaveHash\s*=[^\r\n]*'; Nuevo = "`$Script:ClaveHash = '$hash'" },
    @{ Patron = '(?m)^\$Script:ClaveIteraciones\s*=[^\r\n]*'; Nuevo = "`$Script:ClaveIteraciones = $iteraciones" }
)
foreach ($c in $cambios) {
    $coincidencias = [regex]::Matches($texto, $c.Patron).Count
    if ($coincidencias -ne 1) {
        Write-Host ("No se encontró la línea a modificar ({0} coincidencias): {1}" -f $coincidencias, $c.Patron) -ForegroundColor Red
        exit 1
    }
    $reemplazo = $c.Nuevo
    $texto = [regex]::Replace($texto, $c.Patron, { param($m) $reemplazo })
}

# UTF-8 con BOM (necesario para las tildes en PowerShell 5.1); ReadAllText conserva los CRLF.
[System.IO.File]::WriteAllText($fuente, $texto, (New-Object System.Text.UTF8Encoding($true)))

if ($hash) {
    Write-Host 'Contraseña configurada.' -ForegroundColor Green
}
else {
    Write-Host 'Contraseña eliminada: la herramienta ya no la pedirá.' -ForegroundColor Yellow
}
Write-Host 'Vuelva a compilar con build\Compilar.ps1 para que el .exe use el cambio.' -ForegroundColor Cyan
