<#
    Funciones de la contrasena de acceso, compartidas por Compilar.ps1.
    No se ejecuta solo: Compilar.ps1 lo carga con ". build\Clave.ps1".
    La contrasena se lee del archivo .env (SOPORTE_CLAVE=...). En el .exe solo entra su hash PBKDF2.
#>

function Read-DotEnv {
    # Lee un archivo .env (CLAVE=valor). Ignora lineas vacias y comentarios (#). Devuelve un hashtable.
    param([string]$Ruta)
    $valores = @{}
    if (-not (Test-Path -LiteralPath $Ruta)) { return $valores }
    foreach ($linea in [System.IO.File]::ReadAllLines($Ruta, [System.Text.Encoding]::UTF8)) {
        $l = $linea.TrimStart([char]0xFEFF).Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf('=')
        if ($i -lt 1) { continue }
        $clave = $l.Substring(0, $i).Trim()
        $valor = $l.Substring($i + 1).Trim()
        if ($valor.Length -ge 2 -and (($valor.StartsWith('"') -and $valor.EndsWith('"')) -or ($valor.StartsWith("'") -and $valor.EndsWith("'")))) {
            $valor = $valor.Substring(1, $valor.Length - 2)
        }
        $valores[$clave] = $valor
    }
    return $valores
}

function New-DatosClave {
    # Sal aleatoria nueva y hash PBKDF2 (mismo algoritmo que Get-HashClave en SoporteTecnico.ps1).
    param([string]$Clave, [int]$Iteraciones = 100000)
    $sal = New-Object byte[] 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($sal)
    $rng.Dispose()
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Clave, $sal, $Iteraciones)
    $hash = [Convert]::ToBase64String($kdf.GetBytes(32))
    $kdf.Dispose()
    return @{ Sal = [Convert]::ToBase64String($sal); Hash = $hash; Iteraciones = $Iteraciones }
}

function Set-ClaveEnTexto {
    # Devuelve el texto del script con la sal, el hash y las iteraciones puestos. No toca ningun archivo.
    param([string]$Texto, $Datos)
    $cambios = @(
        @{ Patron = '(?m)^\$Script:ClaveSal\s*=[^\r\n]*';         Nuevo = ("`$Script:ClaveSal = '{0}'" -f $Datos.Sal) },
        @{ Patron = '(?m)^\$Script:ClaveHash\s*=[^\r\n]*';        Nuevo = ("`$Script:ClaveHash = '{0}'" -f $Datos.Hash) },
        @{ Patron = '(?m)^\$Script:ClaveIteraciones\s*=[^\r\n]*'; Nuevo = ("`$Script:ClaveIteraciones = {0}" -f $Datos.Iteraciones) }
    )
    foreach ($c in $cambios) {
        $n = [regex]::Matches($Texto, $c.Patron).Count
        if ($n -ne 1) { throw ("No se encontro la linea a modificar ({0} coincidencias): {1}" -f $n, $c.Patron) }
        $reemplazo = $c.Nuevo
        $Texto = [regex]::Replace($Texto, $c.Patron, { param($m) $reemplazo })
    }
    return $Texto
}
