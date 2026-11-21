#Requires -Version 5.1
<#
    Soporte Técnico para Windows 10 / 11
    ------------------------------------
    Herramienta portable de diagnóstico y reparación para técnicos de soporte.
    - Compatible con Windows PowerShell 5.1 (no usar sintaxis de PowerShell 7).
    - Guardar SIEMPRE como UTF-8 con BOM y saltos de línea CRLF.
    - Compilar con build\Compilar.ps1 (ps2exe) o ejecutar con Ejecutar.bat.
#>

param([switch]$Consola)

# Funciones que ya existen antes de cargar la herramienta (para copiar solo las nuestras al runspace de tareas)
$Script:FuncionesIniciales = @(Get-ChildItem -Path function: | ForEach-Object { $_.Name })
# 'Grafica' = ventana WPF; 'Consola' = menú de texto. Compilar.ps1 genera un .exe de cada tipo.
$Script:ModoInterfaz = 'Grafica'
if ($Consola) { $Script:ModoInterfaz = 'Consola' }

$Script:Version = '2.6'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

#region ==================== AUTO-ELEVACIÓN ====================

function Test-EsAdmin {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidad)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-EsAdmin)) {
    Write-Host 'Se necesitan permisos de administrador. Solicitando elevación...' -ForegroundColor Yellow
    try {
        $rutaProceso = (Get-Process -Id $PID).Path
        $esHostPowerShell = $rutaProceso -match '\\(powershell|powershell_ise|pwsh)\.exe$'
        if ($PSCommandPath -and $esHostPowerShell) {
            # Ejecutándose como .ps1
            $argumentos = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
            if ($Script:ModoInterfaz -eq 'Consola') { $argumentos += ' -Consola' }
            else { $argumentos = '-WindowStyle Hidden ' + $argumentos }
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentos -Verb RunAs -ErrorAction Stop
        }
        else {
            # Ejecutándose como .exe (ps2exe deja $PSCommandPath vacío)
            Start-Process -FilePath $rutaProceso -Verb RunAs -ErrorAction Stop
        }
    }
    catch {
        $mensajeError = "No se pudieron obtener permisos de administrador: $($_.Exception.Message)"
        if ($Script:ModoInterfaz -eq 'Grafica') {
            # La ventana de PowerShell puede estar oculta: avisar con un cuadro de diálogo
            try {
                Add-Type -AssemblyName PresentationFramework
                [void][System.Windows.MessageBox]::Show($mensajeError, 'Soporte Técnico')
            }
            catch { }
        }
        else {
            Write-Host $mensajeError -ForegroundColor Red
            Read-Host 'Presione Enter para salir'
        }
    }
    exit
}

#endregion

#region ==================== CONFIGURACIÓN Y LOG ====================

$Script:BaseLocal   = Join-Path $env:SystemDrive 'SoporteTecnico'
$Script:Base        = $Script:BaseLocal
$Script:EnUsb       = $false
$Script:AvisoUsb    = ''

function Get-CarpetaPrograma {
    # Carpeta donde está la herramienta: la del .exe o, si se usa el .ps1, la del proyecto.
    if ($PSCommandPath) {
        $dir = Split-Path -Parent $PSCommandPath
        if ((Split-Path -Leaf $dir) -ieq 'src') { $dir = Split-Path -Parent $dir }
        return $dir
    }
    try { return (Split-Path -Parent (Get-Process -Id $PID).Path) } catch { return $null }
}

function Test-UnidadUsb {
    # True si la ruta está en una memoria USB o un disco externo USB.
    param([string]$Ruta)
    try {
        $letra = ([System.IO.Path]::GetPathRoot($Ruta)).TrimEnd('\')
        if ($letra -notmatch '^[A-Za-z]:$' -or $letra -ieq $env:SystemDrive) { return $false }
        $disco = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letra) -ErrorAction Stop
        if ($disco.DriveType -eq 2) { return $true }
        $bus = (Get-Partition -DriveLetter $letra.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType
        return ("$bus" -eq 'USB')
    }
    catch { return $false }
}

# Si la herramienta se abre desde una USB, los logs, reportes y respaldos se guardan en la USB:
#   <USB>\Clientes\<NOMBRE-DEL-EQUIPO>\Logs  y  \Reportes
# Si la USB está protegida o llena, se usa C:\SoporteTecnico como siempre.
$carpetaPrograma = Get-CarpetaPrograma
if ($carpetaPrograma -and (Test-UnidadUsb $carpetaPrograma)) {
    $baseUsb = Join-Path (Join-Path $carpetaPrograma 'Clientes') $env:COMPUTERNAME
    try {
        $letraUsb = ([System.IO.Path]::GetPathRoot($carpetaPrograma)).TrimEnd('\')
        $libre = (Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letraUsb) -ErrorAction Stop).FreeSpace
        if ($libre -and $libre -lt 100MB) { throw ('quedan solo {0} MB libres' -f [math]::Round($libre / 1MB)) }
        if (-not (Test-Path -LiteralPath $baseUsb)) { New-Item -ItemType Directory -Path $baseUsb -Force -ErrorAction Stop | Out-Null }
        $prueba = Join-Path $baseUsb ('.prueba_{0}' -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($prueba, 'ok')
        Remove-Item -LiteralPath $prueba -Force -ErrorAction SilentlyContinue
        $Script:Base = $baseUsb
        $Script:EnUsb = $true
    }
    catch {
        $Script:AvisoUsb = 'No se pudo guardar en la USB ({0}); los logs y reportes quedan en {1}.' -f $_.Exception.Message, $Script:BaseLocal
    }
}

$Script:DirLogs     = Join-Path $Script:Base 'Logs'
$Script:DirReportes = Join-Path $Script:Base 'Reportes'
$Script:LogFile     = Join-Path $Script:DirLogs ('log_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$Script:RequiereReinicio = $false

# En modo gráfico, Write-Host / Read-Host / Clear-Host se reemplazan por versiones que
# envían el texto al registro de la ventana y las preguntas a cuadros de diálogo.
$Sync = [hashtable]::Synchronized(@{})
$Sync.Cola = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$Sync.Pregunta = $null
$Sync.Respuesta = $null
$Sync.Cancelado = $false
$Sync.Ocupado = $false
$Sync.HiloUI = -1
$Sync.Diagnostico = $null
$Sync.PsActual = $null
$Sync.ClaveExportacion = $null
$Sync.SinArchivosLocales = $false
$Sync.Visita = [hashtable]::Synchronized(@{
        Activa = $false; Id = ''; Inicio = (Get-Date); Serie = ''; Diagnostico = $false
        Acciones = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        PuntajeAntes = $null; PuntajeDespues = $null; TareaActual = ''; Cliente = ''; Notas = ''
        Ficha = $null; AvisoAnterior = ''; ClienteAnterior = ''
    })

if ($Script:ModoInterfaz -eq 'Grafica') {
    function Write-Host {
        param(
            [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
            [System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray,
            [System.ConsoleColor]$BackgroundColor = [System.ConsoleColor]::Black,
            [switch]$NoNewline,
            [object]$Separator = ' '
        )
        $texto = (@($Object) | ForEach-Object { "$_" }) -join ' '
        $Sync.Cola.Enqueue(@{ Tipo = 'Log'; Texto = $texto; Color = "$ForegroundColor" })
    }

    function Read-Host {
        param([Parameter(Position = 0)][object]$Prompt, [switch]$AsSecureString)
        return (Solicitar-Gui -Tipo 'Texto' -Texto ("$Prompt".Trim()))
    }

    function Clear-Host { }
}

foreach ($carpeta in @($Script:DirLogs, $Script:DirReportes)) {
    try {
        if (-not (Test-Path -LiteralPath $carpeta)) {
            New-Item -ItemType Directory -Path $carpeta -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Host "No se pudo crear la carpeta ${carpeta}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Mensaje,
        [ValidateSet('OK', 'INFO', 'ADVERTENCIA', 'ERROR')][string]$Nivel = 'INFO',
        [switch]$SoloArchivo
    )
    $color = switch ($Nivel) {
        'OK'          { 'Green' }
        'INFO'        { 'Cyan' }
        'ADVERTENCIA' { 'Yellow' }
        'ERROR'       { 'Red' }
    }
    if (-not $SoloArchivo) {
        Write-Host ("  [{0}] {1}" -f $Nivel, $Mensaje) -ForegroundColor $color
    }
    # Sin la USB, al cerrar se borra el log del equipo del cliente: desde ahí ya no se escribe en disco
    if ($Sync.SinArchivosLocales) { return }
    $linea = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensaje
    # La ventana y las tareas en segundo plano escriben al mismo archivo: reintentar si está ocupado
    for ($intento = 1; $intento -le 3; $intento++) {
        try {
            Add-Content -LiteralPath $Script:LogFile -Value $linea -Encoding UTF8 -ErrorAction Stop
            break
        }
        catch {
            Start-Sleep -Milliseconds (50 * $intento)
        }
    }
}

#endregion

#region ==================== CONTRASEÑA DE ACCESO ====================

# Hash PBKDF2 de la contraseña (nunca la contraseña en texto). Se cambia con build\CambiarContrasena.ps1.
# Si ClaveHash está vacío, la herramienta no pide contraseña.
$Script:ClaveSal = ''
$Script:ClaveHash = ''
$Script:ClaveIteraciones = 100000

function Get-HashClave {
    param([string]$Clave, [byte[]]$Sal, [int]$Iteraciones)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Clave, $Sal, $Iteraciones)
    try { return [Convert]::ToBase64String($kdf.GetBytes(32)) }
    finally { $kdf.Dispose() }
}

function Test-Acceso {
    if (-not $Script:ClaveHash) { return $true }
    try {
        $sal = [Convert]::FromBase64String($Script:ClaveSal)
    }
    catch {
        Write-Log 'La contraseña configurada está dañada. Vuelva a configurarla con build\CambiarContrasena.ps1.' 'ERROR'
        Start-Sleep -Seconds 3
        return $false
    }
    Write-Host ''
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host ("   SOPORTE TÉCNICO v{0} - acceso restringido" -f $Script:Version) -ForegroundColor White
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host ''
    for ($intento = 1; $intento -le 3; $intento++) {
        $plano = ''
        $seguro = Read-Host '  Contraseña' -AsSecureString
        if ($seguro) {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
            try { $plano = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        }
        $hash = Get-HashClave -Clave $plano -Sal $sal -Iteraciones $Script:ClaveIteraciones
        if ($hash -ceq $Script:ClaveHash) { try { Set-ClaveExportacion -Clave $plano } catch { } }
        $plano = $null
        if ($hash -ceq $Script:ClaveHash) {
            Write-Log ("Acceso concedido (usuario de Windows: {0})." -f $env:USERNAME) 'INFO' -SoloArchivo
            return $true
        }
        Write-Log ("Contraseña incorrecta (intento {0} de 3)." -f $intento) 'ADVERTENCIA'
        Start-Sleep -Seconds (2 * $intento)
    }
    Write-Log 'Acceso denegado: 3 intentos fallidos.' 'ERROR'
    Start-Sleep -Seconds 2
    return $false
}

#endregion

#region ==================== UTILIDADES ====================

function Leer-SalidaNativa {
    # Lee lo nuevo del archivo de salida de un comando y lo muestra en el registro de la ventana.
    param([string]$Ruta, $Lector, [switch]$Final)
    if (-not (Test-Path -LiteralPath $Ruta)) { return }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Ruta, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($null -eq $Lector.Unicode -and $fs.Length -ge 2) {
            $inicio = New-Object byte[] 2
            $fs.Position = 0
            [void]$fs.Read($inicio, 0, 2)
            # sfc escribe en UTF-16; DISM y el resto en la página de códigos OEM
            $Lector.Unicode = ($inicio[1] -eq 0) -or ($inicio[0] -eq 0xFF -and $inicio[1] -eq 0xFE)
        }
        if ($null -eq $Lector.Unicode) { return }
        $disponibles = $fs.Length - $Lector.Posicion
        if ($Lector.Unicode -and ($disponibles % 2) -eq 1) { $disponibles-- }
        if ($disponibles -gt 0) {
            $buffer = New-Object byte[] ([int]$disponibles)
            $fs.Position = $Lector.Posicion
            $leidos = $fs.Read($buffer, 0, [int]$disponibles)
            $Lector.Posicion += $leidos
            if ($Lector.Unicode) {
                $texto = [System.Text.Encoding]::Unicode.GetString($buffer, 0, $leidos)
            }
            else {
                $oem = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
                $texto = [System.Text.Encoding]::GetEncoding($oem).GetString($buffer, 0, $leidos)
            }
            $Lector.Pendiente += $texto.Replace([string][char]0xFEFF, '').Replace([string][char]0, '')
        }
        $partes = $Lector.Pendiente -split "`n"
        $completas = $partes.Count - 1
        if ($Final) { $completas = $partes.Count }
        for ($i = 0; $i -lt $completas; $i++) {
            $linea = @($partes[$i] -split "`r" | Where-Object { $_.Trim() }) | Select-Object -Last 1
            if ($linea) { Write-Host ('    ' + $linea.TrimEnd()) -ForegroundColor Gray }
        }
        if ($Final) { $Lector.Pendiente = '' } else { $Lector.Pendiente = $partes[$partes.Count - 1] }
        $progreso = @($Lector.Pendiente -split "`r" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if ($progreso) { $Sync.Cola.Enqueue(@{ Tipo = 'Estado'; Texto = $progreso.Trim() }) }
    }
    catch { }
    finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Invoke-NativoGui {
    # Versión gráfica de Invoke-Nativo: ventana oculta y salida en vivo en el registro.
    param([string]$Archivo, [string]$Argumentos, [string]$Descripcion)
    $salidaTmp = Join-Path $env:TEMP ('soporte_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    try {
        $parametros = @{ FilePath = $Archivo; WindowStyle = 'Hidden'; RedirectStandardOutput = $salidaTmp; PassThru = $true; ErrorAction = 'Stop' }
        if ($Argumentos) { $parametros['ArgumentList'] = $Argumentos }
        $proceso = Start-Process @parametros
        $null = $proceso.Handle
        $lector = New-Object PSObject -Property @{ Posicion = [long]0; Unicode = $null; Pendiente = '' }
        while (-not $proceso.HasExited) {
            Start-Sleep -Milliseconds 700
            Leer-SalidaNativa -Ruta $salidaTmp -Lector $lector
        }
        $proceso.WaitForExit()
        Start-Sleep -Milliseconds 200
        Leer-SalidaNativa -Ruta $salidaTmp -Lector $lector -Final
        $codigo = $proceso.ExitCode
        if ($null -eq $codigo) {
            Write-Log "$Descripcion terminó (código de salida desconocido)." 'ADVERTENCIA'
            return 0
        }
        if ($codigo -eq 0) { Write-Log "$Descripcion terminó correctamente (código 0)." 'OK' }
        else { Write-Log "$Descripcion terminó con código $codigo." 'ADVERTENCIA' }
        return [int]$codigo
    }
    catch {
        Write-Log "No se pudo ejecutar ${Archivo}: $($_.Exception.Message)" 'ERROR'
        return -1
    }
    finally {
        Remove-Item -LiteralPath $salidaTmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-PuntajeSalud {
    $criticas = @($Script:Alertas | Where-Object { $_.StartsWith('[CRÍTICO]') }).Count
    $normales = @($Script:Alertas | Where-Object { $_.StartsWith('[ALERTA]') }).Count
    $puntaje = 100 - (20 * $criticas) - (7 * $normales)
    if ($puntaje -lt 0) { $puntaje = 0 }
    if ($puntaje -ge 80) { $color = '#16a34a'; $estado = 'Buen estado' }
    elseif ($puntaje -ge 50) { $color = '#d97706'; $estado = 'Requiere atención' }
    else { $color = '#dc2626'; $estado = 'Estado crítico' }
    return [pscustomobject]@{ Puntaje = $puntaje; Color = $color; Estado = $estado; Criticas = $criticas; Alertas = $normales }
}

function Get-AlertasOrdenadas {
    $lista = New-Object System.Collections.Generic.List[string]
    foreach ($prefijo in @('[CRÍTICO]', '[ALERTA]', '[INFO]')) {
        foreach ($a in $Script:Alertas) { if ($a.StartsWith($prefijo)) { $lista.Add($a) } }
    }
    return $lista.ToArray()
}


function Confirmar {
    param([string]$Pregunta)
    if ($Script:ModoInterfaz -eq 'Grafica') { return ((Solicitar-Gui -Tipo 'SiNo' -Texto $Pregunta) -eq 'Si') }
    $respuesta = Read-Host ("  {0} (S/N)" -f $Pregunta)
    if ($null -eq $respuesta) { return $false }
    return ($respuesta.Trim() -match '^(s|si|sí)$')
}

function Pausa {
    if ($Script:ModoInterfaz -eq 'Grafica') { return }
    Write-Host ''
    Read-Host '  Presione Enter para volver al menú' | Out-Null
}

function Get-RutaSistema {
    # Devuelve la ruta de un ejecutable de System32 (usa Sysnative si el proceso es de 32 bits en un Windows de 64 bits)
    param([string]$Ejecutable)
    $sistema = Join-Path $env:windir 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sistema = Join-Path $env:windir 'Sysnative'
    }
    $ruta = Join-Path $sistema $Ejecutable
    if (Test-Path -LiteralPath $ruta) { return $ruta }
    return $Ejecutable
}

function Invoke-Nativo {
    # Ejecuta un comando nativo en la misma consola, espera a que termine y registra el código de salida.
    param(
        [Parameter(Mandatory = $true)][string]$Archivo,
        [string]$Argumentos = '',
        [string]$Descripcion = ''
    )
    if (-not $Descripcion) { $Descripcion = "$Archivo $Argumentos" }
    Write-Log ("Ejecutando: {0} {1}" -f (Split-Path $Archivo -Leaf), $Argumentos) 'INFO'
    if ($Script:ModoInterfaz -eq 'Grafica') {
        return (Invoke-NativoGui -Archivo $Archivo -Argumentos $Argumentos -Descripcion $Descripcion)
    }
    try {
        if ($Argumentos) {
            $proceso = Start-Process -FilePath $Archivo -ArgumentList $Argumentos -NoNewWindow -Wait -PassThru -ErrorAction Stop
        }
        else {
            $proceso = Start-Process -FilePath $Archivo -NoNewWindow -Wait -PassThru -ErrorAction Stop
        }
        $codigo = $proceso.ExitCode
        if ($null -eq $codigo) {
            Write-Log "$Descripcion terminó (código de salida desconocido)." 'ADVERTENCIA'
            return 0
        }
        if ($codigo -eq 0) {
            Write-Log "$Descripcion terminó correctamente (código 0)." 'OK'
        }
        else {
            Write-Log "$Descripcion terminó con código $codigo." 'ADVERTENCIA'
        }
        return [int]$codigo
    }
    catch {
        Write-Log "No se pudo ejecutar ${Archivo}: $($_.Exception.Message)" 'ERROR'
        return -1
    }
}

function Get-TamanoCarpeta {
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return [long]0 }
    $suma = (Get-ChildItem -LiteralPath $Ruta -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $suma) { return [long]0 }
    return [long]$suma
}

function Get-EspacioLibre {
    try {
        $disco = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        return [long]$disco.FreeSpace
    }
    catch { return [long]0 }
}

function Detener-Servicio {
    # Detiene un servicio con reintentos (algunos, como wuauserv, se reinician solos)
    param([string]$Nombre)
    $servicio = Get-Service -Name $Nombre -ErrorAction SilentlyContinue
    if (-not $servicio) { Write-Log "El servicio $Nombre no existe en este equipo." 'ADVERTENCIA'; return $true }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Stop-Service -Name $Nombre -Force -ErrorAction Stop
            (Get-Service -Name $Nombre).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
            Write-Log "Servicio $Nombre detenido." 'OK'
            return $true
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
    if ((Get-Service -Name $Nombre).Status -eq 'Stopped') { return $true }
    Write-Log "No se pudo detener el servicio $Nombre." 'ADVERTENCIA'
    return $false
}

function Iniciar-Servicio {
    param([string]$Nombre, [switch]$HabilitarSiDeshabilitado)
    try {
        $servicio = Get-Service -Name $Nombre -ErrorAction Stop
        if ("$($servicio.StartType)" -eq 'Disabled') {
            if (-not $HabilitarSiDeshabilitado) {
                Write-Log "El servicio $Nombre está deshabilitado; no se inicia." 'ADVERTENCIA'
                return $false
            }
            Write-Log "El servicio $Nombre estaba deshabilitado; se cambia a inicio Manual." 'ADVERTENCIA'
            Set-Service -Name $Nombre -StartupType Manual -ErrorAction Stop
        }
        Start-Service -Name $Nombre -ErrorAction Stop
        Write-Log "Servicio $Nombre iniciado." 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo iniciar el servicio ${Nombre}: $($_.Exception.Message)" 'ADVERTENCIA'
        return $false
    }
}

function Preguntar-Reinicio {
    Write-Host ''
    Write-Log 'Algunas reparaciones necesitan reiniciar el equipo para completarse.' 'ADVERTENCIA'
    if (Confirmar '¿Reiniciar ahora?') {
        Write-Log 'Reiniciando el equipo por solicitud del técnico.' 'INFO'
        Start-Sleep -Seconds 2
        Restart-Computer -Force
    }
    else {
        Write-Log 'Reinicio pospuesto. Recuerde reiniciar más tarde.' 'INFO'
    }
    $Script:RequiereReinicio = $false
}

function Mostrar-AvisoSesionRemota {
    Write-Host ''
    Write-Host '  ************************************************************' -ForegroundColor Yellow
    Write-Host '  *  ATENCIÓN: esta acción cortará la conexión de red.        *' -ForegroundColor Yellow
    Write-Host '  *  Si está conectado por AnyDesk, TeamViewer u otra         *' -ForegroundColor Yellow
    Write-Host '  *  herramienta remota, la sesión se va a cortar y deberá    *' -ForegroundColor Yellow
    Write-Host '  *  volver a conectarse en unos minutos.                     *' -ForegroundColor Yellow
    Write-Host '  ************************************************************' -ForegroundColor Yellow
    Write-Host ''
}

function Mostrar-Titulo {
    param([string]$Texto)
    Write-Host ''
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host ('   ' + $Texto) -ForegroundColor White
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host ''
}

function SiNo {
    param([bool]$Valor)
    if ($Valor) { return 'OK' } else { return 'FALLA' }
}

#endregion

#region ==================== 1. DIAGNÓSTICO COMPLETO ====================

$Script:Rep = $null
$Script:Alertas = $null
$Script:Sugerencias = $null
$Script:Secciones = $null
$Script:SeccionActual = $null
$Script:AccionesSugeridas = $null
$Script:DiagInfo = $null

function Rep-Titulo {
    param([string]$Texto)
    $Script:Rep.Add('')
    $Script:Rep.Add("=== $Texto ===")
    if ($Script:ModoInterfaz -eq 'Grafica') { $Sync.Cola.Enqueue(@{ Tipo = 'Estado'; Texto = "Diagnóstico: analizando $Texto..." }) }
    $Script:SeccionActual = [pscustomobject]@{
        Nombre  = $Texto
        Lineas  = New-Object System.Collections.Generic.List[string]
        Alertas = New-Object System.Collections.Generic.List[object]
    }
    $Script:Secciones.Add($Script:SeccionActual)
    Write-Host ''
    Write-Host "  === $Texto ===" -ForegroundColor Cyan
}

function Rep-Linea {
    param([string]$Texto)
    $Script:Rep.Add("  $Texto")
    if ($Script:SeccionActual) { $Script:SeccionActual.Lineas.Add($Texto) }
    Write-Host "    $Texto"
}

function Rep-Alerta {
    param(
        [string]$Texto,
        [string]$Sugerencia,
        [switch]$Critica,
        [string]$Accion,
        [switch]$Info
    )
    if ($Critica) { $prefijo = 'CRÍTICO'; $color = 'Red' } else { $prefijo = 'ALERTA'; $color = 'Yellow' }
    if ($Info -and -not $Critica) { $prefijo = 'INFO'; $color = 'Cyan' }
    $Script:Rep.Add("  [!] $Texto")
    $Script:Alertas.Add("[$prefijo] $Texto")
    if ($Sugerencia -and -not $Script:Sugerencias.Contains($Sugerencia)) { $Script:Sugerencias.Add($Sugerencia) }
    if ($Script:SeccionActual) { $Script:SeccionActual.Alertas.Add([pscustomobject]@{ Texto = $Texto; Critica = [bool]$Critica; Info = ($prefijo -eq 'INFO') }) }
    if ($Accion -and -not $Script:AccionesSugeridas.Contains($Accion)) { $Script:AccionesSugeridas.Add($Accion) }
    Write-Host "    [!] $Texto" -ForegroundColor $color
    Write-Log "Diagnóstico - $prefijo - $Texto" 'ADVERTENCIA' -SoloArchivo
}

function Rep-Seccion {
    # Ejecuta una sección del diagnóstico; si falla, se registra y se continúa con la siguiente.
    param([string]$NombreSeccion, [scriptblock]$Contenido)
    Rep-Titulo $NombreSeccion
    try {
        & $Contenido
    }
    catch {
        Rep-Linea "No se pudo completar esta sección: $($_.Exception.Message)"
        Write-Log "Diagnóstico [$NombreSeccion]: $($_.Exception.Message)" 'ERROR' -SoloArchivo
    }
}

function Get-EventosSeguro {
    # Get-WinEvent lanza error si no hay eventos o si un proveedor no existe: se consulta cada proveedor por separado.
    param(
        [string]$Log,
        [string[]]$Proveedores,
        [int[]]$Ids,
        [int[]]$Niveles,
        [datetime]$Desde
    )
    $lista = New-Object System.Collections.Generic.List[object]
    if ($Proveedores) { $provs = $Proveedores } else { $provs = @('') }
    foreach ($proveedor in $provs) {
        $filtro = @{ LogName = $Log; StartTime = $Desde }
        if ($proveedor) { $filtro['ProviderName'] = $proveedor }
        if ($Ids)       { $filtro['Id'] = $Ids }
        if ($Niveles)   { $filtro['Level'] = $Niveles }
        try {
            $eventos = Get-WinEvent -FilterHashtable $filtro -ErrorAction SilentlyContinue
            foreach ($e in @($eventos)) { if ($e) { $lista.Add($e) } }
        }
        catch { }
    }
    return $lista.ToArray()
}

function Invoke-Diagnostico {
    param([switch]$SinPreguntas)
    $Script:Rep = New-Object System.Collections.Generic.List[string]
    $Script:Alertas = New-Object System.Collections.Generic.List[string]
    $Script:Sugerencias = New-Object System.Collections.Generic.List[string]
    $Script:ServiciosDetenidos = New-Object System.Collections.Generic.List[string]
    $Script:Secciones = New-Object System.Collections.Generic.List[object]
    $Script:SeccionActual = $null
    $Script:AccionesSugeridas = New-Object System.Collections.Generic.List[string]
    $Script:DiagInfo = [ordered]@{}
    $desde = (Get-Date).AddDays(-7)

    Mostrar-Titulo 'DIAGNÓSTICO COMPLETO'
    Write-Log 'Inicio del diagnóstico completo.' 'INFO'
    Write-Host '    Recolectando información, puede tardar 1 o 2 minutos...' -ForegroundColor DarkGray

    # ---------- Equipo ----------
    Rep-Seccion 'Equipo' {
        $cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $os   = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $Script:DiagOS = $os
        $Script:DiagCS = $cs
        $reg  = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $verWin = $reg.DisplayVersion
        if (-not $verWin) { $verWin = $reg.ReleaseId }
        $compilacion = '{0}.{1}' -f $reg.CurrentBuild, $reg.UBR

        Rep-Linea ("Nombre del equipo : {0}" -f $env:COMPUTERNAME)
        Rep-Linea ("Fabricante/Modelo : {0} {1}" -f $cs.Manufacturer, $cs.Model)
        if ($bios) {
            $fechaBios = ''
            if ($bios.ReleaseDate) { $fechaBios = ([datetime]$bios.ReleaseDate).ToString('dd/MM/yyyy') }
            Rep-Linea ("Número de serie   : {0}" -f $bios.SerialNumber)
            Rep-Linea ("BIOS              : {0} ({1})" -f $bios.SMBIOSBIOSVersion, $fechaBios)
        }
        Rep-Linea ("Sistema operativo : {0} {1} (compilación {2}) {3}" -f $os.Caption, $verWin, $compilacion, $os.OSArchitecture)
        Rep-Linea ("Usuario con sesión: {0}" -f $cs.UserName)
        Rep-Linea ("Dominio/Grupo     : {0}" -f $cs.Domain)

        $Script:DiagInfo['Equipo'] = "$($cs.Manufacturer) $($cs.Model)"
        $Script:DiagInfo['Sistema'] = "$($os.Caption) $verWin"
        if ($bios) { $Script:DiagInfo['Número de serie'] = "$($bios.SerialNumber)" }
        $Script:DiagInfo['Usuario'] = "$($cs.UserName)"

        $esWin10 = ($os.Caption -match 'Windows 10') -and ([int]$os.BuildNumber -lt 22000)
        if ($esWin10) {
            Rep-Alerta 'Windows 10 ya no recibe actualizaciones de seguridad gratuitas (soporte finalizado el 14/10/2025).' 'Considerar migrar a Windows 11 (verificar compatibilidad del equipo) o contratar ESU.'
        }

        $encendido = (Get-Date) - $os.LastBootUpTime
        $Script:DiagInfo['Encendido'] = "{0} días, {1} h" -f $encendido.Days, $encendido.Hours
        Rep-Linea ("Tiempo encendido  : {0} días, {1} horas (último inicio: {2})" -f $encendido.Days, $encendido.Hours, $os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm'))
        if ($encendido.TotalDays -gt 7) {
            Rep-Alerta ("El equipo lleva {0} días sin reiniciar." -f [int]$encendido.TotalDays) 'Reiniciar el equipo (con el inicio rápido activo, "Apagar" NO cuenta como reinicio).'
        }
    }

    # ---------- Memoria RAM ----------
    Rep-Seccion 'Memoria RAM' {
        $os = $Script:DiagOS
        if (-not $os) { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $libreGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $usoPct  = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 0)
        $instaladaGB = 0
        if ($Script:DiagCS) { $instaladaGB = [math]::Round($Script:DiagCS.TotalPhysicalMemory / 1GB, 1) }
        Rep-Linea ("Total: {0} GB | Libre: {1} GB | En uso: {2} %" -f $totalGB, $libreGB, $usoPct)
        $Script:DiagInfo['Memoria RAM'] = "{0} GB ({1} % en uso)" -f [math]::Max($totalGB, $instaladaGB), $usoPct
        if ($usoPct -ge 85) {
            Rep-Alerta ("Uso de memoria RAM alto ({0} %)." -f $usoPct) 'Revisar los procesos que más memoria consumen (ver "Top procesos por RAM").'
        }
        $referencia = $totalGB
        if ($instaladaGB -gt $referencia) { $referencia = $instaladaGB }
        if ($referencia -lt 7.5) {
            Rep-Alerta ("El equipo tiene poca memoria RAM ({0} GB)." -f $referencia) 'Ampliar la memoria RAM a 8 GB o más.'
        }

        Rep-Linea ''
        Rep-Linea 'Top procesos por RAM:'
        $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5
        foreach ($p in $top) {
            Rep-Linea ("  {0,-32} {1,8} MB" -f $p.ProcessName, [math]::Round($p.WorkingSet64 / 1MB, 0))
        }
    }

    # ---------- CPU ----------
    Rep-Seccion 'Procesador (CPU)' {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $carga = [math]::Round((($cpus | Measure-Object -Property LoadPercentage -Average).Average), 0)
        $nucleos = 0
        if ($Script:DiagCS) { $nucleos = [int]$Script:DiagCS.NumberOfLogicalProcessors }
        if ($nucleos -le 0) { $nucleos = [int]$env:NUMBER_OF_PROCESSORS }
        if ($nucleos -le 0) { $nucleos = 1 }
        Rep-Linea ("Procesador: {0}" -f $cpus[0].Name.Trim())
        $Script:DiagInfo['Procesador'] = $cpus[0].Name.Trim()
        Rep-Linea ("Núcleos lógicos: {0} | Carga actual: {1} %" -f $nucleos, $carga)
        if ($carga -ge 85) {
            Rep-Alerta ("Uso de CPU alto ({0} %)." -f $carga) 'Revisar el proceso que más CPU consume (ver "Top procesos por CPU").'
        }
        Rep-Linea ''
        Rep-Linea 'Top procesos por CPU:'
        $procs = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
            Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
            Sort-Object -Property PercentProcessorTime -Descending |
            Select-Object -First 5
        foreach ($p in $procs) {
            $pct = [math]::Round($p.PercentProcessorTime / $nucleos, 1)
            Rep-Linea ("  {0,-32} {1,6} %  (PID {2})" -f $p.Name, $pct, $p.IDProcess)
        }
    }

    # ---------- Espacio en disco ----------
    Rep-Seccion 'Espacio en disco' {
        $discos = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
        foreach ($d in $discos) {
            if (-not $d.Size -or $d.Size -eq 0) { continue }
            $totalGB = [math]::Round($d.Size / 1GB, 1)
            $libreGB = [math]::Round($d.FreeSpace / 1GB, 1)
            $librePct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 0)
            Rep-Linea ("{0}  Total: {1} GB | Libre: {2} GB ({3} %)" -f $d.DeviceID, $totalGB, $libreGB, $librePct)
            if ($d.DeviceID -eq $env:SystemDrive) { $Script:DiagInfo["Disco $($d.DeviceID)"] = "{0} GB libres de {1} GB" -f $libreGB, $totalGB }
            if ($librePct -lt 10) {
                Rep-Alerta ("La unidad {0} tiene poco espacio libre ({1} %)." -f $d.DeviceID, $librePct) 'Opción 4 (Limpiar archivos temporales) y revisar Descargas / programas que no se usan.' -Accion '4'
            }
        }
    }

    # ---------- Salud del disco ----------
    Rep-Seccion 'Salud del disco' {
        $hayHDD = $false
        try {
            $fisicos = @(Get-PhysicalDisk -ErrorAction Stop)
            foreach ($d in $fisicos) {
                $salud = "$($d.HealthStatus)"
                if ($salud -eq '0') { $salud = 'Healthy' }
                $tipo = "$($d.MediaType)"
                if ($tipo -eq '3') { $tipo = 'HDD' } elseif ($tipo -eq '4') { $tipo = 'SSD' } elseif ($tipo -eq '0') { $tipo = 'Unspecified' }
                Rep-Linea ("{0} | Tipo: {1} | {2} GB | Bus: {3} | Salud: {4}" -f $d.FriendlyName, $tipo, [math]::Round($d.Size / 1GB, 0), $d.BusType, $salud)
                if ($salud -ne 'Healthy') {
                    Rep-Alerta ("El disco '{0}' reporta estado de salud '{1}'." -f $d.FriendlyName, $salud) 'RESPALDAR LA INFORMACIÓN YA y reemplazar el disco.' -Critica
                }
                if ($tipo -eq 'HDD') { $hayHDD = $true }
            }
        }
        catch {
            Rep-Linea 'No se pudo consultar Get-PhysicalDisk.'
        }
        try {
            $smart = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
            $fallas = @($smart | Where-Object { $_.PredictFailure })
            if ($fallas.Count -gt 0) {
                Rep-Alerta 'SMART predice una falla inminente del disco.' 'RESPALDAR LA INFORMACIÓN YA y reemplazar el disco.' -Critica
            }
            else {
                Rep-Linea 'SMART: sin predicción de falla.'
            }
        }
        catch {
            Rep-Linea 'SMART no disponible (normal en discos NVMe o algunas controladoras).'
        }
        try {
            foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
                $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                $partes = New-Object System.Collections.Generic.List[string]
                if ($rc.Temperature) { $partes.Add(("temperatura {0} °C" -f $rc.Temperature)) }
                if ($null -ne $rc.Wear) { $partes.Add(("desgaste {0} %" -f $rc.Wear)) }
                if ($rc.PowerOnHours) { $partes.Add(("encendido {0} días en total" -f [math]::Round($rc.PowerOnHours / 24))) }
                if ($null -ne $rc.ReadErrorsUncorrected) { $partes.Add(("errores de lectura sin corregir: {0}" -f $rc.ReadErrorsUncorrected)) }
                if ($partes.Count -gt 0) { Rep-Linea ("{0}: {1}" -f $d.FriendlyName, ($partes -join ' | ')) }
                if ($rc.Wear -ge 90) {
                    Rep-Alerta ("El SSD '{0}' tiene {1} % de desgaste: está al final de su vida útil." -f $d.FriendlyName, $rc.Wear) 'RESPALDAR y planificar el reemplazo del disco.' -Critica
                }
                elseif ($rc.Wear -ge 75) {
                    Rep-Alerta ("El SSD '{0}' tiene {1} % de desgaste." -f $d.FriendlyName, $rc.Wear) 'Planificar el reemplazo del disco y mantener respaldos al día.'
                }
                if ($rc.ReadErrorsUncorrected -gt 0) {
                    Rep-Alerta ("El disco '{0}' tiene {1} errores de lectura sin corregir." -f $d.FriendlyName, $rc.ReadErrorsUncorrected) 'RESPALDAR LA INFORMACIÓN YA y reemplazar el disco.' -Critica
                }
                if ($rc.Temperature -ge 60) {
                    Rep-Alerta ("El disco '{0}' está a {1} °C (alto)." -f $d.FriendlyName, $rc.Temperature) 'Revisar la ventilación y limpiar el polvo del equipo.'
                }
            }
        }
        catch { }
        if ($hayHDD) {
            Rep-Linea 'El equipo usa disco mecánico (HDD).'
            if (-not $Script:Sugerencias.Contains('Cambiar el disco mecánico (HDD) por un SSD mejora mucho la velocidad del equipo.')) {
                $Script:Sugerencias.Add('Cambiar el disco mecánico (HDD) por un SSD mejora mucho la velocidad del equipo.')
            }
        }
    }

    # ---------- Eventos de los últimos 7 días ----------
    Rep-Seccion 'Eventos críticos (últimos 7 días)' {
        $bsod = @(Get-EventosSeguro -Log 'System' -Proveedores @('Microsoft-Windows-WER-SystemErrorReporting') -Ids @(1001) -Desde $desde)
        Rep-Linea ("Pantallazos azules (BSOD)       : {0}" -f $bsod.Count)
        if ($bsod.Count -gt 0) {
            foreach ($e in ($bsod | Select-Object -First 3)) {
                $textoBsod = "$($e.Message) " + ((@($e.Properties) | ForEach-Object { "$($_.Value)" }) -join ' ')
                Rep-Linea ("   - {0}  {1}" -f $e.TimeCreated.ToString('dd/MM/yyyy HH:mm'), (Get-DescripcionBugCheck $textoBsod))
            }
            $dumps = @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'Minidump') -Filter '*.dmp' -ErrorAction SilentlyContinue)
            if ($dumps.Count -gt 0) { Rep-Linea ("   Archivos de volcado en C:\Windows\Minidump: {0}" -f $dumps.Count) }
            Rep-Alerta ("Se registraron {0} pantallazo(s) azul(es)." -f $bsod.Count) 'Pantallazos azules: actualizar drivers (video, chipset, red), opción 2 (DISM + SFC) y diagnóstico de memoria (opción 13).' -Accion '2'
        }

        $kp = @(Get-EventosSeguro -Log 'System' -Proveedores @('Microsoft-Windows-Kernel-Power') -Ids @(41) -Desde $desde)
        Rep-Linea ("Apagados inesperados (Id 41)    : {0}" -f $kp.Count)
        if ($kp.Count -gt 0) {
            Rep-Alerta ("Se registraron {0} apagado(s) inesperado(s)." -f $kp.Count) 'Apagados inesperados: revisar fuente de poder, batería, temperatura (ventiladores/polvo) y cortes de luz.'
        }

        $discoEv = @(Get-EventosSeguro -Log 'System' -Proveedores @('disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci') -Niveles @(1, 2, 3) -Desde $desde)
        Rep-Linea ("Errores/advertencias de disco   : {0}" -f $discoEv.Count)
        if ($discoEv.Count -gt 0) {
            $grupos = $discoEv | Group-Object -Property { '{0} (Id {1})' -f $_.ProviderName, $_.Id } | Sort-Object -Property Count -Descending | Select-Object -First 5
            foreach ($g in $grupos) { Rep-Linea ("   - {0}: {1}" -f $g.Name, $g.Count) }
            Rep-Alerta ("Se registraron {0} evento(s) de error de disco." -f $discoEv.Count) 'Errores de disco: RESPALDAR la información y usar la opción 7 (Revisar disco).' -Accion '7'
        }

        $whea = @(Get-EventosSeguro -Log 'System' -Proveedores @('Microsoft-Windows-WHEA-Logger') -Niveles @(1, 2, 3) -Desde $desde)
        Rep-Linea ("Errores de hardware (WHEA)      : {0}" -f $whea.Count)
        if ($whea.Count -gt 0) {
            Rep-Alerta ("Se registraron {0} error(es) de hardware (WHEA)." -f $whea.Count) 'Errores WHEA: posible falla de CPU, RAM o placa base; revisar temperatura, BIOS y hacer diagnóstico de memoria.' -Critica
        }

        Rep-Linea ''
        Rep-Linea 'Top errores del registro Sistema:'
        $errores = @(Get-EventosSeguro -Log 'System' -Niveles @(1, 2) -Desde $desde)
        if ($errores.Count -eq 0) {
            Rep-Linea '   (sin errores)'
        }
        else {
            $top = $errores | Group-Object -Property ProviderName | Sort-Object -Property Count -Descending | Select-Object -First 8
            foreach ($g in $top) { Rep-Linea ("   {0,-55} {1,5}" -f $g.Name, $g.Count) }
        }
    }

    # ---------- Aplicaciones que se cierran ----------
    Rep-Seccion 'Aplicaciones que se cierran solas (últimos 7 días)' {
        $apps = @(Get-EventosSeguro -Log 'Application' -Proveedores @('Application Error') -Ids @(1000) -Desde $desde)
        if ($apps.Count -eq 0) {
            Rep-Linea 'Ninguna.'
        }
        else {
            $grupos = $apps | Group-Object -Property { "$($_.Properties[0].Value)" } | Sort-Object -Property Count -Descending | Select-Object -First 8
            foreach ($g in $grupos) { Rep-Linea ("{0,-45} {1,4} vez/veces" -f $g.Name, $g.Count) }
            Rep-Alerta ("Hay {0} cierre(s) inesperado(s) de aplicaciones." -f $apps.Count) 'Reinstalar o actualizar las aplicaciones que se cierran solas.'
        }
    }

    # ---------- Drivers ----------
    Rep-Seccion 'Dispositivos y drivers' { Rep-Estado (Get-EstadoDrivers) }

    # ---------- Sonido ----------
    Rep-Seccion 'Sonido' {
        $audio = Get-EstadoAudio
        foreach ($l in $audio.Lineas) { Rep-Linea $l }
        foreach ($p in $audio.Problemas) {
            $acc = ''
            if ($p.Auto) { $acc = '15' }
            Rep-Alerta $p.Texto $p.Sugerencia -Critica:$p.Critica -Accion $acc
        }
        if ($audio.Problemas.Count -eq 0) { Rep-Linea 'Configuración de audio correcta.' }
    }

    # ---------- Outlook / Office ----------
    Rep-Seccion 'Outlook / Office' {
        $outlook = Get-EstadoOutlook
        foreach ($l in $outlook.Lineas) { Rep-Linea $l }
        foreach ($p in $outlook.Problemas) {
            $acc = ''
            if ($p.Auto) { $acc = '16' }
            Rep-Alerta $p.Texto $p.Sugerencia -Critica:$p.Critica -Accion $acc
        }
    }

    # ---------- Micrófono, cámara, impresoras y video ----------
    Rep-Seccion 'Micrófono y cámara' { Rep-Estado (Get-EstadoPrivacidad) 'PRIV' }
    Rep-Seccion 'Impresoras' { Rep-Estado (Get-EstadoImpresoras) '6' }
    Rep-Seccion 'Video y drivers' { Rep-Estado (Get-EstadoVideoDrivers) }

    # ---------- Red ----------
    Rep-Seccion 'Red e internet' {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter -and "$($_.NetAdapter.Status)" -eq 'Up' })
        if ($configs.Count -eq 0) {
            Rep-Alerta 'No hay ningún adaptador de red conectado.' 'Red: revisar cable / WiFi encendido / driver del adaptador; luego opción 3 (Reparar red).'
            return
        }
        $gateway = $null
        foreach ($c in $configs) {
            $ips  = @($c.IPv4Address.IPAddress | Where-Object { $_ })
            $gws  = @($c.IPv4DefaultGateway.NextHop | Where-Object { $_ })
            $dnss = @($c.DNSServer | Where-Object { $_ -and $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
            Rep-Linea ("{0} ({1})" -f $c.InterfaceAlias, $c.NetAdapter.InterfaceDescription)
            Rep-Linea ("   IP: {0} | Puerta de enlace: {1} | DNS: {2}" -f ($ips -join ', '), ($gws -join ', '), ($dnss -join ', '))
            if (@($ips | Where-Object { $_ -like '169.254.*' }).Count -gt 0) {
                Rep-Alerta ("El adaptador '{0}' tiene IP 169.254.x.x: no recibió dirección del router (DHCP)." -f $c.InterfaceAlias) 'Sin DHCP: revisar router/cable/WiFi y usar la opción 3 (Reparar red).' -Accion '3'
            }
            if (-not $gateway -and $gws.Count -gt 0) { $gateway = $gws[0] }
        }

        $okGw = $false
        if ($gateway) { $okGw = [bool](Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue) }
        $okNet = [bool](Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet -ErrorAction SilentlyContinue)
        $okDns = $false
        try {
            $null = Resolve-DnsName -Name 'www.microsoft.com' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
            $okDns = $true
        }
        catch { $okDns = $false }

        Rep-Linea ("Ping puerta de enlace: {0} | Ping internet (8.8.8.8): {1} | DNS: {2}" -f $(if ($gateway) { SiNo $okGw } else { 'N/A' }), (SiNo $okNet), (SiNo $okDns))

        if (-not $gateway) {
            Rep-Alerta 'No hay puerta de enlace: problema local (cable, WiFi, adaptador o el router no entrega IP).' 'Red: revisar cable/WiFi y router; luego opción 3 (Reparar red).'
        }
        elseif (-not $okNet -and -not $okDns) {
            if ($okGw) {
                Rep-Alerta 'El router responde pero NO hay internet: problema del proveedor o del router.' 'Reiniciar el router/módem; si persiste, llamar al proveedor de internet.'
            }
            else {
                Rep-Alerta 'El router (puerta de enlace) no responde: problema local de cable, WiFi o router.' 'Revisar cable/WiFi, reiniciar el router y usar la opción 3 (Reparar red).'
            }
        }
        elseif (-not $okDns) {
            Rep-Alerta 'Hay internet pero no se resuelven nombres (falla de DNS).' 'Opción 3 (Reparar red) para limpiar la caché DNS y restablecer la configuración.' -Accion '3'
        }
        elseif (-not $okNet) {
            Rep-Linea 'El ping a 8.8.8.8 falla pero el DNS funciona: probablemente un firewall bloquea el ping. Internet OK.'
        }
        else {
            Rep-Linea 'Conectividad a internet: OK.'
        }
    }

    # ---------- WiFi, proxy y VPN ----------
    Rep-Seccion 'WiFi, proxy y VPN' { Rep-Estado (Get-EstadoConexion) }

    # ---------- Antivirus ----------
    Rep-Seccion 'Antivirus' {
        $otroActivo = $false
        try {
            $avs = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
            foreach ($av in $avs) {
                $hex = '{0:X6}' -f [int]$av.productState
                $activo = @('10', '11') -contains $hex.Substring(2, 2)
                $alDia = $hex.Substring(4, 2) -eq '00'
                $txtActivo = 'inactivo'; if ($activo) { $txtActivo = 'activo' }
                $txtFirmas = 'desactualizadas'; if ($alDia) { $txtFirmas = 'al día' }
                Rep-Linea ("{0}: {1}, firmas {2}" -f $av.displayName, $txtActivo, $txtFirmas)
                if ($av.displayName -notmatch 'Defender') {
                    if ($activo) { $otroActivo = $true }
                    if ($activo -and -not $alDia) {
                        Rep-Alerta ("Las firmas de '{0}' están desactualizadas." -f $av.displayName) 'Actualizar el antivirus instalado.'
                    }
                }
            }
        }
        catch {
            Rep-Linea 'No se pudo consultar el Centro de seguridad de Windows.'
        }

        $defensorActivo = $false
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $defensorActivo = [bool]($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled)
            Rep-Linea ("Microsoft Defender: antivirus {0}, tiempo real {1}, firmas de hace {2} día(s)" -f $mp.AntivirusEnabled, $mp.RealTimeProtectionEnabled, $mp.AntivirusSignatureAge)
            if ($defensorActivo -and $mp.AntivirusSignatureAge -gt 7) {
                Rep-Alerta ("Las firmas de Microsoft Defender tienen {0} días." -f $mp.AntivirusSignatureAge) 'Actualizar Microsoft Defender (Seguridad de Windows > Buscar actualizaciones) o usar la opción 5 si Windows Update falla.' -Accion 'AV'
            }
        }
        catch {
            Rep-Linea 'Microsoft Defender no está disponible (normal si hay otro antivirus instalado).'
        }

        if (-not $defensorActivo -and -not $otroActivo) {
            Rep-Alerta 'No hay ningún antivirus activo.' 'Activar Microsoft Defender (Seguridad de Windows) o el antivirus instalado.' -Critica
        }
    }

    # ---------- Seguridad, licencia, actualizaciones, arranque y perfil ----------
    Rep-Seccion 'Seguridad del sistema' { Rep-Estado (Get-EstadoSeguridad) }
    Rep-Seccion 'Licencia y BitLocker' { Rep-Estado (Get-EstadoLicencia) }
    Rep-Seccion 'Actualizaciones de Windows' { Rep-Estado (Get-EstadoActualizaciones) }
    Rep-Seccion 'Arranque' { Rep-Estado (Get-EstadoArranque) }
    Rep-Seccion 'Perfil de usuario' { Rep-Estado (Get-EstadoPerfil) }

    # ---------- Reinicio pendiente ----------
    Rep-Seccion 'Reinicio pendiente' {
        $claves = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        )
        $pendiente = $false
        foreach ($k in $claves) { if (Test-Path -LiteralPath $k) { $pendiente = $true } }
        if ($pendiente) {
            Rep-Alerta 'Windows tiene un reinicio pendiente (actualizaciones o componentes).' 'Reiniciar el equipo para terminar de instalar las actualizaciones.'
        }
        else {
            Rep-Linea 'No hay reinicios pendientes.'
        }
    }

    # ---------- Servicios clave ----------
    Rep-Seccion 'Servicios clave' {
        $mapa = [ordered]@{
            'Spooler'  = 'Servicio de impresión detenido: opción 6 (Reparar impresora).'
            'Dhcp'     = 'Servicio DHCP detenido: iniciarlo o usar la opción 3 (Reparar red).'
            'Dnscache' = 'Servicio DNS detenido: iniciarlo o usar la opción 3 (Reparar red).'
            'Audiosrv' = 'Servicio de audio detenido: opción 15 (Reparar sonido).'
            'EventLog' = 'Registro de eventos detenido: iniciarlo y usar la opción 2 (DISM + SFC).'
            'Winmgmt'  = 'Servicio WMI detenido: iniciarlo y usar la opción 2 (DISM + SFC).'
        }
        foreach ($nombre in $mapa.Keys) {
            $s = Get-Service -Name $nombre -ErrorAction SilentlyContinue
            if (-not $s) { continue }
            Rep-Linea ("{0,-10} {1,-35} {2,-8} ({3})" -f $s.Name, $s.DisplayName, $s.Status, $s.StartType)
            if ("$($s.StartType)" -eq 'Automatic' -and "$($s.Status)" -ne 'Running') {
                $accionServicio = 'SRV'
                if ($nombre -eq 'Audiosrv') { $accionServicio = '15' }
                Rep-Alerta ("El servicio '{0}' ({1}) está detenido y debería estar en ejecución." -f $s.DisplayName, $s.Name) $mapa[$nombre] -Accion $accionServicio
                $Script:ServiciosDetenidos.Add($s.Name)
            }
        }
    }

    # ---------- Batería ----------
    Rep-Seccion 'Batería' {
        $baterias = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
        if ($baterias.Count -eq 0) {
            Rep-Linea 'Sin batería (equipo de escritorio).'
            return
        }
        foreach ($b in $baterias) {
            Rep-Linea ("{0}: carga {1} %" -f $b.Name, $b.EstimatedChargeRemaining)
        }
        try {
            $completa = (@(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop) | Measure-Object -Property FullChargedCapacity -Sum).Sum
            $diseno   = (@(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop) | Measure-Object -Property DesignedCapacity -Sum).Sum
            if ($diseno -gt 0) {
                $salud = [math]::Round(($completa / $diseno) * 100, 0)
                Rep-Linea ("Capacidad de diseño: {0} mWh | Capacidad actual: {1} mWh | Salud: {2} %" -f $diseno, $completa, $salud)
                if ($salud -lt 60) {
                    Rep-Alerta ("La batería está desgastada (salud {0} %)." -f $salud) 'Cambiar la batería; ver detalle con la opción 12 (Reporte de batería).'
                }
            }
        }
        catch {
            Rep-Linea 'No se pudo leer la capacidad de la batería (usar la opción 12).'
        }
    }

    # ---------- Temporales ----------
    Rep-Seccion 'Archivos temporales' {
        $tamUsuario = Get-TamanoCarpeta $env:TEMP
        $tamWindows = Get-TamanoCarpeta (Join-Path $env:windir 'Temp')
        $totalGB = [math]::Round(($tamUsuario + $tamWindows) / 1GB, 2)
        Rep-Linea ("%TEMP%: {0} MB | Windows\Temp: {1} MB | Total: {2} GB" -f [math]::Round($tamUsuario / 1MB, 0), [math]::Round($tamWindows / 1MB, 0), $totalGB)
        if ($totalGB -gt 2) {
            Rep-Alerta ("Hay {0} GB de archivos temporales." -f $totalGB) 'Opción 4 (Limpiar archivos temporales).' -Accion '4'
        }
    }

    # ---------- Inicio ----------
    Rep-Seccion 'Programas de inicio' {
        $inicio = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
        Rep-Linea ("Cantidad de programas al inicio: {0}" -f $inicio.Count)
        foreach ($i in ($inicio | Select-Object -First 25)) { Rep-Linea ("   - {0}" -f $i.Name) }
        if ($inicio.Count -gt 12) {
            Rep-Alerta ("Hay demasiados programas al inicio ({0})." -f $inicio.Count) 'Desactivar programas innecesarios en Administrador de tareas > Inicio.'
        }
    }

    # ---------- Guardar reporte ----------
    $fecha = Get-Date
    $archivo = Join-Path $Script:DirReportes ('Diagnostico_{0}_{1}.txt' -f $env:COMPUTERNAME, $fecha.ToString('yyyyMMdd_HHmmss'))
    $salida = New-Object System.Collections.Generic.List[string]
    $salida.Add('=====================================================================')
    $salida.Add(" REPORTE DE DIAGNÓSTICO - Soporte Técnico v$($Script:Version)")
    $salida.Add((" Equipo: {0}    Fecha: {1}" -f $env:COMPUTERNAME, $fecha.ToString('dd/MM/yyyy HH:mm')))
    $salida.Add('=====================================================================')
    $salida.Add('')
    $salida.Add(("RESUMEN: {0} alerta(s)" -f $Script:Alertas.Count))
    if ($Script:Alertas.Count -eq 0) {
        $salida.Add('  No se detectaron problemas.')
    }
    else {
        foreach ($a in $Script:Alertas) { $salida.Add("  $a") }
    }
    $salida.Add('')
    $salida.Add('SUGERENCIAS:')
    if ($Script:Sugerencias.Count -eq 0) {
        $salida.Add('  Ninguna.')
    }
    else {
        $n = 1
        foreach ($s in $Script:Sugerencias) { $salida.Add(("  {0}. {1}" -f $n, $s)); $n++ }
    }
    $salida.Add('')
    $salida.Add('---------------------------------------------------------------------')
    $salida.Add('DETALLE')
    $salida.Add('---------------------------------------------------------------------')
    foreach ($l in $Script:Rep) { $salida.Add($l) }

    # Resumen en pantalla
    Mostrar-Titulo ("RESUMEN: {0} alerta(s)" -f $Script:Alertas.Count)
    if ($Script:Alertas.Count -eq 0) {
        Write-Host '    No se detectaron problemas.' -ForegroundColor Green
    }
    else {
        foreach ($a in $Script:Alertas) {
            $color = 'Yellow'; if ($a.StartsWith('[CRÍTICO]')) { $color = 'Red' } elseif ($a.StartsWith('[INFO]')) { $color = 'Cyan' }
            Write-Host "    $a" -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '    SUGERENCIAS:' -ForegroundColor Cyan
        $n = 1
        foreach ($s in $Script:Sugerencias) { Write-Host ("    {0}. {1}" -f $n, $s) -ForegroundColor White; $n++ }
    }
    Write-Host ''

    try {
        [System.IO.File]::WriteAllLines($archivo, $salida.ToArray(), (New-Object System.Text.UTF8Encoding($true)))
        Write-Log "Reporte guardado en: $archivo" 'OK'
    }
    catch {
        Write-Log "No se pudo guardar el reporte: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    Registrar-PuntajeVisita
    $archivoHtml = [System.IO.Path]::ChangeExtension($archivo, '.html')
    try {
        New-ReporteHtml -Ruta $archivoHtml -Fecha $fecha
        Write-Log "Reporte visual guardado en: $archivoHtml" 'OK'
    }
    catch {
        Write-Log "No se pudo generar el reporte HTML: $($_.Exception.Message)" 'ERROR'
        $archivoHtml = $null
    }
    $Script:UltimoHtml = $archivoHtml
    if ($SinPreguntas) { return $true }

    if ($archivoHtml -and (Confirmar '¿Abrir el reporte visual (HTML) en el navegador?')) {
        Abrir-ParaUsuario $archivoHtml
    }
    elseif (Confirmar '¿Abrir el reporte de texto en el Bloc de notas?') {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$archivo`"" } catch { Write-Log "No se pudo abrir el Bloc de notas: $($_.Exception.Message)" 'ERROR' }
    }

    if ($Script:ServiciosDetenidos.Count -gt 0) {
        if (Confirmar ("¿Iniciar ahora los servicios detenidos ({0})?" -f ($Script:ServiciosDetenidos -join ', '))) {
            foreach ($srv in $Script:ServiciosDetenidos) { $null = Iniciar-Servicio $srv }
        }
    }

    Invoke-ReparacionAutomatica
    return $true
}

#endregion

#region ==================== 2. ARCHIVOS DE WINDOWS (DISM + SFC) ====================

function Reparar-ArchivosSistema {
    Mostrar-Titulo 'REPARAR ARCHIVOS DE WINDOWS (DISM + SFC)'
    Write-Log 'DISM necesita conexión a internet y puede tardar entre 10 y 30 minutos. No cierre esta ventana.' 'ADVERTENCIA'
    $dism = Invoke-Nativo -Archivo (Get-RutaSistema 'dism.exe') -Argumentos '/Online /Cleanup-Image /RestoreHealth' -Descripcion 'DISM RestoreHealth'
    Write-Log 'Ejecutando SFC. Puede tardar entre 5 y 15 minutos.' 'INFO'
    $sfc = Invoke-Nativo -Archivo (Get-RutaSistema 'sfc.exe') -Argumentos '/scannow' -Descripcion 'SFC /scannow'
    Write-Log 'Detalle de SFC en C:\Windows\Logs\CBS\CBS.log y de DISM en C:\Windows\Logs\DISM\dism.log' 'INFO'
    $Script:RequiereReinicio = $true
    return (($dism -eq 0) -and ($sfc -eq 0))
}

#endregion

#region ==================== 3. RED ====================

function Reparar-Red {
    param([switch]$Suave)
    if ($Suave) {
        Mostrar-Titulo 'REPARAR RED (MODO SUAVE)'
        Write-Log 'Modo suave: flushdns + winsock reset + ip reset (sin release/renew).' 'INFO'
    }
    else {
        Mostrar-Titulo 'REPARAR RED / INTERNET'
        Mostrar-AvisoSesionRemota
        if (-not (Confirmar '¿Continuar con la reparación de red?')) {
            Write-Log 'Reparación de red cancelada por el usuario.' 'INFO'
            return $false
        }
    }

    $ipconfig = Get-RutaSistema 'ipconfig.exe'
    $netsh    = Get-RutaSistema 'netsh.exe'
    $null = Invoke-Nativo -Archivo $ipconfig -Argumentos '/flushdns' -Descripcion 'Limpiar caché DNS'
    if (-not $Suave) {
        $null = Invoke-Nativo -Archivo $ipconfig -Argumentos '/release' -Descripcion 'Liberar IP'
        $null = Invoke-Nativo -Archivo $ipconfig -Argumentos '/renew' -Descripcion 'Renovar IP'
    }
    $winsock = Invoke-Nativo -Archivo $netsh -Argumentos 'winsock reset' -Descripcion 'Restablecer Winsock'
    $ipreset = Invoke-Nativo -Archivo $netsh -Argumentos 'int ip reset' -Descripcion 'Restablecer TCP/IP'
    if ($ipreset -ne 0) {
        Write-Log 'Es normal que "int ip reset" reporte "Acceso denegado" en alguna clave; el resto se aplica igual.' 'INFO'
    }

    if (-not $Suave) {
        if (Confirmar '¿Reiniciar también los adaptadores de red activos?') {
            try {
                $adaptadores = @(Get-NetAdapter -ErrorAction Stop | Where-Object { "$($_.Status)" -eq 'Up' })
                foreach ($a in $adaptadores) {
                    Write-Log "Reiniciando adaptador: $($a.Name)" 'INFO'
                    Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop
                    Write-Log "Adaptador $($a.Name) reiniciado." 'OK'
                }
            }
            catch {
                Write-Log "No se pudo reiniciar un adaptador: $($_.Exception.Message)" 'ADVERTENCIA'
            }
        }
    }

    Write-Log 'Winsock y TCP/IP requieren reiniciar el equipo para aplicarse.' 'ADVERTENCIA'
    $Script:RequiereReinicio = $true
    return ($winsock -eq 0)
}

#endregion

#region ==================== 4. LIMPIEZA ====================

function Limpiar-Carpeta {
    # Borra el contenido de una carpeta ignorando los archivos en uso.
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return }
    $elementos = Get-ChildItem -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue
    foreach ($e in $elementos) {
        try {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                # Enlace/junction: se borra solo el enlace, nunca el destino
                if ($e.PSIsContainer) { [System.IO.Directory]::Delete($e.FullName) } else { [System.IO.File]::Delete($e.FullName) }
            }
            else {
                Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }
}

function Limpiar-Temporales {
    param([switch]$SinPapelera)
    Mostrar-Titulo 'LIMPIAR ARCHIVOS TEMPORALES'
    $antes = Get-EspacioLibre

    $rutas = New-Object System.Collections.Generic.List[string]
    $rutas.Add($env:TEMP)
    $rutas.Add((Join-Path $env:windir 'Temp'))
    $perfiles = Join-Path $env:SystemDrive 'Users'
    foreach ($u in @(Get-ChildItem -LiteralPath $perfiles -Directory -Force -ErrorAction SilentlyContinue)) {
        $rutas.Add((Join-Path $u.FullName 'AppData\Local\Temp'))
        $rutas.Add((Join-Path $u.FullName 'AppData\Local\Microsoft\Windows\INetCache'))
    }
    $rutasUnicas = $rutas | Where-Object { $_ } | Select-Object -Unique
    foreach ($r in $rutasUnicas) {
        if (Test-Path -LiteralPath $r) {
            Write-Log "Limpiando: $r" 'INFO'
            Limpiar-Carpeta $r
        }
    }

    Write-Log 'Limpiando caché de descargas de Windows Update...' 'INFO'
    $wu = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    $wuCorria = $wu -and ("$($wu.Status)" -eq 'Running')
    $null = Detener-Servicio 'wuauserv'
    Limpiar-Carpeta (Join-Path $env:windir 'SoftwareDistribution\Download')
    if ($wuCorria) { $null = Iniciar-Servicio 'wuauserv' }

    if (-not $SinPapelera) {
        if (Confirmar '¿Vaciar también la papelera de reciclaje?') {
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-Log 'Papelera vaciada.' 'OK'
            }
            catch {
                Write-Log 'La papelera ya estaba vacía o no se pudo vaciar.' 'INFO'
            }
        }
    }

    $despues = Get-EspacioLibre
    $liberadoGB = [math]::Round(($despues - $antes) / 1GB, 2)
    if ($liberadoGB -lt 0) { $liberadoGB = 0 }
    Write-Log ("Limpieza terminada. Espacio liberado: {0} GB (libre ahora: {1} GB)." -f $liberadoGB, [math]::Round($despues / 1GB, 1)) 'OK'
    return $true
}

#endregion

#region ==================== 5. WINDOWS UPDATE ====================

function Renombrar-ComoOld {
    param([string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) {
        Write-Log "No existe $Ruta (se creará de nuevo automáticamente)." 'INFO'
        return $true
    }
    $old = "$Ruta.old"
    if (Test-Path -LiteralPath $old) {
        Write-Log "Borrando copia anterior: $old" 'INFO'
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
    }
    $nuevoNombre = Split-Path $old -Leaf
    if (Test-Path -LiteralPath $old) {
        # No se pudo borrar por completo el .old anterior: usar un nombre con fecha
        $nuevoNombre = '{0}.old_{1}' -f (Split-Path $Ruta -Leaf), (Get-Date -Format 'yyyyMMddHHmmss')
    }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Rename-Item -LiteralPath $Ruta -NewName $nuevoNombre -ErrorAction Stop
            Write-Log "Renombrado: $Ruta -> $nuevoNombre" 'OK'
            return $true
        }
        catch {
            if ($i -lt 3) {
                Start-Sleep -Seconds 3
                foreach ($s in @('wuauserv', 'bits', 'cryptsvc', 'msiserver')) { $null = Detener-Servicio $s }
            }
            else {
                Write-Log "No se pudo renombrar ${Ruta}: $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    return $false
}

function Reparar-WindowsUpdate {
    param([switch]$SinConfirmar)
    Mostrar-Titulo 'REPARAR WINDOWS UPDATE'
    if (-not $SinConfirmar) {
        Write-Host '    Se detendrán los servicios de Windows Update y se renombrarán SoftwareDistribution y catroot2.' -ForegroundColor Yellow
        Write-Host '    Se pierde el historial de actualizaciones y las descargas pendientes (Windows las vuelve a bajar).' -ForegroundColor Yellow
        Write-Host ''
        if (-not (Confirmar '¿Continuar?')) {
            Write-Log 'Reparación de Windows Update cancelada por el usuario.' 'INFO'
            return $false
        }
    }
    $servicios = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    foreach ($s in $servicios) { $null = Detener-Servicio $s }

    $ok1 = Renombrar-ComoOld (Join-Path $env:windir 'SoftwareDistribution')
    $ok2 = Renombrar-ComoOld (Join-Path $env:windir 'System32\catroot2')

    foreach ($s in @('cryptsvc', 'bits', 'wuauserv', 'msiserver')) { $null = Iniciar-Servicio $s -HabilitarSiDeshabilitado }

    if ($ok1 -and $ok2) {
        Write-Log 'Windows Update restablecido. Busque actualizaciones nuevamente en Configuración.' 'OK'
        return $true
    }
    Write-Log 'Windows Update se restableció de forma parcial. Reinicie el equipo y vuelva a intentar.' 'ADVERTENCIA'
    return $false
}

#endregion

#region ==================== 6. IMPRESORA ====================

function Reparar-Impresora {
    param([switch]$SinConfirmar)
    Mostrar-Titulo 'REPARAR IMPRESORA (COLA DE IMPRESIÓN)'
    if (-not $SinConfirmar) {
        Write-Host '    Se borrarán TODOS los trabajos pendientes en la cola de impresión.' -ForegroundColor Yellow
        Write-Host ''
        if (-not (Confirmar '¿Continuar?')) {
            Write-Log 'Reparación de impresora cancelada por el usuario.' 'INFO'
            return $false
        }
    }
    $null = Detener-Servicio 'Spooler'
    $cola = Join-Path $env:windir 'System32\spool\PRINTERS'
    $trabajos = @(Get-ChildItem -LiteralPath $cola -Force -ErrorAction SilentlyContinue)
    Write-Log ("Borrando {0} archivo(s) de la cola de impresión." -f $trabajos.Count) 'INFO'
    foreach ($t in $trabajos) { Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $ok = Iniciar-Servicio 'Spooler'
    try {
        foreach ($imp in @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Where-Object { $_.WorkOffline })) {
            Set-CimInstance -InputObject $imp -Property @{ WorkOffline = $false } -ErrorAction Stop
            Write-Log "Impresora '$($imp.Name)' puesta en línea." 'OK'
        }
    }
    catch {
        Write-Log "No se pudo poner en línea una impresora: $($_.Exception.Message)" 'ADVERTENCIA'
    }

    try {
        $impresoras = @(Get-Printer -ErrorAction Stop)
        Write-Host ''
        Write-Host '    Impresoras instaladas:' -ForegroundColor Cyan
        foreach ($p in $impresoras) {
            $linea = "{0} | Driver: {1} | Puerto: {2} | Estado: {3}" -f $p.Name, $p.DriverName, $p.PortName, $p.PrinterStatus
            Write-Host "    - $linea"
            Write-Log "Impresora: $linea" 'INFO' -SoloArchivo
        }
    }
    catch {
        Write-Log "No se pudo listar las impresoras: $($_.Exception.Message)" 'ADVERTENCIA'
    }
    return $ok
}

#endregion

#region ==================== 7. DISCO ====================

function Revisar-Disco {
    param([switch]$Automatico)
    Mostrar-Titulo 'REVISAR DISCO (CHKDSK)'
    $predeterminada = $env:SystemDrive.TrimEnd(':')
    $letra = ''
    if (-not $Automatico) { $letra = Read-Host ("  Letra de la unidad a revisar [{0}]" -f $predeterminada) }
    if (-not $letra) { $letra = $predeterminada }
    $letra = $letra.Trim().TrimEnd(':', '\').ToUpper()
    if ($letra -notmatch '^[A-Z]$') {
        Write-Log "Letra de unidad no válida: $letra" 'ERROR'
        return $false
    }

    Write-Log "Escaneando la unidad ${letra}: en línea (puede tardar varios minutos)..." 'INFO'
    try {
        $resultado = "$(Repair-Volume -DriveLetter $letra -Scan -ErrorAction Stop)"
    }
    catch {
        Write-Log "No se pudo escanear la unidad ${letra}: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    if ($resultado -eq 'NoErrorsFound') {
        Write-Log "No se encontraron errores en la unidad ${letra}:." 'OK'
        return $true
    }

    Write-Log "Resultado del escaneo de ${letra}: $resultado" 'ADVERTENCIA'
    if (Confirmar "¿Programar CHKDSK en ${letra}: para el próximo reinicio?") {
        $codigo = Invoke-Nativo -Archivo (Get-RutaSistema 'fsutil.exe') -Argumentos "dirty set ${letra}:" -Descripcion 'Marcar unidad para CHKDSK'
        if ($codigo -eq 0) {
            Write-Log "CHKDSK se ejecutará en ${letra}: al reiniciar (puede tardar bastante)." 'OK'
            $Script:RequiereReinicio = $true
            return $true
        }
        return $false
    }
    return $false
}

#endregion

#region ==================== 8. EXPLORADOR ====================

function Reiniciar-Explorador {
    Mostrar-Titulo 'REINICIAR EXPLORADOR DE WINDOWS'
    Write-Host '    Se cerrarán todas las ventanas de carpetas abiertas y se interrumpirán las copias de archivos en curso.' -ForegroundColor Yellow
    Write-Host '    Si está conectado por AnyDesk/TeamViewer, el escritorio se verá en negro unos segundos.' -ForegroundColor Yellow
    Write-Host ''
    if (-not (Confirmar '¿Reiniciar el Explorador?')) {
        Write-Log 'Reinicio del Explorador cancelado por el usuario.' 'INFO'
        return $false
    }
    $null = Get-PerfilUsuarioActivo
    try {
        Stop-Process -Name 'explorer' -Force -ErrorAction Stop
        Write-Log 'Explorador detenido.' 'INFO'
    }
    catch {
        Write-Log 'El Explorador no estaba en ejecución.' 'INFO'
    }
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) {
        try {
            Iniciar-ExploradorUsuario
            Write-Log 'Explorador iniciado manualmente.' 'OK'
        }
        catch {
            Write-Log "No se pudo iniciar el Explorador: $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }
    else {
        Write-Log 'El Explorador se reinició automáticamente.' 'OK'
    }
    return $true
}

#endregion

#region ==================== 9. MICROSOFT STORE ====================

function Reparar-Store {
    Mostrar-Titulo 'REPARAR MICROSOFT STORE Y APPS'
    Write-Log 'Limpiando caché de la Store (wsreset). Se abrirá la Store al terminar.' 'INFO'
    $null = Invoke-Nativo -Archivo (Get-RutaSistema 'wsreset.exe') -Descripcion 'WSReset'

    Write-Log 'Volviendo a registrar Microsoft Store...' 'INFO'
    try {
        $paquetes = @(Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsStore' -ErrorAction Stop)
        if ($paquetes.Count -eq 0) {
            Write-Log 'Microsoft Store no está instalada en este equipo.' 'ADVERTENCIA'
            return $false
        }
        foreach ($p in $paquetes) {
            $manifiesto = Join-Path $p.InstallLocation 'AppXManifest.xml'
            Add-AppxPackage -DisableDevelopmentMode -Register $manifiesto -ErrorAction Stop
        }
        Write-Log 'Microsoft Store registrada de nuevo.' 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo volver a registrar la Store: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

#endregion

#region ==================== 10. FECHA Y HORA ====================

function Sincronizar-Hora {
    Mostrar-Titulo 'SINCRONIZAR FECHA Y HORA'
    $w32tm = Get-RutaSistema 'w32tm.exe'
    $null = Iniciar-Servicio 'w32time' -HabilitarSiDeshabilitado
    $codigo = Invoke-Nativo -Archivo $w32tm -Argumentos '/resync /force' -Descripcion 'Sincronizar hora'
    if ($codigo -ne 0) {
        Write-Log 'Configurando time.windows.com como servidor de hora y reintentando...' 'INFO'
        $null = Invoke-Nativo -Archivo $w32tm -Argumentos '/config /manualpeerlist:"time.windows.com" /syncfromflags:manual /update' -Descripcion 'Configurar servidor de hora'
        try { Restart-Service -Name 'w32time' -Force -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 2
        $codigo = Invoke-Nativo -Archivo $w32tm -Argumentos '/resync /force' -Descripcion 'Sincronizar hora (reintento)'
    }
    Write-Log ("Fecha y hora actual: {0}" -f (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')) 'INFO'
    return ($codigo -eq 0)
}

#endregion

#region ==================== 11. PUNTO DE RESTAURACIÓN ====================

function New-PuntoRestauracion {
    Mostrar-Titulo 'CREAR PUNTO DE RESTAURACIÓN'
    $clave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $nombreValor = 'SystemRestorePointCreationFrequency'
    $anterior = Get-ItemProperty -Path $clave -Name $nombreValor -ErrorAction SilentlyContinue
    $existia = $null -ne $anterior
    $valorAnterior = $null
    if ($existia) { $valorAnterior = $anterior.$nombreValor }

    try {
        Enable-ComputerRestore -Drive ("{0}\" -f $env:SystemDrive) -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $clave)) { New-Item -Path $clave -Force | Out-Null }
        New-ItemProperty -Path $clave -Name $nombreValor -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Log 'Creando punto de restauración (puede tardar 1 o 2 minutos)...' 'INFO'
        Checkpoint-Computer -Description 'SoporteTecnico' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'Punto de restauración "SoporteTecnico" creado.' 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo crear el punto de restauración: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    finally {
        try {
            if ($existia) {
                Set-ItemProperty -Path $clave -Name $nombreValor -Value $valorAnterior -ErrorAction Stop
            }
            else {
                Remove-ItemProperty -Path $clave -Name $nombreValor -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }
}

#endregion

#region ==================== 12. BATERÍA ====================

function Get-ReporteBateria {
    Mostrar-Titulo 'REPORTE DE BATERÍA'
    $baterias = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($baterias.Count -eq 0) {
        Write-Log 'Este equipo no tiene batería (equipo de escritorio).' 'ADVERTENCIA'
        return $false
    }
    $archivo = Join-Path $Script:DirReportes ('bateria_{0}.html' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $codigo = Invoke-Nativo -Archivo (Get-RutaSistema 'powercfg.exe') -Argumentos ('/batteryreport /output "{0}"' -f $archivo) -Descripcion 'Reporte de batería'
    if ($codigo -eq 0 -and (Test-Path -LiteralPath $archivo)) {
        Write-Log "Reporte guardado en: $archivo" 'OK'
        Abrir-ParaUsuario $archivo
        return $true
    }
    return $false
}

#endregion

#region ==================== 13. HERRAMIENTAS DE WINDOWS ====================

function Mostrar-Herramientas {
    $volver = $false
    while (-not $volver) {
        Clear-Host
        Mostrar-Titulo 'HERRAMIENTAS DE WINDOWS'
        Write-Host '    1. Administrador de dispositivos'
        Write-Host '    2. Visor de eventos'
        Write-Host '    3. Monitor de confiabilidad'
        Write-Host '    4. Diagnóstico de memoria (reinicia el equipo)'
        Write-Host '    5. Administrador de tareas'
        Write-Host '    6. Programas y características'
        Write-Host '    7. Conexiones de red'
        Write-Host '    8. Abrir carpeta de reportes'
        Write-Host '    0. Volver al menú principal'
        Write-Host ''
        $op = Read-Host '  Elija una opción'
        if ($null -eq $op) { $op = '' }
        try {
            switch ($op.Trim()) {
                '1' { Start-Process -FilePath 'devmgmt.msc'; Write-Log 'Abierto: Administrador de dispositivos' 'INFO' -SoloArchivo }
                '2' { Start-Process -FilePath 'eventvwr.msc'; Write-Log 'Abierto: Visor de eventos' 'INFO' -SoloArchivo }
                '3' { Start-Process -FilePath (Get-RutaSistema 'perfmon.exe') -ArgumentList '/rel'; Write-Log 'Abierto: Monitor de confiabilidad' 'INFO' -SoloArchivo }
                '4' { Start-Process -FilePath (Get-RutaSistema 'mdsched.exe'); Write-Log 'Abierto: Diagnóstico de memoria' 'INFO' -SoloArchivo }
                '5' { Start-Process -FilePath (Get-RutaSistema 'taskmgr.exe'); Write-Log 'Abierto: Administrador de tareas' 'INFO' -SoloArchivo }
                '6' { Start-Process -FilePath (Get-RutaSistema 'control.exe') -ArgumentList 'appwiz.cpl'; Write-Log 'Abierto: Programas y características' 'INFO' -SoloArchivo }
                '7' { Start-Process -FilePath (Get-RutaSistema 'control.exe') -ArgumentList 'ncpa.cpl'; Write-Log 'Abierto: Conexiones de red' 'INFO' -SoloArchivo }
                '8' { Start-Process -FilePath (Join-Path $env:windir 'explorer.exe') -ArgumentList "`"$($Script:DirReportes)`""; Write-Log 'Abierta la carpeta de reportes' 'INFO' -SoloArchivo }
                '0' { $volver = $true }
                default { Write-Host '  Opción no válida.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
            }
        }
        catch {
            Write-Log "No se pudo abrir la herramienta: $($_.Exception.Message)" 'ERROR'
            Pausa
        }
    }
}

#endregion

#region ==================== 14. REPARACIÓN COMPLETA ====================

function Invoke-ReparacionCompleta {
    Mostrar-Titulo 'REPARACIÓN COMPLETA'
    Write-Host '    Se ejecutará, en este orden:' -ForegroundColor White
    Write-Host '      1) Crear punto de restauración'
    Write-Host '      2) Limpiar archivos temporales (sin vaciar la papelera)'
    Write-Host '      3) Reparar archivos de Windows (DISM + SFC)'
    Write-Host '      4) Reparar red en modo suave (sin cortar la conexión)'
    Write-Host '      5) Reparar Windows Update'
    Write-Host ''
    Write-Host '    Puede tardar entre 30 y 60 minutos. DISM necesita internet.' -ForegroundColor Yellow
    Write-Host ''
    if (-not (Confirmar '¿Iniciar la reparación completa?')) {
        Write-Log 'Reparación completa cancelada por el usuario.' 'INFO'
        return $false
    }
    Write-Log 'Inicio de la REPARACIÓN COMPLETA.' 'INFO'

    $pasos = @(
        @{ Nombre = 'Punto de restauración';            Accion = { New-PuntoRestauracion } },
        @{ Nombre = 'Limpieza de temporales';           Accion = { Limpiar-Temporales -SinPapelera } },
        @{ Nombre = 'Archivos de Windows (DISM + SFC)'; Accion = { Reparar-ArchivosSistema } },
        @{ Nombre = 'Red (modo suave)';                 Accion = { Reparar-Red -Suave } },
        @{ Nombre = 'Windows Update';                   Accion = { Reparar-WindowsUpdate -SinConfirmar } }
    )
    $resultados = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($paso in $pasos) {
        $i++
        Write-Log ("Paso {0} de {1}: {2}" -f $i, $pasos.Count, $paso.Nombre) 'INFO'
        $ok = $false
        try {
            $salida = & $paso.Accion
            $ok = [bool](@($salida)[-1])
        }
        catch {
            Write-Log ("Error en '{0}': {1}" -f $paso.Nombre, $_.Exception.Message) 'ERROR'
        }
        $resultados.Add([pscustomobject]@{ Paso = $paso.Nombre; Ok = $ok })
    }

    Mostrar-Titulo 'RESUMEN DE LA REPARACIÓN COMPLETA'
    foreach ($r in $resultados) {
        if ($r.Ok) {
            Write-Host ("    [OK]    {0}" -f $r.Paso) -ForegroundColor Green
            Write-Log ("Resumen: {0} -> OK" -f $r.Paso) 'OK' -SoloArchivo
        }
        else {
            Write-Host ("    [FALLÓ] {0}" -f $r.Paso) -ForegroundColor Red
            Write-Log ("Resumen: {0} -> FALLÓ" -f $r.Paso) 'ERROR' -SoloArchivo
        }
    }
    Write-Host ''
    Write-Log "Detalle completo en el log: $($Script:LogFile)" 'INFO'
    $Script:RequiereReinicio = $true
    return (@($resultados | Where-Object { -not $_.Ok }).Count -eq 0)
}

#endregion

#region ==================== USUARIO ACTIVO Y UTILIDADES EXTRA ====================

$Script:PerfilActivo = $null
$Script:CoreAudioListo = $null

$Script:NombresAcciones = [ordered]@{
    '4'    = 'Limpiar archivos temporales (sin vaciar la papelera)'
    '7'    = 'Revisar el disco del sistema'
    '2'    = 'Reparar archivos de Windows (DISM + SFC, 10 a 30 min)'
    '5'    = 'Reparar Windows Update'
    'DRVWU' = 'Instalar desde Windows Update los drivers de dispositivos sin driver'
    'AV'   = 'Actualizar las firmas de Microsoft Defender'
    'SCAN' = 'Escaneo rápido de Microsoft Defender'
    'FW'   = 'Activar el firewall de Windows'
    'SRV'  = 'Iniciar los servicios clave detenidos'
    '15'   = 'Reparar sonido'
    'PRIV' = 'Reparar micrófono y cámara (permisos y silencio)'
    '6'    = 'Reparar impresora (vaciar cola y ponerla en línea)'
    '16'   = 'Outlook: cerrar y limpiar caché y temporales'
    '3'    = 'Reparar red en modo suave (sin cortar la conexión)'
}

function Get-BuildWindows {
    try { return [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild }
    catch { return 0 }
}

function Get-PerfilUsuarioActivo {
    # Usuario dueño del escritorio (explorer.exe) en esta sesión. Puede ser distinto
    # del administrador con el que se elevó la herramienta.
    if ($Script:PerfilActivo) { return $Script:PerfilActivo }
    $resultado = $null
    try {
        $sesion = (Get-Process -Id $PID).SessionId
        $exploradores = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
        $exp = $exploradores | Where-Object { $_.SessionId -eq $sesion } | Select-Object -First 1
        if (-not $exp) { $exp = $exploradores | Select-Object -First 1 }
        if ($exp) {
            $duenio = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction Stop
            $sid = (Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid -ErrorAction Stop).Sid
            $perfil = Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID='{0}'" -f $sid) -ErrorAction Stop
            if ($sid -and $perfil) {
                $resultado = [pscustomobject]@{
                    Usuario      = '{0}\{1}' -f $duenio.Domain, $duenio.User
                    SID          = $sid
                    Ruta         = $perfil.LocalPath
                    LocalAppData = Join-Path $perfil.LocalPath 'AppData\Local'
                    Registro     = "Registry::HKEY_USERS\$sid"
                }
            }
        }
    }
    catch { }
    if (-not $resultado) {
        $actual = [Security.Principal.WindowsIdentity]::GetCurrent()
        $resultado = [pscustomobject]@{
            Usuario      = $actual.Name
            SID          = $actual.User.Value
            Ruta         = $env:USERPROFILE
            LocalAppData = $env:LOCALAPPDATA
            Registro     = 'Registry::HKEY_CURRENT_USER'
        }
    }
    $Script:PerfilActivo = $resultado
    return $resultado
}

function Start-ComoUsuario {
    # Inicia un programa en la sesión del usuario, SIN privilegios de administrador,
    # mediante una tarea programada temporal (se borra al terminar).
    param([string]$Programa, [string]$Argumentos = '')
    $perfil = Get-PerfilUsuarioActivo
    $nombreTarea = 'SoporteTecnico_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        # cmd /c start: el programa queda independiente de la tarea
        $argumentosCmd = '/c start "" "{0}" {1}' -f $Programa, $Argumentos
        $accion = New-ScheduledTaskAction -Execute (Get-RutaSistema 'cmd.exe') -Argument $argumentosCmd
        $config = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $registrada = $false
        foreach ($id in @($perfil.Usuario, $perfil.SID)) {
            try {
                $principal = New-ScheduledTaskPrincipal -UserId $id -LogonType Interactive -RunLevel Limited -ErrorAction Stop
                Register-ScheduledTask -TaskName $nombreTarea -Action $accion -Principal $principal -Settings $config -Force -ErrorAction Stop | Out-Null
                $registrada = $true
                break
            }
            catch { }
        }
        if (-not $registrada) { throw 'No se pudo crear la tarea temporal.' }
        Start-ScheduledTask -TaskName $nombreTarea -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Log ("Iniciado en la sesión de {0}: {1} {2}" -f $perfil.Usuario, $Programa, $Argumentos) 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo iniciar el programa en la sesión del usuario: $($_.Exception.Message)" 'ADVERTENCIA'
        Write-Log ("Hágalo manualmente con Win + R:  `"{0}`" {1}" -f $Programa, $Argumentos) 'INFO'
        return $false
    }
    finally {
        Unregister-ScheduledTask -TaskName $nombreTarea -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Abrir-ParaUsuario {
    # Abre un archivo con el programa predeterminado del usuario con sesión (no como administrador).
    param([string]$Ruta)
    $perfil = Get-PerfilUsuarioActivo
    $actual = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $explorer = Join-Path $env:windir 'explorer.exe'
    try {
        if ($perfil.SID -eq $actual) {
            Start-Process -FilePath $explorer -ArgumentList "`"$Ruta`"" -ErrorAction Stop
        }
        elseif (-not (Start-ComoUsuario -Programa $explorer -Argumentos "`"$Ruta`"")) {
            Start-Process -FilePath $Ruta -ErrorAction Stop
        }
    }
    catch {
        Write-Log "No se pudo abrir ${Ruta}: $($_.Exception.Message)" 'ADVERTENCIA'
    }
}

function Nuevo-Problema {
    param([string]$Texto, [string]$Sugerencia, [switch]$Critica, [switch]$Auto, [string]$Accion = '', [switch]$Info)
    return [pscustomobject]@{ Texto = $Texto; Sugerencia = $Sugerencia; Critica = [bool]$Critica; Auto = [bool]$Auto; Accion = $Accion; Info = [bool]$Info }
}

function Mostrar-EstadoComponente {
    param($Estado)
    foreach ($l in $Estado.Lineas) { Write-Host "    $l" }
    Write-Host ''
    if ($Estado.Problemas.Count -eq 0) {
        Write-Host '    No se detectaron problemas.' -ForegroundColor Green
    }
    foreach ($p in $Estado.Problemas) {
        $color = 'Yellow'; if ($p.Critica) { $color = 'Red' } elseif ($p.Info) { $color = 'Cyan' }
        Write-Host "    [!] $($p.Texto)" -ForegroundColor $color
        if ($p.Sugerencia) { Write-Host "        -> $($p.Sugerencia)" -ForegroundColor DarkGray }
        Write-Log "Problema detectado: $($p.Texto)" 'ADVERTENCIA' -SoloArchivo
    }
    Write-Host ''
}

function Get-DescripcionCodigoPnp {
    param($Codigo)
    $c = 0
    try { $c = [int]$Codigo } catch { }
    switch ($c) {
        0  { 'funcionando' }
        1  { 'código 1: mal configurado (reinstalar el driver)' }
        3  { 'código 3: driver dañado o sin memoria' }
        10 { 'código 10: el dispositivo no puede iniciar (driver incompatible)' }
        12 { 'código 12: conflicto de recursos' }
        14 { 'código 14: requiere reiniciar el equipo' }
        18 { 'código 18: hay que reinstalar los drivers' }
        19 { 'código 19: configuración del registro dañada' }
        21 { 'código 21: Windows está quitando el dispositivo' }
        22 { 'código 22: DESHABILITADO' }
        24 { 'código 24: no presente o con falla' }
        28 { 'código 28: SIN DRIVER instalado' }
        31 { 'código 31: el driver no carga correctamente' }
        32 { 'código 32: driver o servicio deshabilitado' }
        37 { 'código 37: el driver falló al iniciar' }
        39 { 'código 39: driver dañado o faltante' }
        43 { 'código 43: Windows lo detuvo porque reportó fallas (posible falla de hardware)' }
        45 { 'código 45: desconectado' }
        48 { 'código 48: driver bloqueado por incompatibilidad' }
        52 { 'código 52: firma digital del driver no válida' }
        default { "código $c" }
    }
}

#endregion

#region ==================== 15. SONIDO ====================

$Script:CodigoCoreAudio = @'
using System;
using System.Runtime.InteropServices;

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISTAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISTMMDevice {
    int Activate(ref Guid id, int clsCtx, int activationParams, out ISTAudioEndpointVolume aev);
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISTMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out ISTMMDevice endpoint);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class STMMDeviceEnumeratorComObject { }

public class SoporteAudio2 {
    static ISTAudioEndpointVolume Vol(int flujo) {
        ISTMMDeviceEnumerator enumerator = new STMMDeviceEnumeratorComObject() as ISTMMDeviceEnumerator;
        ISTMMDevice dev = null;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(flujo, 1, out dev));
        ISTAudioEndpointVolume epv = null;
        Guid epvid = typeof(ISTAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
        return epv;
    }
    public static float Volume {
        get { float v = -1; Marshal.ThrowExceptionForHR(Vol(0).GetMasterVolumeLevelScalar(out v)); return v; }
        set { Marshal.ThrowExceptionForHR(Vol(0).SetMasterVolumeLevelScalar(value, Guid.Empty)); }
    }
    public static bool Mute {
        get { bool mute; Marshal.ThrowExceptionForHR(Vol(0).GetMute(out mute)); return mute; }
        set { Marshal.ThrowExceptionForHR(Vol(0).SetMute(value, Guid.Empty)); }
    }
    public static float MicVolume {
        get { float v = -1; Marshal.ThrowExceptionForHR(Vol(1).GetMasterVolumeLevelScalar(out v)); return v; }
        set { Marshal.ThrowExceptionForHR(Vol(1).SetMasterVolumeLevelScalar(value, Guid.Empty)); }
    }
    public static bool MicMute {
        get { bool mute; Marshal.ThrowExceptionForHR(Vol(1).GetMute(out mute)); return mute; }
        set { Marshal.ThrowExceptionForHR(Vol(1).SetMute(value, Guid.Empty)); }
    }
}
'@

function Initialize-CoreAudio {
    if ($null -ne $Script:CoreAudioListo) { return $Script:CoreAudioListo }
    try {
        if (-not ('SoporteAudio2' -as [type])) {
            Add-Type -TypeDefinition $Script:CodigoCoreAudio -Language CSharp -ErrorAction Stop
        }
        $Script:CoreAudioListo = $true
    }
    catch {
        Write-Log "No se pudo cargar el control de volumen: $($_.Exception.Message)" 'ADVERTENCIA' -SoloArchivo
        $Script:CoreAudioListo = $false
    }
    return $Script:CoreAudioListo
}

function Get-EstadoAudio {
    $r = [pscustomobject]@{
        Lineas                     = New-Object System.Collections.Generic.List[string]
        Problemas                  = New-Object System.Collections.Generic.List[object]
        DispositivosDeshabilitados = New-Object System.Collections.Generic.List[string]
        DispositivosAudio          = New-Object System.Collections.Generic.List[string]
        SalidasActivas             = 0
    }

    # 1. Servicios de audio
    foreach ($nombre in @('AudioEndpointBuilder', 'Audiosrv')) {
        $s = Get-Service -Name $nombre -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        $r.Lineas.Add(("Servicio {0}: {1} (inicio {2})" -f $s.DisplayName, $s.Status, $s.StartType))
        if ("$($s.Status)" -ne 'Running' -or "$($s.StartType)" -ne 'Automatic') {
            $r.Problemas.Add((Nuevo-Problema -Texto ("El servicio de audio '{0}' no está bien configurado ({1}, inicio {2})." -f $s.DisplayName, $s.Status, $s.StartType) -Sugerencia 'Opción 15 (Reparar sonido): configura e inicia los servicios de audio.' -Critica -Auto))
        }
    }

    # 2. Tarjetas de sonido
    $dispositivos = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    $controladoras = @($dispositivos | Where-Object { "$($_.Class)" -eq 'MEDIA' })
    $sinDriver = @($dispositivos | Where-Object { ([int]$_.ConfigManagerErrorCode -eq 28) -and ("$($_.Class)" -ne 'MEDIA') -and ("$($_.FriendlyName) $($_.InstanceId)" -match 'audio|sound|sonido|HDAUDIO') })
    foreach ($d in $controladoras) {
        $codigo = [int]$d.ConfigManagerErrorCode
        $r.DispositivosAudio.Add($d.InstanceId)
        $r.Lineas.Add(("Tarjeta de sonido: {0} - {1}" -f $d.FriendlyName, (Get-DescripcionCodigoPnp $codigo)))
        if ($codigo -eq 22) {
            $r.DispositivosDeshabilitados.Add($d.InstanceId)
            $r.Problemas.Add((Nuevo-Problema -Texto ("El dispositivo de sonido '{0}' está DESHABILITADO." -f $d.FriendlyName) -Sugerencia 'Opción 15 (Reparar sonido): lo habilita automáticamente.' -Critica -Auto))
        }
        elseif ($codigo -ne 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("El dispositivo de sonido '{0}' tiene un error ({1})." -f $d.FriendlyName, (Get-DescripcionCodigoPnp $codigo)) -Sugerencia 'Opción 15 (Reparar sonido): reinstala el driver de audio.' -Critica -Auto))
        }
    }
    foreach ($d in $sinDriver) {
        $r.Lineas.Add(("Dispositivo sin driver: {0}" -f $d.FriendlyName))
        $r.Problemas.Add((Nuevo-Problema -Texto ("El dispositivo de audio '{0}' NO tiene driver instalado." -f $d.FriendlyName) -Sugerencia 'Instalar el driver de audio desde la página del fabricante del equipo o en Windows Update > Opciones avanzadas > Actualizaciones opcionales.' -Critica))
    }
    if ($controladoras.Count -eq 0 -and $sinDriver.Count -eq 0) {
        $r.Problemas.Add((Nuevo-Problema -Texto 'No se detecta ninguna tarjeta de sonido en el equipo.' -Sugerencia 'Revisar en la BIOS que el audio integrado esté habilitado e instalar el driver de audio/chipset del fabricante.' -Critica))
    }
    foreach ($d in @($dispositivos | Where-Object { "$($_.Class)" -eq 'AudioEndpoint' -and [int]$_.ConfigManagerErrorCode -eq 22 })) {
        $r.DispositivosDeshabilitados.Add($d.InstanceId)
    }

    # 3. Drivers de audio
    try {
        $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass='MEDIA'" -ErrorAction Stop)
        foreach ($x in $drivers) {
            $fechaTxt = ''
            if ($x.DriverDate) { $fechaTxt = ([datetime]$x.DriverDate).ToString('dd/MM/yyyy') }
            $r.Lineas.Add(("Driver: {0} | {1} | versión {2} ({3})" -f $x.DeviceName, $x.DriverProviderName, $x.DriverVersion, $fechaTxt))
            if ("$($x.DriverProviderName)" -match 'Microsoft' -and "$($x.DeviceName)" -match 'High Definition Audio|alta definici') {
                $r.Problemas.Add((Nuevo-Problema -Texto ("'{0}' usa el driver GENÉRICO de Microsoft." -f $x.DeviceName) -Sugerencia 'Si no hay sonido o no detecta audífonos/micrófono, instalar el driver de audio del fabricante (Realtek, Conexant, etc.) desde su página de soporte.'))
            }
        }
    }
    catch { }

    # 4. ¿Cambió un driver de audio en los últimos 14 días?
    $instalaciones = @(Get-EventosSeguro -Log 'System' -Proveedores @('Microsoft-Windows-UserPnp') -Ids @(20001) -Desde ((Get-Date).AddDays(-14)) | Where-Object {
        $texto = "$($_.Message) " + ((@($_.Properties) | ForEach-Object { "$($_.Value)" }) -join ' ')
        $texto -match 'HDAUDIO|INTELAUDIO|Realtek|Conexant|Audio'
    })
    if ($instalaciones.Count -gt 0) {
        $ultima = ($instalaciones | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1).TimeCreated
        $r.Lineas.Add(("Se instaló o actualizó un driver de audio el {0}." -f $ultima.ToString('dd/MM/yyyy HH:mm')))
        $r.Problemas.Add((Nuevo-Problema -Texto ("Un driver de audio cambió hace poco ({0}): posible causa si el sonido falla desde esa fecha." -f $ultima.ToString('dd/MM/yyyy')) -Sugerencia 'Administrador de dispositivos > dispositivo de sonido > Propiedades > Controlador > "Revertir al controlador anterior".'))
    }

    # 5. Salidas de audio (parlantes, audífonos, HDMI)
    $activas = 0; $deshabilitadas = 0; $desconectadas = 0
    $baseRender = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    foreach ($k in @(Get-ChildItem -Path $baseRender -ErrorAction SilentlyContinue)) {
        $valor = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'DeviceState' -ErrorAction SilentlyContinue).DeviceState
        if ($null -eq $valor) { continue }
        $st = [int]$valor -band 0xF
        if ($st -eq 4) { continue }   # dispositivos que ya no existen
        $props = Get-ItemProperty -LiteralPath ("{0}\Properties" -f $k.PSPath) -ErrorAction SilentlyContinue
        $nombre = "$($props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2')"
        $interfaz = "$($props.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6')"
        switch ($st) {
            1 { $txt = 'ACTIVA'; $activas++ }
            2 { $txt = 'DESHABILITADA'; $deshabilitadas++ }
            8 { $txt = 'DESCONECTADA (no hay nada enchufado)'; $desconectadas++ }
            default { $txt = "estado $st" }
        }
        $r.Lineas.Add(("Salida: {0} ({1}) - {2}" -f $nombre, $interfaz, $txt))
    }
    $r.SalidasActivas = $activas
    if ($activas -eq 0) {
        if ($deshabilitadas -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("No hay salidas de audio activas: hay {0} DESHABILITADA(S)." -f $deshabilitadas) -Sugerencia 'Opción 15 intenta habilitarlas. Manual: Panel de sonido (mmsys.cpl) > clic derecho > "Mostrar dispositivos deshabilitados" > Habilitar.' -Critica -Auto))
        }
        elseif ($desconectadas -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto 'No hay salidas de audio activas: Windows ve los conectores como DESCONECTADOS.' -Sugerencia 'Conectar parlantes/audífonos (jack verde o frontal). Si ya están conectados, el jack o su detección puede estar dañado: probar audífonos USB/Bluetooth o instalar el driver del fabricante.' -Critica))
        }
        else {
            $r.Problemas.Add((Nuevo-Problema -Texto 'No hay ninguna salida de audio (parlantes/audífonos) disponible.' -Sugerencia 'Opción 15 (reinstalar el driver de audio) o instalar el driver del fabricante.' -Critica -Auto))
        }
    }

    # 6. Volumen y silencio de la salida predeterminada
    if ($activas -gt 0 -and (Initialize-CoreAudio)) {
        try {
            $vol = [int][math]::Round([SoporteAudio2]::Volume * 100)
            $mute = [bool][SoporteAudio2]::Mute
            $txtMute = 'no'; if ($mute) { $txtMute = 'SÍ' }
            $r.Lineas.Add(("Salida predeterminada: volumen {0} % | silenciada: {1}" -f $vol, $txtMute))
            if ($mute) {
                $r.Problemas.Add((Nuevo-Problema -Texto 'El sonido está SILENCIADO (mute).' -Sugerencia 'Opción 15: quita el silencio automáticamente.' -Auto))
            }
            if ($vol -lt 5) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("El volumen está en {0} %." -f $vol) -Sugerencia 'Opción 15: sube el volumen al 50 %.' -Auto))
            }
        }
        catch {
            $r.Problemas.Add((Nuevo-Problema -Texto 'Windows no tiene una salida de audio predeterminada.' -Sugerencia 'Elegir la salida en Configuración > Sistema > Sonido o en el Panel de sonido (mmsys.cpl).'))
        }
    }
    return $r
}

function Probar-Sonido {
    $wav = @('tada.wav', 'Windows Background.wav', 'chimes.wav', 'Windows Notify System Generic.wav') |
        ForEach-Object { Join-Path $env:windir "Media\$_" } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $wav) {
        Write-Log 'No se encontró un sonido de prueba en C:\Windows\Media.' 'ADVERTENCIA'
        return $false
    }
    Write-Log 'Reproduciendo sonido de prueba (suba el volumen de los parlantes)...' 'INFO'
    try {
        $reproductor = New-Object System.Media.SoundPlayer $wav
        $reproductor.PlaySync()
        Start-Sleep -Milliseconds 400
        $reproductor.PlaySync()
        $reproductor.Dispose()
    }
    catch {
        Write-Log "No se pudo reproducir el sonido: $($_.Exception.Message)" 'ADVERTENCIA'
    }
    return (Confirmar '¿Se escuchó el sonido de prueba?')
}

function Reparar-Audio {
    param([switch]$Automatico)
    Mostrar-Titulo 'DIAGNOSTICAR Y REPARAR SONIDO'
    Write-Host '    Analizando el audio del equipo...' -ForegroundColor DarkGray
    $antes = Get-EstadoAudio
    Mostrar-EstadoComponente $antes

    if (-not $Automatico) {
        if (-not (Confirmar '¿Aplicar la reparación automática de sonido?')) {
            Write-Log 'Reparación de sonido cancelada por el usuario.' 'INFO'
            return $false
        }
    }

    # 1. Servicios de audio
    Write-Log 'Configurando e iniciando los servicios de audio...' 'INFO'
    foreach ($n in @('AudioEndpointBuilder', 'Audiosrv')) {
        try { Set-Service -Name $n -StartupType Automatic -ErrorAction Stop }
        catch { Write-Log "No se pudo cambiar el inicio de ${n}: $($_.Exception.Message)" 'ADVERTENCIA' }
    }
    try {
        Restart-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction Stop
        Write-Log 'Servicio AudioEndpointBuilder reiniciado.' 'OK'
    }
    catch {
        Write-Log "No se pudo reiniciar AudioEndpointBuilder: $($_.Exception.Message)" 'ADVERTENCIA'
    }
    $null = Iniciar-Servicio 'Audiosrv'

    # 2. Habilitar dispositivos deshabilitados
    foreach ($id in @($antes.DispositivosDeshabilitados)) {
        try {
            Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
            Write-Log "Dispositivo habilitado: $id" 'OK'
        }
        catch {
            Write-Log "No se pudo habilitar ${id}: $($_.Exception.Message)" 'ADVERTENCIA'
        }
    }

    # 3. Buscar cambios de hardware
    $build = Get-BuildWindows
    if ($build -ge 19041) {
        $null = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos '/scan-devices' -Descripcion 'Buscar cambios de hardware'
    }
    Start-Sleep -Seconds 3

    # 4. Quitar silencio y subir volumen
    if (Initialize-CoreAudio) {
        try {
            if ([SoporteAudio2]::Mute) { [SoporteAudio2]::Mute = $false; Write-Log 'Se quitó el silencio (mute).' 'OK' }
            if ([SoporteAudio2]::Volume -lt 0.05) { [SoporteAudio2]::Volume = 0.5; Write-Log 'Volumen ajustado al 50 %.' 'OK' }
        }
        catch {
            Write-Log 'No hay una salida de audio predeterminada para ajustar el volumen.' 'ADVERTENCIA'
        }
    }

    # 5. Volver a verificar
    $despues = Get-EstadoAudio
    Write-Host ''
    Write-Host ("    Problemas antes: {0}  |  después: {1}" -f $antes.Problemas.Count, $despues.Problemas.Count) -ForegroundColor Cyan
    foreach ($p in $despues.Problemas) {
        Write-Host "    [!] $($p.Texto)" -ForegroundColor Yellow
        if ($p.Sugerencia) { Write-Host "        -> $($p.Sugerencia)" -ForegroundColor DarkGray }
    }
    Write-Log ("Sonido: {0} problema(s) antes de reparar, {1} después." -f $antes.Problemas.Count, $despues.Problemas.Count) 'INFO' -SoloArchivo
    Write-Host ''

    # 6. Prueba real
    if (Probar-Sonido) {
        Write-Log 'El técnico confirmó que el sonido funciona.' 'OK'
        return $true
    }

    # 7. Reinstalar el driver
    if ($despues.DispositivosAudio.Count -gt 0 -and $build -ge 19041) {
        Write-Host ''
        Write-Host '    Siguiente paso: reinstalar el driver de audio. Se quitan las tarjetas de sonido y Windows' -ForegroundColor Yellow
        Write-Host '    las vuelve a detectar con su driver (el sonido se corta unos segundos).' -ForegroundColor Yellow
        if (Confirmar '¿Reinstalar el driver de audio?') {
            foreach ($id in $despues.DispositivosAudio) {
                $null = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos ('/remove-device "{0}"' -f $id) -Descripcion 'Quitar tarjeta de sonido'
            }
            Start-Sleep -Seconds 2
            $null = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos '/scan-devices' -Descripcion 'Detectar hardware de nuevo'
            Write-Log 'Esperando a que Windows reinstale el audio (10 segundos)...' 'INFO'
            Start-Sleep -Seconds 10
            if (Initialize-CoreAudio) {
                try { if ([SoporteAudio2]::Mute) { [SoporteAudio2]::Mute = $false } } catch { }
            }
            if (Probar-Sonido) {
                Write-Log 'El sonido funciona después de reinstalar el driver.' 'OK'
                return $true
            }
        }
    }

    # 8. Lo que queda es manual o de hardware
    $modelo = ''
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; $modelo = "$($cs.Manufacturer) $($cs.Model)" } catch { }
    Write-Host ''
    Write-Host '    No se resolvió por software. Siguientes pasos:' -ForegroundColor Yellow
    Write-Host '      1. Probar con audífonos en otro conector, o con audífonos USB/Bluetooth.'
    Write-Host '      2. En el Panel de sonido, elegir la salida correcta como predeterminada.'
    Write-Host '      3. Si un driver cambió hace poco: Administrador de dispositivos > Revertir controlador.'
    Write-Host "      4. Instalar el driver de audio desde la web del fabricante (modelo: $modelo)."
    Write-Host '      5. Revisar en la BIOS que el audio integrado esté habilitado.'
    Write-Host '      6. Si nada funciona: posible falla de hardware (jack, parlante o placa). Un adaptador USB de audio lo resuelve.'
    Write-Log 'Sonido no resuelto automáticamente; se mostraron los pasos manuales.' 'ADVERTENCIA'
    if (Confirmar '¿Abrir el Panel de sonido?') {
        $null = Start-ComoUsuario -Programa (Get-RutaSistema 'control.exe') -Argumentos 'mmsys.cpl'
    }
    return $false
}

#endregion

#region ==================== 16. OUTLOOK / OFFICE ====================

function Get-InfoOffice {
    $info = [pscustomobject]@{
        Instalado          = $false
        ClickToRun         = $false
        Version            = ''
        Plataforma         = ''
        Idioma             = ''
        Canal              = ''
        Productos          = ''
        RutaOutlook        = ''
        VersionOutlook     = ''
        FechaActualizacion = $null
        OutlookNuevo       = $false
    }
    try {
        $cfg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction Stop
        $info.ClickToRun = $true
        $info.Version = "$($cfg.VersionToReport)"
        $info.Plataforma = "$($cfg.Platform)"
        $info.Idioma = "$($cfg.ClientCulture)"
        $info.Productos = "$($cfg.ProductReleaseIds)"
        $canales = [ordered]@{
            '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Actual'
            '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Mensual empresarial'
            '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semestral empresarial'
            'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semestral (vista previa)'
            '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Actual (vista previa)'
            '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta'
        }
        foreach ($url in @("$($cfg.UpdateChannel)", "$($cfg.CDNBaseUrl)")) {
            if ($info.Canal -or -not $url) { continue }
            foreach ($g in $canales.Keys) { if ($url -match $g) { $info.Canal = $canales[$g] } }
        }
        if (-not $info.Canal) { $info.Canal = 'desconocido' }
    }
    catch { }
    try {
        $app = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE' -ErrorAction Stop
        $ruta = "$($app.'(default)')".Trim().Trim('"')
        if ($ruta -and (Test-Path -LiteralPath $ruta)) {
            $archivo = Get-Item -LiteralPath $ruta
            $info.Instalado = $true
            $info.RutaOutlook = $ruta
            $info.VersionOutlook = "$($archivo.VersionInfo.ProductVersion)"
            $info.FechaActualizacion = $archivo.LastWriteTime
        }
    }
    catch { }
    try { $info.OutlookNuevo = @(Get-AppxPackage -AllUsers -Name 'Microsoft.OutlookForWindows' -ErrorAction Stop).Count -gt 0 } catch { }
    return $info
}

function Get-EstadoOutlook {
    $r = [pscustomobject]@{
        Lineas    = New-Object System.Collections.Generic.List[string]
        Problemas = New-Object System.Collections.Generic.List[object]
        Office    = $null
        Perfil    = $null
    }
    $office = Get-InfoOffice
    $perfil = Get-PerfilUsuarioActivo
    $r.Office = $office
    $r.Perfil = $perfil

    if (-not $office.Instalado) {
        $r.Lineas.Add('Outlook clásico no está instalado.')
        if ($office.OutlookNuevo) {
            $r.Lineas.Add('Está instalado el Outlook nuevo. Para repararlo: Configuración > Aplicaciones > Outlook (new) > Opciones avanzadas > Reparar / Restablecer.')
        }
        return $r
    }

    if ($office.ClickToRun) {
        $r.Lineas.Add(("Office (Click-to-Run) {0} | {1} | idioma {2} | canal {3}" -f $office.Version, $office.Plataforma, $office.Idioma, $office.Canal))
        $r.Lineas.Add(("Productos: {0}" -f $office.Productos))
    }
    else {
        $r.Lineas.Add('Office instalado por MSI (versión por volumen o antigua).')
    }
    $diasAct = 9999
    if ($office.FechaActualizacion) {
        $diasAct = [int]((Get-Date) - $office.FechaActualizacion).TotalDays
        $r.Lineas.Add(("Outlook {0} | actualizado aprox. el {1} (hace {2} días, según la fecha de OUTLOOK.EXE)" -f $office.VersionOutlook, $office.FechaActualizacion.ToString('dd/MM/yyyy'), $diasAct))
    }
    $r.Lineas.Add(("Usuario analizado: {0}" -f $perfil.Usuario))
    if ($office.OutlookNuevo) { $r.Lineas.Add('También está instalado el Outlook nuevo (olk.exe).') }

    # Outlook abierto / congelado
    $procesos = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
    if ($procesos.Count -gt 0) {
        if (@($procesos | Where-Object { -not $_.Responding }).Count -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto 'Outlook está abierto pero NO RESPONDE (congelado).' -Sugerencia 'Opción 16 > Reparación rápida (cierra Outlook y limpia la caché).' -Auto))
        }
        else {
            $r.Lineas.Add('Outlook está abierto y responde.')
        }
    }

    # Cierres y congelamientos de los últimos 14 días
    $desde = (Get-Date).AddDays(-14)
    $cierres = @(Get-EventosSeguro -Log 'Application' -Proveedores @('Application Error') -Ids @(1000) -Desde $desde | Where-Object { "$($_.Properties[0].Value)" -eq 'OUTLOOK.EXE' })
    $bloqueos = @(Get-EventosSeguro -Log 'Application' -Proveedores @('Application Hang') -Ids @(1002) -Desde $desde | Where-Object { "$($_.Properties[0].Value)" -eq 'OUTLOOK.EXE' })
    $r.Lineas.Add(("Cierres inesperados (14 días): {0} | Congelamientos: {1}" -f $cierres.Count, $bloqueos.Count))
    if ($cierres.Count -gt 0) {
        $modulos = @($cierres | Group-Object -Property { "$($_.Properties[3].Value)" } | Sort-Object -Property Count -Descending)
        foreach ($m in ($modulos | Select-Object -First 3)) {
            $r.Lineas.Add(("   Módulo que falla: {0} ({1} vez/veces)" -f $m.Name, $m.Count))
        }
        $r.Problemas.Add((Nuevo-Problema -Texto ("Outlook se cerró solo {0} vez/veces en los últimos 14 días." -f $cierres.Count) -Sugerencia 'Opción 16: limpiar caché, probar en modo seguro y hacer la reparación rápida de Office.' -Auto))
        $principal = $modulos[0].Name
        if ($principal -and $principal -notmatch '^(outlook\.exe|olmapi32|mso|emsmdb32|ntdll|kernelbase|ucrtbase|vcruntime|msvcp|combase|user32|clr|coreclr|wwlib|riched20|unknown|d3d|dxgi|ole32|oleaut32|win32u|gdi|appvisvsubsystems)') {
            $r.Problemas.Add((Nuevo-Problema -Texto ("El módulo que provoca los cierres ('{0}') no es de Office ni de Windows: probablemente un complemento o un antivirus." -f $principal) -Sugerencia 'Abrir Outlook en modo seguro (opción 16) y desactivar ese complemento en Archivo > Opciones > Complementos > Ir.'))
        }
        $primero = ($cierres | Sort-Object -Property TimeCreated | Select-Object -First 1).TimeCreated
        if ($office.FechaActualizacion -and $diasAct -le 14 -and $primero -ge $office.FechaActualizacion) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("Los cierres empezaron DESPUÉS de la última actualización de Outlook (aprox. {0})." -f $office.FechaActualizacion.ToString('dd/MM/yyyy')) -Sugerencia 'Opción 16 > Reparación rápida de Office; si sigue fallando, Reparación en línea.'))
        }
    }
    if ($bloqueos.Count -ge 3) {
        $r.Problemas.Add((Nuevo-Problema -Texto ("Outlook se congeló {0} veces en 14 días." -f $bloqueos.Count) -Sugerencia 'Opción 16: limpiar caché y revisar el tamaño del archivo de datos (OST/PST).' -Auto))
    }

    # Archivos de datos OST / PST
    $archivos = New-Object System.Collections.Generic.List[object]
    $carpetaOutlook = Join-Path $perfil.LocalAppData 'Microsoft\Outlook'
    foreach ($a in @(Get-ChildItem -LiteralPath $carpetaOutlook -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.ost' -or $_.Extension -eq '.pst' })) { $archivos.Add($a) }
    foreach ($a in @(Get-ChildItem -LiteralPath (Join-Path $perfil.Ruta 'Documents') -Filter '*.pst' -File -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue)) { $archivos.Add($a) }
    foreach ($a in $archivos) {
        $gb = [math]::Round($a.Length / 1GB, 2)
        $r.Lineas.Add(("Archivo de datos: {0} | {1} GB | modificado {2}" -f $a.FullName, $gb, $a.LastWriteTime.ToString('dd/MM/yyyy')))
        if ($gb -ge 40) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("El archivo '{0}' pesa {1} GB (el límite es 50 GB): Outlook se pone lento y puede dañarse." -f $a.Name, $gb) -Sugerencia 'Archivar correo antiguo o reducir el período sin conexión (Configuración de la cuenta > Cambiar > "Mantener sin conexión": 1 año).'))
        }
    }
    if ($archivos.Count -eq 0) { $r.Lineas.Add('No se encontraron archivos OST/PST en las rutas habituales.') }

    # Carpeta temporal de adjuntos
    $temporal = Join-Path $perfil.LocalAppData 'Microsoft\Windows\INetCache\Content.Outlook'
    $cantTemp = @(Get-ChildItem -LiteralPath $temporal -File -Recurse -Force -ErrorAction SilentlyContinue).Count
    $r.Lineas.Add(("Archivos temporales de adjuntos: {0}" -f $cantTemp))
    if ($cantTemp -gt 200) {
        $r.Problemas.Add((Nuevo-Problema -Texto ("La carpeta temporal de adjuntos tiene {0} archivos (provoca errores al abrir adjuntos)." -f $cantTemp) -Sugerencia 'Opción 16 > Reparación rápida (limpia esa carpeta).' -Auto))
    }

    # Complementos
    $activos = New-Object System.Collections.Generic.List[string]
    $rutasAddins = @(
        "$($perfil.Registro)\Software\Microsoft\Office\Outlook\Addins",
        'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins'
    )
    foreach ($rutaAddin in $rutasAddins) {
        foreach ($k in @(Get-ChildItem -Path $rutaAddin -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and [int]$p.LoadBehavior -eq 3) {
                $nombre = "$($p.FriendlyName)"
                if (-not $nombre -or $nombre.StartsWith('@')) { $nombre = $k.PSChildName }
                if (-not $activos.Contains($nombre)) { $activos.Add($nombre) }
            }
        }
    }
    $r.Lineas.Add(("Complementos activos ({0}): {1}" -f $activos.Count, ($activos -join ', ')))
    $desactivados = Get-Item -Path "$($perfil.Registro)\Software\Microsoft\Office\16.0\Outlook\Resiliency\DisabledItems" -ErrorAction SilentlyContinue
    if ($desactivados -and $desactivados.ValueCount -gt 0) {
        $r.Lineas.Add(("Outlook desactivó {0} complemento(s) por provocar fallas." -f $desactivados.ValueCount))
    }
    return $r
}

function Cerrar-Outlook {
    $procesos = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
    if ($procesos.Count -eq 0) { return $true }
    Write-Host '    Outlook está abierto y se va a cerrar (pida al usuario guardar lo que esté escribiendo).' -ForegroundColor Yellow
    if (-not (Confirmar '¿Cerrar Outlook ahora?')) { return $false }
    foreach ($p in $procesos) { try { $null = $p.CloseMainWindow() } catch { } }
    for ($i = 0; $i -lt 15; $i++) {
        if (@(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Seconds 1
    }
    $quedan = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
    if ($quedan.Count -gt 0) {
        $quedan | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Log 'Outlook no respondía: se forzó el cierre.' 'ADVERTENCIA'
    }
    else {
        Write-Log 'Outlook cerrado.' 'OK'
    }
    return $true
}

function Renombrar-Respaldo {
    # Renombra un archivo o carpeta a <nombre>.old_<fecha> (respaldo en lugar de borrar).
    param([string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return $false }
    $nuevo = '{0}.old_{1}' -f (Split-Path $Ruta -Leaf), (Get-Date -Format 'yyyyMMdd_HHmmss')
    try {
        Rename-Item -LiteralPath $Ruta -NewName $nuevo -ErrorAction Stop
        Write-Log "Respaldado: $Ruta -> $nuevo" 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo renombrar ${Ruta}: $($_.Exception.Message)" 'ADVERTENCIA'
        return $false
    }
}

function Limpiar-CacheOutlook {
    Mostrar-Titulo 'OUTLOOK: REPARACIÓN RÁPIDA (CACHÉ Y TEMPORALES)'
    $office = Get-InfoOffice
    if (-not $office.Instalado) {
        Write-Log 'Outlook clásico no está instalado.' 'ADVERTENCIA'
        return $false
    }
    if (-not (Cerrar-Outlook)) {
        Write-Log 'Cancelado: Outlook sigue abierto.' 'INFO'
        return $false
    }
    $la = (Get-PerfilUsuarioActivo).LocalAppData

    $temporal = Join-Path $la 'Microsoft\Windows\INetCache\Content.Outlook'
    if (Test-Path -LiteralPath $temporal) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $temporal -Directory -Force -ErrorAction SilentlyContinue)) { Limpiar-Carpeta $sub.FullName }
        Write-Log 'Limpiada la carpeta temporal de adjuntos (Content.Outlook).' 'OK'
    }

    $roam = Join-Path $la 'Microsoft\Outlook\RoamCache'
    if (Renombrar-Respaldo $roam) {
        Write-Log 'RoamCache se regenera sola. Si se pierden sugerencias de direcciones, el respaldo quedó en la misma carpeta.' 'INFO'
    }

    $oab = Join-Path $la 'Microsoft\Outlook\Offline Address Books'
    if (Test-Path -LiteralPath $oab) {
        Limpiar-Carpeta $oab
        Write-Log 'Limpiada la libreta de direcciones sin conexión (se descarga de nuevo).' 'OK'
    }

    $wef = Join-Path $la 'Microsoft\Office\16.0\Wef'
    if (Test-Path -LiteralPath $wef) {
        Limpiar-Carpeta $wef
        Write-Log 'Limpiada la caché de complementos web de Office.' 'OK'
    }

    Write-Log 'Listo. La primera vez que abra Outlook puede tardar un poco más.' 'INFO'
    if (Confirmar '¿Abrir Outlook ahora?') { $null = Start-ComoUsuario -Programa $office.RutaOutlook }
    return $true
}

function Reparar-InicioSesionOffice {
    Mostrar-Titulo 'OUTLOOK: PIDE CONTRASEÑA / NO INICIA SESIÓN'
    Write-Host '    Se borran las credenciales en caché de Office del usuario (con respaldo).' -ForegroundColor Yellow
    Write-Host '    Al abrir Outlook pedirá iniciar sesión de nuevo con el correo y la contraseña.' -ForegroundColor Yellow
    $abiertas = @(Get-Process -Name 'WINWORD', 'EXCEL', 'POWERPNT', 'ONENOTE', 'MSACCESS' -ErrorAction SilentlyContinue)
    if ($abiertas.Count -gt 0) {
        Write-Host ("    Cierre primero: {0}" -f (($abiertas | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) -ForegroundColor Yellow
    }
    Write-Host ''
    if (-not (Confirmar '¿Continuar?')) { return $false }
    if (-not (Cerrar-Outlook)) { return $false }

    $perfil = Get-PerfilUsuarioActivo
    foreach ($c in @('Microsoft\OneAuth', 'Microsoft\IdentityCache')) {
        $null = Renombrar-Respaldo (Join-Path $perfil.LocalAppData $c)
    }
    $claveId = "$($perfil.Registro)\Software\Microsoft\Office\16.0\Common\Identity"
    if (Test-Path -LiteralPath $claveId) {
        $respaldo = Join-Path $Script:DirReportes ('OfficeIdentity_{0}.reg' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $rutaReg = $claveId -replace '^Registry::', ''
        $null = Invoke-Nativo -Archivo (Get-RutaSistema 'reg.exe') -Argumentos ('export "{0}" "{1}" /y' -f $rutaReg, $respaldo) -Descripcion 'Respaldo del registro de identidad de Office'
        $identidades = "$claveId\Identities"
        if (Test-Path -LiteralPath $identidades) {
            Remove-Item -LiteralPath $identidades -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Identidades de Office borradas (respaldo: $respaldo)." 'OK'
        }
    }
    Write-Host ''
    Write-Host '    Si sigue pidiendo contraseña:' -ForegroundColor Cyan
    Write-Host '      - Administrador de credenciales > Credenciales de Windows > quitar las que empiezan con "MicrosoftOffice16".'
    Write-Host '      - Configuración > Cuentas > Acceder a trabajo o escuela: revisar que la cuenta esté conectada.'
    if (Confirmar '¿Abrir el Administrador de credenciales del usuario?') {
        $null = Start-ComoUsuario -Programa (Get-RutaSistema 'control.exe') -Argumentos '/name Microsoft.CredentialManager'
    }
    return $true
}

function Reconstruir-Ost {
    Mostrar-Titulo 'OUTLOOK: RECONSTRUIR ARCHIVO OST'
    $perfil = Get-PerfilUsuarioActivo
    $osts = @(Get-ChildItem -LiteralPath (Join-Path $perfil.LocalAppData 'Microsoft\Outlook') -Filter '*.ost' -File -Force -ErrorAction SilentlyContinue)
    if ($osts.Count -eq 0) {
        Write-Log 'No hay archivos OST. Las cuentas POP usan PST, que esta herramienta NO toca.' 'ADVERTENCIA'
        return $false
    }
    foreach ($o in $osts) { Write-Host ("    - {0} ({1} GB)" -f $o.Name, [math]::Round($o.Length / 1GB, 2)) }
    Write-Host ''
    Write-Host '    El OST es una copia local del buzón (Microsoft 365, Exchange, Outlook.com e IMAP).' -ForegroundColor Yellow
    Write-Host '    Outlook volverá a descargar todo el correo del servidor: puede tardar horas si el buzón es grande.' -ForegroundColor Yellow
    Write-Host '    Los archivos se renombran (no se borran), así que nada se pierde.' -ForegroundColor Yellow
    Write-Host ''
    if (-not (Confirmar '¿Renombrar los OST para que Outlook los cree de nuevo?')) { return $false }
    if (-not (Cerrar-Outlook)) { return $false }
    $ok = $true
    foreach ($o in $osts) { if (-not (Renombrar-Respaldo $o.FullName)) { $ok = $false } }
    Write-Log 'Al abrir Outlook se descargará el correo. Cuando todo esté bien, puede borrar los archivos .old.' 'INFO'
    return $ok
}

function Reparar-Office {
    param([ValidateSet('QuickRepair', 'FullRepair')][string]$Tipo = 'QuickRepair')
    $office = Get-InfoOffice
    if (-not $office.ClickToRun) {
        Write-Log 'Office no es Click-to-Run: use Programas y características > Microsoft Office > Cambiar > Reparar.' 'ADVERTENCIA'
        Start-Process -FilePath (Get-RutaSistema 'control.exe') -ArgumentList 'appwiz.cpl'
        return $false
    }
    $comunes = $env:CommonProgramW6432
    if (-not $comunes) { $comunes = $env:CommonProgramFiles }
    $c2r = Join-Path $comunes 'Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if (-not (Test-Path -LiteralPath $c2r)) {
        Write-Log "No se encontró $c2r" 'ERROR'
        return $false
    }
    if ($Tipo -eq 'FullRepair') {
        Write-Host '    Reparación EN LÍNEA: necesita internet, tarda unos 30 minutos y reinstala Office.' -ForegroundColor Yellow
        Write-Host '    Los correos y documentos se conservan.' -ForegroundColor Yellow
    }
    else {
        Write-Host '    Reparación RÁPIDA: no necesita internet y tarda entre 5 y 10 minutos.' -ForegroundColor Yellow
    }
    Write-Host '    Se cerrarán todas las aplicaciones de Office.' -ForegroundColor Yellow
    if (-not (Confirmar '¿Iniciar la reparación de Office?')) { return $false }
    $plataforma = $office.Plataforma; if (-not $plataforma) { $plataforma = 'x64' }
    $idioma = $office.Idioma; if (-not $idioma) { $idioma = 'es-es' }
    $argumentos = 'scenario=Repair platform={0} culture={1} forceappshutdown=True RepairType={2} DisplayLevel=True' -f $plataforma, $idioma, $Tipo
    try {
        Start-Process -FilePath $c2r -ArgumentList $argumentos -ErrorAction Stop
        Write-Log "Reparación de Office ($Tipo) iniciada: siga el avance en la ventana de Office." 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo iniciar la reparación de Office: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Reparar-Outlook {
    Clear-Host
    Mostrar-Titulo 'OUTLOOK / OFFICE'
    Write-Host '    Analizando Outlook...' -ForegroundColor DarkGray
    $estado = Get-EstadoOutlook
    Mostrar-EstadoComponente $estado
    if (-not $estado.Office.Instalado) {
        Pausa
        return
    }
    $volver = $false
    while (-not $volver) {
        Write-Host '    1. Reparación rápida de Outlook (cierra Outlook y limpia caché y temporales)  [recomendado]' -ForegroundColor Green
        Write-Host '    2. Abrir Outlook en modo seguro (sin complementos)'
        Write-Host '    3. Pide contraseña siempre / no inicia sesión'
        Write-Host '    4. Reconstruir el archivo de datos OST'
        Write-Host '    5. Reparación rápida de Office (sin internet, 5-10 min)'
        Write-Host '    6. Reparación en línea de Office (con internet, ~30 min)'
        Write-Host '    7. Restablecer el panel de carpetas (/resetnavpane)'
        Write-Host '    8. Abrir la configuración de Correo (perfiles de Outlook)'
        Write-Host '    0. Volver al menú principal'
        Write-Host ''
        $op = Read-Host '  Elija una opción'
        if ($null -eq $op) { $op = '' }
        $op = $op.Trim()
        if ($op) { Write-Log "Outlook - opción elegida: $op" 'INFO' -SoloArchivo }
        $hizoAlgo = $true
        try {
            switch ($op) {
                '1' { Invoke-Registrada 'Outlook: limpiar caché' { Limpiar-CacheOutlook } }
                '2' { Invoke-Registrada 'Outlook: abrir en modo seguro' { Abrir-OutlookModoSeguro } }
                '3' { Invoke-Registrada 'Outlook: reparar inicio de sesión de Office' { Reparar-InicioSesionOffice } }
                '4' { Invoke-Registrada 'Outlook: reconstruir OST' { Reconstruir-Ost } }
                '5' { Invoke-Registrada 'Reparar Office (rápida)' { Reparar-Office -Tipo 'QuickRepair' } }
                '6' { Invoke-Registrada 'Reparar Office (en línea)' { Reparar-Office -Tipo 'FullRepair' } }
                '7' { Invoke-Registrada 'Outlook: restablecer panel de carpetas' { Restablecer-PanelOutlook } }
                '8' { Invoke-Registrada 'Outlook: abrir perfiles de correo' { Abrir-PerfilesCorreo } }
                '0' { $volver = $true; $hizoAlgo = $false }
                ''  { $hizoAlgo = $false }
                default { Write-Host '  Opción no válida.' -ForegroundColor Red; $hizoAlgo = $false; Start-Sleep -Seconds 1 }
            }
        }
        catch {
            Write-Log "Error en Outlook: $($_.Exception.Message)" 'ERROR'
        }
        if ($hizoAlgo) { Pausa }
        if (-not $volver) { Clear-Host; Mostrar-Titulo 'OUTLOOK / OFFICE' }
    }
}

#endregion

#region ==================== REPORTE HTML Y REPARACIÓN AUTOMÁTICA ====================

function Html {
    param([string]$Texto)
    return [System.Net.WebUtility]::HtmlEncode($Texto)
}

function New-ReporteHtml {
    param([string]$Ruta, [datetime]$Fecha)
    $salud = Get-PuntajeSalud
    $criticas = $salud.Criticas
    $normales = $salud.Alertas
    $puntaje = $salud.Puntaje
    $colorP = $salud.Color
    $estadoP = $salud.Estado

    # Datos del equipo
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $Script:DiagInfo.Keys) {
        [void]$sb.Append(('<div class="kv"><span>{0}</span><b>{1}</b></div>' -f (Html $k), (Html "$($Script:DiagInfo[$k])")))
    }
    $equipoHtml = $sb.ToString()

    # Problemas
    $sb = New-Object System.Text.StringBuilder
    if ($Script:Alertas.Count -eq 0) {
        [void]$sb.Append('<p class="ok-msg">No se detectaron problemas.</p>')
    }
    else {
        [void]$sb.Append('<ul class="alertas">')
        foreach ($a in (Get-AlertasOrdenadas)) {
            $clase = 'warn'; $etiqueta = 'ALERTA'; $texto = $a
            if ($a.StartsWith('[CRÍTICO]')) { $clase = 'crit'; $etiqueta = 'CRÍTICO'; $texto = $a.Substring(9).Trim() }
            elseif ($a.StartsWith('[ALERTA]')) { $texto = $a.Substring(8).Trim() }
            elseif ($a.StartsWith('[INFO]')) { $clase = 'info'; $etiqueta = 'NOTA'; $texto = $a.Substring(6).Trim() }
            [void]$sb.Append(('<li class="{0}"><span class="tag">{1}</span>{2}</li>' -f $clase, $etiqueta, (Html $texto)))
        }
        [void]$sb.Append('</ul>')
    }
    $alertasHtml = $sb.ToString()

    # Sugerencias
    $sb = New-Object System.Text.StringBuilder
    if ($Script:Sugerencias.Count -eq 0) {
        [void]$sb.Append('<p>Ninguna.</p>')
    }
    else {
        [void]$sb.Append('<ol>')
        foreach ($s in $Script:Sugerencias) { [void]$sb.Append(('<li>{0}</li>' -f (Html $s))) }
        [void]$sb.Append('</ol>')
    }
    $sugerenciasHtml = $sb.ToString()

    # Reparaciones automáticas disponibles
    $autoHtml = ''
    $claves = @($Script:NombresAcciones.Keys | Where-Object { $Script:AccionesSugeridas.Contains($_) })
    if ($claves.Count -gt 0) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<div class="panel"><h2>Reparaciones automáticas disponibles</h2><ul class="auto">')
        foreach ($c in $claves) { [void]$sb.Append(('<li>{0}</li>' -f (Html $Script:NombresAcciones[$c]))) }
        [void]$sb.Append('</ul></div>')
        $autoHtml = $sb.ToString()
    }

    # Tarjetas por área
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $Script:Secciones) {
        $n = @($s.Alertas | Where-Object { -not $_.Info }).Count
        $ni = $s.Alertas.Count - $n
        $nc = @($s.Alertas | Where-Object { $_.Critica }).Count
        if ($nc -gt 0) { $clase = 'crit'; $badge = "$n problema(s)" }
        elseif ($n -gt 0) { $clase = 'warn'; $badge = "$n alerta(s)" }
        else {
            $clase = 'ok'; $badge = 'OK'
            if ($ni -gt 0) { $badge = "OK · $ni nota(s)" }
        }
        [void]$sb.Append(('<div class="card {0}"><div class="card-h"><h3>{1}</h3><span class="badge">{2}</span></div>' -f $clase, (Html $s.Nombre), $badge))
        if ($s.Alertas.Count -gt 0) {
            [void]$sb.Append('<ul>')
            foreach ($a in $s.Alertas) { [void]$sb.Append(('<li>{0}</li>' -f (Html $a.Texto))) }
            [void]$sb.Append('</ul>')
        }
        if ($s.Lineas.Count -gt 0) {
            [void]$sb.Append(('<details><summary>Ver detalle</summary><pre>{0}</pre></details>' -f (Html (($s.Lineas | ForEach-Object { $_.Trim() }) -join "`n"))))
        }
        [void]$sb.Append('</div>')
    }
    $seccionesHtml = $sb.ToString()

    $plantilla = @'
<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Diagnóstico - __EQUIPO__</title>
<style>
*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI",Arial,sans-serif;background:#f1f5f9;color:#0f172a}
header{background:linear-gradient(135deg,#0f172a,#1e3a8a);color:#fff;padding:28px 36px;display:flex;gap:32px;align-items:center;flex-wrap:wrap}
.gauge{width:150px;height:150px;border-radius:50%;background:conic-gradient(__COLOR__ 0 __PUNTAJE__%,rgba(255,255,255,.15) __PUNTAJE__% 100%);display:flex;align-items:center;justify-content:center;flex:none}
.gauge .in{width:116px;height:116px;border-radius:50%;background:#14224f;display:flex;flex-direction:column;align-items:center;justify-content:center}
.gauge b{font-size:42px;line-height:1}.gauge span{font-size:12px;opacity:.75}
h1{margin:0 0 4px;font-size:26px}.sub{opacity:.85;font-size:14px}
.estado{display:inline-block;margin-top:10px;padding:4px 14px;border-radius:999px;background:__COLOR__;font-weight:600}
.kvs{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:10px 24px;margin-top:16px}
.kv span{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.04em;opacity:.65}.kv b{font-weight:600;font-size:14px}
main{max-width:1200px;margin:0 auto;padding:24px}
.panel{background:#fff;border-radius:12px;padding:20px 24px;margin-bottom:20px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
h2{margin:0 0 12px;font-size:18px}
ul.alertas{list-style:none;padding:0;margin:0}ul.alertas li{padding:9px 0;border-bottom:1px solid #e2e8f0}ul.alertas li:last-child{border-bottom:0}
.tag{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:6px;margin-right:10px;color:#fff;background:#d97706}
li.crit .tag{background:#dc2626}li.info .tag{background:#0284c7}
ol li,.auto li{margin:6px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}
.card{background:#fff;border-radius:12px;padding:16px 18px;box-shadow:0 1px 3px rgba(0,0,0,.08);border-left:6px solid #16a34a}
.card.warn{border-left-color:#d97706}.card.crit{border-left-color:#dc2626}
.card-h{display:flex;justify-content:space-between;align-items:center;gap:8px}.card h3{margin:0;font-size:15px}
.badge{font-size:12px;font-weight:600;padding:3px 10px;border-radius:999px;background:#dcfce7;color:#166534;white-space:nowrap}
.card.warn .badge{background:#fef3c7;color:#92400e}.card.crit .badge{background:#fee2e2;color:#991b1b}
.card ul{padding-left:18px;margin:10px 0 0;font-size:13px}
details{margin-top:10px}summary{cursor:pointer;font-size:13px;color:#1d4ed8}
pre{white-space:pre-wrap;font-family:Consolas,monospace;font-size:12px;background:#f8fafc;padding:10px;border-radius:8px;margin:8px 0 0}
.ok-msg{color:#166534;font-weight:600}
footer{text-align:center;font-size:12px;color:#64748b;padding:20px}
@media print{body{background:#fff}.panel,.card{box-shadow:none;border:1px solid #cbd5e1}}
</style></head><body>
<header>
<div class="gauge"><div class="in"><b>__PUNTAJE__</b><span>de 100</span></div></div>
<div style="flex:1;min-width:280px">
<h1>Diagnóstico de __EQUIPO__</h1>
<div class="sub">__FECHA__ &middot; __NALERTAS__ alerta(s), __NCRITICAS__ crítica(s)</div>
<div class="estado">__ESTADO__</div>
<div class="kvs">__EQUIPOINFO__</div>
</div>
</header>
<main>
<div class="panel"><h2>Problemas detectados</h2>__LISTAALERTAS__</div>
<div class="panel"><h2>Qué hacer</h2>__SUGERENCIAS__</div>
__AUTO__
<h2 style="margin:28px 0 12px">Detalle por área</h2>
<div class="grid">__SECCIONES__</div>
</main>
<footer>Generado por Soporte Técnico v__VERSION__ &middot; __FECHA__</footer>
</body></html>
'@
    $html = $plantilla
    $html = $html.Replace('__EQUIPO__', (Html $env:COMPUTERNAME))
    $html = $html.Replace('__COLOR__', $colorP)
    $html = $html.Replace('__PUNTAJE__', "$puntaje")
    $html = $html.Replace('__ESTADO__', (Html $estadoP))
    $html = $html.Replace('__FECHA__', $Fecha.ToString('dd/MM/yyyy HH:mm'))
    $html = $html.Replace('__NALERTAS__', "$normales")
    $html = $html.Replace('__NCRITICAS__', "$criticas")
    $html = $html.Replace('__EQUIPOINFO__', $equipoHtml)
    $html = $html.Replace('__LISTAALERTAS__', $alertasHtml)
    $html = $html.Replace('__SUGERENCIAS__', $sugerenciasHtml)
    $html = $html.Replace('__AUTO__', $autoHtml)
    $html = $html.Replace('__SECCIONES__', $seccionesHtml)
    $html = $html.Replace('__VERSION__', $Script:Version)
    [System.IO.File]::WriteAllText($Ruta, $html, (New-Object System.Text.UTF8Encoding($true)))
}

function Update-FirmasDefender {
    Mostrar-Titulo 'ACTUALIZAR FIRMAS DE MICROSOFT DEFENDER'
    try {
        Update-MpSignature -ErrorAction Stop
        Write-Log 'Firmas de Microsoft Defender actualizadas.' 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudieron actualizar las firmas: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Invoke-ReparacionAutomatica {
    $claves = @($Script:NombresAcciones.Keys | Where-Object { $Script:AccionesSugeridas.Contains($_) })
    if ($claves.Count -eq 0) {
        Write-Log 'No hay reparaciones automáticas pendientes (ejecute primero el diagnóstico).' 'INFO'
        return $false
    }
    Mostrar-Titulo 'REPARACIÓN AUTOMÁTICA SEGÚN EL DIAGNÓSTICO'
    Write-Host '    Según lo encontrado, la herramienta puede aplicar ahora:' -ForegroundColor White
    foreach ($c in $claves) { Write-Host ("      - {0}" -f $Script:NombresAcciones[$c]) -ForegroundColor Green }
    Write-Host ''
    Write-Host '    Antes se crea un punto de restauración. Algunas reparaciones pueden pedir confirmación.' -ForegroundColor DarkGray
    if (-not (Confirmar '¿Aplicar estas reparaciones ahora?')) {
        Write-Log 'Reparación automática omitida por el usuario.' 'INFO'
        return $false
    }
    Write-Log ("Reparación automática: {0}" -f (($claves | ForEach-Object { $Script:NombresAcciones[$_] }) -join ', ')) 'INFO'
    $null = New-PuntoRestauracion

    $resultados = New-Object System.Collections.Generic.List[object]
    foreach ($c in $claves) {
        $ok = $false
        try {
            $salida = switch ($c) {
                '4'  { Limpiar-Temporales -SinPapelera }
                '7'  { Revisar-Disco -Automatico }
                '2'  { Reparar-ArchivosSistema }
                'AV' { Update-FirmasDefender }
                '15' { Reparar-Audio -Automatico }
                '16' { Limpiar-CacheOutlook }
                '3'  { Reparar-Red -Suave }
                '5'    { Reparar-WindowsUpdate -SinConfirmar }
                'DRVWU' { Buscar-DriversWindowsUpdate -Automatico }
                'SCAN' { Invoke-EscaneoDefender -Tipo 'Rapido' }
                'FW'   { Activar-Firewall }
                'SRV'  { Iniciar-ServiciosDetenidos }
                'PRIV' { Reparar-MicrofonoCamara -Automatico }
                '6'    { Reparar-Impresora -SinConfirmar }
            }
            $ok = [bool](@($salida)[-1])
        }
        catch {
            Write-Log ("Error en '{0}': {1}" -f $Script:NombresAcciones[$c], $_.Exception.Message) 'ERROR'
        }
        $resultados.Add([pscustomobject]@{ Paso = $Script:NombresAcciones[$c]; Ok = $ok })
    }

    Mostrar-Titulo 'RESUMEN DE LA REPARACIÓN AUTOMÁTICA'
    foreach ($r in $resultados) {
        if ($r.Ok) {
            Write-Host ("    [OK]    {0}" -f $r.Paso) -ForegroundColor Green
            Write-Log ("Resumen automático: {0} -> OK" -f $r.Paso) 'OK' -SoloArchivo
            try { Registrar-AccionVisita ('Automática: ' + $r.Paso) 'OK' } catch { }
        }
        else {
            Write-Host ("    [FALLÓ] {0}" -f $r.Paso) -ForegroundColor Red
            Write-Log ("Resumen automático: {0} -> FALLÓ o cancelado" -f $r.Paso) 'ERROR' -SoloArchivo
            try { Registrar-AccionVisita ('Automática: ' + $r.Paso) 'Avisos' } catch { }
        }
    }
    Write-Host ''
    Write-Log 'Después de reiniciar, vuelva a correr el diagnóstico (opción 1) para comparar el puntaje.' 'INFO'
    return (@($resultados | Where-Object { -not $_.Ok }).Count -eq 0)
}

#endregion

#region ==================== DIAGNÓSTICO AMPLIADO (PAQUETE A) ====================

function Nuevo-Estado {
    return [pscustomobject]@{
        Lineas    = New-Object System.Collections.Generic.List[string]
        Problemas = New-Object System.Collections.Generic.List[object]
    }
}

function Rep-Estado {
    # Pasa las líneas y problemas de un componente al reporte del diagnóstico.
    param($Estado, [string]$AccionAuto = '')
    foreach ($l in $Estado.Lineas) { Rep-Linea $l }
    foreach ($p in $Estado.Problemas) {
        $acc = "$($p.Accion)"
        if (-not $acc -and $p.Auto) { $acc = $AccionAuto }
        Rep-Alerta $p.Texto $p.Sugerencia -Critica:([bool]$p.Critica) -Info:([bool]$p.Info) -Accion $acc
    }
}

function Get-DatosEvento {
    param($Evento)
    $datos = @{}
    try {
        $xml = [xml]$Evento.ToXml()
        foreach ($d in @($xml.Event.EventData.Data)) {
            if ($d -and $d.Name) { $datos[$d.Name] = $d.'#text' }
        }
    }
    catch { }
    return $datos
}

function Get-DescripcionBugCheck {
    param([string]$Texto)
    if ($Texto -notmatch '0x([0-9a-fA-F]{8})') { return '' }
    $hex = $Matches[1]
    $codigo = [int][Convert]::ToInt64($hex, 16)
    $mapa = @{
        0x0A  = 'IRQL_NOT_LESS_OR_EQUAL: un driver accedió a memoria inválida (actualizar drivers)'
        0x19  = 'BAD_POOL_HEADER: driver o memoria RAM'
        0x1A  = 'MEMORY_MANAGEMENT: probable falla de memoria RAM (diagnóstico de memoria)'
        0x1E  = 'KMODE_EXCEPTION_NOT_HANDLED: driver defectuoso'
        0x3B  = 'SYSTEM_SERVICE_EXCEPTION: driver o archivos de sistema (DISM + SFC)'
        0x50  = 'PAGE_FAULT_IN_NONPAGED_AREA: memoria RAM, driver o antivirus'
        0x7A  = 'KERNEL_DATA_INPAGE_ERROR: disco o cable del disco (RESPALDAR)'
        0x7E  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED: driver (a menudo el de video)'
        0x9F  = 'DRIVER_POWER_STATE_FAILURE: driver que falla al suspender o hibernar'
        0xA0  = 'INTERNAL_POWER_ERROR: administración de energía o hibernación'
        0xBE  = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY: driver defectuoso'
        0xC2  = 'BAD_POOL_CALLER: driver defectuoso'
        0xC5  = 'DRIVER_CORRUPTED_EXPOOL: driver defectuoso'
        0xD1  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL: driver (frecuente: red o WiFi)'
        0xEF  = 'CRITICAL_PROCESS_DIED: archivos de sistema dañados (DISM + SFC) o disco'
        0xF4  = 'CRITICAL_OBJECT_TERMINATION: disco o SSD con fallas'
        0xFC  = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY: driver o RAM'
        0x101 = 'CLOCK_WATCHDOG_TIMEOUT: procesador, BIOS o temperatura'
        0x109 = 'CRITICAL_STRUCTURE_CORRUPTION: driver o RAM'
        0x116 = 'VIDEO_TDR_FAILURE: driver o tarjeta de video'
        0x117 = 'VIDEO_TDR_TIMEOUT_DETECTED: driver o tarjeta de video'
        0x124 = 'WHEA_UNCORRECTABLE_ERROR: hardware (CPU, RAM, temperatura u overclock)'
        0x12B = 'FAULTY_HARDWARE_CORRUPTED_PAGE: memoria RAM'
        0x133 = 'DPC_WATCHDOG_VIOLATION: driver de disco o firmware del SSD'
        0x139 = 'KERNEL_SECURITY_CHECK_FAILURE: driver o RAM'
        0x154 = 'UNEXPECTED_STORE_EXCEPTION: disco o SSD'
    }
    $desc = $mapa[$codigo]
    if (-not $desc) { $desc = 'consultar el código en Microsoft' }
    return ('0x{0}: {1}' -f $hex.ToUpper(), $desc)
}

function Get-DescripcionErrorWU {
    param([string]$Codigo)
    switch ("$Codigo".ToLower()) {
        '0x80070002' { 'faltan archivos de la actualización (Reparar Windows Update)' }
        '0x80070003' { 'faltan archivos de la actualización (Reparar Windows Update)' }
        '0x8007000d' { 'datos de actualización dañados (Reparar Windows Update)' }
        '0x800f0922' { 'no se pudo instalar: partición reservada llena, VPN activa o .NET dañado' }
        '0x800f081f' { 'faltan archivos de origen (DISM + SFC)' }
        '0x800f0831' { 'falta una actualización anterior (DISM + SFC)' }
        '0x80073712' { 'almacén de componentes dañado (DISM + SFC)' }
        '0x80070422' { 'el servicio Windows Update está deshabilitado' }
        '0x80070070' { 'no hay espacio suficiente en el disco' }
        '0x800705b4' { 'tiempo de espera agotado (conexión lenta)' }
        '0x80244022' { 'problema de conexión con los servidores de Microsoft' }
        '0x8024402c' { 'problema de conexión (proxy o DNS)' }
        '0x8024a105' { 'problema de conexión con Windows Update' }
        '0x80070643' { 'error de instalación (común en .NET o en la partición de recuperación)' }
        '0xc1900101' { 'driver incompatible con la nueva versión de Windows' }
        '0xc1900208' { 'aplicación incompatible con la nueva versión de Windows' }
        default      { 'consultar el código en Microsoft' }
    }
}

function Get-EstadoArranque {
    $r = Nuevo-Estado
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    $desde = (Get-Date).AddDays(-30)
    $arranques = @(Get-EventosSeguro -Log $log -Ids @(100) -Desde $desde | Sort-Object -Property TimeCreated -Descending)
    if ($arranques.Count -eq 0) {
        $r.Lineas.Add('Sin registros de tiempo de arranque en 30 días (Windows no los guarda en todos los arranques).')
    }
    else {
        $tiempos = New-Object System.Collections.Generic.List[double]
        foreach ($e in ($arranques | Select-Object -First 5)) {
            $d = Get-DatosEvento $e
            $ms = 0
            [void][int]::TryParse("$($d['BootTime'])", [ref]$ms)
            if ($ms -gt 0) {
                $tiempos.Add($ms)
                $r.Lineas.Add(("Arranque del {0}: {1} segundos" -f $e.TimeCreated.ToString('dd/MM/yyyy HH:mm'), [math]::Round($ms / 1000)))
            }
        }
        if ($tiempos.Count -gt 0) {
            $promedio = [math]::Round((($tiempos | Measure-Object -Average).Average) / 1000)
            $r.Lineas.Add("Promedio: $promedio segundos")
            if ($promedio -gt 120) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("El equipo tarda {0} segundos en arrancar (con SSD lo normal es menos de 30)." -f $promedio) -Sugerencia 'Optimizar rendimiento (desactivar programas de inicio) y considerar cambiar a SSD.' -Critica))
            }
            elseif ($promedio -gt 60) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("El arranque es lento ({0} segundos)." -f $promedio) -Sugerencia 'Optimizar rendimiento (desactivar programas de inicio que no se usan).'))
            }
        }
    }
    $lentos = @(Get-EventosSeguro -Log $log -Ids @(101, 102, 103) -Desde $desde)
    if ($lentos.Count -gt 0) {
        $tipos = @{ 101 = 'programa'; 102 = 'driver'; 103 = 'servicio' }
        $datos = foreach ($e in $lentos) {
            $d = Get-DatosEvento $e
            $nombre = "$($d['FriendlyName'])"
            if (-not $nombre) { $nombre = "$($d['Name'])" }
            $t = 0
            [void][int]::TryParse("$($d['DegradationTime'])", [ref]$t)
            if ($nombre) { [pscustomobject]@{ Nombre = ("{0} ({1})" -f $nombre, $tipos[$e.Id]); Tiempo = $t } }
        }
        $top = @($datos | Group-Object -Property Nombre | ForEach-Object {
                [pscustomobject]@{ Nombre = $_.Name; Veces = $_.Count; Promedio = [math]::Round((($_.Group | Measure-Object -Property Tiempo -Average).Average) / 1000, 1) }
            } | Sort-Object -Property Promedio -Descending | Select-Object -First 5)
        if ($top.Count -gt 0) {
            $r.Lineas.Add('Lo que más retrasa el arranque:')
            foreach ($x in $top) { $r.Lineas.Add(("   {0}: +{1} s ({2} vez/veces)" -f $x.Nombre, $x.Promedio, $x.Veces)) }
        }
    }
    return $r
}

function Get-EstadoActualizaciones {
    $r = Nuevo-Estado
    $proveedor = @('Microsoft-Windows-WindowsUpdateClient')
    $instaladas = @(Get-EventosSeguro -Log 'System' -Proveedores $proveedor -Ids @(19) -Desde ((Get-Date).AddDays(-90)) | Sort-Object -Property TimeCreated -Descending)
    $dias = $null
    if ($instaladas.Count -gt 0) {
        $d = Get-DatosEvento $instaladas[0]
        $dias = [int]((Get-Date) - $instaladas[0].TimeCreated).TotalDays
        $r.Lineas.Add(("Última actualización instalada: {0} (hace {1} días) - {2}" -f $instaladas[0].TimeCreated.ToString('dd/MM/yyyy'), $dias, $d['updateTitle']))
    }
    else {
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            $dias = [int]((Get-Date) - $hf.InstalledOn).TotalDays
            $r.Lineas.Add(("Última actualización: {0}, hace {1} días" -f $hf.HotFixID, $dias))
        }
        else {
            $r.Lineas.Add('No se encontró la fecha de la última actualización.')
        }
    }
    if ($null -ne $dias -and $dias -gt 45) {
        $r.Problemas.Add((Nuevo-Problema -Texto ("Windows no instala actualizaciones hace {0} días." -f $dias) -Sugerencia 'Reparar Windows Update (opción 5) y buscar actualizaciones.' -Accion '5'))
    }

    $fallidas = @(Get-EventosSeguro -Log 'System' -Proveedores $proveedor -Ids @(20) -Desde ((Get-Date).AddDays(-30)))
    if ($fallidas.Count -gt 0) {
        $grupos = @($fallidas | ForEach-Object {
                $d = Get-DatosEvento $_
                [pscustomobject]@{ Titulo = "$($d['updateTitle'])"; Codigo = "$($d['errorCode'])" }
            } | Group-Object -Property Titulo)
        foreach ($g in ($grupos | Select-Object -First 5)) {
            $codigo = $g.Group[0].Codigo
            $r.Lineas.Add(("Falló: {0} | error {1} ({2} vez/veces): {3}" -f $g.Name, $codigo, $g.Count, (Get-DescripcionErrorWU $codigo)))
        }
        $r.Problemas.Add((Nuevo-Problema -Texto ("{0} actualización(es) fallaron en los últimos 30 días." -f $grupos.Count) -Sugerencia 'Reparar Windows Update (opción 5); si el error es de archivos dañados, también DISM + SFC (opción 2).' -Accion '5'))
    }
    else {
        $r.Lineas.Add('Sin actualizaciones fallidas en 30 días.')
    }
    return $r
}

function Get-EstadoLicencia {
    $r = Nuevo-Estado
    $estados = @{ 0 = 'sin licencia'; 1 = 'ACTIVADO'; 2 = 'período de gracia'; 3 = 'período de gracia'; 4 = 'no genuino'; 5 = 'NO ACTIVADO (notificación)'; 6 = 'período de gracia extendido' }
    try {
        $win = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Where-Object { $_.Name -match 'Windows' } | Select-Object -First 1
        if ($win) {
            $txt = $estados[[int]$win.LicenseStatus]
            $r.Lineas.Add(("Windows: {0} | {1} | clave terminada en {2}" -f $txt, $win.Description, $win.PartialProductKey))
            if ([int]$win.LicenseStatus -ne 1) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("Windows NO está activado ({0})." -f $txt) -Sugerencia 'Activar Windows en Configuración > Sistema > Activación (si hay clave en la BIOS, Windows la usa sola al conectarse a internet).'))
            }
        }
    }
    catch {
        $r.Lineas.Add('No se pudo consultar la activación de Windows.')
    }
    try {
        $clave = "$((Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey)"
        if ($clave.Length -ge 5) {
            $r.Lineas.Add(("Clave original de Windows grabada en la BIOS: termina en {0}" -f $clave.Substring($clave.Length - 5)))
        }
    }
    catch { }
    try {
        $office = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
        foreach ($o in $office) {
            $txt = $estados[[int]$o.LicenseStatus]
            $r.Lineas.Add(("Office: {0} - {1}" -f $o.Name, $txt))
            if ([int]$o.LicenseStatus -ne 1) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("Office no está activado ({0})." -f $o.Name) -Sugerencia 'Iniciar sesión en Office con la cuenta de la licencia o activar con la clave del producto.'))
            }
        }
        if ($office.Count -eq 0) { $r.Lineas.Add('Office: sin licencias por clave (las de Microsoft 365 dependen de la cuenta del usuario).') }
    }
    catch { }
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        if ($vol -and [int]$vol.ProtectionStatus -eq 1) {
            $r.Lineas.Add('BitLocker: ACTIVO en la unidad del sistema.')
            $r.Problemas.Add((Nuevo-Problema -Texto 'BitLocker está activo: antes de tocar la BIOS, el disco o restablecer Windows, tenga a mano la clave de recuperación.' -Sugerencia 'Ver la clave en Seguridad > "Clave de recuperación de BitLocker" o en https://aka.ms/myrecoverykey (cuenta Microsoft).' -Info))
        }
        else {
            $r.Lineas.Add('BitLocker: no activo en la unidad del sistema.')
        }
    }
    catch {
        $r.Lineas.Add('BitLocker: no disponible en esta edición de Windows.')
    }
    return $r
}

function Get-EstadoSeguridad {
    $r = Nuevo-Estado
    try {
        $perfilesFw = @(Get-NetFirewallProfile -ErrorAction Stop)
        $r.Lineas.Add(("Firewall: {0}" -f (($perfilesFw | ForEach-Object { '{0}={1}' -f $_.Name, $_.Enabled }) -join ', ')))
        $apagados = @($perfilesFw | Where-Object { "$($_.Enabled)" -eq 'False' })
        if ($apagados.Count -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("El firewall está APAGADO en: {0}." -f (($apagados | ForEach-Object { $_.Name }) -join ', ')) -Sugerencia 'Activar el firewall (Seguridad > "Activar firewall").' -Critica -Accion 'FW'))
        }
    }
    catch { }

    $uac = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
    if ($null -ne $uac -and [int]$uac -eq 0) {
        $r.Problemas.Add((Nuevo-Problema -Texto 'El Control de cuentas de usuario (UAC) está DESACTIVADO.' -Sugerencia 'Activarlo en Panel de control > Cuentas de usuario > Cambiar configuración de Control de cuentas (requiere reiniciar).' -Critica))
    }
    else {
        $r.Lineas.Add('Control de cuentas de usuario (UAC): activo.')
    }

    $ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    if ($ts -and [int]$ts.fDenyTSConnections -eq 0) {
        $nla = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).UserAuthentication
        if ([int]$nla -eq 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto 'Escritorio remoto está activado SIN autenticación a nivel de red (NLA).' -Sugerencia 'Activar NLA en Configuración > Sistema > Escritorio remoto, o desactivarlo si no se usa.' -Critica))
        }
        else {
            $r.Problemas.Add((Nuevo-Problema -Texto 'Escritorio remoto está activado.' -Sugerencia 'Si no se usa, desactivarlo; nunca abrir el puerto 3389 en el router.' -Info))
        }
    }
    else {
        $r.Lineas.Add('Escritorio remoto: desactivado.')
    }

    try {
        $adm = Get-LocalUser -ErrorAction Stop | Where-Object { "$($_.SID)" -like '*-500' } | Select-Object -First 1
        if ($adm -and $adm.Enabled) {
            $r.Problemas.Add((Nuevo-Problema -Texto 'La cuenta "Administrador" integrada de Windows está habilitada.' -Sugerencia 'Deshabilitarla si no se usa (lusrmgr.msc) o ponerle una contraseña fuerte.'))
        }
        $miembros = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.Name)" })
        $r.Lineas.Add(("Administradores del equipo: {0}" -f ($miembros -join ', ')))
    }
    catch { }

    $hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $entradas = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($entradas.Count -gt 0) {
        $r.Lineas.Add(("Archivo hosts: {0} entrada(s): {1}" -f $entradas.Count, (($entradas | Select-Object -First 5) -join ' | ')))
        $r.Problemas.Add((Nuevo-Problema -Texto ("El archivo hosts tiene {0} entrada(s) personalizada(s)." -f $entradas.Count) -Sugerencia 'Si no es un equipo de empresa que lo use, restablecerlo (Red > "Quitar proxy y restablecer hosts"): el malware lo usa para bloquear el antivirus o redirigir páginas.'))
    }
    else {
        $r.Lineas.Add('Archivo hosts: limpio.')
    }

    try {
        $inicio = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
        $patron = '\\AppData\\Local\\Temp\\|\\Windows\\Temp\\|\\AppData\\Roaming\\[^\\]+\.(exe|vbs|js|bat|cmd)|\\Users\\Public\\|wscript|mshta|powershell.*-e(nc|ncodedcommand)? '
        $sospechosos = @($inicio | Where-Object { "$($_.Command)" -match $patron })
        foreach ($s in $sospechosos) { $r.Lineas.Add(("Inicio sospechoso: {0} -> {1}" -f $s.Name, $s.Command)) }
        if ($sospechosos.Count -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("Hay {0} programa(s) de inicio en ubicaciones sospechosas." -f $sospechosos.Count) -Sugerencia 'Escaneo completo o sin conexión de Microsoft Defender (Seguridad).' -Critica -Accion 'SCAN'))
        }
    }
    catch { }

    try {
        $amenazas = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge (Get-Date).AddDays(-30) })
        if ($amenazas.Count -gt 0) {
            $nombres = @{}
            foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $nombres["$($t.ThreatID)"] = $t.ThreatName }
            foreach ($a in ($amenazas | Select-Object -First 5)) {
                $r.Lineas.Add(("Amenaza del {0}: {1}" -f $a.InitialDetectionTime.ToString('dd/MM/yyyy'), $nombres["$($a.ThreatID)"]))
            }
            $r.Problemas.Add((Nuevo-Problema -Texto ("Microsoft Defender detectó {0} amenaza(s) en los últimos 30 días." -f $amenazas.Count) -Sugerencia 'Escaneo completo y luego sin conexión; cambiar las contraseñas si pudo haber robo de datos.' -Critica -Accion 'SCAN'))
        }
        else {
            $r.Lineas.Add('Microsoft Defender: sin amenazas en 30 días.')
        }
    }
    catch { }

    foreach ($pol in @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge')) {
        if (Test-Path -Path $pol) {
            $r.Lineas.Add("Políticas de navegador configuradas: $pol")
            $r.Problemas.Add((Nuevo-Problema -Texto 'Hay políticas de navegador configuradas.' -Sugerencia 'Normal en empresas; en un equipo personal puede ser adware (página de inicio o extensiones forzadas).' -Info))
        }
    }
    return $r
}

function Get-EstadoConexion {
    $r = Nuevo-Estado
    $perfil = Get-PerfilUsuarioActivo
    try {
        $salida = @(& (Get-RutaSistema 'netsh.exe') wlan show interfaces 2>$null)
        $ssid = ''; $senal = $null; $radio = ''
        $velocidades = New-Object System.Collections.Generic.List[double]
        foreach ($l in $salida) {
            if ($l -match '^\s*SSID\s*:\s*(.+)$') { $ssid = $Matches[1].Trim() }
            elseif ($l -match ':\s*(\d{1,3})\s*%\s*$') { $senal = [int]$Matches[1] }
            elseif ($l -match '\(Mbps\)\s*:\s*([\d\.,]+)') { $velocidades.Add([double]($Matches[1] -replace ',', '.')) }
            elseif ($l -match ':\s*(802\.11\S*)') { $radio = $Matches[1] }
        }
        if ($ssid -and $null -ne $senal) {
            $vel = 0
            if ($velocidades.Count -gt 0) { $vel = ($velocidades | Measure-Object -Maximum).Maximum }
            $r.Lineas.Add(("WiFi: {0} | señal {1} % | {2} | velocidad de enlace {3} Mbps" -f $ssid, $senal, $radio, $vel))
            if ($senal -lt 40) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("La señal WiFi es débil ({0} %)." -f $senal) -Sugerencia 'Acercar el equipo al router, usar un repetidor o cable de red: con señal débil la conexión se corta y va lenta.'))
            }
            if ($vel -gt 0 -and $vel -lt 20) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("La velocidad de enlace WiFi es baja ({0} Mbps)." -f $vel) -Sugerencia 'Acercarse al router, usar la red de 5 GHz o actualizar el driver WiFi.'))
            }
        }
        else {
            $r.Lineas.Add('WiFi: no conectado (o el equipo usa cable).')
        }
    }
    catch { }

    $is = Get-ItemProperty -Path "$($perfil.Registro)\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    $hayProxy = $false
    if ($is -and [int]$is.ProxyEnable -eq 1 -and $is.ProxyServer) {
        $hayProxy = $true
        $r.Problemas.Add((Nuevo-Problema -Texto ("Hay un proxy configurado: {0}." -f $is.ProxyServer) -Sugerencia 'Si el equipo no es de una empresa que use proxy, quitarlo (Red > "Quitar proxy y restablecer hosts"): un proxy falso causa "sin internet" y es típico de malware.'))
    }
    if ($is -and $is.AutoConfigURL) {
        $hayProxy = $true
        $r.Problemas.Add((Nuevo-Problema -Texto ("Hay un script de configuración de proxy: {0}." -f $is.AutoConfigURL) -Sugerencia 'Si no es de la empresa, quitarlo (Red > "Quitar proxy y restablecer hosts").'))
    }
    if (-not $hayProxy) { $r.Lineas.Add('Proxy: no configurado.') }

    $vpn = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            "$($_.Status)" -eq 'Up' -and "$($_.InterfaceDescription) $($_.Name)" -match 'VPN|TAP-|WireGuard|Forti|AnyConnect|Juniper|GlobalProtect|PANGP|Sophos|OpenVPN|NordLynx|Wintun'
        })
    foreach ($v in $vpn) { $r.Lineas.Add(("VPN conectada: {0} ({1})" -f $v.Name, $v.InterfaceDescription)) }
    if ($vpn.Count -gt 0) {
        $r.Problemas.Add((Nuevo-Problema -Texto 'Hay una VPN conectada.' -Sugerencia 'Si hay problemas de internet o de acceso a la red local, probar desconectando la VPN.' -Info))
    }
    return $r
}

function Get-EstadoVideoDrivers {
    $r = Nuevo-Estado
    try {
        foreach ($v in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
            $fecha = ''
            if ($v.DriverDate) { $fecha = ([datetime]$v.DriverDate).ToString('dd/MM/yyyy') }
            $r.Lineas.Add(("Video: {0} | driver {1} ({2}) | {3}x{4}" -f $v.Name, $v.DriverVersion, $fecha, $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution))
            if ("$($v.Name)" -match 'Basic Display|Basic Render|sico de Microsoft') {
                $r.Problemas.Add((Nuevo-Problema -Texto 'La tarjeta de video usa el driver BÁSICO de Microsoft (sin aceleración).' -Sugerencia 'Instalar el driver de video (Intel, AMD o NVIDIA) desde la web del fabricante del equipo: sin él la pantalla va lenta y no ajusta la resolución.' -Critica))
            }
        }
    }
    catch { }
    try {
        $limite = (Get-Date).AddYears(-5)
        $clases = @('DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH', 'HDC', 'SCSIADAPTER', 'USB', 'SYSTEM')
        $viejos = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
                $_.DriverDate -and $_.DriverDate -lt $limite -and $_.DriverDate.Year -ge 2000 -and
                "$($_.DriverProviderName)" -notmatch 'Microsoft' -and ($clases -contains "$($_.DeviceClass)")
            })
        if ($viejos.Count -gt 0) {
            foreach ($x in ($viejos | Select-Object -First 6)) {
                $r.Lineas.Add(("Driver antiguo: {0} | {1} | {2}" -f $x.DeviceName, $x.DriverProviderName, $x.DriverDate.ToString('dd/MM/yyyy')))
            }
            $r.Problemas.Add((Nuevo-Problema -Texto ("Hay {0} driver(s) de más de 5 años." -f $viejos.Count) -Sugerencia 'Actualizar con la herramienta del fabricante (Lenovo Vantage, Dell SupportAssist, HP Support Assistant) o desde su web.' -Info))
        }
        else {
            $r.Lineas.Add('No hay drivers de más de 5 años.')
        }
    }
    catch { }
    return $r
}

function Get-EstadoPerfil {
    $r = Nuevo-Estado
    $perfil = Get-PerfilUsuarioActivo
    $r.Lineas.Add(("Perfil: {0} en {1}" -f $perfil.Usuario, $perfil.Ruta))
    $consejo = 'Perfil dañado: NO borrar nada. Use Sistema > "Reparar perfil de usuario" (respalda el registro y restaura la clave .bak) o cree un usuario nuevo y copie los datos.'
    if ("$($perfil.Ruta)" -match '\\TEMP(\.|$)') {
        $r.Problemas.Add((Nuevo-Problema -Texto 'El usuario está usando un PERFIL TEMPORAL (no ve su escritorio ni sus archivos).' -Sugerencia $consejo -Critica))
    }
    $bak = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '*.bak' })
    if ($bak.Count -gt 0) {
        $r.Problemas.Add((Nuevo-Problema -Texto ("Hay {0} perfil(es) marcados como dañados (.bak) en el registro." -f $bak.Count) -Sugerencia $consejo -Critica))
    }
    $eventos = @(Get-EventosSeguro -Log 'Application' -Proveedores @('Microsoft-Windows-User Profiles Service') -Ids @(1500, 1502, 1508, 1511, 1515) -Desde ((Get-Date).AddDays(-30)))
    if ($eventos.Count -gt 0) {
        $r.Lineas.Add(("Errores del servicio de perfiles (30 días): {0}" -f $eventos.Count))
        if (@($eventos | Where-Object { $_.Id -eq 1511 -or $_.Id -eq 1515 }).Count -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto 'Windows cargó un perfil temporal en los últimos 30 días.' -Sugerencia $consejo))
        }
    }
    else {
        $r.Lineas.Add('Sin errores del servicio de perfiles.')
    }
    return $r
}

function Get-EstadoPrivacidad {
    $r = Nuevo-Estado
    $perfil = Get-PerfilUsuarioActivo
    $base = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    foreach ($cap in @(@{ Clave = 'microphone'; Nombre = 'micrófono'; Politica = 'LetAppsAccessMicrophone' }, @{ Clave = 'webcam'; Nombre = 'cámara'; Politica = 'LetAppsAccessCamera' })) {
        $pol = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue).($cap.Politica)
        if ($null -ne $pol -and [int]$pol -eq 2) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("Una política de la empresa BLOQUEA el {0}." -f $cap.Nombre) -Sugerencia 'Lo debe cambiar el administrador de la red (directiva de grupo o Intune).' -Critica))
            continue
        }
        $bloqueos = New-Object System.Collections.Generic.List[string]
        if ((Get-ItemProperty -Path ("HKLM:\{0}\{1}" -f $base, $cap.Clave) -ErrorAction SilentlyContinue).Value -eq 'Deny') { $bloqueos.Add('todo el equipo') }
        if ((Get-ItemProperty -Path ("{0}\{1}\{2}" -f $perfil.Registro, $base, $cap.Clave) -ErrorAction SilentlyContinue).Value -eq 'Deny') { $bloqueos.Add('el usuario') }
        if ((Get-ItemProperty -Path ("{0}\{1}\{2}\NonPackaged" -f $perfil.Registro, $base, $cap.Clave) -ErrorAction SilentlyContinue).Value -eq 'Deny') { $bloqueos.Add('las aplicaciones de escritorio (Zoom, Teams clásico, navegadores)') }
        if ($bloqueos.Count -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("El acceso al {0} está BLOQUEADO para {1} (Privacidad)." -f $cap.Nombre, ($bloqueos -join ', ')) -Sugerencia 'Reparar micrófono y cámara: vuelve a permitir el acceso.' -Accion 'PRIV'))
        }
        else {
            $r.Lineas.Add(("Privacidad del {0}: permitido." -f $cap.Nombre))
        }
    }
    if (Initialize-CoreAudio) {
        try {
            $v = [int][math]::Round([SoporteAudio2]::MicVolume * 100)
            $m = [bool][SoporteAudio2]::MicMute
            $txt = 'no'; if ($m) { $txt = 'SÍ' }
            $r.Lineas.Add(("Micrófono predeterminado: volumen {0} % | silenciado: {1}" -f $v, $txt))
            if ($m) { $r.Problemas.Add((Nuevo-Problema -Texto 'El micrófono está SILENCIADO.' -Sugerencia 'Reparar micrófono y cámara: quita el silencio.' -Accion 'PRIV')) }
            if ($v -lt 10) { $r.Problemas.Add((Nuevo-Problema -Texto ("El volumen del micrófono está en {0} %." -f $v) -Sugerencia 'Reparar micrófono y cámara: lo sube al 80 %.' -Accion 'PRIV')) }
        }
        catch {
            $r.Lineas.Add('No hay un micrófono predeterminado.')
        }
    }
    $camaras = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { "$($_.Class)" -eq 'Camera' -or "$($_.Class)" -eq 'Image' })
    foreach ($c in $camaras) {
        $codigo = [int]$c.ConfigManagerErrorCode
        $r.Lineas.Add(("Cámara: {0} - {1}" -f $c.FriendlyName, (Get-DescripcionCodigoPnp $codigo)))
        if ($codigo -eq 22) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("La cámara '{0}' está DESHABILITADA." -f $c.FriendlyName) -Sugerencia 'Reparar micrófono y cámara: la habilita.' -Accion 'PRIV'))
        }
        elseif ($codigo -ne 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("La cámara '{0}' tiene un error ({1})." -f $c.FriendlyName, (Get-DescripcionCodigoPnp $codigo)) -Sugerencia 'Reinstalar el driver de la cámara desde el Administrador de dispositivos o la web del fabricante.'))
        }
    }
    if ($camaras.Count -eq 0) { $r.Lineas.Add('No se detectó cámara (en laptops, revisar la tecla o el interruptor de la cámara).') }
    return $r
}

function Get-EstadoImpresoras {
    $r = Nuevo-Estado
    try {
        $impresoras = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop)
        $puertos = @{}
        foreach ($p in @(Get-PrinterPort -ErrorAction SilentlyContinue)) { $puertos["$($p.Name)"] = $p }
        foreach ($i in $impresoras) {
            $notas = New-Object System.Collections.Generic.List[string]
            if ($i.Default) { $notas.Add('predeterminada') }
            if ($i.WorkOffline) { $notas.Add('SIN CONEXIÓN') }
            $trabajos = 0
            if (-not $i.Network) { $trabajos = @(Get-PrintJob -PrinterName $i.Name -ErrorAction SilentlyContinue).Count }
            $r.Lineas.Add(("Impresora: {0} | puerto {1} | en cola: {2} {3}" -f $i.Name, $i.PortName, $trabajos, ($notas -join ', ')))
            if ($i.WorkOffline) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("La impresora '{0}' está en modo SIN CONEXIÓN." -f $i.Name) -Sugerencia 'Reparar impresora: la vuelve a poner en línea.' -Accion '6'))
            }
            if ($trabajos -ge 5) {
                $r.Problemas.Add((Nuevo-Problema -Texto ("La impresora '{0}' tiene {1} trabajos atascados." -f $i.Name, $trabajos) -Sugerencia 'Reparar impresora: vacía la cola.' -Accion '6'))
            }
            $puerto = $null
            if ($i.PortName) { $puerto = $puertos["$($i.PortName)"] }
            if ($puerto -and $puerto.PrinterHostAddress) {
                if (-not (Test-Connection -ComputerName $puerto.PrinterHostAddress -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                    $r.Problemas.Add((Nuevo-Problema -Texto ("La impresora '{0}' no responde en la red ({1})." -f $i.Name, $puerto.PrinterHostAddress) -Sugerencia 'Revisar que esté encendida y en la misma red; si cambió de IP, actualizar el puerto en Propiedades de impresora > Puertos.'))
                }
            }
        }
        if ($impresoras.Count -eq 0) { $r.Lineas.Add('No hay impresoras instaladas.') }
    }
    catch {
        $r.Lineas.Add('No se pudo consultar las impresoras.')
    }
    return $r
}

#endregion

#region ==================== REPARACIONES AVANZADAS (PAQUETE B) ====================

function Iniciar-ExploradorUsuario {
    $explorer = Join-Path $env:windir 'explorer.exe'
    if (Start-ComoUsuario -Programa $explorer) { return }
    try { Start-Process -FilePath $explorer -ErrorAction Stop } catch { Write-Log "No se pudo iniciar el Explorador: $($_.Exception.Message)" 'ERROR' }
}

function Invoke-ScriptComoUsuario {
    # Guarda un script y lo ejecuta oculto en la sesión del usuario (sin permisos de administrador).
    param([string]$Contenido, [string]$Nombre = 'tarea')
    $dir = Join-Path $Script:BaseLocal 'Temp'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $archivo = Join-Path $dir ('{0}_{1}.ps1' -f $Nombre, (Get-Date -Format 'yyyyMMddHHmmss'))
    [System.IO.File]::WriteAllText($archivo, $Contenido, (New-Object System.Text.UTF8Encoding($true)))
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return (Start-ComoUsuario -Programa $ps -Argumentos ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $archivo))
}

function Cerrar-Procesos {
    param([string[]]$Nombres, [string]$Descripcion)
    $procesos = @(Get-Process -Name $Nombres -ErrorAction SilentlyContinue)
    if ($procesos.Count -eq 0) { return $true }
    if (-not (Confirmar ("Se cerrará {0}. ¿Continuar?" -f $Descripcion))) { return $false }
    foreach ($p in $procesos) { try { $null = $p.CloseMainWindow() } catch { } }
    Start-Sleep -Seconds 3
    Get-Process -Name $Nombres -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Write-Log "Cerrado: $Descripcion" 'INFO'
    return $true
}

function Reparar-MenuInicio {
    Mostrar-Titulo 'REPARAR MENÚ INICIO Y BÚSQUEDA'
    $null = Iniciar-Servicio 'WSearch' -HabilitarSiDeshabilitado
    try { Set-Service -Name 'WSearch' -StartupType Automatic -ErrorAction Stop } catch { }
    $scriptUsuario = @'
$paquetes = @('Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.Core', 'Microsoft.Windows.Search', 'Microsoft.Windows.Cortana')
foreach ($n in $paquetes) {
    foreach ($p in @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue)) {
        try { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $p.InstallLocation 'AppXManifest.xml') -ErrorAction Stop } catch { }
    }
}
Stop-Process -Name 'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost', 'SearchApp', 'SearchUI' -Force -ErrorAction SilentlyContinue
'@
    Write-Log 'Volviendo a registrar el menú Inicio y la búsqueda para el usuario...' 'INFO'
    $ok = Invoke-ScriptComoUsuario -Contenido $scriptUsuario -Nombre 'menu_inicio'
    Start-Sleep -Seconds 15
    if (Confirmar '¿Reconstruir también el índice de búsqueda? (útil si no encuentra archivos; termina en segundo plano en unas horas)') {
        try {
            $null = Detener-Servicio 'WSearch'
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name 'SetupCompletedSuccessfully' -Value 0 -Type DWord -ErrorAction Stop
            $null = Iniciar-Servicio 'WSearch'
            Write-Log 'El índice de búsqueda se está reconstruyendo en segundo plano.' 'OK'
        }
        catch {
            Write-Log "No se pudo reconstruir el índice: $($_.Exception.Message)" 'ADVERTENCIA'
        }
    }
    Write-Log 'Si el menú Inicio sigue sin abrir: Reparar archivos de Windows (DISM + SFC) y reiniciar.' 'INFO'
    return $ok
}

function Reparar-CacheIconos {
    Mostrar-Titulo 'RECONSTRUIR ICONOS Y MINIATURAS'
    Write-Host '    Se cerrará el Explorador (barra de tareas y carpetas abiertas) por unos segundos.' -ForegroundColor Yellow
    if (-not (Confirmar '¿Continuar?')) { return $false }
    $perfil = Get-PerfilUsuarioActivo
    $la = $perfil.LocalAppData
    try { Stop-Process -Name 'explorer' -Force -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 2
    $archivos = @()
    $archivos += @(Get-Item -LiteralPath (Join-Path $la 'IconCache.db') -Force -ErrorAction SilentlyContinue)
    $archivos += @(Get-ChildItem -LiteralPath (Join-Path $la 'Microsoft\Windows\Explorer') -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'iconcache_*.db' -or $_.Name -like 'thumbcache_*.db' })
    $borrados = 0
    foreach ($a in $archivos) {
        if ($a) { try { Remove-Item -LiteralPath $a.FullName -Force -ErrorAction Stop; $borrados++ } catch { } }
    }
    Write-Log "Archivos de caché de iconos borrados: $borrados" 'OK'
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) { Iniciar-ExploradorUsuario }
    Write-Log 'Si algunos iconos siguen mal, reinicie el equipo.' 'INFO'
    return $true
}

function Reparar-MicrofonoCamara {
    param([switch]$Automatico)
    Mostrar-Titulo 'REPARAR MICRÓFONO Y CÁMARA'
    $estado = Get-EstadoPrivacidad
    Mostrar-EstadoComponente $estado
    if (-not $Automatico) {
        if (-not (Confirmar '¿Aplicar la reparación de micrófono y cámara?')) { return $false }
    }
    $perfil = Get-PerfilUsuarioActivo
    $base = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
    foreach ($cap in @('microphone', 'webcam')) {
        foreach ($ruta in @(("HKLM:\{0}\{1}" -f $base, $cap), ("{0}\{1}\{2}" -f $perfil.Registro, $base, $cap), ("{0}\{1}\{2}\NonPackaged" -f $perfil.Registro, $base, $cap))) {
            try {
                if (-not (Test-Path -Path $ruta)) { New-Item -Path $ruta -Force | Out-Null }
                Set-ItemProperty -Path $ruta -Name 'Value' -Value 'Allow' -Type String -ErrorAction Stop
            }
            catch {
                Write-Log "No se pudo cambiar el permiso en ${ruta}: $($_.Exception.Message)" 'ADVERTENCIA'
            }
        }
    }
    Write-Log 'Permisos de micrófono y cámara restablecidos a "Permitir".' 'OK'

    $deshabilitados = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            ("$($_.Class)" -eq 'Camera' -or "$($_.Class)" -eq 'Image' -or "$($_.Class)" -eq 'AudioEndpoint') -and [int]$_.ConfigManagerErrorCode -eq 22
        })
    foreach ($d in $deshabilitados) {
        try {
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Log "Dispositivo habilitado: $($d.FriendlyName)" 'OK'
        }
        catch {
            Write-Log "No se pudo habilitar $($d.FriendlyName): $($_.Exception.Message)" 'ADVERTENCIA'
        }
    }
    if (Initialize-CoreAudio) {
        try {
            if ([SoporteAudio2]::MicMute) { [SoporteAudio2]::MicMute = $false; Write-Log 'Se quitó el silencio del micrófono.' 'OK' }
            if ([SoporteAudio2]::MicVolume -lt 0.1) { [SoporteAudio2]::MicVolume = 0.8; Write-Log 'Volumen del micrófono ajustado al 80 %.' 'OK' }
        }
        catch {
            Write-Log 'No hay micrófono predeterminado (revisar que esté conectado).' 'ADVERTENCIA'
        }
    }
    Write-Log 'En Teams, Zoom o Meet revise también qué micrófono y cámara están elegidos en su configuración.' 'INFO'
    if (-not $Automatico -and (Confirmar '¿Abrir la configuración de privacidad del micrófono del usuario?')) {
        $null = Start-ComoUsuario -Programa 'ms-settings:privacy-microphone'
    }
    return $true
}

function Reparar-BluetoothUsb {
    Mostrar-Titulo 'REPARAR BLUETOOTH Y USB'
    Write-Host '    Reinicia Bluetooth, habilita dispositivos deshabilitados y evita que Windows apague el USB para ahorrar energía.' -ForegroundColor DarkGray
    if (-not (Confirmar '¿Continuar?')) { return $false }
    foreach ($s in @('bthserv', 'BthAvctpSvc')) {
        if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
            $null = Iniciar-Servicio $s -HabilitarSiDeshabilitado
            try { Restart-Service -Name $s -Force -ErrorAction Stop; Write-Log "Servicio $s reiniciado." 'OK' } catch { }
        }
    }
    $bt = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { "$($_.Class)" -eq 'Bluetooth' })
    if ($bt.Count -eq 0) {
        Write-Log 'No se detecta adaptador Bluetooth (puede estar apagado por tecla, modo avión o sin driver).' 'ADVERTENCIA'
    }
    foreach ($d in @($bt | Where-Object { [int]$_.ConfigManagerErrorCode -eq 22 })) {
        try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop; Write-Log "Habilitado: $($d.FriendlyName)" 'OK' } catch { }
    }
    $powercfg = Get-RutaSistema 'powercfg.exe'
    $sub = '2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'
    $null = Invoke-Nativo -Archivo $powercfg -Argumentos "/setacvalueindex SCHEME_CURRENT $sub" -Descripcion 'Desactivar suspensión selectiva USB (corriente)'
    $null = Invoke-Nativo -Archivo $powercfg -Argumentos "/setdcvalueindex SCHEME_CURRENT $sub" -Descripcion 'Desactivar suspensión selectiva USB (batería)'
    $null = Invoke-Nativo -Archivo $powercfg -Argumentos '/setactive SCHEME_CURRENT' -Descripcion 'Aplicar plan de energía'
    $cambiados = 0
    try {
        foreach ($e in @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSPower_DeviceEnable -ErrorAction Stop | Where-Object { $_.InstanceName -match '^USB\\' -and $_.Enable })) {
            try { Set-CimInstance -InputObject $e -Property @{ Enable = $false } -ErrorAction Stop; $cambiados++ } catch { }
        }
    }
    catch { }
    Write-Log "Dispositivos USB a los que se quitó el ahorro de energía: $cambiados" 'OK'
    if ((Get-BuildWindows) -ge 19041) {
        $null = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos '/scan-devices' -Descripcion 'Buscar cambios de hardware'
    }
    return $true
}

function Limpiar-Navegadores {
    Mostrar-Titulo 'LIMPIAR CACHÉ DE NAVEGADORES'
    Write-Host '    Solo se borra la caché: NO se borran contraseñas, historial, favoritos ni sesiones.' -ForegroundColor DarkGray
    if (-not (Cerrar-Procesos -Nombres @('chrome', 'msedge', 'firefox', 'brave') -Descripcion 'los navegadores (Chrome, Edge, Firefox, Brave)')) { return $false }
    $la = (Get-PerfilUsuarioActivo).LocalAppData
    $carpetas = New-Object System.Collections.Generic.List[string]
    foreach ($base in @('Google\Chrome\User Data', 'Microsoft\Edge\User Data', 'BraveSoftware\Brave-Browser\User Data')) {
        foreach ($p in @(Get-ChildItem -LiteralPath (Join-Path $la $base) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage')) { $carpetas.Add((Join-Path $p.FullName $sub)) }
        }
    }
    foreach ($ff in @(Get-ChildItem -LiteralPath (Join-Path $la 'Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue)) {
        $carpetas.Add((Join-Path $ff.FullName 'cache2'))
    }
    $antes = [long]0
    foreach ($c in $carpetas) { $antes += Get-TamanoCarpeta $c }
    foreach ($c in $carpetas) { Limpiar-Carpeta $c }
    $despues = [long]0
    foreach ($c in $carpetas) { $despues += Get-TamanoCarpeta $c }
    Write-Log ("Caché de navegadores limpiada: {0} MB liberados." -f [math]::Round(($antes - $despues) / 1MB)) 'OK'
    return $true
}

function Reparar-ProxyHosts {
    Mostrar-Titulo 'QUITAR PROXY Y RESTABLECER HOSTS'
    $perfil = Get-PerfilUsuarioActivo
    $clave = "$($perfil.Registro)\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $is = Get-ItemProperty -Path $clave -ErrorAction SilentlyContinue
    if ($is -and (([int]$is.ProxyEnable -eq 1) -or $is.AutoConfigURL)) {
        Write-Host ("    Proxy: {0}  |  Script: {1}" -f $is.ProxyServer, $is.AutoConfigURL) -ForegroundColor Yellow
        Write-Host '    Si el equipo es de una empresa que usa proxy, NO lo quite.' -ForegroundColor DarkGray
        if (Confirmar '¿Quitar el proxy del usuario?') {
            $respaldo = Join-Path $Script:DirReportes ('proxy_{0}.reg' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            $null = Invoke-Nativo -Archivo (Get-RutaSistema 'reg.exe') -Argumentos ('export "{0}" "{1}" /y' -f ($clave -replace '^Registry::', ''), $respaldo) -Descripcion 'Respaldo de la configuración de proxy'
            Set-ItemProperty -Path $clave -Name 'ProxyEnable' -Value 0 -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $clave -Name 'ProxyServer' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $clave -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
            Write-Log "Proxy del usuario quitado (respaldo: $respaldo)." 'OK'
        }
    }
    else {
        Write-Log 'El usuario no tiene proxy configurado.' 'INFO'
    }
    $null = Invoke-Nativo -Archivo (Get-RutaSistema 'netsh.exe') -Argumentos 'winhttp reset proxy' -Descripcion 'Restablecer proxy del sistema (WinHTTP)'

    $hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $entradas = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($entradas.Count -gt 0) {
        Write-Host '    Entradas en el archivo hosts:' -ForegroundColor Yellow
        foreach ($e in ($entradas | Select-Object -First 15)) { Write-Host "      $e" }
        if (Confirmar '¿Restablecer el archivo hosts al original de Windows? (se guarda una copia)') {
            try {
                Copy-Item -LiteralPath $hosts -Destination (Join-Path $Script:DirReportes ('hosts_{0}.bak' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) -Force -ErrorAction Stop
                $original = @(
                    '# Copyright (c) 1993-2009 Microsoft Corp.',
                    '#',
                    '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.',
                    '#',
                    '# localhost name resolution is handled within DNS itself.',
                    '#       127.0.0.1       localhost',
                    '#       ::1             localhost'
                )
                [System.IO.File]::WriteAllLines($hosts, $original, (New-Object System.Text.ASCIIEncoding))
                Write-Log 'Archivo hosts restablecido (copia en la carpeta Reportes).' 'OK'
            }
            catch {
                Write-Log "No se pudo restablecer hosts (el antivirus puede bloquearlo): $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    else {
        Write-Log 'El archivo hosts está limpio.' 'INFO'
    }
    $null = Invoke-Nativo -Archivo (Get-RutaSistema 'ipconfig.exe') -Argumentos '/flushdns' -Descripcion 'Limpiar caché DNS'
    return $true
}

function Restablecer-OneDrive {
    Mostrar-Titulo 'RESTABLECER ONEDRIVE'
    $la = (Get-PerfilUsuarioActivo).LocalAppData
    $exe = @((Join-Path $la 'Microsoft\OneDrive\OneDrive.exe'), (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $exe) {
        Write-Log 'OneDrive no está instalado para este usuario.' 'ADVERTENCIA'
        return $false
    }
    Write-Host '    OneDrive se reinicia y vuelve a revisar todos los archivos. NO se borra nada.' -ForegroundColor DarkGray
    if (-not (Confirmar '¿Restablecer OneDrive?')) { return $false }
    $null = Start-ComoUsuario -Programa $exe -Argumentos '/reset'
    Write-Log 'Esperando a que OneDrive se restablezca (25 segundos)...' 'INFO'
    Start-Sleep -Seconds 25
    if (-not (Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)) {
        $null = Start-ComoUsuario -Programa $exe
    }
    Write-Log 'OneDrive restablecido. La sincronización puede tardar según la cantidad de archivos.' 'OK'
    return $true
}

function Limpiar-CacheTeams {
    Mostrar-Titulo 'LIMPIAR CACHÉ DE TEAMS'
    if (-not (Cerrar-Procesos -Nombres @('ms-teams', 'Teams', 'msteams') -Descripcion 'Microsoft Teams')) { return $false }
    $perfil = Get-PerfilUsuarioActivo
    $hecho = $false
    $clasico = Join-Path $perfil.Ruta 'AppData\Roaming\Microsoft\Teams'
    if (Test-Path -LiteralPath $clasico) {
        foreach ($sub in @('Cache', 'blob_storage', 'databases', 'GPUCache', 'IndexedDB', 'Local Storage', 'tmp', 'Code Cache', 'Service Worker')) {
            Limpiar-Carpeta (Join-Path $clasico $sub)
        }
        Write-Log 'Caché de Teams clásico limpiada.' 'OK'
        $hecho = $true
    }
    $nuevo = Join-Path $perfil.LocalAppData 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'
    if (Test-Path -LiteralPath $nuevo) {
        Limpiar-Carpeta $nuevo
        Write-Log 'Caché del Teams nuevo limpiada.' 'OK'
        $hecho = $true
    }
    if (-not $hecho) {
        Write-Log 'No se encontró Teams para este usuario.' 'ADVERTENCIA'
        return $false
    }
    Write-Log 'Abra Teams de nuevo: la primera vez tarda un poco más y puede pedir iniciar sesión.' 'INFO'
    return $true
}

function Invoke-EscaneoDefender {
    param([ValidateSet('Rapido', 'Completo', 'SinConexion')][string]$Tipo = 'Rapido')
    Mostrar-Titulo 'ESCANEO DE MICROSOFT DEFENDER'
    try { $mp = Get-MpComputerStatus -ErrorAction Stop }
    catch { Write-Log 'Microsoft Defender no está disponible: use el antivirus instalado.' 'ADVERTENCIA'; return $false }
    if (-not $mp.AntivirusEnabled) {
        Write-Log 'Microsoft Defender no es el antivirus activo (hay otro antivirus instalado). Escanee con ese antivirus.' 'ADVERTENCIA'
        return $false
    }
    if ($Tipo -eq 'Completo') {
        Write-Host '    El escaneo completo tarda entre 1 y 3 horas y el equipo irá más lento mientras tanto.' -ForegroundColor Yellow
        if (-not (Confirmar '¿Iniciar el escaneo completo?')) { return $false }
    }
    if ($Tipo -eq 'SinConexion') {
        Write-Host '    El equipo se REINICIARÁ y Defender escaneará antes de que arranque Windows (unos 15 minutos).' -ForegroundColor Yellow
        Write-Host '    Guarde todo el trabajo. La sesión remota se cortará.' -ForegroundColor Yellow
        if (-not (Confirmar '¿Reiniciar ahora y escanear sin conexión?')) { return $false }
    }
    Write-Log 'Actualizando firmas antes de escanear...' 'INFO'
    try { Update-MpSignature -ErrorAction Stop; Write-Log 'Firmas actualizadas.' 'OK' }
    catch { Write-Log 'No se pudieron actualizar las firmas; se escanea con las actuales.' 'ADVERTENCIA' }
    $inicio = Get-Date
    try {
        switch ($Tipo) {
            'Rapido'      { Write-Log 'Escaneo rápido en curso (5 a 15 minutos)...' 'INFO'; Start-MpScan -ScanType QuickScan -ErrorAction Stop }
            'Completo'    { Write-Log 'Escaneo completo en curso...' 'INFO'; Start-MpScan -ScanType FullScan -ErrorAction Stop }
            'SinConexion' { Write-Log 'Reiniciando para el escaneo sin conexión...' 'ADVERTENCIA'; Start-MpWDOScan -ErrorAction Stop; return $true }
        }
    }
    catch {
        Write-Log "El escaneo falló: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    $nuevas = @()
    try { $nuevas = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge $inicio.AddMinutes(-1) }) } catch { }
    if ($nuevas.Count -gt 0) {
        $nombres = @{}
        foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $nombres["$($t.ThreatID)"] = $t.ThreatName }
        foreach ($n in $nuevas) {
            Write-Log ("Amenaza: {0} | {1}" -f $nombres["$($n.ThreatID)"], (@($n.Resources) | Select-Object -First 1)) 'ERROR'
        }
        Write-Log ("Se encontraron {0} amenaza(s). Defender las pone en cuarentena; revise Seguridad de Windows > Historial de protección." -f $nuevas.Count) 'ADVERTENCIA'
    }
    else {
        Write-Log 'Escaneo terminado: no se encontraron amenazas.' 'OK'
    }
    return $true
}

function Activar-Firewall {
    Mostrar-Titulo 'ACTIVAR FIREWALL'
    try {
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -ErrorAction Stop
        Write-Log 'Firewall de Windows activado en todos los perfiles.' 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo activar el firewall: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Mostrar-ClaveBitLocker {
    Mostrar-Titulo 'CLAVE DE RECUPERACIÓN DE BITLOCKER'
    if (-not (Confirmar '¿Mostrar la clave de recuperación en pantalla? (no se guarda en el log)')) { return $false }
    try {
        $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        if (-not $vol) { Write-Log 'La unidad del sistema no está cifrada con BitLocker.' 'INFO'; return $false }
        $ids = Invoke-CimMethod -InputObject $vol -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]3 } -ErrorAction Stop
        $lista = @($ids.VolumeKeyProtectorID | Where-Object { $_ })
        if ($lista.Count -eq 0) { Write-Log 'La unidad no tiene clave de recuperación numérica.' 'ADVERTENCIA'; return $false }
        foreach ($id in $lista) {
            $num = Invoke-CimMethod -InputObject $vol -MethodName GetKeyProtectorNumericalPassword -Arguments @{ VolumeKeyProtectorID = $id } -ErrorAction Stop
            Write-Host ("    Id de la clave: {0}" -f $id) -ForegroundColor White
            Write-Host ("    Clave de recuperación: {0}" -f $num.NumericalPassword) -ForegroundColor Yellow
        }
        Write-Log 'Se mostró la clave de recuperación de BitLocker en pantalla.' 'INFO' -SoloArchivo
        return $true
    }
    catch {
        Write-Log "No se pudo leer la clave de BitLocker: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Desinstalar-Actualizacion {
    Mostrar-Titulo 'DESINSTALAR UNA ACTUALIZACIÓN'
    Write-Log 'Buscando las actualizaciones instaladas (puede tardar 1 o 2 minutos)...' 'INFO'
    try {
        $paquetes = @(Get-WindowsPackage -Online -ErrorAction Stop | Where-Object {
                "$($_.PackageState)" -eq 'Installed' -and $_.InstallTime -and "$($_.ReleaseType)" -match 'Update|Hotfix'
            } | Sort-Object -Property InstallTime -Descending | Select-Object -First 12)
    }
    catch {
        Write-Log "No se pudo obtener la lista de actualizaciones: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    if ($paquetes.Count -eq 0) { Write-Log 'No se encontraron actualizaciones para desinstalar.' 'INFO'; return $false }
    for ($i = 0; $i -lt $paquetes.Count; $i++) {
        $p = $paquetes[$i]
        $nombre = 'Actualización'
        if ($p.PackageName -match '(KB\d+)') { $nombre = $Matches[1] } elseif ($p.PackageName -match 'RollupFix') { $nombre = 'Actualización acumulativa' }
        Write-Host ("    {0,2}. {1}  {2,-26} {3}" -f ($i + 1), $p.InstallTime.ToString('dd/MM/yyyy'), $nombre, $p.PackageName)
    }
    Write-Host ''
    Write-Host '    Desinstale solo si el problema empezó justo después de esa fecha.' -ForegroundColor Yellow
    $resp = Read-Host '  Número de la actualización a desinstalar (Enter = cancelar)'
    $n = 0
    if (-not [int]::TryParse("$resp", [ref]$n) -or $n -lt 1 -or $n -gt $paquetes.Count) {
        Write-Log 'Desinstalación cancelada.' 'INFO'
        return $false
    }
    $elegido = $paquetes[$n - 1]
    if (-not (Confirmar ("¿Desinstalar {0}? Requiere reiniciar." -f $elegido.PackageName))) { return $false }
    $null = New-PuntoRestauracion
    try {
        Write-Log 'Desinstalando (puede tardar varios minutos)...' 'INFO'
        Remove-WindowsPackage -Online -PackageName $elegido.PackageName -NoRestart -ErrorAction Stop | Out-Null
        Write-Log "Actualización desinstalada: $($elegido.PackageName)" 'OK'
        $Script:RequiereReinicio = $true
        return $true
    }
    catch {
        Write-Log "No se pudo desinstalar: $($_.Exception.Message)" 'ERROR'
        Write-Log 'Alternativa: Configuración > Windows Update > Historial > Desinstalar actualizaciones, o desde el Entorno de recuperación de Windows.' 'INFO'
        return $false
    }
}

function Test-InicioActivo {
    param([string]$ClaveAprobado, [string]$Nombre)
    try {
        $valor = (Get-ItemProperty -Path $ClaveAprobado -ErrorAction Stop).$Nombre
        if ($valor -is [byte[]] -and $valor.Length -gt 0) { return (($valor[0] -band 1) -eq 0) }
    }
    catch { }
    return $true
}

function Get-ProgramasInicio {
    $perfil = Get-PerfilUsuarioActivo
    $aprobados = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $lista = New-Object System.Collections.Generic.List[object]
    $fuentes = @(
        @{ Ruta = "$($perfil.Registro)\Software\Microsoft\Windows\CurrentVersion\Run"; Aprobado = "$($perfil.Registro)\$aprobados\Run"; Ambito = 'usuario' },
        @{ Ruta = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Aprobado = "HKLM:\$aprobados\Run"; Ambito = 'todos' },
        @{ Ruta = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprobado = "HKLM:\$aprobados\Run32"; Ambito = 'todos' }
    )
    foreach ($f in $fuentes) {
        $clave = Get-Item -Path $f.Ruta -ErrorAction SilentlyContinue
        if (-not $clave) { continue }
        foreach ($nombre in $clave.GetValueNames()) {
            if (-not $nombre) { continue }
            $lista.Add([pscustomobject]@{ Tipo = 'Registro'; Nombre = $nombre; Comando = "$($clave.GetValue($nombre))"; Aprobado = $f.Aprobado; Ambito = $f.Ambito; Activo = (Test-InicioActivo $f.Aprobado $nombre); RutaTarea = '' })
        }
    }
    $carpetas = @(
        @{ Ruta = (Join-Path $perfil.Ruta 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'); Aprobado = "$($perfil.Registro)\$aprobados\StartupFolder"; Ambito = 'usuario' },
        @{ Ruta = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Aprobado = "HKLM:\$aprobados\StartupFolder"; Ambito = 'todos' }
    )
    foreach ($c in $carpetas) {
        foreach ($a in @(Get-ChildItem -LiteralPath $c.Ruta -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $lista.Add([pscustomobject]@{ Tipo = 'Carpeta'; Nombre = $a.Name; Comando = $a.FullName; Aprobado = $c.Aprobado; Ambito = $c.Ambito; Activo = (Test-InicioActivo $c.Aprobado $a.Name); RutaTarea = '' })
        }
    }
    # Tareas programadas que se ejecutan al iniciar sesión o al arrancar (Adobe, Google Update, etc.).
    # Se omiten las de Microsoft: son del sistema.
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            if ("$($t.TaskPath)" -like '\Microsoft\*') { continue }
            $alInicio = $false
            foreach ($g in @($t.Triggers)) { if ("$($g.CimClass.CimClassName)" -match 'LogonTrigger|BootTrigger') { $alInicio = $true } }
            if (-not $alInicio) { continue }
            $accion = @($t.Actions)[0]
            $cmd = ("{0} {1}" -f $accion.Execute, $accion.Arguments).Trim()
            $lista.Add([pscustomobject]@{ Tipo = 'Tarea'; Nombre = "$($t.TaskName)"; Comando = $cmd; Aprobado = ''; Ambito = 'tarea programada'; Activo = ("$($t.State)" -ne 'Disabled'); RutaTarea = "$($t.TaskPath)" })
        }
    }
    catch { Write-Log ("No se pudieron leer las tareas programadas de inicio: {0}" -f $_.Exception.Message) 'ADVERTENCIA' -SoloArchivo }
    return $lista.ToArray()
}

function Desactivar-ProgramaInicio {
    # Igual que "Deshabilitar" en Administrador de tareas > Inicio (reversible).
    param($Programa)
    try {
        if ($Programa.Tipo -eq 'Tarea') {
            Disable-ScheduledTask -TaskPath $Programa.RutaTarea -TaskName $Programa.Nombre -ErrorAction Stop | Out-Null
        }
        else {
            if (-not (Test-Path -Path $Programa.Aprobado)) { New-Item -Path $Programa.Aprobado -Force | Out-Null }
            $bytes = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            New-ItemProperty -Path $Programa.Aprobado -Name $Programa.Nombre -Value $bytes -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        }
        Write-Log "Desactivado al inicio: $($Programa.Nombre)" 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo desactivar $($Programa.Nombre): $($_.Exception.Message)" 'ADVERTENCIA'
        return $false
    }
}

function Activar-ProgramaInicio {
    # Deshace Desactivar-ProgramaInicio (igual que "Habilitar" en Administrador de tareas > Inicio).
    param($Programa)
    try {
        if ($Programa.Tipo -eq 'Tarea') {
            Enable-ScheduledTask -TaskPath $Programa.RutaTarea -TaskName $Programa.Nombre -ErrorAction Stop | Out-Null
        }
        else {
            if (-not (Test-Path -Path $Programa.Aprobado)) { New-Item -Path $Programa.Aprobado -Force | Out-Null }
            $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            New-ItemProperty -Path $Programa.Aprobado -Name $Programa.Nombre -Value $bytes -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        }
        Write-Log "Activado al inicio: $($Programa.Nombre)" 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo activar $($Programa.Nombre): $($_.Exception.Message)" 'ADVERTENCIA'
        return $false
    }
}

$Script:XamlInicio = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Programas de inicio" Width="860" Height="680" MinWidth="680" MinHeight="460"
        WindowStartupLocation="CenterOwner" Background="#0B1120" Foreground="#E2E8F0" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock Text="Programas de inicio" FontSize="22" FontWeight="SemiBold" Foreground="#F8FAFC"/>
      <TextBlock x:Name="TxtResumen" Foreground="#94A3B8" Margin="0,4,0,12" TextWrapping="Wrap"/>
    </StackPanel>
    <Border Grid.Row="1" Background="#111827" CornerRadius="10" Padding="14,10" BorderBrush="#1F2937" BorderThickness="1" Margin="0,0,0,14">
      <TextBlock x:Name="TxtArranque" Foreground="#CBD5E1" FontSize="12" TextWrapping="Wrap"/>
    </Border>
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="Lista" Margin="0,0,10,0"/>
    </ScrollViewer>
    <DockPanel Grid.Row="3" Margin="0,14,0,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="BtnDesactivar" Content="Desactivar marcados" Margin="0,0,10,0"/>
        <Button x:Name="BtnActivar" Content="Activar marcados" Margin="0,0,10,0"/>
        <Button x:Name="BtnCerrar" Content="Cerrar"/>
      </StackPanel>
      <TextBlock x:Name="TxtMensaje" Foreground="#FACC15" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,14,0"/>
    </DockPanel>
  </Grid>
</Window>
'@

function Cargar-InicioGui {
    $g = $Script:InicioGui
    $g.Lista.Children.Clear()
    $items = @(Get-ProgramasInicio | Sort-Object -Property @{ Expression = { -not $_.Activo } }, Nombre)
    $nAct = @($items | Where-Object { $_.Activo }).Count
    $g.TxtResumen.Text = ("{0} elemento(s) de inicio, {1} activo(s). Marque los que quiera y pulse Desactivar o Activar. No se desinstala nada y todo se puede volver a activar. Los cambios se notan en el próximo inicio de sesión." -f $items.Count, $nAct)
    foreach ($p in $items) {
        $borde = New-Object System.Windows.Controls.Border
        $borde.Background = Get-ColorPincel '#111827'
        $borde.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $borde.Padding = New-Object System.Windows.Thickness(12, 9, 12, 9)
        $borde.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Tag = $p
        $cb.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Top
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        [void]$sp.Children.Add((Nuevo-TextoGui $p.Nombre 14 '#F1F5F9' -Negrita))
        if ($p.Activo) { $estado = Nuevo-TextoGui ("Activo al iniciar · {0}" -f $p.Ambito) 12 '#4ADE80' }
        else { $estado = Nuevo-TextoGui ("Desactivado · {0}" -f $p.Ambito) 12 '#94A3B8' }
        [void]$sp.Children.Add($estado)
        $cmd = Nuevo-TextoGui $p.Comando 11 '#64748B'
        $cmd.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $cmd.TextWrapping = [System.Windows.TextWrapping]::NoWrap
        $cmd.ToolTip = $p.Comando
        [void]$sp.Children.Add($cmd)
        $cb.Content = $sp
        $borde.Child = $cb
        [void]$g.Lista.Children.Add($borde)
    }
    if ($items.Count -eq 0) { [void]$g.Lista.Children.Add((Nuevo-TextoGui 'No hay elementos de inicio.' 13 '#64748B')) }
}

function Aplicar-InicioGui {
    # $Activar: $true = activar los marcados que están desactivados; $false = desactivar los marcados que están activos.
    param([bool]$Activar)
    $g = $Script:InicioGui
    $hechos = 0
    $fallos = 0
    foreach ($b in @($g.Lista.Children)) {
        $cb = $b.Child
        if (-not ($cb -is [System.Windows.Controls.CheckBox]) -or -not $cb.IsChecked) { continue }
        $p = $cb.Tag
        if ($Activar -eq [bool]$p.Activo) { continue }
        if ($Activar) { $ok = Activar-ProgramaInicio $p } else { $ok = Desactivar-ProgramaInicio $p }
        if ($ok) { $hechos++ } else { $fallos++ }
    }
    Cargar-InicioGui
    $verbo = 'desactivaron'
    if ($Activar) { $verbo = 'activaron' }
    if ($hechos -eq 0 -and $fallos -eq 0) { $g.TxtMensaje.Text = 'No hay nada marcado que cambiar.'; return }
    $g.TxtMensaje.Text = ("Se {0} {1} elemento(s)." -f $verbo, $hechos)
    if ($fallos -gt 0) { $g.TxtMensaje.Text += (" {0} no se pudieron cambiar (vea el registro)." -f $fallos) }
    if ($hechos -gt 0) { try { Registrar-AccionVisita 'Programas de inicio' 'OK' } catch { } }
}

function Mostrar-InicioGui {
    [xml]$x = $Script:XamlInicio
    $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $Script:InicioGui = @{ Ventana = $w }
    foreach ($n in @('TxtResumen', 'TxtArranque', 'Lista', 'TxtMensaje', 'BtnDesactivar', 'BtnActivar', 'BtnCerrar')) { $Script:InicioGui[$n] = $w.FindName($n) }
    try {
        $Script:InicioGui.BtnDesactivar.Style = $Script:Gui.Ventana.FindResource('Primario')
        $Script:InicioGui.BtnActivar.Style = $Script:Gui.Ventana.FindResource('Exito')
        $Script:InicioGui.BtnCerrar.Style = $Script:Gui.Ventana.FindResource('Secundario')
    }
    catch { }
    try { if ($Script:Gui.Ventana.IsLoaded) { $w.Owner = $Script:Gui.Ventana } } catch { }
    $Script:InicioGui.TxtArranque.Text = 'Midiendo el arranque...'
    try {
        $est = Get-EstadoArranque
        $Script:InicioGui.TxtArranque.Text = ((@($est.Lineas) | Select-Object -First 10) -join "`n")
    }
    catch { $Script:InicioGui.TxtArranque.Text = 'No se pudo leer el tiempo de arranque.' }
    Cargar-InicioGui
    $Script:InicioGui.BtnDesactivar.Add_Click({ Aplicar-InicioGui $false })
    $Script:InicioGui.BtnActivar.Add_Click({ Aplicar-InicioGui $true })
    $Script:InicioGui.BtnCerrar.Add_Click({ $Script:InicioGui.Ventana.Close() })
    [void]$w.ShowDialog()
}

function Optimizar-Rendimiento {
    Mostrar-Titulo 'OPTIMIZAR RENDIMIENTO'
    $perfil = Get-PerfilUsuarioActivo

    $activos = @(Get-ProgramasInicio | Where-Object { $_.Activo })
    if ($Script:ModoInterfaz -eq 'Grafica') {
        # En la ventana: lista con casillas en vez de pedir números por escrito.
        Write-Log 'Se abrió la ventana "Programas de inicio": marque lo que quiera desactivar y ciérrela para continuar.' 'INFO'
        [void](Solicitar-Gui -Tipo 'Inicio' -Texto '')
    }
    elseif ($activos.Count -gt 0) {
        Write-Host '    Programas que arrancan con Windows:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $activos.Count; $i++) {
            Write-Host ("    {0,2}. {1}  ({2})" -f ($i + 1), $activos[$i].Nombre, $activos[$i].Ambito)
            Write-Host ("        {0}" -f $activos[$i].Comando) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '    Desactivar NO desinstala nada; se vuelve a activar en Administrador de tareas > Inicio.' -ForegroundColor DarkGray
        $respuesta = Read-Host '  Números a desactivar, separados por coma (Enter = ninguno)'
        foreach ($parte in ("$respuesta" -split '[,; ]+')) {
            $n = 0
            if ([int]::TryParse($parte, [ref]$n) -and $n -ge 1 -and $n -le $activos.Count) { $null = Desactivar-ProgramaInicio $activos[$n - 1] }
        }
    }
    else {
        Write-Log 'No hay programas de inicio activos.' 'INFO'
    }

    $esPortatil = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    if ($esPortatil) {
        Write-Log 'Equipo portátil: se mantiene el plan de energía Equilibrado (mejor para la batería).' 'INFO'
    }
    elseif (Confirmar '¿Activar el plan de energía "Alto rendimiento"?') {
        $c = Invoke-Nativo -Archivo (Get-RutaSistema 'powercfg.exe') -Argumentos '/setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' -Descripcion 'Plan Alto rendimiento'
        if ($c -ne 0) { Write-Log 'Este equipo no tiene el plan Alto rendimiento; se mantiene el actual.' 'ADVERTENCIA' }
    }

    if (Confirmar '¿Ajustar los efectos visuales para mejor rendimiento? (Windows se verá más simple)') {
        try {
            $clave = "$($perfil.Registro)\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
            if (-not (Test-Path -Path $clave)) { New-Item -Path $clave -Force | Out-Null }
            New-ItemProperty -Path $clave -Name 'VisualFXSetting' -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            Write-Log 'Efectos visuales en modo rendimiento (se aplica al cerrar sesión).' 'OK'
        }
        catch {
            Write-Log "No se pudieron cambiar los efectos visuales: $($_.Exception.Message)" 'ADVERTENCIA'
        }
    }

    $clavePower = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $hb = (Get-ItemProperty -Path $clavePower -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($null -ne $hb -and [int]$hb -eq 1) {
        Write-Host '    Con el "Inicio rápido" activo, Apagar no reinicia Windows de verdad y los problemas se acumulan.' -ForegroundColor DarkGray
        if (Confirmar '¿Desactivar el Inicio rápido?') {
            Set-ItemProperty -Path $clavePower -Name 'HiberbootEnabled' -Value 0
            Write-Log 'Inicio rápido desactivado.' 'OK'
        }
    }
    return $true
}

function Iniciar-ServiciosDetenidos {
    Mostrar-Titulo 'INICIAR SERVICIOS CLAVE'
    $lista = @($Script:ServiciosDetenidos)
    if ($lista.Count -eq 0) { Write-Log 'No hay servicios detenidos en el último diagnóstico.' 'INFO'; return $true }
    $ok = $true
    foreach ($s in $lista) { if (-not (Iniciar-Servicio $s)) { $ok = $false } }
    return $ok
}

function Abrir-OutlookModoSeguro {
    Mostrar-Titulo 'OUTLOOK EN MODO SEGURO'
    $office = Get-InfoOffice
    if (-not $office.Instalado) { Write-Log 'Outlook clásico no está instalado.' 'ADVERTENCIA'; return $false }
    if (-not (Cerrar-Outlook)) { return $false }
    $ok = Start-ComoUsuario -Programa $office.RutaOutlook -Argumentos '/safe'
    Write-Host ''
    Write-Host '    Si en modo seguro Outlook funciona bien, el problema es un complemento:' -ForegroundColor Cyan
    Write-Host '    Archivo > Opciones > Complementos > Administrar "Complementos COM" > Ir... y desactivarlos de uno en uno.'
    return $ok
}

function Restablecer-PanelOutlook {
    Mostrar-Titulo 'OUTLOOK: RESTABLECER PANEL DE CARPETAS'
    $office = Get-InfoOffice
    if (-not $office.Instalado) { Write-Log 'Outlook clásico no está instalado.' 'ADVERTENCIA'; return $false }
    if (-not (Cerrar-Outlook)) { return $false }
    return (Start-ComoUsuario -Programa $office.RutaOutlook -Argumentos '/resetnavpane')
}

function Abrir-PerfilesCorreo {
    Mostrar-Titulo 'OUTLOOK: PERFILES DE CORREO'
    $office = Get-InfoOffice
    if (-not $office.Instalado) { Write-Log 'Outlook clásico no está instalado.' 'ADVERTENCIA'; return $false }
    $cpl = Join-Path (Split-Path $office.RutaOutlook -Parent) 'MLCFG32.CPL'
    if (-not (Test-Path -LiteralPath $cpl)) { Write-Log 'No se encontró MLCFG32.CPL. Abra Panel de control > Correo.' 'ADVERTENCIA'; return $false }
    return (Start-ComoUsuario -Programa (Get-RutaSistema 'control.exe') -Argumentos ('"{0}"' -f $cpl))
}

function Abrir-Herramienta {
    param([string]$Id)
    switch ($Id) {
        'devmgmt'  { Start-Process -FilePath 'devmgmt.msc' }
        'eventvwr' { Start-Process -FilePath 'eventvwr.msc' }
        'perfmon'  { Start-Process -FilePath (Get-RutaSistema 'perfmon.exe') -ArgumentList '/rel' }
        'mdsched'  { Start-Process -FilePath (Get-RutaSistema 'mdsched.exe') }
        'taskmgr'  { Start-Process -FilePath (Get-RutaSistema 'taskmgr.exe') }
        'appwiz'   { Start-Process -FilePath (Get-RutaSistema 'control.exe') -ArgumentList 'appwiz.cpl' }
        'ncpa'     { Start-Process -FilePath (Get-RutaSistema 'control.exe') -ArgumentList 'ncpa.cpl' }
        'mmsys'    { Start-Process -FilePath (Get-RutaSistema 'control.exe') -ArgumentList 'mmsys.cpl' }
        'services' { Start-Process -FilePath 'services.msc' }
        'reportes' { Start-Process -FilePath (Join-Path $env:windir 'explorer.exe') -ArgumentList ('"{0}"' -f $Script:DirReportes) }
        'log'      { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $Script:LogFile) }
    }
    Write-Log "Abierto: $Id" 'INFO' -SoloArchivo
}

#endregion

#region ==================== DRIVERS: IDENTIFICACIÓN E INVENTARIO ====================

# Tabla de fabricantes por identificador de hardware (sin internet).
$Script:VendoresPci = @{
    '8086' = 'Intel'; '10EC' = 'Realtek'; '1022' = 'AMD'; '1002' = 'AMD (Radeon)'; '10DE' = 'NVIDIA'; '14E4' = 'Broadcom'
    '168C' = 'Qualcomm Atheros'; '17CB' = 'Qualcomm'; '14C3' = 'MediaTek'; '1814' = 'MediaTek (Ralink)'; '1969' = 'Qualcomm Atheros'
    '11AB' = 'Marvell'; '1B4B' = 'Marvell'; '1B21' = 'ASMedia'; '1912' = 'Renesas'; '104C' = 'Texas Instruments'; '1217' = 'O2Micro'
    '1180' = 'Ricoh'; '14F1' = 'Conexant (Synaptics)'; '111D' = 'IDT'; '1106' = 'VIA'; '1039' = 'SiS'; '144D' = 'Samsung'
    '15B7' = 'SanDisk / Western Digital'; '1C5C' = 'SK hynix'; '126F' = 'Silicon Motion'; '1987' = 'Phison'; '1D6A' = 'Aquantia'
    '197B' = 'JMicron'; '1095' = 'Silicon Image'; '1A03' = 'ASPEED'; '15AD' = 'VMware'; '80EE' = 'VirtualBox'; '1AF4' = 'Red Hat VirtIO'
    '1414' = 'Microsoft Hyper-V'; '11D4' = 'Analog Devices'; '1AE0' = 'Google'; '1C00' = 'Nuvoton'
}
$Script:VendoresUsb = @{
    '8087' = 'Intel'; '0BDA' = 'Realtek'; '0CF3' = 'Qualcomm Atheros'; '13D3' = 'AzureWave'; '04CA' = 'Lite-On'; '0489' = 'Foxconn'
    '5986' = 'Acer / Bison'; '04F2' = 'Chicony'; '0C45' = 'Microdia'; '174F' = 'Syntek'; '06CB' = 'Synaptics'; '27C6' = 'Goodix'
    '138A' = 'Synaptics (Validity)'; '0A5C' = 'Broadcom'; '046D' = 'Logitech'; '045E' = 'Microsoft'; '04E8' = 'Samsung'; '05AC' = 'Apple'
    '2717' = 'Xiaomi'; '12D1' = 'Huawei'; '18D1' = 'Google'; '22B8' = 'Motorola'; '1004' = 'LG'; '0E8D' = 'MediaTek'; '2C7C' = 'Quectel'
    '1199' = 'Sierra Wireless'; '03F0' = 'HP'; '04A9' = 'Canon'; '04B8' = 'Epson'; '04F9' = 'Brother'; '0424' = 'Microchip'
    '05E3' = 'Genesys Logic'; '1A40' = 'Terminus'; '2109' = 'VIA Labs'; '0B95' = 'ASIX'; '1532' = 'Razer'; '1038' = 'SteelSeries'
    '0951' = 'Kingston'; '0781' = 'SanDisk'; '067B' = 'Prolific'; '1A86' = 'QinHeng (CH340)'; '10C4' = 'Silicon Labs'; '0403' = 'FTDI'
}
$Script:VendoresAcpi = @{
    'INT' = 'Intel'; 'ELAN' = 'ELAN'; 'SYNA' = 'Synaptics'; 'ATML' = 'Atmel'; 'MSFT' = 'Microsoft'; 'AMDI' = 'AMD'; 'QCOM' = 'Qualcomm'
    'NVDA' = 'NVIDIA'; 'IDEA' = 'Lenovo'; 'LEN' = 'Lenovo'; 'HPQ' = 'HP'; 'DELL' = 'Dell'; 'ASUS' = 'ASUS'; 'ACER' = 'Acer'; 'MSHW' = 'Microsoft Surface'
    'GDIX' = 'Goodix'; 'WCOM' = 'Wacom'; 'ALPS' = 'ALPS'; 'BCM' = 'Broadcom'; 'SMO' = 'Sensores (SMO)'
}
$Script:TiposPci = @{
    '0100' = 'controladora SCSI'; '0101' = 'controladora IDE'; '0104' = 'controladora RAID'; '0106' = 'controladora SATA (AHCI)'
    '0108' = 'controladora NVMe'; '0200' = 'tarjeta de red de cable'; '0280' = 'tarjeta de red inalámbrica (WiFi)'; '0300' = 'tarjeta de video'
    '0302' = 'tarjeta de video'; '0380' = 'tarjeta de video'; '0401' = 'audio'; '0403' = 'audio (HD Audio)'; '0480' = 'multimedia'
    '0500' = 'controladora de memoria'; '0580' = 'controladora de memoria'; '0600' = 'chipset (puente de host)'; '0601' = 'chipset (puente ISA)'
    '0604' = 'chipset (puente PCI)'; '0780' = 'comunicaciones (Intel Management Engine o similar)'; '0805' = 'lector de tarjetas SD'
    '0880' = 'dispositivo del sistema (chipset, sensores o Serial IO)'; '0C03' = 'controladora USB'; '0C05' = 'controladora SMBus (chipset)'
    '0C80' = 'controladora de bus serie (Serial IO)'; '0D11' = 'Bluetooth'; '1180' = 'controladora térmica o de energía'; '0D80' = 'controladora inalámbrica'
}
$Script:TiposUsb = @{
    '01' = 'audio USB'; '02' = 'módem o comunicaciones'; '03' = 'teclado, mouse o control (HID)'; '06' = 'cámara o escáner'; '07' = 'impresora'
    '08' = 'almacenamiento USB'; '09' = 'hub USB'; '0B' = 'lector de tarjetas inteligentes'; '0E' = 'cámara web'; 'E0' = 'Bluetooth'; 'FF' = 'específico del fabricante'
}

function Get-IdentificacionHardware {
    # Traduce los identificadores de hardware a "fabricante - tipo de dispositivo".
    param($Dispositivo)
    $ids = @(@($Dispositivo.HardwareID) + @($Dispositivo.CompatibleID) + @("$($Dispositivo.InstanceId)") | Where-Object { $_ })
    $texto = ($ids -join ' ').ToUpper()
    $idPrincipal = "$(@($Dispositivo.HardwareID | Where-Object { $_ })[0])"
    if (-not $idPrincipal) { $idPrincipal = "$($Dispositivo.InstanceId)" }
    $fabricante = ''
    $tipo = ''
    if ($texto -match 'PCI\\VEN_([0-9A-F]{4})') { $fabricante = $Script:VendoresPci[$Matches[1]]; if (-not $fabricante) { $fabricante = "fabricante PCI $($Matches[1])" } }
    elseif ($texto -match 'HDAUDIO\\FUNC_[0-9A-F]+&VEN_([0-9A-F]{4})') { $fabricante = $Script:VendoresPci[$Matches[1]]; $tipo = 'audio (HD Audio)'; if (-not $fabricante) { $fabricante = "fabricante $($Matches[1])" } }
    elseif ($texto -match '(?:USB|HID)\\VID_([0-9A-F]{4})') { $fabricante = $Script:VendoresUsb[$Matches[1]]; if (-not $fabricante) { $fabricante = "fabricante USB $($Matches[1])" } }
    elseif ($texto -match 'ACPI\\VEN_([A-Z0-9]{3,4})') { $fabricante = $Script:VendoresAcpi[$Matches[1]] }
    elseif ($texto -match 'ACPI\\([A-Z]{3,4})[0-9A-F]{4}') {
        $prefijo = $Matches[1]
        $fabricante = $Script:VendoresAcpi[$prefijo]
        if (-not $fabricante -and $prefijo.Length -eq 4) { $fabricante = $Script:VendoresAcpi[$prefijo.Substring(0, 3)] }
    }
    if (-not $tipo) {
        if ($texto -match 'PCI\\CC_([0-9A-F]{4})') { $tipo = $Script:TiposPci[$Matches[1]] }
        elseif ($texto -match 'USB\\CLASS_([0-9A-F]{2})') { $tipo = $Script:TiposUsb[$Matches[1]] }
        elseif ($texto -match '^ACPI\\|\sACPI\\') { $tipo = 'dispositivo de la placa (ACPI: chipset, touchpad, sensores o botones)' }
        elseif ($texto -match 'BTH') { $tipo = 'dispositivo Bluetooth' }
    }
    if (-not $fabricante) { $fabricante = 'fabricante desconocido' }
    if (-not $tipo) { $tipo = 'tipo desconocido' }
    return [pscustomobject]@{ Fabricante = $fabricante; Tipo = $tipo; Id = $idPrincipal; Texto = ('{0} - {1}' -f $fabricante, $tipo) }
}

function Get-EntradasDesinstalar {
    # Lee las claves "Uninstall" una por una. Get-ItemProperty sobre "Uninstall\*" lanza "La conversión
    # especificada no es válida" si UNA sola entrada tiene un valor mal formado (visto con NetBeans) y se
    # pierde toda la lista. Aquí una entrada dañada se omite sin afectar a las demás.
    param([string[]]$Rutas)
    foreach ($ruta in $Rutas) {
        $claves = @()
        try { $claves = @(Get-ChildItem -Path $ruta -ErrorAction SilentlyContinue) } catch { }
        foreach ($k in $claves) {
            try {
                [pscustomobject]@{
                    DisplayName     = $k.GetValue('DisplayName')
                    DisplayVersion  = $k.GetValue('DisplayVersion')
                    Publisher       = $k.GetValue('Publisher')
                    InstallDate     = $k.GetValue('InstallDate')
                    SystemComponent = $k.GetValue('SystemComponent')
                    ParentKeyName   = $k.GetValue('ParentKeyName')
                }
            }
            catch { }
        }
    }
}

function Get-InfoFabricante {
    # Marca, modelo, serie, página de drivers y herramientas del fabricante instaladas.
    $info = [pscustomobject]@{ Marca = ''; Modelo = ''; Serie = ''; Url = ''; Herramientas = @(); Generico = $false }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $placa = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
        $fabricante = "$($cs.Manufacturer)".Trim()
        $info.Modelo = "$($cs.Model)".Trim()
        $info.Serie = "$($bios.SerialNumber)".Trim()
        if ($fabricante -match 'O\.?E\.?M|System manufacturer|Default string|To Be Filled') {
            # PC armada: usar la placa madre
            $info.Generico = $true
            $fabricante = "$($placa.Manufacturer)".Trim()
            $info.Modelo = "$($placa.Product)".Trim()
        }
        $serie = [uri]::EscapeDataString($info.Serie)
        switch -Regex ($fabricante) {
            'Dell' { $info.Marca = 'Dell'; $info.Url = "https://www.dell.com/support/home/es-es/product-support/servicetag/$serie/drivers" }
            'HP|Hewlett' { $info.Marca = 'HP'; $info.Url = 'https://support.hp.com/es-es/drivers' }
            'Lenovo' { $info.Marca = 'Lenovo'; $info.Url = 'https://pcsupport.lenovo.com/' }
            'ASUS' { $info.Marca = 'ASUS'; $info.Url = 'https://www.asus.com/es/support/download-center/' }
            'Acer' { $info.Marca = 'Acer'; $info.Url = 'https://www.acer.com/latam/es/support/drivers-and-manuals' }
            'Micro-Star|MSI' { $info.Marca = 'MSI'; $info.Url = 'https://www.msi.com/support' }
            'Gigabyte' { $info.Marca = 'Gigabyte'; $info.Url = 'https://www.gigabyte.com/Support' }
            'ASRock' { $info.Marca = 'ASRock'; $info.Url = 'https://www.asrock.com/support/index.asp' }
            'Samsung' { $info.Marca = 'Samsung'; $info.Url = 'https://www.samsung.com/latin/support/' }
            'Toshiba|Dynabook' { $info.Marca = 'Dynabook (Toshiba)'; $info.Url = 'https://support.dynabook.com/' }
            'Microsoft' { $info.Marca = 'Microsoft Surface'; $info.Url = 'https://support.microsoft.com/es-es/surface' }
            'VMware|innotek|QEMU|Xen' { $info.Marca = 'Máquina virtual'; $info.Url = '' }
            default { $info.Marca = $fabricante }
        }
        if (-not $info.Marca) { $info.Marca = 'desconocido' }
    }
    catch { }

    $patron = 'Lenovo Vantage|Lenovo System Update|Lenovo Commercial Vantage|SupportAssist|Dell Command \| Update|Dell Update|HP Support Assistant|HP Image Assistant|MyASUS|ASUS Live Update|Armoury Crate|Acer Care Center|Acer Product Registration|MSI Center|Dragon Center|Intel.*Driver.*Support Assistant|AMD Software|NVIDIA App|GeForce Experience'
    $encontradas = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-EntradasDesinstalar -Rutas @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'))) {
        $nombre = "$($p.DisplayName)"
        if ($nombre -match $patron -and -not $encontradas.Contains($nombre)) { $encontradas.Add($nombre) }
    }
    try {
        $apps = @{ 'E046963F.LenovoCompanion' = 'Lenovo Vantage'; 'E046963F.LenovoSettingsforEnterprise' = 'Lenovo Commercial Vantage'; 'B9ECED6F.ASUSPCAssistant' = 'MyASUS'; 'AD2F1837.HPSupportAssistant' = 'HP Support Assistant'; 'DellInc.DellSupportAssistforPCs' = 'Dell SupportAssist' }
        foreach ($k in $apps.Keys) {
            if (@(Get-AppxPackage -AllUsers -Name $k -ErrorAction SilentlyContinue).Count -gt 0 -and -not $encontradas.Contains($apps[$k])) { $encontradas.Add($apps[$k]) }
        }
    }
    catch { }
    $info.Herramientas = $encontradas.ToArray()
    return $info
}

function Test-BloqueoDriversWU {
    $pol = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
    $orden = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -ErrorAction SilentlyContinue).SearchOrderConfig
    return (($null -ne $pol -and [int]$pol -eq 1) -or ($null -ne $orden -and [int]$orden -eq 0))
}

function Get-DispositivosConProblema {
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            [int]$_.ConfigManagerErrorCode -ne 0 -and "$($_.Class)" -ne 'AudioEndpoint'
        })
}

function Get-EstadoDrivers {
    $r = Nuevo-Estado

    # 1. Dispositivos con problemas, identificados por su hardware
    $malos = @(Get-DispositivosConProblema)
    if ($malos.Count -eq 0) {
        $r.Lineas.Add('Todos los dispositivos tienen driver y funcionan.')
    }
    $sinDriver = New-Object System.Collections.Generic.List[string]
    $conError = New-Object System.Collections.Generic.List[string]
    $fabricantesSinDriver = New-Object System.Collections.Generic.List[string]
    foreach ($d in $malos) {
        $codigo = [int]$d.ConfigManagerErrorCode
        $id = Get-IdentificacionHardware $d
        $nombre = "$($d.FriendlyName)"
        if (-not $nombre) { $nombre = 'Dispositivo desconocido' }
        $r.Lineas.Add(("{0} [{1}] - {2}" -f $nombre, $d.Class, (Get-DescripcionCodigoPnp $codigo)))
        $r.Lineas.Add(("   Es: {0} | {1}" -f $id.Texto, $id.Id))
        if ($codigo -eq 28 -or $codigo -eq 1 -or $codigo -eq 18) {
            $sinDriver.Add(("'{0}' ({1})" -f $nombre, $id.Texto))
            if ($id.Fabricante -and -not $fabricantesSinDriver.Contains("$($id.Fabricante)")) { $fabricantesSinDriver.Add("$($id.Fabricante)") }
        }
        elseif ($codigo -eq 22) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("'{0}' está deshabilitado." -f $nombre) -Sugerencia 'Habilitarlo en el Administrador de dispositivos si se necesita.' -Info))
        }
        elseif ($codigo -eq 45) {
            $r.Lineas.Add('   (desconectado: normal si se desenchufó)')
        }
        elseif ($codigo -eq 24) {
            # Conectado pero Windows no lo puede usar: suele faltar un driver o estar dañado
            $r.Problemas.Add((Nuevo-Problema -Texto ("'{0}' no funciona bien o le faltan drivers (código 24). Es: {1}." -f $nombre, $id.Texto) -Sugerencia 'Drivers > "Reinstalar un dispositivo"; si sigue, "Buscar drivers en Windows Update".' -Accion 'DRVWU'))
        }
        else {
            $conError.Add(("'{0}' ({1})" -f $nombre, (Get-DescripcionCodigoPnp $codigo)))
        }
    }
    # Un solo problema por tipo, para que varios dispositivos no lleven el puntaje a 0
    if ($sinDriver.Count -eq 1) {
        $origen = 'la página del fabricante del equipo'
        if ($fabricantesSinDriver.Count -gt 0) { $origen = '{0} o de la página del fabricante del equipo' -f $fabricantesSinDriver[0] }
        $r.Problemas.Add((Nuevo-Problema -Texto ("{0} no tiene driver." -f $sinDriver[0]) -Sugerencia ("Drivers > ""Buscar drivers en Windows Update""; si no aparece, descargar el driver de {0}." -f $origen) -Critica -Accion 'DRVWU'))
    }
    elseif ($sinDriver.Count -gt 1) {
        $origen = 'la página del fabricante del equipo'
        if ($fabricantesSinDriver.Count -gt 0) { $origen = '{0} o de la página del fabricante del equipo' -f ($fabricantesSinDriver -join ', ') }
        $r.Problemas.Add((Nuevo-Problema -Texto ("{0} dispositivos no tienen driver: {1}." -f $sinDriver.Count, ($sinDriver -join '; ')) -Sugerencia ("Drivers > ""Buscar drivers en Windows Update""; lo que no aparezca, descargarlo de {0}." -f $origen) -Critica -Accion 'DRVWU'))
    }
    if ($conError.Count -gt 0) {
        $texto = "Dispositivo con error: {0}." -f $conError[0]
        if ($conError.Count -gt 1) { $texto = "{0} dispositivos con error: {1}." -f $conError.Count, ($conError -join '; ') }
        $r.Problemas.Add((Nuevo-Problema -Texto $texto -Sugerencia 'Drivers > "Reinstalar un dispositivo"; si empezó después de una actualización, "Revertir el driver".' -Critica))
    }

    # 2. Drivers sin firma y drivers que no cargaron
    try {
        $firmados = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
        $sinFirma = @($firmados | Where-Object { $_.DeviceName -and $_.InfName -and $_.IsSigned -eq $false })
        foreach ($x in $sinFirma) { $r.Lineas.Add(("Driver SIN FIRMA: {0} | {1} | {2}" -f $x.DeviceName, $x.DriverProviderName, $x.InfName)) }
        if ($sinFirma.Count -gt 0) {
            $r.Problemas.Add((Nuevo-Problema -Texto ("Hay {0} driver(s) sin firma digital." -f $sinFirma.Count) -Sugerencia 'Reemplazarlos por la versión oficial del fabricante: los drivers sin firma pueden causar pantallazos azules.'))
        }
    }
    catch { $firmados = @() }
    try {
        $arranque = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $fallos = @(Get-EventosSeguro -Log 'System' -Proveedores @('Microsoft-Windows-Kernel-PnP') -Ids @(219) -Desde $arranque)
        if ($fallos.Count -gt 0) {
            $nombres = @($fallos | ForEach-Object { $d = Get-DatosEvento $_; "$($d['DriverName'])" } | Where-Object { $_ } | Select-Object -Unique -First 5)
            $r.Lineas.Add(("Drivers que no cargaron en el último arranque: {0} ({1})" -f $fallos.Count, ($nombres -join ', ')))
            $r.Problemas.Add((Nuevo-Problema -Texto ("{0} driver(s) no cargaron en el último arranque." -f $fallos.Count) -Sugerencia 'Suele ser inofensivo; si un dispositivo no funciona, reinstalarlo o actualizar su driver.' -Info))
        }
    }
    catch { }

    # 3. Windows Update y herramienta del fabricante
    if (Test-BloqueoDriversWU) { $r.Lineas.Add('Windows Update: NO instala drivers automáticamente (bloqueado).') }
    else { $r.Lineas.Add('Windows Update: puede instalar drivers automáticamente.') }
    $fab = Get-InfoFabricante
    $r.Lineas.Add(("Fabricante: {0} | Modelo: {1} | Serie: {2}" -f $fab.Marca, $fab.Modelo, $fab.Serie))
    if ($fab.Herramientas.Count -gt 0) {
        $r.Lineas.Add(("Herramienta de drivers del fabricante: {0}" -f ($fab.Herramientas -join ', ')))
    }
    elseif ($fab.Url) {
        $r.Problemas.Add((Nuevo-Problema -Texto ("No hay instalada una herramienta de drivers de {0}." -f $fab.Marca) -Sugerencia 'Drivers > "Página de drivers del fabricante": abre la página de soporte del equipo.' -Info))
    }

    # 4. Inventario de drivers de terceros
    $terceros = @($firmados | Where-Object { $_.DeviceName -and $_.InfName -like 'oem*.inf' } | Sort-Object -Property DriverProviderName, DeviceName)
    $r.Lineas.Add(("Inventario: {0} driver(s) de fabricantes (además de los de Microsoft):" -f $terceros.Count))
    foreach ($x in ($terceros | Select-Object -First 80)) {
        $fecha = ''
        if ($x.DriverDate) { $fecha = ([datetime]$x.DriverDate).ToString('dd/MM/yyyy') }
        $firma = 'firmado'; if ($x.IsSigned -eq $false) { $firma = 'SIN FIRMA' }
        $r.Lineas.Add(("   {0} | {1} | {2} | {3} | {4}" -f $x.DriverProviderName, $x.DeviceName, $x.DriverVersion, $fecha, $firma))
    }
    return $r
}

#endregion

#region ==================== DRIVERS: ACCIONES ====================

function ConvertTo-VersionDriver {
    # Convierte "31.0.101.4502" en [version] para comparar bien (como texto, "9.0" quedaría por encima de "10.0").
    param($Texto)
    $v = $null
    if ([version]::TryParse(("$Texto".Trim()), [ref]$v)) { return $v }
    return $null
}

function Test-CodigoPnputil {
    # pnputil: 0 = correcto, 3010 = correcto pero requiere reiniciar
    param([int]$Codigo)
    if ($Codigo -eq 3010) { $Script:RequiereReinicio = $true; return $true }
    return ($Codigo -eq 0)
}

function Buscar-DriversWindowsUpdate {
    param([switch]$Automatico)
    Mostrar-Titulo 'BUSCAR DRIVERS EN WINDOWS UPDATE'
    if (Test-BloqueoDriversWU) {
        Write-Log 'Los drivers por Windows Update están bloqueados en este equipo; puede que no aparezca ninguno (ver "Bloquear drivers de Windows Update").' 'ADVERTENCIA'
    }
    $null = Iniciar-Servicio 'wuauserv' -HabilitarSiDeshabilitado
    Write-Log 'Buscando drivers en Windows Update (puede tardar de 1 a 5 minutos)...' 'INFO'
    try {
        $sesion = New-Object -ComObject Microsoft.Update.Session
        $sesion.ClientApplicationID = 'SoporteTecnico'
        $buscador = $sesion.CreateUpdateSearcher()
        $buscador.ServerSelection = 2   # Windows Update directo (no WSUS)
        $resultado = $buscador.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    }
    catch {
        Write-Log "No se pudo buscar en Windows Update: $($_.Exception.Message)" 'ERROR'
        Write-Log 'Revise la conexión a internet o use "Reparar Windows Update".' 'INFO'
        return $false
    }
    $total = $resultado.Updates.Count
    if ($total -eq 0) {
        Write-Log 'Windows Update no tiene drivers nuevos para este equipo.' 'OK'
        $malos = @(Get-DispositivosConProblema | Where-Object { [int]$_.ConfigManagerErrorCode -eq 28 })
        if ($malos.Count -gt 0) {
            Write-Log 'Hay dispositivos sin driver: use "Página de drivers del fabricante" o "Instalar drivers desde carpeta/USB".' 'ADVERTENCIA'
        }
        return $true
    }

    # Qué dispositivos con problema corrige cada driver
    $problemas = @(Get-DispositivosConProblema)
    $lista = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $total; $i++) {
        $u = $resultado.Updates.Item($i)
        $hw = "$($u.DriverHardwareID)"
        $corrige = ''
        foreach ($d in $problemas) {
            foreach ($idHw in @($d.HardwareID) + @($d.CompatibleID)) {
                if ($idHw -and $hw -and ("$idHw" -ieq $hw)) { $corrige = "$($d.FriendlyName)"; if (-not $corrige) { $corrige = 'dispositivo desconocido' } }
            }
        }
        $fecha = ''
        try { $fecha = ([datetime]$u.DriverVerDate).ToString('dd/MM/yyyy') } catch { }
        $lista.Add([pscustomobject]@{ Update = $u; Titulo = "$($u.Title)"; Clase = "$($u.DriverClass)"; Fecha = $fecha; Corrige = $corrige })
    }

    Write-Host ''
    Write-Host '    Drivers disponibles:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $x = $lista[$i]
        $marca = ''
        if ($x.Corrige) { $marca = "  [CORRIGE: $($x.Corrige)]" }
        $color = 'White'; if ($x.Corrige) { $color = 'Green' }
        Write-Host ("    {0,2}. {1} ({2}, {3}){4}" -f ($i + 1), $x.Titulo, $x.Clase, $x.Fecha, $marca) -ForegroundColor $color
    }
    Write-Host ''

    $elegidos = New-Object System.Collections.Generic.List[object]
    if ($Automatico) {
        foreach ($x in $lista) { if ($x.Corrige) { $elegidos.Add($x) } }
        if ($elegidos.Count -eq 0) {
            Write-Log 'Ninguno de estos drivers corresponde a un dispositivo con problema; no se instala nada automáticamente.' 'INFO'
            return $true
        }
    }
    else {
        $resp = Read-Host '  Números a instalar separados por coma, "todos", o Enter para cancelar'
        if ("$resp".Trim() -match '^(todos|t)$') {
            foreach ($x in $lista) { $elegidos.Add($x) }
        }
        else {
            foreach ($parte in ("$resp" -split '[,; ]+')) {
                $n = 0
                if ([int]::TryParse($parte, [ref]$n) -and $n -ge 1 -and $n -le $lista.Count) { $elegidos.Add($lista[$n - 1]) }
            }
        }
        if ($elegidos.Count -eq 0) { Write-Log 'Instalación de drivers cancelada.' 'INFO'; return $false }
    }

    try {
        $coleccion = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($x in $elegidos) {
            if (-not $x.Update.EulaAccepted) { $x.Update.AcceptEula() }
            [void]$coleccion.Add($x.Update)
        }
        Write-Log ("Descargando {0} driver(s)..." -f $coleccion.Count) 'INFO'
        $descargador = $sesion.CreateUpdateDownloader()
        $descargador.Updates = $coleccion
        [void]$descargador.Download()
        Write-Log 'Instalando...' 'INFO'
        $instalador = $sesion.CreateUpdateInstaller()
        $instalador.Updates = $coleccion
        $res = $instalador.Install()
        $ok = $true
        for ($i = 0; $i -lt $coleccion.Count; $i++) {
            $codigo = [int]$res.GetUpdateResult($i).ResultCode
            $titulo = $coleccion.Item($i).Title
            if ($codigo -eq 2 -or $codigo -eq 3) { Write-Log "Instalado: $titulo" 'OK' }
            else { Write-Log "No se pudo instalar: $titulo (código $codigo)" 'ERROR'; $ok = $false }
        }
        if ($res.RebootRequired) { $Script:RequiereReinicio = $true }
        return $ok
    }
    catch {
        Write-Log "Error al instalar los drivers: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Respaldar-Drivers {
    Mostrar-Titulo 'RESPALDAR DRIVERS'
    Write-Host '    Copia todos los drivers de fabricantes instalados (no los de Microsoft, que vienen con Windows).' -ForegroundColor DarkGray
    Write-Host '    Úselo antes de formatear: después se restauran con "Restaurar o instalar drivers desde carpeta/USB".' -ForegroundColor DarkGray
    $predeterminada = Join-Path $Script:Base ('Drivers_{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))
    $nombreCarpeta = 'Drivers_{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd')
    $resp = Read-Host ("  Carpeta de destino, por ejemplo E:\ para una USB (vacío = {0})" -f $predeterminada)
    # En la ventana, "Cancelar" no debe iniciar el respaldo en la carpeta predeterminada
    if ($Script:ModoInterfaz -eq 'Grafica' -and $Sync.Cancelado) { Write-Log 'Operación cancelada.' 'INFO'; return $false }
    $destino = "$resp".Trim().Trim('"')
    if (-not $destino) { $destino = $predeterminada }
    elseif ($destino -match '^[A-Za-z]:\\?$') { $destino = Join-Path $destino.Substring(0, 2) $nombreCarpeta }
    else { $destino = $destino.TrimEnd('\') }
    # Si la carpeta ya tiene archivos, se usa una subcarpeta nueva para no mezclar con respaldos viejos
    if ((Test-Path -LiteralPath $destino) -and @(Get-ChildItem -LiteralPath $destino -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        $destino = Join-Path $destino ('{0}_{1}' -f $nombreCarpeta, (Get-Date -Format 'HHmmss'))
    }
    try {
        if (-not (Test-Path -LiteralPath $destino)) { New-Item -ItemType Directory -Path $destino -Force -ErrorAction Stop | Out-Null }
    }
    catch {
        Write-Log "No se pudo crear la carpeta ${destino}: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    Write-Log "Exportando drivers a $destino (puede tardar unos minutos)..." 'INFO'
    $codigo = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos ('/export-driver * "{0}"' -f $destino) -Descripcion 'Exportar drivers'
    $infs = @(Get-ChildItem -LiteralPath $destino -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) {
        Write-Log 'No se exportó ningún driver.' 'ERROR'
        return $false
    }
    # Inventario para saber qué hay en el respaldo
    try {
        $inventario = Join-Path $destino 'inventario_drivers.csv'
        Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.InfName -like 'oem*.inf' } |
            Select-Object DeviceName, DeviceClass, DriverProviderName, DriverVersion, @{ n = 'DriverDate'; e = { if ($_.DriverDate) { ([datetime]$_.DriverDate).ToString('yyyy-MM-dd') } } }, InfName, @{ n = 'HardWareID'; e = { @($_.HardWareID) -join '; ' } } |
            Export-Csv -LiteralPath $inventario -NoTypeInformation -Encoding UTF8
        $leeme = @(
            "Respaldo de drivers de $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy HH:mm')",
            "Equipo: $((Get-InfoFabricante).Marca) $((Get-InfoFabricante).Modelo)",
            '',
            'Para restaurar: Soporte Técnico > Drivers > "Restaurar o instalar drivers desde carpeta/USB"',
            'o en una consola de administrador:  pnputil /add-driver "<esta carpeta>\*.inf" /subdirs /install'
        )
        [System.IO.File]::WriteAllLines((Join-Path $destino 'LEEME.txt'), $leeme, (New-Object System.Text.UTF8Encoding($true)))
    }
    catch { }
    $tamano = [math]::Round((Get-TamanoCarpeta $destino) / 1MB)
    if (-not (Test-CodigoPnputil $codigo)) {
        Write-Log ("Respaldo INCOMPLETO: pnputil terminó con código {0}. Se copiaron {1} drivers ({2} MB) en {3}, pero pueden faltar otros. No formatee confiando en este respaldo." -f $codigo, $infs.Count, $tamano, $destino) 'ERROR'
        return $false
    }
    Write-Log ("Respaldo listo: {0} drivers ({1} MB) en {2}" -f $infs.Count, $tamano, $destino) 'OK'
    return $true
}

function Instalar-DriversCarpeta {
    Mostrar-Titulo 'RESTAURAR O INSTALAR DRIVERS DESDE CARPETA / USB'
    Write-Host '    Sirve para un respaldo hecho con esta herramienta o para drivers descargados del fabricante' -ForegroundColor DarkGray
    Write-Host '    (si el driver viene como .exe, ejecútelo directamente; si viene en .zip, descomprímalo primero).' -ForegroundColor DarkGray
    $resp = Read-Host '  Carpeta con los drivers (por ejemplo E:\Drivers_PC01_20261120)'
    $carpeta = "$resp".Trim().Trim('"')
    if (-not $carpeta -or -not (Test-Path -LiteralPath $carpeta -PathType Container)) {
        Write-Log "La carpeta no existe: $carpeta" 'ERROR'
        return $false
    }
    $infs = @(Get-ChildItem -LiteralPath $carpeta -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) {
        Write-Log 'La carpeta no contiene archivos .inf (drivers). Si el driver es un .exe, ejecútelo directamente.' 'ERROR'
        return $false
    }
    Write-Host ("    Se encontraron {0} archivo(s) .inf." -f $infs.Count) -ForegroundColor Cyan
    if (-not (Confirmar '¿Instalar estos drivers? (se crea antes un punto de restauración)')) { return $false }
    $null = New-PuntoRestauracion
    $antes = @(Get-DispositivosConProblema).Count
    $codigo = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos ('/add-driver "{0}" /subdirs /install' -f (Join-Path $carpeta '*.inf')) -Descripcion 'Instalar drivers'
    if ((Get-BuildWindows) -ge 19041) {
        $null = Invoke-Nativo -Archivo (Get-RutaSistema 'pnputil.exe') -Argumentos '/scan-devices' -Descripcion 'Buscar cambios de hardware'
    }
    Start-Sleep -Seconds 3
    $despues = @(Get-DispositivosConProblema).Count
    Write-Log ("Dispositivos con problema: antes {0}, después {1}." -f $antes, $despues) 'INFO'
    Write-Log 'Algunos drivers se terminan de aplicar al reiniciar.' 'INFO'
    $Script:RequiereReinicio = $true
    if ($codigo -eq 259) {
        # 259 = los drivers quedaron en el almacén pero ningún dispositivo necesitaba actualizarse
        Write-Log 'Los drivers se agregaron; ningún dispositivo conectado necesitaba actualizarse.' 'INFO'
        return $true
    }
    return ((Test-CodigoPnputil $codigo) -or $despues -lt $antes)
}

function Get-ListaDispositivosElegibles {
    # Dispositivos que es seguro reinstalar o revertir (no discos, procesador ni chipset base).
    $clases = @('MEDIA', 'Net', 'Display', 'Bluetooth', 'Camera', 'Image', 'Printer', 'USB', 'HIDClass', 'Mouse', 'Keyboard', 'Biometric', 'SmartCardReader', 'Sensor', 'Ports', 'Modem', 'WPD', 'SDHost', 'Monitor')
    $todos = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            ([int]$_.ConfigManagerErrorCode -ne 0 -and "$($_.Class)" -ne 'AudioEndpoint') -or ($clases -contains "$($_.Class)")
        })
    $conProblema = @($todos | Where-Object { [int]$_.ConfigManagerErrorCode -ne 0 } | Sort-Object -Property Class, FriendlyName)
    $resto = @($todos | Where-Object { [int]$_.ConfigManagerErrorCode -eq 0 } | Sort-Object -Property Class, FriendlyName)
    return @($conProblema + $resto)
}

function Elegir-Dispositivo {
    param([string]$Pregunta)
    $lista = @(Get-ListaDispositivosElegibles)
    if ($lista.Count -eq 0) { Write-Log 'No hay dispositivos para elegir.' 'INFO'; return $null }
    if ($Script:ModoInterfaz -eq 'Grafica') {
        # En la ventana la lista va dentro del cuadro de diálogo, no solo en el registro de actividad.
        $opciones = @(foreach ($d in $lista) {
                $nombre = "$($d.FriendlyName)"
                if (-not $nombre) { $nombre = 'Dispositivo desconocido' }
                $estado = ''
                if ([int]$d.ConfigManagerErrorCode -ne 0) { $estado = '   <- ' + (Get-DescripcionCodigoPnp $d.ConfigManagerErrorCode) }
                '[{0}] {1}{2}' -f $d.Class, $nombre, $estado
            })
        $idx = Elegir-Opcion $Pregunta $opciones
        if ($idx -ge 0) { return $lista[$idx] }
        Write-Log 'Operación cancelada.' 'INFO'
        return $null
    }
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $d = $lista[$i]
        $nombre = "$($d.FriendlyName)"
        if (-not $nombre) { $nombre = 'Dispositivo desconocido' }
        $estado = ''
        $color = 'White'
        if ([int]$d.ConfigManagerErrorCode -ne 0) { $estado = '  <- ' + (Get-DescripcionCodigoPnp $d.ConfigManagerErrorCode); $color = 'Yellow' }
        Write-Host ("    {0,2}. [{1}] {2}{3}" -f ($i + 1), $d.Class, $nombre, $estado) -ForegroundColor $color
    }
    Write-Host ''
    $resp = Read-Host $Pregunta
    $n = 0
    if ([int]::TryParse("$resp", [ref]$n) -and $n -ge 1 -and $n -le $lista.Count) { return $lista[$n - 1] }
    Write-Log 'Operación cancelada.' 'INFO'
    return $null
}

function Reinstalar-Dispositivo {
    Mostrar-Titulo 'REINSTALAR UN DISPOSITIVO'
    if ((Get-BuildWindows) -lt 19041) {
        Write-Log 'Esta función necesita Windows 10 versión 2004 o superior. Use el Administrador de dispositivos > Desinstalar dispositivo > Buscar cambios de hardware.' 'ADVERTENCIA'
        return $false
    }
    Write-Host '    Se quita el dispositivo y Windows lo vuelve a detectar con su driver (los problemas aparecen primero).' -ForegroundColor DarkGray
    Write-Host ''
    $d = Elegir-Dispositivo '  Número del dispositivo a reinstalar (Enter = cancelar)'
    if (-not $d) { return $false }
    if ("$($d.Class)" -eq 'Net') { Mostrar-AvisoSesionRemota }
    if ("$($d.Class)" -in @('Keyboard', 'Mouse', 'HIDClass', 'USB')) {
        Write-Host '    El teclado, el mouse o los puertos USB pueden dejar de responder unos segundos.' -ForegroundColor Yellow
    }
    if (-not (Confirmar ("¿Reinstalar '{0}'?" -f $d.FriendlyName))) { return $false }
    $pnputil = Get-RutaSistema 'pnputil.exe'
    $c1 = Invoke-Nativo -Archivo $pnputil -Argumentos ('/remove-device "{0}"' -f $d.InstanceId) -Descripcion 'Quitar dispositivo'
    Start-Sleep -Seconds 2
    $null = Invoke-Nativo -Archivo $pnputil -Argumentos '/scan-devices' -Descripcion 'Detectar hardware de nuevo'
    Start-Sleep -Seconds 5
    $nuevo = Get-PnpDevice -InstanceId $d.InstanceId -ErrorAction SilentlyContinue
    if ($nuevo -and [int]$nuevo.ConfigManagerErrorCode -eq 0) {
        Write-Log ("'{0}' se reinstaló y funciona." -f $nuevo.FriendlyName) 'OK'
        return $true
    }
    if ($nuevo) {
        Write-Log ("'{0}' se reinstaló pero sigue con: {1}" -f $nuevo.FriendlyName, (Get-DescripcionCodigoPnp $nuevo.ConfigManagerErrorCode)) 'ADVERTENCIA'
        Write-Log 'Siguiente paso: "Buscar drivers en Windows Update" o el driver del fabricante.' 'INFO'
    }
    else {
        Write-Log 'Windows todavía no detectó el dispositivo de nuevo; puede requerir reiniciar.' 'ADVERTENCIA'
        $Script:RequiereReinicio = $true
    }
    return (Test-CodigoPnputil $c1)
}

function Revertir-Driver {
    Mostrar-Titulo 'REVERTIR EL DRIVER DE UN DISPOSITIVO'
    Write-Host '    Vuelve a la versión anterior del driver si todavía está guardada en el equipo.' -ForegroundColor DarkGray
    Write-Host ''
    $d = Elegir-Dispositivo '  Número del dispositivo cuyo driver quiere revertir (Enter = cancelar)'
    if (-not $d) { return $false }
    try {
        $actual = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceID -eq $d.InstanceId } | Select-Object -First 1
    }
    catch { $actual = $null }
    if (-not $actual -or "$($actual.InfName)" -notlike 'oem*.inf') {
        Write-Log 'Este dispositivo usa un driver incluido en Windows; no hay versión anterior que restaurar.' 'ADVERTENCIA'
        return $false
    }
    Write-Log ("Driver actual: {0} versión {1} ({2})" -f $actual.DriverProviderName, $actual.DriverVersion, $actual.InfName) 'INFO'
    try {
        $almacen = @(Get-WindowsDriver -Online -ErrorAction Stop)
    }
    catch {
        Write-Log "No se pudo leer el almacén de drivers: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    $paquete = $almacen | Where-Object { $_.Driver -ieq $actual.InfName } | Select-Object -First 1
    if (-not $paquete) { Write-Log 'No se encontró el paquete del driver actual.' 'ERROR'; return $false }
    $original = Split-Path $paquete.OriginalFileName -Leaf
    $versionActual = ConvertTo-VersionDriver $paquete.Version
    if (-not $versionActual) { $versionActual = ConvertTo-VersionDriver $actual.DriverVersion }
    # Identificadores del dispositivo, para usar solo paquetes que de verdad le sirven
    $idsDispositivo = @()
    foreach ($clave in @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds')) {
        try { $idsDispositivo += @((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $clave -ErrorAction Stop).Data) } catch { }
    }
    $idsDispositivo = @($idsDispositivo | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() })
    $anteriores = New-Object System.Collections.Generic.List[object]
    foreach ($c in @($almacen | Where-Object { $_.Driver -ine $actual.InfName -and (Split-Path $_.OriginalFileName -Leaf) -ieq $original })) {
        $v = ConvertTo-VersionDriver $c.Version
        # Solo versiones MÁS VIEJAS que la actual
        if (-not $v -or -not $versionActual -or $v -ge $versionActual) { continue }
        if ($idsDispositivo.Count -gt 0) {
            $sirve = $false
            try {
                foreach ($h in @(Get-WindowsDriver -Online -Driver $c.Driver -ErrorAction Stop)) {
                    if ($h.HardwareId -and $idsDispositivo -contains "$($h.HardwareId)".ToUpperInvariant()) { $sirve = $true; break }
                }
            }
            catch { }
            if (-not $sirve) { continue }
        }
        $anteriores.Add([pscustomobject]@{ Driver = $c.Driver; Version = $c.Version; VersionObj = $v })
    }
    $anteriores = @($anteriores | Sort-Object -Property VersionObj -Descending)
    if ($anteriores.Count -eq 0) {
        Write-Log 'No hay otra versión de este driver guardada en el equipo.' 'ADVERTENCIA'
        Write-Log 'Alternativas: "Reinstalar un dispositivo", "Buscar drivers en Windows Update" o el driver del fabricante.' 'INFO'
        return $false
    }
    foreach ($a in $anteriores) { Write-Log ("Versión anterior disponible: {0} ({1})" -f $a.Version, $a.Driver) 'INFO' }
    # pnputil /delete-driver /force quita el paquete de TODOS los dispositivos que lo usan
    $otros = @()
    try {
        $otros = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.InfName -ieq $actual.InfName -and $_.DeviceID -ne $d.InstanceId -and $_.DeviceName })
    }
    catch { }
    if ($otros.Count -gt 0) {
        Write-Log ("Este mismo driver ({0}) también lo usan {1} dispositivo(s) más; se les quitará también:" -f $actual.InfName, $otros.Count) 'ADVERTENCIA'
        foreach ($o in ($otros | Select-Object -First 10)) { Write-Host ("      - {0}" -f $o.DeviceName) -ForegroundColor Yellow }
    }
    if (-not (Confirmar ("¿Quitar la versión {0} para que Windows use la {1}? (se crea un punto de restauración)" -f $actual.DriverVersion, $anteriores[0].Version))) { return $false }
    if ("$($d.Class)" -eq 'Net') { Mostrar-AvisoSesionRemota }
    $null = New-PuntoRestauracion
    $pnputil = Get-RutaSistema 'pnputil.exe'
    $codigo = Invoke-Nativo -Archivo $pnputil -Argumentos ('/delete-driver {0} /uninstall /force' -f $actual.InfName) -Descripcion 'Quitar la versión actual del driver'
    if ((Get-BuildWindows) -ge 19041) {
        $null = Invoke-Nativo -Archivo $pnputil -Argumentos '/scan-devices' -Descripcion 'Detectar hardware de nuevo'
    }
    Start-Sleep -Seconds 5
    $nuevo = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $d.InstanceId } | Select-Object -First 1
    if ($nuevo) { Write-Log ("Driver en uso ahora: {0} versión {1}" -f $nuevo.DriverProviderName, $nuevo.DriverVersion) 'OK' }
    Write-Log 'Para que Windows Update no vuelva a instalar la versión nueva, use "Bloquear drivers de Windows Update".' 'INFO'
    $Script:RequiereReinicio = $true
    return (Test-CodigoPnputil $codigo)
}

function Cambiar-BloqueoDriversWU {
    Mostrar-Titulo 'BLOQUEAR DRIVERS DE WINDOWS UPDATE'
    $bloqueado = Test-BloqueoDriversWU
    $politica = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $busqueda = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
    if ($bloqueado) {
        Write-Host '    Estado actual: Windows Update NO instala drivers automáticamente.' -ForegroundColor Yellow
        if (-not (Confirmar '¿Volver a permitir que Windows Update instale drivers?')) { return $false }
        try {
            Remove-ItemProperty -Path $politica -Name 'ExcludeWUDriversInQualityUpdate' -ErrorAction SilentlyContinue
            if (-not (Test-Path -Path $busqueda)) { New-Item -Path $busqueda -Force | Out-Null }
            Set-ItemProperty -Path $busqueda -Name 'SearchOrderConfig' -Value 1 -Type DWord -ErrorAction Stop
            Write-Log 'Windows Update puede volver a instalar drivers.' 'OK'
            return $true
        }
        catch { Write-Log "No se pudo cambiar: $($_.Exception.Message)" 'ERROR'; return $false }
    }
    Write-Host '    Estado actual: Windows Update instala drivers automáticamente.' -ForegroundColor Cyan
    Write-Host '    Bloquearlo sirve cuando Windows reinstala una y otra vez un driver que falla.' -ForegroundColor DarkGray
    Write-Host '    Desventaja: los drivers ya no se actualizan solos (hay que hacerlo a mano o con la herramienta del fabricante).' -ForegroundColor DarkGray
    if (-not (Confirmar '¿Bloquear la instalación automática de drivers por Windows Update?')) { return $false }
    try {
        if (-not (Test-Path -Path $politica)) { New-Item -Path $politica -Force | Out-Null }
        Set-ItemProperty -Path $politica -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -Type DWord -ErrorAction Stop
        if (-not (Test-Path -Path $busqueda)) { New-Item -Path $busqueda -Force | Out-Null }
        Set-ItemProperty -Path $busqueda -Name 'SearchOrderConfig' -Value 0 -Type DWord -ErrorAction Stop
        Write-Log 'Bloqueado: Windows Update ya no instalará drivers automáticamente. Se puede revertir desde esta misma opción.' 'OK'
        return $true
    }
    catch {
        Write-Log "No se pudo bloquear: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Abrir-PaginaFabricante {
    Mostrar-Titulo 'PÁGINA DE DRIVERS DEL FABRICANTE'
    $f = Get-InfoFabricante
    Write-Host ("    Marca: {0}" -f $f.Marca) -ForegroundColor White
    Write-Host ("    Modelo: {0}" -f $f.Modelo) -ForegroundColor White
    Write-Host ("    Número de serie: {0}" -f $f.Serie) -ForegroundColor White
    if ($f.Generico) { Write-Host '    Es una PC armada: se muestra la placa madre (los drivers se descargan de su fabricante).' -ForegroundColor DarkGray }
    if ($f.Herramientas.Count -gt 0) {
        Write-Host ("    Herramientas del fabricante instaladas: {0}" -f ($f.Herramientas -join ', ')) -ForegroundColor Green
        Write-Host '    Ábrala y use "Buscar actualizaciones": instala los drivers exactos del modelo.' -ForegroundColor DarkGray
    }
    try { if ($f.Serie) { Set-Clipboard -Value $f.Serie; Write-Log 'Número de serie copiado al portapapeles (péguelo en la página del fabricante).' 'INFO' } } catch { }
    if (-not $f.Url) {
        Write-Log 'No se conoce la página de este fabricante: busque "<marca> <modelo> drivers" en el navegador.' 'ADVERTENCIA'
        return $false
    }
    Write-Log "Página de drivers: $($f.Url)" 'INFO'
    Write-Host '    Consejos: descargue chipset, video, red/WiFi, audio y Bluetooth, en ese orden.' -ForegroundColor DarkGray
    Write-Host '    Si una CPU es Intel, también sirve "Intel Driver & Support Assistant"; para video AMD/NVIDIA, sus propias apps.' -ForegroundColor DarkGray
    if (Confirmar '¿Abrir la página de drivers en el navegador?') {
        return (Start-ComoUsuario -Programa $f.Url)
    }
    return $true
}

#endregion

#region ==================== PAQUETE C: IMPRESORA, WINDOWS UPDATE Y PERFIL ====================

function Elegir-Opcion {
    # Elige un elemento de una lista numerada. En la ventana la lista va DENTRO del cuadro de diálogo
    # (no solo en el registro de actividad). Devuelve el índice (desde 0) o -1 si se cancela o no es válido.
    param([string]$Pregunta, [string[]]$Opciones)
    $Opciones = @($Opciones)
    if ($Opciones.Count -eq 0) { return -1 }
    $lineas = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Opciones.Count; $i++) { $lineas.Add(('{0}. {1}' -f ($i + 1), $Opciones[$i])) }
    if ($Script:ModoInterfaz -eq 'Grafica') {
        $resp = Solicitar-Gui -Tipo 'Texto' -Texto (($lineas -join "`n") + "`n`n" + $Pregunta)
    }
    else {
        foreach ($l in $lineas) { Write-Host ("    {0}" -f $l) }
        Write-Host ''
        $resp = Read-Host $Pregunta
    }
    $n = 0
    if ([int]::TryParse("$resp".Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Opciones.Count) { return ($n - 1) }
    return -1
}

function Set-ValorDword {
    param([string]$Ruta, [string]$Nombre, [int]$Valor)
    if (-not (Test-Path -Path $Ruta)) { New-Item -Path $Ruta -Force | Out-Null }
    New-ItemProperty -Path $Ruta -Name $Nombre -Value $Valor -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function Reiniciar-Spooler {
    $null = Detener-Servicio 'Spooler'
    return (Iniciar-Servicio 'Spooler')
}

# ---------- Impresoras ----------

function Reparar-ImpresoraRpc {
    Mostrar-Titulo 'IMPRESORA: ERROR 0x0000011b / 0x00000709 AL CONECTAR'
    Write-Host '    Aparece al conectarse a una impresora COMPARTIDA en red tras una actualización de seguridad de Windows.' -ForegroundColor Cyan
    Write-Host '    Windows exige una autenticación RPC más estricta; la corrección la relaja (RpcAuthnLevelPrivacyEnabled = 0).' -ForegroundColor DarkGray
    Write-Host '    Conviene aplicarla en el equipo que COMPARTE la impresora y también en el que se conecta.' -ForegroundColor DarkGray
    Write-Host '    Baja un poco la seguridad de la impresión en red: úsela solo en redes de confianza.' -ForegroundColor Yellow
    $clave = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print'
    $actual = $null
    try { $actual = (Get-ItemProperty -Path $clave -Name 'RpcAuthnLevelPrivacyEnabled' -ErrorAction Stop).RpcAuthnLevelPrivacyEnabled } catch { }
    if ($null -ne $actual -and [int]$actual -eq 0) {
        Write-Log 'La corrección ya está aplicada en este equipo (RpcAuthnLevelPrivacyEnabled = 0).' 'INFO'
        if (-not (Confirmar '¿Quitarla y volver al valor seguro de Windows?')) { return $true }
        try { Remove-ItemProperty -Path $clave -Name 'RpcAuthnLevelPrivacyEnabled' -ErrorAction Stop; Write-Log 'Corrección quitada.' 'OK' }
        catch { Write-Log "No se pudo quitar la corrección: $($_.Exception.Message)" 'ERROR'; return $false }
        return (Reiniciar-Spooler)
    }
    if (-not (Confirmar '¿Aplicar la corrección (error 0x0000011b / 0x00000709) y reiniciar el servicio de impresión?')) {
        Write-Log 'Cancelado por el usuario.' 'INFO'
        return $false
    }
    try { Set-ValorDword $clave 'RpcAuthnLevelPrivacyEnabled' 0 }
    catch { Write-Log "No se pudo aplicar la corrección: $($_.Exception.Message)" 'ERROR'; return $false }
    $ok = Reiniciar-Spooler
    Write-Log 'Corrección aplicada. Vuelva a conectar la impresora compartida; si sigue igual, reinicie el equipo y aplique lo mismo en el que la comparte.' 'OK'
    return $ok
}

function Reparar-ImpresoraPredeterminada {
    Mostrar-Titulo 'IMPRESORA: ERROR 0x00000709 AL FIJAR LA PREDETERMINADA'
    Write-Host '    Windows administra solo la impresora predeterminada (la última que se usó) y choca con la elección manual.' -ForegroundColor Cyan
    Write-Host '    La corrección desactiva esa administración automática para el usuario de la sesión (LegacyDefaultPrinterMode = 1).' -ForegroundColor DarkGray
    $perfil = Get-PerfilUsuarioActivo
    $clave = "$($perfil.Registro)\Software\Microsoft\Windows NT\CurrentVersion\Windows"
    $actual = $null
    try { $actual = (Get-ItemProperty -Path $clave -Name 'LegacyDefaultPrinterMode' -ErrorAction Stop).LegacyDefaultPrinterMode } catch { }
    if ($null -ne $actual -and [int]$actual -eq 1) {
        Write-Log ("La corrección ya está aplicada para {0}." -f $perfil.Usuario) 'INFO'
        if (-not (Confirmar '¿Quitarla y dejar que Windows vuelva a administrar la impresora predeterminada?')) { return $true }
        try { Remove-ItemProperty -Path $clave -Name 'LegacyDefaultPrinterMode' -ErrorAction Stop; Write-Log 'Corrección quitada.' 'OK'; return $true }
        catch { Write-Log "No se pudo quitar la corrección: $($_.Exception.Message)" 'ERROR'; return $false }
    }
    if (-not (Confirmar ("¿Aplicar la corrección para el usuario {0}?" -f $perfil.Usuario))) {
        Write-Log 'Cancelado por el usuario.' 'INFO'
        return $false
    }
    try { Set-ValorDword $clave 'LegacyDefaultPrinterMode' 1 }
    catch { Write-Log "No se pudo aplicar la corrección: $($_.Exception.Message)" 'ERROR'; return $false }
    Write-Log ("Listo para {0}. Ya puede elegir la impresora predeterminada a mano en Configuración > Impresoras." -f $perfil.Usuario) 'OK'
    return $true
}

function Reparar-ImpresoraDriverBloqueado {
    Mostrar-Titulo 'IMPRESORA: ERROR 0x00000bcb / 0x0000007c (DRIVER BLOQUEADO)'
    Write-Host '    Desde las actualizaciones de 2021 (PrintNightmare) solo un administrador puede instalar drivers de impresoras compartidas.' -ForegroundColor Cyan
    Write-Host '    Un usuario normal ve el error 0x00000bcb o 0x0000007c al conectar la impresora.' -ForegroundColor DarkGray
    Write-Host '    Lo MÁS SEGURO es instalar usted el driver como administrador y no cambiar nada.' -ForegroundColor Yellow
    Write-Host '    Esta opción permite instalarlo a usuarios normales y deja el equipo MENOS protegido.' -ForegroundColor Yellow
    $clave = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
    $actual = $null
    try { $actual = (Get-ItemProperty -Path $clave -Name 'RestrictDriverInstallationToAdministrators' -ErrorAction Stop).RestrictDriverInstallationToAdministrators } catch { }
    if ($null -ne $actual -and [int]$actual -eq 0) {
        Write-Log 'Ya se permite a usuarios normales instalar drivers de impresora.' 'INFO'
        if (-not (Confirmar '¿Volver a restringirlo solo a administradores (recomendado)?')) { return $true }
        try { Set-ValorDword $clave 'RestrictDriverInstallationToAdministrators' 1; Write-Log 'Restringido de nuevo a administradores.' 'OK' }
        catch { Write-Log "No se pudo cambiar: $($_.Exception.Message)" 'ERROR'; return $false }
        return (Reiniciar-Spooler)
    }
    if (-not (Confirmar '¿Permitir que usuarios normales instalen drivers de impresora? (menos seguro)')) {
        Write-Log 'Cancelado por el usuario.' 'INFO'
        return $false
    }
    try { Set-ValorDword $clave 'RestrictDriverInstallationToAdministrators' 0 }
    catch { Write-Log "No se pudo aplicar el cambio: $($_.Exception.Message)" 'ERROR'; return $false }
    $ok = Reiniciar-Spooler
    Write-Log 'Hecho. El usuario ya puede conectar la impresora. Cuando termine, vuelva a ejecutar esta opción para restringirlo de nuevo.' 'OK'
    return $ok
}

function Reinstalar-Impresora {
    Mostrar-Titulo 'REINSTALAR UNA IMPRESORA (PUERTO Y DRIVER)'
    $todas = @()
    try { $todas = @(Get-Printer -ErrorAction Stop) }
    catch { Write-Log "No se pudo listar las impresoras: $($_.Exception.Message)" 'ERROR'; return $false }
    $virtuales = @('PORTPROMPT:', 'nul:', 'SHRFAX:', 'FILE:')
    $impresoras = @($todas | Where-Object { $virtuales -notcontains "$($_.PortName)" -and "$($_.DriverName)" -notmatch 'Microsoft (Print To PDF|XPS Document Writer)|OneNote' })
    if ($impresoras.Count -eq 0) { Write-Log 'No hay impresoras físicas ni de red instaladas.' 'INFO'; return $true }

    $opciones = @($impresoras | ForEach-Object { '{0}   (puerto {1}, driver {2})' -f $_.Name, $_.PortName, $_.DriverName })
    $idx = Elegir-Opcion 'Número de la impresora a reinstalar (Cancelar = salir)' $opciones
    if ($idx -lt 0) { Write-Log 'Operación cancelada.' 'INFO'; return $false }
    $p = $impresoras[$idx]
    $nombre = "$($p.Name)"
    $driver = "$($p.DriverName)"
    $puerto = "$($p.PortName)"
    $esConexion = ("$($p.Type)" -eq 'Connection')

    $infoPuerto = $null
    if (-not $esConexion) { try { $infoPuerto = Get-PrinterPort -Name $puerto -ErrorAction Stop } catch { } }
    $otrasPuerto = @($todas | Where-Object { "$($_.Name)" -ne $nombre -and "$($_.PortName)" -eq $puerto }).Count
    $otrasDriver = @($todas | Where-Object { "$($_.Name)" -ne $nombre -and "$($_.DriverName)" -eq $driver }).Count
    $recrearPuerto = $false
    if ($infoPuerto -and "$($infoPuerto.PrinterHostAddress)" -and $otrasPuerto -eq 0 -and "$($infoPuerto.Protocol)" -notmatch '^(LPR|2)$') { $recrearPuerto = $true }

    Write-Host ''
    Write-Host ("    Impresora: {0}" -f $nombre) -ForegroundColor White
    Write-Host ("    Driver:    {0}" -f $driver)
    Write-Host ("    Puerto:    {0}" -f $puerto)
    if ($esConexion) { Write-Host '    Es una impresora compartida por otro equipo: se quita y se vuelve a conectar.' -ForegroundColor DarkGray }
    elseif ($recrearPuerto) { Write-Host ("    Puerto TCP/IP hacia {0}: se borra y se crea de nuevo." -f $infoPuerto.PrinterHostAddress) -ForegroundColor DarkGray }
    else { Write-Host '    El puerto se conserva (USB, WSD o usado por otra impresora). Si es USB, desconecte y vuelva a conectar el cable.' -ForegroundColor DarkGray }
    if (-not (Confirmar ("¿Quitar y volver a agregar '{0}'?" -f $nombre))) { Write-Log 'Cancelado por el usuario.' 'INFO'; return $false }

    $reinstalarDriver = $false
    if (-not $esConexion -and $otrasDriver -eq 0) {
        $reinstalarDriver = Confirmar '¿Reinstalar también el driver? Se quita y se vuelve a registrar desde el almacén de drivers de Windows. Si el paquete no está en el equipo, tendrá que instalar el del fabricante.'
    }

    try { Remove-Printer -Name $nombre -ErrorAction Stop; Write-Log ("Impresora '{0}' quitada." -f $nombre) 'OK' }
    catch { Write-Log ("No se pudo quitar la impresora: {0}" -f $_.Exception.Message) 'ERROR'; return $false }

    if ($esConexion) {
        try { Add-Printer -ConnectionName $nombre -ErrorAction Stop; Write-Log ("Impresora '{0}' conectada de nuevo." -f $nombre) 'OK'; return $true }
        catch {
            Write-Log ("No se pudo volver a conectar '{0}': {1}" -f $nombre, $_.Exception.Message) 'ERROR'
            Write-Log 'Si el error es 0x0000011b o 0x00000709, use "Impresora: error 0x0000011b / 0x00000709 al conectar".' 'INFO'
            return $false
        }
    }

    if ($recrearPuerto) {
        try {
            Remove-PrinterPort -Name $puerto -ErrorAction Stop
            $pp = @{ Name = $puerto; PrinterHostAddress = "$($infoPuerto.PrinterHostAddress)"; ErrorAction = 'Stop' }
            if ($infoPuerto.PortNumber) { $pp.PortNumber = [int]$infoPuerto.PortNumber }
            if ($infoPuerto.SNMPEnabled) { $pp.SNMP = [int]$infoPuerto.SNMPIndex; $pp.SNMPCommunity = "$($infoPuerto.SNMPCommunity)" }
            Add-PrinterPort @pp
            Write-Log ("Puerto '{0}' recreado ({1})." -f $puerto, $infoPuerto.PrinterHostAddress) 'OK'
        }
        catch { Write-Log ("No se pudo recrear el puerto '{0}': {1}" -f $puerto, $_.Exception.Message) 'ADVERTENCIA' }
    }

    if ($reinstalarDriver) {
        try {
            Remove-PrinterDriver -Name $driver -ErrorAction Stop
            Add-PrinterDriver -Name $driver -ErrorAction Stop
            Write-Log ("Driver '{0}' reinstalado." -f $driver) 'OK'
        }
        catch {
            Write-Log ("No se pudo reinstalar el driver '{0}': {1}" -f $driver, $_.Exception.Message) 'ERROR'
            Write-Log ("La impresora '{0}' quedó QUITADA. Instale el driver del fabricante y agréguela con el puerto {1}." -f $nombre, $puerto) 'ADVERTENCIA'
            return $false
        }
    }

    try {
        $ap = @{ Name = $nombre; DriverName = $driver; PortName = $puerto; ErrorAction = 'Stop' }
        if ($p.Shared) { $ap.Shared = $true; $ap.ShareName = "$($p.ShareName)" }
        if ("$($p.Location)") { $ap.Location = "$($p.Location)" }
        if ("$($p.Comment)") { $ap.Comment = "$($p.Comment)" }
        Add-Printer @ap
        Write-Log ("Impresora '{0}' agregada de nuevo (driver {1}, puerto {2})." -f $nombre, $driver, $puerto) 'OK'
        Write-Log 'Si era la predeterminada, vuelva a marcarla: la predeterminada es de cada usuario.' 'INFO'
        return $true
    }
    catch {
        Write-Log ("No se pudo agregar de nuevo '{0}': {1}" -f $nombre, $_.Exception.Message) 'ERROR'
        Write-Log ("Agréguela a mano con: driver '{0}' y puerto '{1}'." -f $driver, $puerto) 'ADVERTENCIA'
        return $false
    }
}

# ---------- Windows Update a fondo ----------

function Reparar-WindowsUpdateProfundo {
    Mostrar-Titulo 'WINDOWS UPDATE: REPARACIÓN A FONDO'
    Write-Host '    Para cuando "Reparar Windows Update" no basta (error 0x80070002, 0x8024xxxx, se queda en 0%, no busca, etc.).' -ForegroundColor Cyan
    Write-Host '    Hace, en orden:' -ForegroundColor White
    Write-Host '      1. Rehabilita los servicios de actualización si estaban deshabilitados.'
    Write-Host '      2. Detiene los servicios y limpia la cola de BITS y la caché de Optimización de entrega.'
    Write-Host '      3. Vuelve a registrar los componentes de Windows Update.'
    Write-Host '      4. Renombra SoftwareDistribution y catroot2 (reparación normal).'
    Write-Host '      5. Revisa políticas que bloquean las actualizaciones (y las quita si usted acepta).'
    Write-Host '      6. Revisa el proxy de WinHTTP.'
    Write-Host '      7. Revisa actualizaciones pendientes sin terminar.'
    Write-Host '      8. Opcional: DISM + SFC.'
    Write-Host '    No borra archivos personales ni programas. Se pierde el historial de actualizaciones.' -ForegroundColor DarkGray
    if (-not (Confirmar '¿Continuar con la reparación a fondo de Windows Update?')) {
        Write-Log 'Reparación a fondo cancelada por el usuario.' 'INFO'
        return $false
    }
    $ok = $true

    Write-Log '1/8 Revisando que los servicios no estén deshabilitados...' 'INFO'
    foreach ($par in @(@('wuauserv', 'Manual'), @('bits', 'Manual'), @('cryptsvc', 'Automatic'), @('UsoSvc', 'Manual'), @('TrustedInstaller', 'Manual'))) {
        $s = Get-Service -Name $par[0] -ErrorAction SilentlyContinue
        if ($s -and "$($s.StartType)" -eq 'Disabled') {
            try { Set-Service -Name $par[0] -StartupType $par[1] -ErrorAction Stop; Write-Log ("El servicio {0} estaba deshabilitado: ahora es {1}." -f $par[0], $par[1]) 'OK' }
            catch { Write-Log ("No se pudo habilitar el servicio {0}: {1}" -f $par[0], $_.Exception.Message) 'ADVERTENCIA'; $ok = $false }
        }
    }

    Write-Log '2/8 Deteniendo servicios y limpiando BITS y la caché de entrega...' 'INFO'
    foreach ($s in @('wuauserv', 'bits', 'cryptsvc', 'msiserver', 'UsoSvc', 'DoSvc')) { $null = Detener-Servicio $s }
    $qmgr = Join-Path $env:ALLUSERSPROFILE 'Microsoft\Network\Downloader'
    $archivos = @(Get-ChildItem -LiteralPath $qmgr -Filter 'qmgr*.dat' -Force -ErrorAction SilentlyContinue)
    foreach ($a in $archivos) { Remove-Item -LiteralPath $a.FullName -Force -ErrorAction SilentlyContinue }
    Write-Log ("Cola de BITS: {0} archivo(s) borrados (se regeneran solos)." -f $archivos.Count) 'INFO'
    $cacheEntrega = Join-Path $env:windir 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    $mb = [math]::Round((Get-TamanoCarpeta $cacheEntrega) / 1MB)
    Limpiar-Carpeta $cacheEntrega
    Write-Log ("Caché de Optimización de entrega: {0} MB limpiados." -f $mb) 'INFO'

    Write-Log '3/8 Registrando de nuevo los componentes de Windows Update...' 'INFO'
    $regsvr = Get-RutaSistema 'regsvr32.exe'
    $dlls = @('atl.dll', 'urlmon.dll', 'msxml3.dll', 'msxml6.dll', 'actxprxy.dll', 'softpub.dll', 'wintrust.dll', 'initpki.dll', 'dssenh.dll', 'rsaenh.dll', 'cryptdlg.dll',
        'wuapi.dll', 'wuaueng.dll', 'wuaueng1.dll', 'wucltui.dll', 'wucltux.dll', 'wups.dll', 'wups2.dll', 'wuweb.dll', 'wuwebv.dll', 'muweb.dll', 'qmgr.dll', 'qmgrprxy.dll')
    $registrados = 0
    $sinRegistro = 0
    foreach ($dll in $dlls) {
        $ruta = Get-RutaSistema $dll
        if (-not [System.IO.Path]::IsPathRooted($ruta) -or -not (Test-Path -LiteralPath $ruta)) { continue }
        try {
            $proc = Start-Process -FilePath $regsvr -ArgumentList ('/s "{0}"' -f $ruta) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($proc.ExitCode -eq 0) { $registrados++ } else { $sinRegistro++ }
        }
        catch { $sinRegistro++ }
    }
    Write-Log ("Componentes registrados: {0}. Sin registro propio (normal en Windows reciente): {1}." -f $registrados, $sinRegistro) 'INFO'

    Write-Log '4/8 Renombrando SoftwareDistribution y catroot2...' 'INFO'
    $r = @(Reparar-WindowsUpdate -SinConfirmar)
    if (-not [bool]$r[-1]) { $ok = $false }

    Write-Log '5/8 Revisando políticas que bloquean Windows Update...' 'INFO'
    $clavePol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $politicas = New-Object System.Collections.Generic.List[string]
    foreach ($ruta in @($clavePol, "$clavePol\AU")) {
        $k = Get-Item -Path $ruta -ErrorAction SilentlyContinue
        if ($k) { foreach ($n in @($k.GetValueNames() | Where-Object { $_ })) { $politicas.Add(("{0} = {1}" -f $n, $k.GetValue($n))) } }
    }
    if ($politicas.Count -eq 0) {
        Write-Log 'No hay políticas de Windows Update configuradas.' 'OK'
    }
    else {
        Write-Log ("Políticas de Windows Update encontradas: {0}" -f ($politicas -join '; ')) 'ADVERTENCIA'
        $enDominio = $false
        try { $enDominio = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }
        if ($enDominio) {
            Write-Log 'El equipo está en un dominio: las políticas las define la empresa y no se tocan.' 'INFO'
        }
        elseif (Confirmar ("Estas políticas pueden impedir las actualizaciones:`n`n{0}`n`n¿Quitarlas? Se respaldan en la carpeta Reportes. Si el equipo lo administra la empresa (Intune), pueden volver." -f ($politicas -join "`n"))) {
            if (-not (Test-Path -LiteralPath $Script:DirReportes)) { New-Item -ItemType Directory -Path $Script:DirReportes -Force | Out-Null }
            $respaldo = Join-Path $Script:DirReportes ('WindowsUpdate_politicas_{0}.reg' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            $c = Invoke-Nativo -Archivo (Get-RutaSistema 'reg.exe') -Argumentos ('export "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "{0}" /y' -f $respaldo) -Descripcion 'Respaldo de las políticas de Windows Update'
            if ($c -eq 0 -and (Test-Path -LiteralPath $respaldo)) {
                try { Remove-Item -Path $clavePol -Recurse -Force -ErrorAction Stop; Write-Log ("Políticas quitadas. Respaldo: {0}" -f $respaldo) 'OK' }
                catch { Write-Log ("No se pudieron quitar las políticas: {0}" -f $_.Exception.Message) 'ERROR'; $ok = $false }
            }
            else {
                Write-Log 'No se pudo respaldar las políticas; no se quitó nada.' 'ERROR'
                $ok = $false
            }
        }
    }

    Write-Log '6/8 Revisando el proxy de WinHTTP...' 'INFO'
    $netsh = Get-RutaSistema 'netsh.exe'
    $proxy = ''
    try { $proxy = (& $netsh winhttp show proxy | Out-String) } catch { }
    if ($proxy -and $proxy -notmatch 'Direct access|Acceso directo') {
        Write-Log ("WinHTTP tiene un proxy configurado: {0}" -f (($proxy -replace '\s+', ' ').Trim())) 'ADVERTENCIA'
        if (Confirmar '¿Quitar el proxy de WinHTTP? Un proxy mal puesto impide las actualizaciones. Si es el proxy de la empresa, déjelo.') {
            $null = Invoke-Nativo -Archivo $netsh -Argumentos 'winhttp reset proxy' -Descripcion 'Quitar el proxy de WinHTTP'
        }
    }
    else {
        Write-Log 'Sin proxy en WinHTTP.' 'OK'
    }

    Write-Log '7/8 Revisando actualizaciones pendientes sin terminar...' 'INFO'
    $pendiente = Test-Path -LiteralPath (Join-Path $env:windir 'WinSxS\pending.xml')
    $rebootCbs = Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if ($pendiente -or $rebootCbs) {
        Write-Log 'Hay una actualización pendiente que no terminó. Reinicie el equipo y vuelva a buscar actualizaciones; si el error vuelve, ejecute DISM + SFC.' 'ADVERTENCIA'
    }
    else {
        Write-Log 'No hay actualizaciones pendientes sin terminar.' 'OK'
    }

    Write-Log '8/8 Archivos del sistema (opcional)...' 'INFO'
    if (Confirmar '¿Ejecutar también DISM + SFC? Repara los archivos de Windows que usa Windows Update. Tarda de 10 a 30 minutos y necesita internet.') {
        $r = @(Reparar-ArchivosSistema)
        if (-not [bool]$r[-1]) { $ok = $false }
    }

    try {
        Start-Process -FilePath (Get-RutaSistema 'UsoClient.exe') -ArgumentList 'StartScan' -WindowStyle Hidden -ErrorAction Stop
        Write-Log 'Se pidió a Windows que busque actualizaciones.' 'INFO'
    }
    catch { }
    $Script:RequiereReinicio = $true
    if ($ok) { Write-Log 'Reparación a fondo terminada. Reinicie el equipo y busque actualizaciones en Configuración.' 'OK' }
    else { Write-Log 'La reparación a fondo terminó con avisos (vea el registro). Reinicie y vuelva a probar.' 'ADVERTENCIA' }
    return $ok
}

# ---------- Perfil de usuario ----------

function Get-NombreUsuarioDeSid {
    param([string]$Sid)
    try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value }
    catch { return '' }
}

function Reparar-PerfilUsuario {
    Mostrar-Titulo 'REPARAR PERFIL DE USUARIO (TEMPORAL O DAÑADO)'
    Write-Host '    Cuando el usuario inicia sesión y ve un escritorio vacío o el aviso "No se pudo cargar su perfil" (perfil TEMP).' -ForegroundColor Cyan
    Write-Host '    Windows deja la clave real del perfil con el sufijo .bak en el registro. Aquí se restaura (sin tocar sus archivos).' -ForegroundColor DarkGray
    $lista = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $porSid = @{}
    foreach ($k in @(Get-ChildItem -Path $lista -ErrorAction SilentlyContinue)) {
        $n = "$($k.PSChildName)"
        if ($n -match '^(S-1-5-21-[\d-]+?)(\.bak)?$') {
            $sid = $Matches[1]
            if (-not $porSid.ContainsKey($sid)) { $porSid[$sid] = @{ Normal = $null; Bak = $null } }
            if ($Matches[2]) { $porSid[$sid].Bak = $k } else { $porSid[$sid].Normal = $k }
        }
    }
    $raizUsuarios = Join-Path $env:SystemDrive 'Users'
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($sid in $porSid.Keys) {
        $par = $porSid[$sid]
        $usuario = Get-NombreUsuarioDeSid $sid
        if (-not $usuario) { $usuario = $sid }
        $rutaNormal = ''
        if ($par.Normal) { $rutaNormal = "$($par.Normal.GetValue('ProfileImagePath'))" }
        if ($par.Bak) {
            $carpeta = "$($par.Bak.GetValue('ProfileImagePath'))"
            if (-not $carpeta -or $carpeta -match '\\TEMP(\.|$)' -or -not (Test-Path -LiteralPath $carpeta)) {
                Write-Log ("{0}: la clave .bak apunta a una carpeta que no existe o es temporal ({1}); no se puede restaurar sola." -f $usuario, $carpeta) 'ADVERTENCIA'
                continue
            }
            if ($par.Normal -and $rutaNormal -notmatch '\\TEMP(\.|$)' -and $rutaNormal -ne $carpeta) {
                Write-Log ("{0}: hay dos perfiles registrados con carpetas distintas ({1} y {2}); corríjalo a mano en el registro." -f $usuario, $rutaNormal, $carpeta) 'ADVERTENCIA'
                continue
            }
            $plan.Add([pscustomobject]@{ Tipo = 'Bak'; Sid = $sid; Usuario = $usuario; Carpeta = $carpeta; TieneNormal = [bool]$par.Normal; Texto = ("{0}: restaurar la clave .bak (carpeta {1})" -f $usuario, $carpeta) })
        }
        elseif ($par.Normal -and $rutaNormal -match '\\TEMP(\.|$)') {
            $corto = ($usuario -split '\\')[-1]
            $candidatas = @(Get-ChildItem -LiteralPath $raizUsuarios -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $corto -or $_.Name -like "$corto.*" })
            if ($candidatas.Count -eq 1) {
                $plan.Add([pscustomobject]@{ Tipo = 'Repuntar'; Sid = $sid; Usuario = $usuario; Carpeta = $candidatas[0].FullName; TieneNormal = $true; Texto = ("{0}: usa un perfil temporal y no hay copia .bak; apuntarlo a {1}" -f $usuario, $candidatas[0].FullName) })
            }
            else {
                Write-Log ("{0}: usa un perfil temporal, no hay copia .bak y no se pudo identificar su carpeta en {1} ({2} candidata(s)). Cree un usuario nuevo y copie los datos." -f $usuario, $raizUsuarios, $candidatas.Count) 'ADVERTENCIA'
            }
        }
    }

    if ($plan.Count -eq 0) {
        Write-Log 'No se encontraron perfiles dañados (.bak) ni temporales que se puedan reparar solos.' 'INFO'
        $activo = Get-PerfilUsuarioActivo
        if ("$($activo.Ruta)" -match '\\TEMP(\.|$)') { Write-Log 'Aun así, el usuario de la sesión usa un perfil TEMP: revise los avisos de arriba.' 'ADVERTENCIA' }
        return $true
    }

    $texto = "Se repararán estos perfiles:`n`n" + (($plan | ForEach-Object { '- ' + $_.Texto }) -join "`n") + "`n`nSe respalda el registro antes. No se borra ningún archivo del usuario. Después el usuario debe cerrar sesión o reiniciar el equipo. ¿Continuar?"
    if (-not (Confirmar $texto)) { Write-Log 'Reparación de perfil cancelada por el usuario.' 'INFO'; return $false }

    if (-not (Test-Path -LiteralPath $Script:DirReportes)) { New-Item -ItemType Directory -Path $Script:DirReportes -Force | Out-Null }
    $respaldo = Join-Path $Script:DirReportes ('ProfileList_{0}.reg' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $c = Invoke-Nativo -Archivo (Get-RutaSistema 'reg.exe') -Argumentos ('export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" "{0}" /y' -f $respaldo) -Descripcion 'Respaldo de la lista de perfiles'
    if ($c -ne 0 -or -not (Test-Path -LiteralPath $respaldo)) {
        Write-Log 'No se pudo respaldar el registro; no se cambió nada.' 'ERROR'
        return $false
    }
    Write-Log ("Respaldo del registro: {0}" -f $respaldo) 'INFO'

    $ok = $true
    $activo = Get-PerfilUsuarioActivo
    foreach ($e in $plan) {
        $normal = "$lista\$($e.Sid)"
        $bak = "$normal.bak"
        try {
            if ($e.Tipo -eq 'Bak') {
                if (Test-Path -LiteralPath $normal) { Remove-Item -LiteralPath $normal -Recurse -Force -ErrorAction Stop }
                Rename-Item -LiteralPath $bak -NewName $e.Sid -ErrorAction Stop
            }
            else {
                Set-ItemProperty -LiteralPath $normal -Name 'ProfileImagePath' -Value $e.Carpeta -Type ExpandString -ErrorAction Stop
            }
            Set-ItemProperty -LiteralPath $normal -Name 'RefCount' -Value 0 -Type DWord -ErrorAction Stop
            Set-ItemProperty -LiteralPath $normal -Name 'State' -Value 0 -Type DWord -ErrorAction Stop
            Write-Log ("Perfil de {0} reparado (carpeta {1})." -f $e.Usuario, $e.Carpeta) 'OK'
            if ($e.Sid -eq "$($activo.SID)") { Write-Log 'Es el usuario de la sesión actual: debe cerrar sesión o reiniciar para que se aplique.' 'ADVERTENCIA' }
        }
        catch {
            Write-Log ("No se pudo reparar el perfil de {0}: {1}" -f $e.Usuario, $_.Exception.Message) 'ERROR'
            $ok = $false
        }
    }
    if ($ok) { Write-Log ("Listo. Si algo sale mal, el respaldo está en {0} (doble clic para restaurarlo)." -f $respaldo) 'OK' }
    $Script:RequiereReinicio = $true
    return $ok
}

#endregion

#region ==================== CATÁLOGO DE ACCIONES ====================

# Lista única de acciones: la usan la interfaz gráfica (tarjetas por categoría) y el submenú de consola.
$Script:Catalogo = @(
    @{ Cat = 'Sistema'; Titulo = 'Reparar archivos de Windows'; Desc = 'DISM + SFC. Repara archivos dañados del sistema (10-30 min, necesita internet).'; Cmd = 'Reparar-ArchivosSistema' }
    @{ Cat = 'Sistema'; Titulo = 'Reparar Windows Update'; Desc = 'Cuando las actualizaciones fallan o se quedan pegadas.'; Cmd = 'Reparar-WindowsUpdate' }
    @{ Cat = 'Sistema'; Titulo = 'Windows Update a fondo'; Desc = 'Cuando la reparación normal no basta: servicios, BITS, componentes, caché de entrega, políticas, proxy y DISM opcional.'; Aviso = 'Tarda unos minutos; pide reiniciar'; Cmd = 'Reparar-WindowsUpdateProfundo'; Avanzada = $true }
    @{ Cat = 'Sistema'; Titulo = 'Reparar perfil de usuario'; Desc = 'Perfil temporal (TEMP) o dañado (clave .bak): lo restaura sin tocar los archivos del usuario.'; Aviso = 'Respalda el registro; el usuario debe reiniciar'; Cmd = 'Reparar-PerfilUsuario'; Avanzada = $true }
    @{ Cat = 'Sistema'; Titulo = 'Desinstalar una actualización'; Desc = 'Quita una actualización reciente si algo dejó de funcionar después de instalarla.'; Cmd = 'Desinstalar-Actualizacion'; Avanzada = $true }
    @{ Cat = 'Sistema'; Titulo = 'Limpiar archivos temporales'; Desc = 'Temporales, caché de Windows Update y, opcionalmente, la papelera.'; Cmd = 'Limpiar-Temporales' }
    @{ Cat = 'Sistema'; Titulo = 'Revisar disco (CHKDSK)'; Desc = 'Escaneo en línea y CHKDSK al reiniciar si encuentra errores.'; Cmd = 'Revisar-Disco' }
    @{ Cat = 'Sistema'; Titulo = 'Programas de inicio'; Desc = 'Ver, desactivar y volver a activar lo que arranca con Windows (programas, carpeta Inicio y tareas programadas), con el tiempo de arranque.'; Cmd = 'Mostrar-InicioGui'; Ui = $true }
    @{ Cat = 'Sistema'; Titulo = 'Optimizar rendimiento'; Desc = 'Programas de inicio, plan de energía, efectos visuales e inicio rápido.'; Cmd = 'Optimizar-Rendimiento'; Avanzada = $true }
    @{ Cat = 'Sistema'; Titulo = 'Menú Inicio y búsqueda'; Desc = 'Cuando el menú Inicio o la búsqueda no abren o no encuentran nada.'; Cmd = 'Reparar-MenuInicio'; Avanzada = $true }
    @{ Cat = 'Sistema'; Titulo = 'Iconos y miniaturas'; Desc = 'Reconstruye la caché de iconos cuando se ven en blanco o equivocados.'; Cmd = 'Reparar-CacheIconos'; Avanzada = $true }
    @{ Cat = 'Sistema'; Titulo = 'Reiniciar Explorador'; Desc = 'Barra de tareas o escritorio congelados.'; Cmd = 'Reiniciar-Explorador' }
    @{ Cat = 'Sistema'; Titulo = 'Microsoft Store y apps'; Desc = 'Limpia la caché de la Store y la vuelve a registrar.'; Cmd = 'Reparar-Store' }
    @{ Cat = 'Sistema'; Titulo = 'Sincronizar fecha y hora'; Desc = 'La hora mal causa errores de certificados y de inicio de sesión.'; Cmd = 'Sincronizar-Hora' }
    @{ Cat = 'Sistema'; Titulo = 'Crear punto de restauración'; Desc = 'Recomendado antes de cualquier cambio grande.'; Cmd = 'New-PuntoRestauracion' }

    @{ Cat = 'Drivers'; Titulo = 'Buscar drivers en Windows Update'; Desc = 'Lista los drivers disponibles para este equipo y marca cuáles corrigen un dispositivo con problema.'; Cmd = 'Buscar-DriversWindowsUpdate'; Avanzada = $true }
    @{ Cat = 'Drivers'; Titulo = 'Página de drivers del fabricante'; Desc = 'Detecta marca, modelo y serie, y abre la página de soporte del equipo.'; Cmd = 'Abrir-PaginaFabricante'; Avanzada = $true }
    @{ Cat = 'Drivers'; Titulo = 'Respaldar todos los drivers'; Desc = 'Copia los drivers a una carpeta o USB. Ideal antes de formatear.'; Cmd = 'Respaldar-Drivers'; Avanzada = $true }
    @{ Cat = 'Drivers'; Titulo = 'Restaurar o instalar drivers desde carpeta/USB'; Desc = 'Instala un respaldo o drivers (.inf) descargados del fabricante.'; Cmd = 'Instalar-DriversCarpeta'; Avanzada = $true }
    @{ Cat = 'Drivers'; Titulo = 'Reinstalar un dispositivo'; Desc = 'Lo quita y Windows lo vuelve a detectar con su driver.'; Cmd = 'Reinstalar-Dispositivo'; Avanzada = $true }
    @{ Cat = 'Drivers'; Titulo = 'Revertir el driver'; Desc = 'Vuelve a la versión anterior si una actualización lo rompió.'; Aviso = 'Crea punto de restauración'; Cmd = 'Revertir-Driver'; Avanzada = $true }
    @{ Cat = 'Drivers'; Titulo = 'Bloquear drivers de Windows Update'; Desc = 'Activa o desactiva que Windows instale drivers solo (cuando reinstala uno que falla).'; Cmd = 'Cambiar-BloqueoDriversWU'; Avanzada = $true }

    @{ Cat = 'Red e internet'; Titulo = 'Reparar red (completo)'; Desc = 'DNS, IP, Winsock y TCP/IP. Requiere reiniciar.'; Aviso = 'Corta AnyDesk / TeamViewer'; Cmd = 'Reparar-Red' }
    @{ Cat = 'Red e internet'; Titulo = 'Reparar red (suave)'; Desc = 'DNS, Winsock y TCP/IP sin cortar la conexión. Requiere reiniciar.'; Cmd = 'Reparar-Red -Suave' }
    @{ Cat = 'Red e internet'; Titulo = 'Quitar proxy y restablecer hosts'; Desc = '"Sin internet" por proxy falso o archivo hosts modificado (con respaldo).'; Cmd = 'Reparar-ProxyHosts'; Avanzada = $true }
    @{ Cat = 'Red e internet'; Titulo = 'Limpiar caché de navegadores'; Desc = 'Chrome, Edge, Brave y Firefox. No borra contraseñas ni historial.'; Cmd = 'Limpiar-Navegadores'; Avanzada = $true }

    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Reparar sonido'; Desc = 'Servicios, driver, salidas, volumen y silencio, con prueba de sonido.'; Cmd = 'Reparar-Audio' }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Micrófono y cámara'; Desc = 'Permisos de privacidad, silencio y dispositivos deshabilitados.'; Cmd = 'Reparar-MicrofonoCamara'; Avanzada = $true }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Bluetooth y USB'; Desc = 'Reinicia Bluetooth y evita que Windows apague el USB para ahorrar energía.'; Cmd = 'Reparar-BluetoothUsb'; Avanzada = $true }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Impresora'; Desc = 'Vacía la cola atascada y vuelve a poner la impresora en línea.'; Cmd = 'Reparar-Impresora' }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Reinstalar impresora (puerto y driver)'; Desc = 'La quita y la vuelve a agregar con el mismo driver y puerto; opcionalmente reinstala el driver.'; Cmd = 'Reinstalar-Impresora'; Avanzada = $true }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Impresora: error 0x0000011b / 0x00000709 al conectar'; Desc = 'Impresora compartida en red que falla tras una actualización de Windows.'; Aviso = 'Baja un poco la seguridad; reversible'; Cmd = 'Reparar-ImpresoraRpc'; Avanzada = $true }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Impresora: error 0x00000709 al fijar la predeterminada'; Desc = 'Windows no deja elegir la impresora predeterminada.'; Cmd = 'Reparar-ImpresoraPredeterminada'; Avanzada = $true }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Impresora: error 0x00000bcb / 0x0000007c (driver bloqueado)'; Desc = 'Un usuario normal no puede instalar el driver de una impresora compartida.'; Aviso = 'Menos seguro; reversible'; Cmd = 'Reparar-ImpresoraDriverBloqueado'; Avanzada = $true }
    @{ Cat = 'Sonido y dispositivos'; Titulo = 'Reporte de batería'; Desc = 'Desgaste y uso de la batería (laptops).'; Cmd = 'Get-ReporteBateria' }

    @{ Cat = 'Outlook y Office'; Titulo = 'Reparación rápida de Outlook'; Desc = 'Cierra Outlook y limpia caché, temporales de adjuntos y libreta sin conexión.'; Cmd = 'Limpiar-CacheOutlook' }
    @{ Cat = 'Outlook y Office'; Titulo = 'Outlook en modo seguro'; Desc = 'Abre Outlook sin complementos para ver si uno causa el problema.'; Cmd = 'Abrir-OutlookModoSeguro' }
    @{ Cat = 'Outlook y Office'; Titulo = 'Pide contraseña siempre'; Desc = 'Borra las credenciales en caché de Office (con respaldo).'; Cmd = 'Reparar-InicioSesionOffice' }
    @{ Cat = 'Outlook y Office'; Titulo = 'Reconstruir OST'; Desc = 'Outlook vuelve a descargar el buzón; el archivo viejo se renombra.'; Cmd = 'Reconstruir-Ost' }
    @{ Cat = 'Outlook y Office'; Titulo = 'Reparación rápida de Office'; Desc = 'Sin internet, 5 a 10 minutos.'; Cmd = "Reparar-Office -Tipo 'QuickRepair'" }
    @{ Cat = 'Outlook y Office'; Titulo = 'Reparación en línea de Office'; Desc = 'Con internet, unos 30 minutos. Reinstala Office.'; Cmd = "Reparar-Office -Tipo 'FullRepair'" }
    @{ Cat = 'Outlook y Office'; Titulo = 'Restablecer panel de carpetas'; Desc = 'Cuando Outlook no abre por el panel de navegación (/resetnavpane).'; Cmd = 'Restablecer-PanelOutlook' }
    @{ Cat = 'Outlook y Office'; Titulo = 'Perfiles de correo'; Desc = 'Abre la configuración de Correo del usuario.'; Cmd = 'Abrir-PerfilesCorreo' }
    @{ Cat = 'Outlook y Office'; Titulo = 'Restablecer OneDrive'; Desc = 'Cuando OneDrive no sincroniza. No borra archivos.'; Cmd = 'Restablecer-OneDrive'; Avanzada = $true }
    @{ Cat = 'Outlook y Office'; Titulo = 'Limpiar caché de Teams'; Desc = 'Teams clásico y nuevo: pantalla en blanco, no carga o va lento.'; Cmd = 'Limpiar-CacheTeams'; Avanzada = $true }

    @{ Cat = 'Seguridad'; Titulo = 'Escaneo rápido'; Desc = 'Microsoft Defender, 5 a 15 minutos.'; Cmd = "Invoke-EscaneoDefender -Tipo 'Rapido'"; Avanzada = $true }
    @{ Cat = 'Seguridad'; Titulo = 'Escaneo completo'; Desc = 'Todo el disco, 1 a 3 horas.'; Cmd = "Invoke-EscaneoDefender -Tipo 'Completo'"; Avanzada = $true }
    @{ Cat = 'Seguridad'; Titulo = 'Escaneo sin conexión'; Desc = 'Escanea antes de que arranque Windows (unos 15 minutos).'; Aviso = 'Reinicia el equipo'; Cmd = "Invoke-EscaneoDefender -Tipo 'SinConexion'"; Avanzada = $true }
    @{ Cat = 'Seguridad'; Titulo = 'Actualizar firmas de Defender'; Desc = 'Descarga las últimas definiciones de virus.'; Cmd = 'Update-FirmasDefender' }
    @{ Cat = 'Seguridad'; Titulo = 'Activar firewall'; Desc = 'Enciende el firewall de Windows en todos los perfiles.'; Cmd = 'Activar-Firewall'; Avanzada = $true }
    @{ Cat = 'Seguridad'; Titulo = 'Clave de recuperación BitLocker'; Desc = 'La muestra en pantalla (no se guarda en el log).'; Cmd = 'Mostrar-ClaveBitLocker'; Avanzada = $true }

    @{ Cat = 'Herramientas'; Titulo = 'Administrador de dispositivos'; Desc = 'Drivers y dispositivos.'; Cmd = "Abrir-Herramienta 'devmgmt'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Visor de eventos'; Desc = 'Registros de Windows.'; Cmd = "Abrir-Herramienta 'eventvwr'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Monitor de confiabilidad'; Desc = 'Historial de fallas por día.'; Cmd = "Abrir-Herramienta 'perfmon'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Diagnóstico de memoria'; Desc = 'Prueba la RAM (reinicia el equipo).'; Cmd = "Abrir-Herramienta 'mdsched'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Administrador de tareas'; Desc = 'Procesos, rendimiento e inicio.'; Cmd = "Abrir-Herramienta 'taskmgr'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Programas y características'; Desc = 'Desinstalar o reparar programas.'; Cmd = "Abrir-Herramienta 'appwiz'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Conexiones de red'; Desc = 'Adaptadores de red.'; Cmd = "Abrir-Herramienta 'ncpa'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Panel de sonido'; Desc = 'Dispositivos de reproducción y grabación.'; Cmd = "Abrir-Herramienta 'mmsys'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Servicios'; Desc = 'Servicios de Windows.'; Cmd = "Abrir-Herramienta 'services'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Carpeta de reportes'; Desc = 'Diagnósticos, respaldos y reportes.'; Cmd = "Abrir-Herramienta 'reportes'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Abrir el log de esta sesión'; Desc = 'Todo lo que hizo la herramienta.'; Cmd = "Abrir-Herramienta 'log'"; Ui = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Exportar esta visita'; Desc = 'Trabajo remoto: guarda la visita en un archivo .stv cifrado para cargarlo después en su USB (se hace solo al cerrar si no está en la USB).'; Cmd = 'Exportar-Visita'; Avanzada = $true }
    @{ Cat = 'Herramientas'; Titulo = 'Importar visitas remotas'; Desc = 'Carga en el historial de la USB los archivos .stv de visitas hechas sin la USB.'; Cmd = 'Importar-Visitas'; Avanzada = $true }
)

function Mostrar-Avanzadas {
    $items = @($Script:Catalogo | Where-Object { $_.Avanzada })
    $volver = $false
    while (-not $volver) {
        Clear-Host
        Mostrar-Titulo 'REPARACIONES AVANZADAS'
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Host ("    {0,2}. {1,-22} {2}" -f ($i + 1), $items[$i].Cat, $items[$i].Titulo)
        }
        Write-Host '     0. Volver al menú principal'
        Write-Host ''
        $op = Read-Host '  Elija una opción'
        if ($null -eq $op) { $op = '' }
        $op = $op.Trim()
        $n = 0
        if ($op -eq '0') {
            $volver = $true
        }
        elseif ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
            $item = $items[$n - 1]
            Write-Log "Avanzadas - opción elegida: $($item.Titulo)" 'INFO' -SoloArchivo
            Ejecutar-Opcion $item.Titulo ([scriptblock]::Create($item.Cmd))
        }
        elseif ($op) {
            Write-Host '  Opción no válida.' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

#endregion

#region ==================== HISTORIAL DE VISITAS Y FICHA DEL EQUIPO ====================
# Cada vez que se abre la herramienta se registra una "visita": qué equipo, de quién es,
# qué se hizo y cómo quedó el puntaje. Solo datos de identificación: NUNCA contraseñas.
# El estado vive en $Sync.Visita porque en la ventana las tareas corren en otro hilo.

function Get-RutaHistorialGeneral {
    # USB: <USB>\Clientes\Historial.csv | Local: C:\SoporteTecnico\Historial.csv
    if ($Script:EnUsb) { return (Join-Path (Split-Path -Parent $Script:Base) 'Historial.csv') }
    return (Join-Path $Script:BaseLocal 'Historial.csv')
}

function Test-SerieValida {
    # Las PCs armadas y las máquinas virtuales traen series de relleno que no identifican nada.
    param([string]$Serie)
    $s = "$Serie".Trim()
    if ($s.Length -lt 4) { return $false }
    if ($s -match '^(0+|1234567890?|[xX]+)$') { return $false }
    if ($s -match 'O\.?E\.?M|Default string|System Serial|Serial Number|To Be Filled|Not Specified|None|Chassis|VMware|VirtualBox|Parallels|^QEMU') { return $false }
    return $true
}

function Test-MismoEquipo {
    # Mismo equipo: por número de serie si es real; por nombre solo si alguna de las dos series es de relleno.
    param($Fila, [string]$Serie, [string]$Equipo = $env:COMPUTERNAME)
    if (Test-SerieValida $Serie) {
        if ($Fila.Serie -eq $Serie) { return $true }
        return ((-not (Test-SerieValida $Fila.Serie)) -and $Fila.Equipo -eq $Equipo)
    }
    return ($Fila.Equipo -eq $Equipo)
}

function Iniciar-Visita {
    # Prepara la visita actual y busca visitas anteriores a este equipo.
    $v = $Sync.Visita
    $v.Activa = $true
    $v.Id = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $env:COMPUTERNAME
    $v.Inicio = Get-Date
    $serie = ''
    try { $serie = "$((Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch { }
    $v.Serie = $serie
    $v.AvisoAnterior = ''
    $v.ClienteAnterior = ''
    $ruta = Get-RutaHistorialGeneral
    if (-not (Test-Path -LiteralPath $ruta)) { return }
    try {
        $anteriores = @(Import-Csv -LiteralPath $ruta -Encoding UTF8 -ErrorAction Stop | Where-Object { Test-MismoEquipo $_ $serie })
        if ($anteriores.Count -eq 0) { return }
        $ultima = $anteriores[$anteriores.Count - 1]
        $v.ClienteAnterior = "$($ultima.Cliente)"
        $texto = 'Ya atendió este equipo {0} vez/veces. Última visita: {1}' -f $anteriores.Count, $ultima.Fecha
        if ($ultima.Cliente) { $texto += (' (cliente: {0})' -f $ultima.Cliente) }
        if ($ultima.Equipo -and $ultima.Equipo -ne $env:COMPUTERNAME) { $texto += (', antes se llamaba {0}' -f $ultima.Equipo) }
        $texto += '.'
        if ($ultima.Acciones) { $texto += (' Se hizo: {0}.' -f $ultima.Acciones) }
        if ($ultima.Notas) { $texto += (' Notas: {0}' -f $ultima.Notas) }
        $v.AvisoAnterior = $texto
    }
    catch {
        Write-Log "No se pudo leer el historial de visitas: $($_.Exception.Message)" 'ADVERTENCIA' -SoloArchivo
    }
}

function Registrar-AccionVisita {
    # Anota una tarea en la visita y guarda el historial enseguida (por si se va la luz o se saca la USB).
    param([string]$Titulo, [ValidateSet('OK', 'Avisos', 'Error', 'Interrumpida')][string]$Estado)
    $v = $Sync.Visita
    if (-not $v.Activa) { return }
    # 'Reparar lo encontrado' se anota paso por paso dentro de Invoke-ReparacionAutomatica
    if ($Titulo -eq 'Datos del equipo') { return }
    if ($Titulo -eq 'Reparar lo encontrado' -and $Estado -ne 'Interrumpida' -and $Estado -ne 'Error') { return }
    if ($Titulo -eq 'Diagnóstico completo') { $v.Diagnostico = $true }
    else {
        $etiqueta = @{ 'OK' = 'OK'; 'Avisos' = 'con avisos o cancelado'; 'Error' = 'ERROR'; 'Interrumpida' = 'interrumpida' }[$Estado]
        [void]$v.Acciones.Add(('{0} ({1})' -f $Titulo, $etiqueta))
    }
    Guardar-Visita
}

function Registrar-PuntajeVisita {
    # Se llama al terminar cada diagnóstico: guarda el primer y el último puntaje de la visita.
    try {
        $p = (Get-PuntajeSalud).Puntaje
        if ($null -eq $Sync.Visita.PuntajeAntes) { $Sync.Visita.PuntajeAntes = $p }
        $Sync.Visita.PuntajeDespues = $p
    }
    catch { }
}

function Get-IdAnyDesk {
    # AnyDesk instalado guarda su ID en ProgramData; el portable, en el AppData del usuario.
    param($Perfil)
    $archivos = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @((Join-Path $env:ProgramData 'AnyDesk'), (Join-Path $Perfil.Ruta 'AppData\Roaming\AnyDesk'))) {
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'system.conf' -Recurse -File -ErrorAction SilentlyContinue)) { $archivos.Add($f.FullName) }
        }
    }
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($a in $archivos) {
        try {
            foreach ($l in @(Get-Content -LiteralPath $a -ErrorAction Stop)) {
                if ($l -match '^\s*ad\.anynet\.id\s*=\s*(\d+)') {
                    if (-not $ids.Contains($Matches[1])) { $ids.Add($Matches[1]) }
                }
            }
        }
        catch { }
    }
    return ($ids -join ', ')
}

function Get-IdTeamViewer {
    foreach ($clave in @('HKLM:\SOFTWARE\TeamViewer', 'HKLM:\SOFTWARE\WOW6432Node\TeamViewer')) {
        try {
            $id = (Get-ItemProperty -Path $clave -Name 'ClientID' -ErrorAction Stop).ClientID
            if ($id) { return "$id" }
        }
        catch { }
    }
    return ''
}

function Get-CuentasUsuario {
    # Cuenta con la que inicia sesión (Microsoft o de empresa) y cuentas de Office del usuario activo.
    param($Perfil)
    $r = [pscustomobject]@{ NombreCompleto = ''; Cuenta = ''; Office = '' }
    try {
        $local = Get-LocalUser -SID $Perfil.SID -ErrorAction Stop
        $r.NombreCompleto = "$($local.FullName)".Trim()
    }
    catch { }
    $cuentas = New-Object System.Collections.Generic.List[string]
    try {
        # Caché de identidad de Windows: guarda el correo de la cuenta Microsoft o de Azure AD / Entra
        $cache = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$($Perfil.SID)\IdentityCache\$($Perfil.SID)"
        $nombre = (Get-ItemProperty -Path $cache -Name 'UserName' -ErrorAction Stop).UserName
        if ("$nombre" -match '@') { $cuentas.Add("$nombre") }
    }
    catch { }
    try {
        foreach ($k in @(Get-ChildItem -Path "$($Perfil.Registro)\Software\Microsoft\IdentityCRL\UserExtendedProperties" -ErrorAction Stop)) {
            if ($k.PSChildName -match '@' -and -not $cuentas.Contains($k.PSChildName)) { $cuentas.Add($k.PSChildName) }
        }
    }
    catch { }
    try {
        foreach ($k in @(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -ErrorAction Stop)) {
            $correo = (Get-ItemProperty -Path $k.PSPath -ErrorAction Stop).UserEmail
            if ("$correo" -match '@' -and -not $cuentas.Contains("$correo")) { $cuentas.Add("$correo") }
        }
    }
    catch { }
    $r.Cuenta = $cuentas -join ', '
    $office = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($k in @(Get-ChildItem -Path "$($Perfil.Registro)\Software\Microsoft\Office\16.0\Common\Identity\Identities" -ErrorAction Stop)) {
            $correo = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).EmailAddress
            if ("$correo" -match '@' -and -not $office.Contains("$correo")) { $office.Add("$correo") }
        }
    }
    catch { }
    $r.Office = $office -join ', '
    return $r
}

function Get-ProgramasInstalados {
    param($Perfil)
    $rutas = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        "$($Perfil.Registro)\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $vistos = @{}
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-EntradasDesinstalar -Rutas $rutas)) {
        $nombre = "$($p.DisplayName)".Trim()
        if (-not $nombre -or $p.SystemComponent -eq 1 -or $p.ParentKeyName) { continue }
        $clave = '{0}|{1}' -f $nombre, $p.DisplayVersion
        if ($vistos.ContainsKey($clave)) { continue }
        $vistos[$clave] = $true
        $fecha = ''
        if ("$($p.InstallDate)" -match '^(\d{4})(\d{2})(\d{2})$') { $fecha = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3] }
        $lista.Add([pscustomobject]@{ Programa = $nombre; Version = "$($p.DisplayVersion)"; Fabricante = "$($p.Publisher)"; Instalado = $fecha })
    }
    return @($lista | Sort-Object -Property Programa)
}

function Guardar-FichaEquipo {
    # Junta la información del equipo y del usuario, la guarda en la carpeta del equipo y la deja en la visita.
    Write-Log 'Recopilando los datos del equipo para el historial...' 'INFO'
    $perfil = Get-PerfilUsuarioActivo
    $fab = Get-InfoFabricante
    $cuentas = Get-CuentasUsuario $perfil
    $f = [ordered]@{
        Equipo         = $env:COMPUTERNAME
        Usuario        = $perfil.Usuario
        NombreCompleto = $cuentas.NombreCompleto
        Cuenta         = $cuentas.Cuenta
        CorreosOffice  = $cuentas.Office
        Dominio        = ''
        Marca          = $fab.Marca
        Modelo         = $fab.Modelo
        Serie          = $fab.Serie
        Windows        = $Script:InfoSO
        AnyDesk        = (Get-IdAnyDesk $perfil)
        TeamViewer     = (Get-IdTeamViewer)
        Procesador     = ''
        RAM            = ''
        Discos         = ''
    }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain) { $f.Dominio = 'Dominio: {0}' -f $cs.Domain } else { $f.Dominio = 'Grupo de trabajo: {0}' -f $cs.Workgroup }
        $f.RAM = '{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB)
    }
    catch { }
    try { $f.Procesador = (@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0].Name).Trim() } catch { }
    try {
        $f.Discos = (@(Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.BusType)" -ne 'USB' } | ForEach-Object {
                    '{0} ({1}, {2} GB, {3})' -f "$($_.FriendlyName)".Trim(), $_.MediaType, [math]::Round($_.Size / 1GB), $_.HealthStatus
                }) -join '; ')
    }
    catch { }
    $Sync.Visita.Ficha = [pscustomobject]$f
    if (Test-SerieValida $fab.Serie) { $Sync.Visita.Serie = $fab.Serie }
    if ($Sync.SinArchivosLocales) { return $true }

    try {
        $programas = @(Get-ProgramasInstalados $perfil)
        if ($programas.Count -gt 0) {
            $rutaProgramas = Join-Path $Script:Base ('Programas_{0}.csv' -f (Get-Date -Format 'yyyyMMdd'))
            $programas | Export-Csv -LiteralPath $rutaProgramas -NoTypeInformation -Encoding UTF8
        }
        $lineas = New-Object System.Collections.Generic.List[string]
        $lineas.Add(('FICHA DEL EQUIPO {0} (actualizada el {1})' -f $env:COMPUTERNAME, (Get-Date -Format 'dd/MM/yyyy HH:mm')))
        $lineas.Add(('=' * 60))
        foreach ($k in $f.Keys) {
            if ($f[$k]) { $lineas.Add(('{0,-16}: {1}' -f $k, $f[$k])) }
        }
        $lineas.Add('')
        $lineas.Add(('Programas instalados: {0} (lista completa en Programas_<fecha>.csv)' -f $programas.Count))
        foreach ($p in $programas) { $lineas.Add(('   {0} {1}' -f $p.Programa, $p.Version)) }
        [System.IO.File]::WriteAllLines((Join-Path $Script:Base 'Ficha_equipo.txt'), $lineas, (New-Object System.Text.UTF8Encoding($true)))
        Write-Log ('Ficha del equipo guardada en {0}' -f (Join-Path $Script:Base 'Ficha_equipo.txt')) 'OK'
    }
    catch {
        Write-Log "No se pudo guardar la ficha del equipo: $($_.Exception.Message)" 'ADVERTENCIA'
    }
    Guardar-Visita
    return $true
}

function Guardar-Visita {
    # Reescribe la fila de esta visita en el historial general y regenera el historial del equipo.
    # Nunca detiene la herramienta: si falla (USB llena, archivo abierto en Excel), solo lo avisa en el log.
    $v = $Sync.Visita
    if (-not $v.Activa -or $Sync.SinArchivosLocales) { return }
    if ($v.Acciones.Count -eq 0 -and -not $v.Diagnostico) { return }
    [System.Threading.Monitor]::Enter($v)
    try {
        $f = $v.Ficha
        $dato = { param($n) if ($f) { "$($f.$n)" } else { '' } }
        $antes = ''; if ($null -ne $v.PuntajeAntes) { $antes = "$($v.PuntajeAntes)" }
        $despues = ''; if ($null -ne $v.PuntajeDespues) { $despues = "$($v.PuntajeDespues)" }
        $fila = [pscustomobject][ordered]@{
            Fecha          = $v.Inicio.ToString('dd/MM/yyyy HH:mm')
            Hasta          = (Get-Date -Format 'HH:mm')
            Equipo         = $env:COMPUTERNAME
            Cliente        = "$($v.Cliente)"
            Usuario        = (& $dato 'Usuario')
            NombreCompleto = (& $dato 'NombreCompleto')
            Cuenta         = (& $dato 'Cuenta')
            CorreosOffice  = (& $dato 'CorreosOffice')
            Dominio        = (& $dato 'Dominio')
            Marca          = (& $dato 'Marca')
            Modelo         = (& $dato 'Modelo')
            Serie          = "$($v.Serie)"
            Windows        = $Script:InfoSO
            AnyDesk        = (& $dato 'AnyDesk')
            TeamViewer     = (& $dato 'TeamViewer')
            PuntajeAntes   = $antes
            PuntajeDespues = $despues
            Acciones       = (@($v.Acciones) -join '; ')
            Notas          = "$($v.Notas)"
            Id             = $v.Id
        }
        # 1. Historial general (todas las PCs): se escribe a un temporal y se reemplaza, para no dejarlo a medias
        $ruta = Get-RutaHistorialGeneral
        $filas = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $ruta) {
            foreach ($x in @(Import-Csv -LiteralPath $ruta -Encoding UTF8 -ErrorAction Stop)) { if ($x.Id -ne $v.Id) { $filas.Add($x) } }
        }
        $filas.Add($fila)
        $tmp = "$ruta.tmp"
        $filas | Select-Object -Property @($fila.PSObject.Properties.Name) | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $ruta -Force -ErrorAction Stop

        # 2. Historial de este equipo, legible
        Escribir-HistorialEquipo -Filas $filas -Serie $v.Serie -Equipo $env:COMPUTERNAME -Carpeta $Script:Base
    }
    catch {
        Write-Log ("No se pudo guardar el historial de visitas (¿está abierto en Excel?): {0}" -f $_.Exception.Message) 'ADVERTENCIA' -SoloArchivo
    }
    finally {
        [System.Threading.Monitor]::Exit($v)
    }
}

function Cerrar-Visita {
    # Al salir: pide (opcional) el cliente y las notas, y guarda la visita por última vez.
    param([string]$Cliente, [string]$Notas)
    $v = $Sync.Visita
    if (-not $v.Activa) { return }
    if ($v.Acciones.Count -eq 0 -and -not $v.Diagnostico) { return }
    $c = "$Cliente".Trim()
    if (-not $c) { $c = $v.ClienteAnterior }
    $v.Cliente = $c
    $v.Notas = ("$Notas".Trim() -replace '[\r\n]+', ' ')
    Guardar-Visita
    Write-Log ('Visita guardada en el historial: {0}' -f (Get-RutaHistorialGeneral)) 'INFO' -SoloArchivo
    $v.Activa = $false
}

function Test-VisitaConActividad {
    return ($Sync.Visita.Activa -and ($Sync.Visita.Acciones.Count -gt 0 -or $Sync.Visita.Diagnostico))
}

#endregion

function Set-ClaveExportacion {
    # Al entrar con la contraseña: deriva la clave que cifra los archivos .stv de visitas.
    # Se guarda solo la clave derivada (nunca la contraseña) y no está dentro del .exe:
    # sin la contraseña de la herramienta, un .stv no se puede abrir.
    param([string]$Clave)
    $sal = [System.Text.Encoding]::UTF8.GetBytes('SoporteTecnico.Visitas.v1|') + [Convert]::FromBase64String($Script:ClaveSal)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Clave, [byte[]]$sal, [int]$Script:ClaveIteraciones)
    try { $Sync.ClaveExportacion = [byte[]]$kdf.GetBytes(32) }
    finally { $kdf.Dispose() }
}

function Get-ClaveExportacion {
    # La coma evita que PowerShell convierta el arreglo de bytes en una lista de objetos
    if ($Sync.ClaveExportacion) { return , ([byte[]]$Sync.ClaveExportacion) }
    # Sin contraseña configurada: clave fija. El formato sigue siendo propio, pero quien extraiga
    # el script del .exe podría abrirlo. Configure una contraseña para que sea realmente privado.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return , ([byte[]]$sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('SoporteTecnico.Visitas.v1|sin-contrasena'))) }
    finally { $sha.Dispose() }
}

function Get-SubclaveVisita {
    # Clave distinta para cifrar y para firmar, y distinta en cada archivo (según su sal).
    param([byte[]]$Maestra, [byte[]]$Sal, [byte]$Uso)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Maestra)
    try { return , ([byte[]]$hmac.ComputeHash([byte[]]($Sal + $Uso))) }
    finally { $hmac.Dispose() }
}

function Get-HuellaClave {
    # 8 bytes que identifican la clave, para avisar "se creó con otra contraseña" en vez de "archivo dañado".
    param([byte[]]$Maestra)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return , ([byte[]]($sha.ComputeHash([byte[]]($Maestra + [System.Text.Encoding]::UTF8.GetBytes('huella')))[0..7])) }
    finally { $sha.Dispose() }
}

# Formato .stv (Soporte Técnico - Visita):
#   "STV1" (4) | huella de la clave (8) | sal (16) | IV (16) | datos cifrados AES-256-CBC | HMAC-SHA256 (32)
# El HMAC cubre todo lo anterior: si el archivo se modifica o se daña, no se importa.

function Protect-ArchivoVisita {
    param([byte[]]$Datos)
    [byte[]]$maestra = Get-ClaveExportacion
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $sal = New-Object byte[] 16
    $rng.GetBytes($sal)
    $rng.Dispose()
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [byte[]](Get-SubclaveVisita $maestra $sal 1)
        $aes.GenerateIV()
        $cifrador = $aes.CreateEncryptor()
        $cifrado = $cifrador.TransformFinalBlock($Datos, 0, $Datos.Length)
        $cifrador.Dispose()
        # Se arma con un MemoryStream: sumar arreglos grandes en PowerShell es muy lento
        $ms = New-Object System.IO.MemoryStream
        foreach ($parte in @([System.Text.Encoding]::ASCII.GetBytes('STV1'), [byte[]](Get-HuellaClave $maestra), $sal, $aes.IV)) { $ms.Write($parte, 0, $parte.Length) }
        $ms.Write($cifrado, 0, $cifrado.Length)
    }
    finally { $aes.Dispose() }
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]](Get-SubclaveVisita $maestra $sal 2))
    try { $firma = $hmac.ComputeHash($ms.ToArray()) }
    finally { $hmac.Dispose() }
    $ms.Write($firma, 0, $firma.Length)
    $resultado = $ms.ToArray()
    $ms.Dispose()
    return , $resultado
}

function Unprotect-ArchivoVisita {
    param([byte[]]$Datos)
    if ($Datos.Length -lt (4 + 8 + 16 + 16 + 16 + 32) -or [System.Text.Encoding]::ASCII.GetString($Datos, 0, 4) -ne 'STV1') {
        throw 'no es un archivo de visita de esta herramienta'
    }
    [byte[]]$maestra = Get-ClaveExportacion
    $huella = [byte[]]$Datos[4..11]
    if ([Convert]::ToBase64String($huella) -ne [Convert]::ToBase64String((Get-HuellaClave $maestra))) {
        throw 'se creó con otra contraseña de la herramienta (o en una herramienta sin contraseña). Ábralo con la contraseña que tenía cuando se exportó'
    }
    $sal = [byte[]]$Datos[12..27]
    $iv = [byte[]]$Datos[28..43]
    $finCuerpo = $Datos.Length - 32
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([byte[]](Get-SubclaveVisita $maestra $sal 2))
    try { $esperada = $hmac.ComputeHash($Datos, 0, $finCuerpo) }
    finally { $hmac.Dispose() }
    $diferencia = 0
    for ($i = 0; $i -lt 32; $i++) { $diferencia = $diferencia -bor ($esperada[$i] -bxor $Datos[$finCuerpo + $i]) }
    if ($diferencia -ne 0) { throw 'el archivo está dañado o fue modificado' }
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [byte[]](Get-SubclaveVisita $maestra $sal 1)
        $aes.IV = $iv
        $descifrador = $aes.CreateDecryptor()
        try { return , ([byte[]]$descifrador.TransformFinalBlock($Datos, 44, $finCuerpo - 44)) }
        finally { $descifrador.Dispose() }
    }
    finally { $aes.Dispose() }
}

function Escribir-HistorialEquipo {
    # Genera <carpeta del equipo>\Historial.txt con todas las visitas de ese equipo.
    param($Filas, [string]$Serie, [string]$Equipo, [string]$Carpeta)
    $propias = @($Filas | Where-Object { Test-MismoEquipo $_ $Serie $Equipo })
    if ($propias.Count -eq 0) { return }
    $ultima = $propias[$propias.Count - 1]
    $lineas = New-Object System.Collections.Generic.List[string]
    $lineas.Add(('HISTORIAL DE VISITAS - {0} {1} (serie {2})' -f $ultima.Marca, $ultima.Modelo, $ultima.Serie))
    $lineas.Add(('=' * 60))
    foreach ($p in $propias) {
        $lineas.Add('')
        $lineas.Add(('{0} a {1} | Equipo: {2} | Cliente: {3}' -f $p.Fecha, $p.Hasta, $p.Equipo, $p.Cliente))
        if ($p.Usuario) { $lineas.Add(('   Usuario: {0} {1} {2}' -f $p.Usuario, $p.NombreCompleto, $p.Cuenta)) }
        if ($p.PuntajeAntes) { $lineas.Add(('   Puntaje: {0} -> {1}' -f $p.PuntajeAntes, $p.PuntajeDespues)) }
        foreach ($a in @("$($p.Acciones)" -split '; ' | Where-Object { $_ })) { $lineas.Add(('   - {0}' -f $a)) }
        if ($p.Notas) { $lineas.Add(('   Notas: {0}' -f $p.Notas)) }
    }
    if (-not (Test-Path -LiteralPath $Carpeta)) { New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null }
    [System.IO.File]::WriteAllLines((Join-Path $Carpeta 'Historial.txt'), $lineas, (New-Object System.Text.UTF8Encoding($true)))
}

function Exportar-Visita {
    # Para el trabajo remoto (sin la USB): empaqueta en un .stv cifrado las visitas de este equipo, su ficha,
    # sus programas y los logs y reportes de esta sesión. Luego se carga en la USB con "Importar visitas".
    $ruta = Get-RutaHistorialGeneral
    if (-not (Test-Path -LiteralPath $ruta)) { Write-Log 'Todavía no hay visitas que exportar.' 'INFO'; return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dirExportar = Join-Path $Script:BaseLocal 'Exportar'
    $preparacion = Join-Path $env:TEMP ('soporte_export_{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        if (-not (Test-Path -LiteralPath $dirExportar)) { New-Item -ItemType Directory -Path $dirExportar -Force | Out-Null }
        $dirEquipo = Join-Path $preparacion 'Equipo'
        New-Item -ItemType Directory -Path (Join-Path $dirEquipo 'Logs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dirEquipo 'Reportes') -Force | Out-Null

        # Todas las visitas de este equipo (así también viajan las de una sesión anterior que no se exportó)
        $serie = "$($Sync.Visita.Serie)"
        $filas = @(Import-Csv -LiteralPath $ruta -Encoding UTF8 -ErrorAction Stop | Where-Object { Test-MismoEquipo $_ $serie })
        if ($filas.Count -eq 0) { Write-Log 'No hay visitas de este equipo que exportar.' 'INFO'; return $null }
        $filas | Export-Csv -LiteralPath (Join-Path $preparacion 'visitas.csv') -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

        # Ficha, programas y lo generado en esta sesión (no los respaldos de drivers: pesan demasiado)
        $desde = $Sync.Visita.Inicio.AddMinutes(-1)
        foreach ($f in @(Get-ChildItem -LiteralPath $Script:Base -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Ficha_equipo.txt' -or $_.Name -like 'Programas_*.csv' })) {
            Copy-Item -LiteralPath $f.FullName -Destination $dirEquipo -Force
        }
        # Sin la USB se llevan todos (también los de una sesión que se cerró de golpe), porque al cerrar se borran
        $logs = @(Get-Item -LiteralPath $Script:LogFile -ErrorAction SilentlyContinue)
        if (-not $Script:EnUsb) { $logs = @(Get-ChildItem -LiteralPath $Script:DirLogs -File -ErrorAction SilentlyContinue) }
        foreach ($f in $logs) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dirEquipo 'Logs') -Force }
        foreach ($f in @(Get-ChildItem -LiteralPath $Script:DirReportes -File -ErrorAction SilentlyContinue | Where-Object { ((-not $Script:EnUsb) -or $_.LastWriteTime -ge $desde) -and $_.Length -lt 50MB })) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dirEquipo 'Reportes') -Force
        }
        Set-Content -LiteralPath (Join-Path $preparacion 'equipo.txt') -Value $env:COMPUTERNAME -Encoding UTF8

        # Se comprime y se cifra: el .stv solo lo abre esta herramienta con su contraseña
        $zipTemporal = "$preparacion.zip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($preparacion, $zipTemporal)
        $original = [System.IO.File]::ReadAllBytes($zipTemporal)
        $cifrado = Protect-ArchivoVisita $original
        # Comprobación: el archivo cifrado debe poder abrirse y dar exactamente lo mismo
        $prueba = Unprotect-ArchivoVisita $cifrado
        if ($prueba.Length -ne $original.Length -or [Convert]::ToBase64String($prueba) -ne [Convert]::ToBase64String($original)) { throw 'la comprobación del archivo cifrado falló' }
        Remove-Item -LiteralPath $zipTemporal -Force -ErrorAction SilentlyContinue
        $archivo = Join-Path $dirExportar ('Visita_{0}_{1}.stv' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmm'))
        [System.IO.File]::WriteAllBytes($archivo, $cifrado)
        Write-Log ("Visita exportada (cifrada): {0}" -f $archivo) 'OK'
        if (-not $Sync.ClaveExportacion) { Write-Log 'La herramienta no tiene contraseña: el archivo usa una clave fija. Configure una contraseña para que nadie más pueda abrirlo.' 'ADVERTENCIA' }
        Write-Log 'Copie ese archivo a su USB, en Clientes\Importar, o use "Importar visitas remotas".' 'INFO'
        return $archivo
    }
    catch {
        Write-Log "No se pudo exportar la visita: $($_.Exception.Message)" 'ERROR'
        return $null
    }
    finally {
        Remove-Item -LiteralPath $preparacion -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$preparacion.zip" -Force -ErrorAction SilentlyContinue
    }
}

function Importar-ArchivoVisita {
    # Carga un .stv de Exportar-Visita en el historial y en la carpeta del equipo. Devuelve cuántas visitas agregó.
    param([string]$Archivo)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temp = Join-Path $env:TEMP ('soporte_import_{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $zipTemporal = "$temp.zip"
        [System.IO.File]::WriteAllBytes($zipTemporal, (Unprotect-ArchivoVisita ([System.IO.File]::ReadAllBytes($Archivo))))
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipTemporal, $temp)
        $csv = Join-Path $temp 'visitas.csv'
        if (-not (Test-Path -LiteralPath $csv)) { throw 'no es un archivo de visita de esta herramienta (falta visitas.csv)' }
        $nuevas = @(Import-Csv -LiteralPath $csv -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.Id })
        if ($nuevas.Count -eq 0) { throw 'el archivo no tiene visitas' }

        # 1. Unir al historial general sin duplicar (la misma visita puede venir en varios .stv)
        $ruta = Get-RutaHistorialGeneral
        $filas = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $ruta) { foreach ($x in @(Import-Csv -LiteralPath $ruta -Encoding UTF8 -ErrorAction Stop)) { $filas.Add($x) } }
        $ids = @{}
        for ($i = 0; $i -lt $filas.Count; $i++) { $ids["$($filas[$i].Id)"] = $i }
        $agregadas = 0
        foreach ($n in $nuevas) {
            if ($ids.ContainsKey("$($n.Id)")) { $filas[$ids["$($n.Id)"]] = $n }
            else { $filas.Add($n); $agregadas++ }
        }
        $columnas = New-Object System.Collections.Generic.List[string]
        foreach ($x in $filas) { foreach ($c in $x.PSObject.Properties.Name) { if (-not $columnas.Contains($c)) { $columnas.Add($c) } } }
        $ordenadas = @($filas | Sort-Object -Property @{ e = { $d = [datetime]::MinValue; [void][datetime]::TryParseExact("$($_.Fecha)", 'dd/MM/yyyy HH:mm', $null, 'None', [ref]$d); $d } })
        $tmp = "$ruta.tmp"
        $ordenadas | Select-Object -Property @($columnas) | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $ruta -Force -ErrorAction Stop

        # 2. Archivos del equipo a su carpeta de clientes
        $ultima = $nuevas[$nuevas.Count - 1]
        $equipo = "$($ultima.Equipo)" -replace '[\\/:*?"<>|]', '_'
        if (-not $equipo) { $equipo = 'Equipo_desconocido' }
        $carpeta = Join-Path (Split-Path -Parent $ruta) (Join-Path 'Clientes' $equipo)
        if ($Script:EnUsb) { $carpeta = Join-Path (Split-Path -Parent $ruta) $equipo }
        $origen = Join-Path $temp 'Equipo'
        if (Test-Path -LiteralPath $origen) {
            foreach ($f in @(Get-ChildItem -LiteralPath $origen -Recurse -File -ErrorAction SilentlyContinue)) {
                $relativa = $f.FullName.Substring($origen.Length).TrimStart('\')
                $destino = Join-Path $carpeta $relativa
                $dirDestino = Split-Path -Parent $destino
                if (-not (Test-Path -LiteralPath $dirDestino)) { New-Item -ItemType Directory -Path $dirDestino -Force | Out-Null }
                Copy-Item -LiteralPath $f.FullName -Destination $destino -Force
            }
        }
        Escribir-HistorialEquipo -Filas $ordenadas -Serie "$($ultima.Serie)" -Equipo "$($ultima.Equipo)" -Carpeta $carpeta
        Write-Log ("Importado {0}: {1} visita(s) nueva(s) de {2}" -f (Split-Path -Leaf $Archivo), $agregadas, $ultima.Equipo) 'OK'
        return $agregadas
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$temp.zip" -Force -ErrorAction SilentlyContinue
    }
}

function Get-DirImportar {
    return (Join-Path (Split-Path -Parent (Get-RutaHistorialGeneral)) 'Importar')
}

function Importar-Visitas {
    # Carga los .stv exportados en equipos atendidos de forma remota.
    param([switch]$Automatico)
    $dirImportar = Get-DirImportar
    if (-not $Automatico) {
        Mostrar-Titulo 'IMPORTAR VISITAS REMOTAS'
        if (-not $Script:EnUsb) {
            Write-Log 'La herramienta no se abrió desde la USB: las visitas se importarán al historial de este equipo, no al de la USB.' 'ADVERTENCIA'
        }
        Write-Host ('    Cargue aquí los archivos Visita_<equipo>_<fecha>.stv que la herramienta genera al trabajar sin la USB.') -ForegroundColor DarkGray
        Write-Host ('    También puede dejarlos en {0}: se cargan solos al abrir la herramienta.' -f $dirImportar) -ForegroundColor DarkGray
        $resp = Read-Host ('  Archivo .stv o carpeta con los .stv (vacío = {0})' -f $dirImportar)
        if ($Script:ModoInterfaz -eq 'Grafica' -and $Sync.Cancelado) { Write-Log 'Operación cancelada.' 'INFO'; return $false }
        $origen = "$resp".Trim().Trim('"')
        if (-not $origen) { $origen = $dirImportar }
    }
    else {
        $origen = $dirImportar
    }
    if (-not (Test-Path -LiteralPath $origen)) {
        if (-not $Automatico) { Write-Log "No existe: $origen" 'ERROR' }
        return $false
    }
    if (Test-Path -LiteralPath $origen -PathType Leaf) { $zips = @(Get-Item -LiteralPath $origen) }
    else { $zips = @(Get-ChildItem -LiteralPath $origen -Filter 'Visita_*.stv' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name) }
    if ($zips.Count -eq 0) {
        if (-not $Automatico) { Write-Log 'No se encontraron archivos Visita_*.stv.' 'INFO' }
        return $false
    }
    $total = 0
    $fallos = 0
    $importados = Join-Path $dirImportar 'Importados'
    foreach ($z in $zips) {
        try {
            $total += [int](Importar-ArchivoVisita $z.FullName)
            # Ya cargado: se mueve para no volver a procesarlo
            if ($z.DirectoryName -eq $dirImportar) {
                if (-not (Test-Path -LiteralPath $importados)) { New-Item -ItemType Directory -Path $importados -Force | Out-Null }
                Move-Item -LiteralPath $z.FullName -Destination (Join-Path $importados $z.Name) -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            $fallos++
            Write-Log ("No se pudo importar {0}: {1}" -f $z.Name, $_.Exception.Message) 'ERROR'
        }
    }
    Write-Log ("Importación terminada: {0} archivo(s), {1} visita(s) nueva(s), {2} con error." -f $zips.Count, $total, $fallos) 'INFO'
    return ($fallos -eq 0)
}

function Get-RutaHistorialLocalCifrado {
    return (Join-Path $Script:BaseLocal 'Historial.stv')
}

function Abrir-HistorialLocal {
    # Sin la USB: el historial de este equipo se guarda cifrado (Historial.stv). Al entrar se descifra
    # para usarlo durante la sesión, y al cerrar se vuelve a cifrar y se borra la copia legible.
    if ($Script:EnUsb) { return }
    $cifrado = Get-RutaHistorialLocalCifrado
    if (-not (Test-Path -LiteralPath $cifrado)) { return }
    # Si quedó el .csv de una sesión que se cerró de golpe, ese es el más nuevo
    if (Test-Path -LiteralPath (Get-RutaHistorialGeneral)) { return }
    try {
        [System.IO.File]::WriteAllBytes((Get-RutaHistorialGeneral), (Unprotect-ArchivoVisita ([System.IO.File]::ReadAllBytes($cifrado))))
    }
    catch {
        Write-Log ("No se pudo abrir el historial guardado en este equipo ({0}). Se empieza uno nuevo; el anterior se conserva aparte." -f $_.Exception.Message) 'ADVERTENCIA' -SoloArchivo
        try { Move-Item -LiteralPath $cifrado -Destination ($cifrado -replace '\.stv$', ('_anterior_{0}.stv' -f (Get-Date -Format 'yyyyMMddHHmmss'))) -Force } catch { }
    }
}

function Limpiar-RastrosLocales {
    # Sin la USB, al cerrar: cifra el historial del equipo y borra todo lo legible que dejó la herramienta
    # (historial, ficha, programas, logs, reportes y temporales). Se conservan los .stv (cifrados) y los
    # respaldos de drivers, que son del cliente y pueden hacer falta.
    param([bool]$ExportacionOk = $true)
    if ($Script:EnUsb) { return $false }
    $csv = Get-RutaHistorialGeneral
    try {
        if (Test-Path -LiteralPath $csv) {
            $datos = [System.IO.File]::ReadAllBytes($csv)
            $cifrado = Protect-ArchivoVisita $datos
            $prueba = Unprotect-ArchivoVisita $cifrado
            if ([Convert]::ToBase64String($prueba) -ne [Convert]::ToBase64String($datos)) { throw 'la comprobación del historial cifrado falló' }
            $destino = Get-RutaHistorialLocalCifrado
            [System.IO.File]::WriteAllBytes("$destino.tmp", $cifrado)
            Move-Item -LiteralPath "$destino.tmp" -Destination $destino -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Log ("No se pudo cifrar el historial de este equipo ({0}): no se borra nada para no perderlo." -f $_.Exception.Message) 'ERROR'
        return $false
    }
    if (-not $ExportacionOk) {
        Write-Log 'La visita no se pudo exportar: los logs y reportes se dejan en este equipo para no perderlos.' 'ADVERTENCIA'
        return $false
    }
    $Sync.SinArchivosLocales = $true
    $borrar = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('Historial.csv', 'Historial.csv.tmp', 'Historial.txt', 'Ficha_equipo.txt')) { $borrar.Add((Join-Path $Script:BaseLocal $n)) }
    foreach ($f in @(Get-ChildItem -LiteralPath $Script:BaseLocal -Filter 'Programas_*.csv' -File -ErrorAction SilentlyContinue)) { $borrar.Add($f.FullName) }
    foreach ($dir in @($Script:DirLogs, $Script:DirReportes, (Join-Path $Script:BaseLocal 'Temp'))) {
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) { $borrar.Add($f.FullName) }
        }
    }
    $fallaron = New-Object System.Collections.Generic.List[string]
    foreach ($f in $borrar) {
        if (Test-Path -LiteralPath $f) {
            try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { $fallaron.Add((Split-Path -Leaf $f)) }
        }
    }
    if ($fallaron.Count -gt 0) {
        Write-Host ("  No se pudieron borrar (en uso): {0}" -f ($fallaron -join ', ')) -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Finalizar-VisitaRemota {
    # Al cerrar sin la USB: exporta la visita a un .stv, borra lo legible y abre la carpeta del .stv
    # para copiarlo por AnyDesk/TeamViewer. Devuelve la ruta del .stv (o $null).
    param([bool]$Exportar = $true)
    if ($Script:EnUsb) { return $null }
    $archivo = $null
    $ok = $true
    if ($Exportar) {
        $archivo = Exportar-Visita
        $ok = [bool]$archivo
    }
    if (Limpiar-RastrosLocales -ExportacionOk $ok) {
        Write-Host '  No quedó información legible de la herramienta en este equipo.' -ForegroundColor Green
    }
    if ($archivo) { try { Abrir-ParaUsuario (Split-Path -Parent $archivo) } catch { } }
    return $archivo
}

function Invoke-Registrada {
    # Ejecuta una acción de un submenú de consola y la anota en la visita.
    param([string]$Titulo, [scriptblock]$Accion)
    $estado = 'Avisos'
    try {
        $salida = & $Accion
        if ([bool](@($salida)[-1])) { $estado = 'OK' }
    }
    catch {
        $estado = 'Error'
        Write-Log ("Error en '{0}': {1}" -f $Titulo, $_.Exception.Message) 'ERROR'
    }
    try { Registrar-AccionVisita $Titulo $estado } catch { }
}

function Iniciar-VisitaGui {
    # Después de entrar: avisa si el equipo ya se atendió antes y recopila su ficha en segundo plano.
    $Script:Gui.AccesoOk = $true
    if ($Script:EnUsb) { try { $null = Importar-Visitas -Automatico } catch { } }
    try { Abrir-HistorialLocal } catch { }
    try { Iniciar-Visita } catch { }
    if ($Sync.Visita.AvisoAnterior) { Write-Host ('HISTORIAL: ' + $Sync.Visita.AvisoAnterior) -ForegroundColor Yellow }
    # La ficha se arma en segundo plano, en un runspace propio, para no bloquear los botones
    try {
        $Script:Gui.RunspaceFicha = New-RunspaceGui
        $ps = [powershell]::Create()
        $ps.Runspace = $Script:Gui.RunspaceFicha
        [void]$ps.AddScript('try { $null = Guardar-FichaEquipo } catch { Write-Log ("No se pudo recopilar la ficha del equipo: {0}" -f $_.Exception.Message) ''ADVERTENCIA'' -SoloArchivo }')
        $Script:Gui.PsFicha = $ps
        [void]$ps.BeginInvoke()
    }
    catch { Write-Log ("No se pudo iniciar la ficha del equipo: {0}" -f $_.Exception.Message) 'ADVERTENCIA' -SoloArchivo }
}

#region ==================== INTERFAZ GRÁFICA: DISEÑO (XAML) ====================

$Script:XamlPrincipal = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Soporte Técnico" Width="1280" Height="820" MinWidth="1020" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#0B1120" Foreground="#E2E8F0"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="BotonBase" TargetType="Button">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="Background" Value="#1E293B"/>
      <Setter Property="BorderBrush" Value="#334155"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Fondo" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Fondo" Property="BorderBrush" Value="#60A5FA"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Fondo" Property="Opacity" Value="0.8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Fondo" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primario" TargetType="Button" BasedOn="{StaticResource BotonBase}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Exito" TargetType="Button" BasedOn="{StaticResource BotonBase}">
      <Setter Property="Background" Value="#059669"/>
      <Setter Property="BorderBrush" Value="#059669"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Secundario" TargetType="Button" BasedOn="{StaticResource BotonBase}"/>
    <Style x:Key="Nav" TargetType="Button" BasedOn="{StaticResource BotonBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Foreground" Value="#CBD5E1"/>
    </Style>
    <Style x:Key="Tile" TargetType="Button" BasedOn="{StaticResource BotonBase}">
      <Setter Property="Background" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#1F2937"/>
      <Setter Property="Width" Value="280"/>
      <Setter Property="MinHeight" Value="108"/>
      <Setter Property="Margin" Value="0,0,14,14"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid x:Name="Principal">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="236"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#0F172A" BorderBrush="#1E293B" BorderThickness="0,0,1,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="20,22,18,14">
            <TextBlock Text="Soporte Técnico" FontSize="20" FontWeight="SemiBold" Foreground="#F8FAFC"/>
            <TextBlock x:Name="TxtEquipo" Foreground="#94A3B8" FontSize="12" Margin="0,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>
          <TextBlock x:Name="TxtVersion" DockPanel.Dock="Bottom" Foreground="#475569" FontSize="11" Margin="20,10,18,14" TextWrapping="Wrap"/>
          <StackPanel x:Name="PanelNav" Margin="10,6,10,0"/>
        </DockPanel>
      </Border>

      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="210"/>
          <RowDefinition Height="34"/>
        </Grid.RowDefinitions>

        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" Padding="28,24,14,10">
          <Grid>
            <StackPanel x:Name="PaginaInicio">
              <TextBlock Text="Panel de salud" FontSize="24" FontWeight="SemiBold" Foreground="#F8FAFC"/>
              <TextBlock x:Name="TxtSubtitulo" Text="Ejecute el diagnóstico completo para analizar el equipo." Foreground="#94A3B8" Margin="0,4,0,18"/>
              <Border Background="#111827" CornerRadius="14" Padding="24" BorderBrush="#1F2937" BorderThickness="1" Margin="0,0,14,0">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid Width="160" Height="160">
                    <Path Stroke="#1E293B" StrokeThickness="14">
                      <Path.Data>
                        <EllipseGeometry Center="80,80" RadiusX="70" RadiusY="70"/>
                      </Path.Data>
                    </Path>
                    <Path x:Name="ArcoPuntaje" Stroke="#334155" StrokeThickness="14" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                      <TextBlock x:Name="TxtPuntaje" Text="--" FontSize="44" FontWeight="Bold" HorizontalAlignment="Center" Foreground="#F8FAFC"/>
                      <TextBlock Text="de 100" Foreground="#94A3B8" FontSize="12" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Grid>
                  <StackPanel Grid.Column="1" Margin="30,0,0,0" VerticalAlignment="Center">
                    <Border x:Name="BordeEstado" CornerRadius="12" Padding="14,4" HorizontalAlignment="Left" Background="#334155">
                      <TextBlock x:Name="TxtEstadoSalud" Text="Sin analizar" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                    </Border>
                    <TextBlock x:Name="TxtResumen" Margin="0,12,0,0" Foreground="#CBD5E1" TextWrapping="Wrap"
                               Text="El diagnóstico revisa hardware, disco, red, sonido, Outlook, seguridad, actualizaciones y más, y sugiere qué reparar."/>
                    <WrapPanel Margin="0,18,0,0">
                      <Button x:Name="BtnDiagnostico" Content="Analizar el equipo" Style="{StaticResource Primario}" Margin="0,0,10,8" ToolTip="Revisa todo el equipo y calcula un puntaje de salud. No cambia nada."/>
                      <Button x:Name="BtnRepararTodo" Content="Reparar lo encontrado" Style="{StaticResource Exito}" Margin="0,0,10,8" IsEnabled="False"/>
                      <Button x:Name="BtnReporte" Content="Ver reporte" Style="{StaticResource Secundario}" Margin="0,0,10,8" IsEnabled="False" ToolTip="Abre el reporte del último análisis en el navegador (se habilita después de analizar)."/>
                      <Button x:Name="BtnCompleta" Content="Reparación completa" Style="{StaticResource Secundario}" Margin="0,0,10,8" ToolTip="Aplica en bloque las reparaciones generales (archivos de Windows, red, limpieza). Es más lento. Pide confirmación."/>
                    </WrapPanel>
                  </StackPanel>
                </Grid>
              </Border>

              <Border x:Name="GuiaInicio" Background="#0F1F3D" CornerRadius="14" Padding="22,18" BorderBrush="#1D4ED8" BorderThickness="1" Margin="0,18,14,0">
                <StackPanel>
                  <TextBlock Text="Cómo empezar" FontSize="16" FontWeight="SemiBold" Foreground="#F8FAFC" Margin="0,0,0,10"/>
                  <TextBlock TextWrapping="Wrap" Foreground="#CBD5E1" Margin="0,0,0,6"><Run FontWeight="Bold" Foreground="#60A5FA">1.  Analizar:</Run><Run Text=" pulse &quot;Analizar el equipo&quot;. Tarda 1 o 2 minutos y no cambia nada."/></TextBlock>
                  <TextBlock TextWrapping="Wrap" Foreground="#CBD5E1" Margin="0,0,0,6"><Run FontWeight="Bold" Foreground="#60A5FA">2.  Revisar:</Run><Run Text=" verá un puntaje de 0 a 100, los problemas y qué hacer con cada uno."/></TextBlock>
                  <TextBlock TextWrapping="Wrap" Foreground="#CBD5E1"><Run FontWeight="Bold" Foreground="#60A5FA">3.  Reparar:</Run><Run Text=" pulse &quot;Reparar lo encontrado&quot;. Antes crea un punto de restauración y le pide confirmación."/></TextBlock>
                  <TextBlock Text="Para algo puntual (red, sonido, Outlook, drivers...) use las categorías del menú de la izquierda." Foreground="#94A3B8" FontSize="12" Margin="0,12,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>

              <Grid Margin="0,18,14,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="18"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" Background="#111827" CornerRadius="14" Padding="20" BorderBrush="#1F2937" BorderThickness="1">
                  <StackPanel>
                    <TextBlock Text="Problemas detectados" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12" Foreground="#F8FAFC"/>
                    <StackPanel x:Name="ListaAlertas">
                      <TextBlock Text="Todavía no hay datos." Foreground="#64748B"/>
                    </StackPanel>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Background="#111827" CornerRadius="14" Padding="20" BorderBrush="#1F2937" BorderThickness="1">
                  <StackPanel>
                    <TextBlock Text="Qué hacer" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12" Foreground="#F8FAFC"/>
                    <StackPanel x:Name="ListaSugerencias">
                      <TextBlock Text="Todavía no hay datos." Foreground="#64748B"/>
                    </StackPanel>
                  </StackPanel>
                </Border>
              </Grid>

              <TextBlock Text="Detalle por área" FontSize="16" FontWeight="SemiBold" Margin="0,24,0,12" Foreground="#F8FAFC"/>
              <WrapPanel x:Name="PanelTarjetas"/>
            </StackPanel>

            <StackPanel x:Name="PaginaCategoria" Visibility="Collapsed">
              <TextBlock x:Name="TxtCategoria" FontSize="24" FontWeight="SemiBold" Foreground="#F8FAFC"/>
              <TextBlock x:Name="TxtCategoriaDesc" Foreground="#94A3B8" Margin="0,4,0,20" TextWrapping="Wrap"/>
              <WrapPanel x:Name="PanelAcciones"/>
            </StackPanel>
          </Grid>
        </ScrollViewer>

        <Border Grid.Row="1" Background="#020617" BorderBrush="#1E293B" BorderThickness="0,1,0,0">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="16,8,16,4">
              <Button x:Name="BtnLimpiarLog" DockPanel.Dock="Right" Content="Limpiar" Style="{StaticResource Secundario}" Padding="10,3" FontSize="11"/>
              <TextBlock Text="Registro de actividad (aquí se ve qué está haciendo la herramienta)" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center"/>
            </DockPanel>
            <RichTextBox x:Name="Log" Background="Transparent" BorderThickness="0" IsReadOnly="True" Foreground="#CBD5E1"
                         FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" Margin="10,0,10,8"/>
          </DockPanel>
        </Border>

        <Border Grid.Row="2" Background="#0F172A" BorderBrush="#1E293B" BorderThickness="0,1,0,0">
          <DockPanel Margin="16,0">
            <ProgressBar x:Name="Progreso" DockPanel.Dock="Right" Width="200" Height="6" Foreground="#3B82F6"
                         Background="#1E293B" BorderThickness="0" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtEstado" Text="Listo" Foreground="#94A3B8" VerticalAlignment="Center" FontSize="12"
                       TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>

    <Grid x:Name="PanelLogin" Background="#0B1120" Visibility="Collapsed">
      <Border Width="380" Padding="32" Background="#111827" CornerRadius="14" BorderBrush="#1F2937" BorderThickness="1"
              VerticalAlignment="Center" HorizontalAlignment="Center">
        <StackPanel>
          <TextBlock Text="Soporte Técnico" FontSize="22" FontWeight="SemiBold" HorizontalAlignment="Center" Foreground="#F8FAFC"/>
          <TextBlock Text="Acceso restringido" Foreground="#94A3B8" HorizontalAlignment="Center" Margin="0,4,0,24"/>
          <TextBlock Text="Contraseña" Foreground="#94A3B8" FontSize="12" Margin="0,0,0,6"/>
          <PasswordBox x:Name="TxtClave" Height="38" FontSize="15" Padding="10,7" Background="#0B1120" Foreground="#E2E8F0"
                       BorderBrush="#334155" CaretBrush="#E2E8F0"/>
          <TextBlock x:Name="TxtErrorClave" Foreground="#F87171" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
          <Button x:Name="BtnEntrar" Content="Entrar" Style="{StaticResource Primario}" Height="40" Margin="0,16,0,0" IsDefault="True"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$Script:XamlDialogo = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Soporte Técnico" Width="520" SizeToContent="Height" WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" FontFamily="Segoe UI" Topmost="True">
  <Border Background="#111827" CornerRadius="12" BorderBrush="#334155" BorderThickness="1" Padding="24">
    <StackPanel>
      <TextBlock x:Name="Titulo" Text="Confirmar" FontSize="16" FontWeight="SemiBold" Foreground="#F8FAFC"/>
      <ScrollViewer MaxHeight="460" VerticalScrollBarVisibility="Auto" Margin="0,12,0,0">
        <TextBlock x:Name="Mensaje" TextWrapping="Wrap" Foreground="#CBD5E1" FontSize="13"/>
      </ScrollViewer>
      <TextBox x:Name="Entrada" Visibility="Collapsed" Margin="0,14,0,0" Height="34" Padding="8,5" Background="#0B1120"
               Foreground="#E2E8F0" BorderBrush="#334155" CaretBrush="#E2E8F0" FontSize="14"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button x:Name="BtnNo" Content="No" MinWidth="100" Margin="0,0,10,0" IsCancel="True"/>
        <Button x:Name="BtnSi" Content="Sí" MinWidth="100" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$Script:CategoriasGui = [ordered]@{
    'Inicio'                = @{ Icono = 0xE80F; Desc = '' }
    'Sistema'               = @{ Icono = 0xE770; Desc = 'Archivos de Windows, actualizaciones, disco, rendimiento y menú Inicio.' }
    'Drivers'               = @{ Icono = 0xE772; Desc = 'Identificar dispositivos desconocidos, instalar, respaldar, reinstalar y revertir drivers.' }
    'Red e internet'        = @{ Icono = 0xE701; Desc = 'Conexión, DNS, proxy, archivo hosts y navegadores.' }
    'Sonido y dispositivos' = @{ Icono = 0xE767; Desc = 'Audio, micrófono, cámara, Bluetooth, USB, impresoras y batería.' }
    'Outlook y Office'      = @{ Icono = 0xE715; Desc = 'Outlook, Office, OneDrive y Teams.' }
    'Seguridad'             = @{ Icono = 0xEA18; Desc = 'Antivirus, firewall y BitLocker.' }
    'Herramientas'          = @{ Icono = 0xE90F; Desc = 'Accesos directos a las herramientas de Windows (se abren al instante, aunque haya una tarea en curso).' }
}

#endregion

#region ==================== INTERFAZ GRÁFICA: LÓGICA ====================

# Las tareas largas corren en un runspace aparte. Ese runspace NUNCA toca la ventana:
# deja mensajes en $Sync.Cola y preguntas en $Sync.Pregunta, y un temporizador de la
# ventana los procesa. Así la interfaz no se congela y no hay llamadas entre hilos.

$Script:EnvolturaTarea = @'
param($Titulo, $Comando)
$Script:RequiereReinicio = $false
Write-Log ("===== Inicio: {0} =====" -f $Titulo) 'INFO' -SoloArchivo
$ok = $false
$estado = 'Avisos'
$Sync.Visita.TareaActual = $Titulo
try {
    $salida = & ([scriptblock]::Create($Comando))
    $ok = [bool](@($salida)[-1])
    if ($ok) { $estado = 'OK' }
}
catch {
    $estado = 'Error'
    Write-Log ("Error inesperado en '{0}': {1}" -f $Titulo, $_.Exception.Message) 'ERROR'
}
# Si la ventana ya la anotó como interrumpida al cerrar, TareaActual quedó vacío y no se repite
if ($Sync.Visita.TareaActual -eq $Titulo) {
    $Sync.Visita.TareaActual = ''
    try { Registrar-AccionVisita $Titulo $estado } catch { }
}
try {
    if ($Script:RequiereReinicio) { Preguntar-Reinicio }
}
catch { }
Write-Log ("===== Fin: {0} =====" -f $Titulo) 'INFO' -SoloArchivo
$Sync.Cola.Enqueue(@{ Tipo = 'Fin'; Texto = $Titulo; Ok = $ok })
'@

$Script:ColoresLog = @{
    'Green' = '#4ADE80'; 'Cyan' = '#67E8F9'; 'Yellow' = '#FACC15'; 'Red' = '#F87171'; 'White' = '#F8FAFC'
    'DarkGray' = '#64748B'; 'DarkCyan' = '#38BDF8'; 'Gray' = '#CBD5E1'; 'Magenta' = '#E879F9'
}

function Get-ColorPincel {
    param([string]$Hex)
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Nuevo-TextoGui {
    param([string]$Texto, [double]$Tamano = 13, [string]$Color = '#CBD5E1', [switch]$Negrita)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Texto
    $t.FontSize = $Tamano
    $t.Foreground = Get-ColorPincel $Color
    $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
    if ($Negrita) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    return $t
}

function Agregar-LogGui {
    param([string]$Texto, [string]$Color)
    $rtb = $Script:Gui.Log
    $hex = $Script:ColoresLog[$Color]
    if (-not $hex) { $hex = '#CBD5E1' }
    if (-not $Texto) { $Texto = ' ' }
    $parrafo = New-Object System.Windows.Documents.Paragraph
    $parrafo.Margin = New-Object System.Windows.Thickness(0)
    $run = New-Object System.Windows.Documents.Run($Texto)
    $run.Foreground = Get-ColorPincel $hex
    $parrafo.Inlines.Add($run)
    $rtb.Document.Blocks.Add($parrafo)
    while ($rtb.Document.Blocks.Count -gt 1500) { [void]$rtb.Document.Blocks.Remove($rtb.Document.Blocks.FirstBlock) }
    $rtb.ScrollToEnd()
}

function Solicitar-Gui {
    # Pide una respuesta al usuario desde cualquier hilo.
    param([string]$Tipo, [string]$Texto)
    if ($Sync.HiloUI -eq [System.Threading.Thread]::CurrentThread.ManagedThreadId) {
        $Sync.Cancelado = $false
        return [string](Mostrar-DialogoGui @{ Tipo = $Tipo; Texto = $Texto })
    }
    $Sync.Respuesta = $null
    $Sync.Cancelado = $false
    $Sync.Pregunta = @{ Tipo = $Tipo; Texto = $Texto }
    while ($null -eq $Sync.Respuesta) { Start-Sleep -Milliseconds 150 }
    $r = [string]$Sync.Respuesta
    $Sync.Respuesta = $null
    return $r
}

function Mostrar-DialogoGui {
    param($Pregunta)
    $tipo = "$($Pregunta.Tipo)"
    if ($tipo -eq 'Inicio') { Mostrar-InicioGui; return 'OK' }
    [xml]$x = $Script:XamlDialogo
    $dlg = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $titulo = $dlg.FindName('Titulo')
    $mensaje = $dlg.FindName('Mensaje')
    $entrada = $dlg.FindName('Entrada')
    $btnSi = $dlg.FindName('BtnSi')
    $btnNo = $dlg.FindName('BtnNo')
    try {
        $btnSi.Style = $Script:Gui.Ventana.FindResource('Primario')
        $btnNo.Style = $Script:Gui.Ventana.FindResource('Secundario')
    }
    catch { }
    $mensaje.Text = "$($Pregunta.Texto)"
    if ($Pregunta.Valor) { $entrada.Text = "$($Pregunta.Valor)" }
    switch ($tipo) {
        'SiNo' {
            $titulo.Text = 'Confirmar'
            $btnSi.Content = 'Sí, continuar'
            $btnNo.Content = 'Cancelar'
        }
        'Texto' {
            $titulo.Text = 'Ingresar dato'
            $entrada.Visibility = [System.Windows.Visibility]::Visible
            $btnSi.Content = 'Aceptar'
            $btnNo.Content = 'Cancelar'
        }
        default {
            $titulo.Text = "$($Pregunta.Titulo)"
            if (-not $titulo.Text) { $titulo.Text = 'Información' }
            $btnNo.Visibility = [System.Windows.Visibility]::Collapsed
            $btnSi.Content = 'Cerrar'
            $mensaje.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
            $mensaje.FontSize = 12
        }
    }
    $dlg.Tag = ''
    $btnSi.Add_Click({
            $w = [System.Windows.Window]::GetWindow($this)
            $e = $w.FindName('Entrada')
            if ($e.Visibility -eq [System.Windows.Visibility]::Visible) { $w.Tag = 'T:' + $e.Text } else { $w.Tag = 'Si' }
            $w.Close()
        })
    $btnNo.Add_Click({
            $w = [System.Windows.Window]::GetWindow($this)
            $w.Tag = 'No'
            $w.Close()
        })
    $dlg.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { } })
    if ($tipo -eq 'Texto') { $dlg.Add_ContentRendered({ [void]$this.FindName('Entrada').Focus() }) }
    try { if ($Script:Gui.Ventana.IsLoaded) { $dlg.Owner = $Script:Gui.Ventana } } catch { }
    [void]$dlg.ShowDialog()
    $r = "$($dlg.Tag)"
    if ($tipo -eq 'Texto') {
        if ($r.StartsWith('T:')) { return $r.Substring(2) }
        $Sync.Cancelado = $true
        return ''
    }
    if ($tipo -eq 'SiNo') {
        if ($r -eq 'Si') { return 'Si' }
        return 'No'
    }
    return 'OK'
}

function Set-Medidor {
    param([int]$Puntaje, [string]$Color)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $angulo = 360.0 * [math]::Max(0, [math]::Min($Puntaje, 100)) / 100.0
    if ($angulo -ge 359.9) { $angulo = 359.9 }
    if ($angulo -le 0.5) {
        $Script:Gui.ArcoPuntaje.Data = $null
    }
    else {
        $rad = $angulo * [math]::PI / 180.0
        $x = 80 + 70 * [math]::Sin($rad)
        $y = 80 - 70 * [math]::Cos($rad)
        $grande = 0
        if ($angulo -gt 180) { $grande = 1 }
        $datos = [string]::Format($inv, 'M 80,10 A 70,70 0 {0} 1 {1:0.##},{2:0.##}', $grande, $x, $y)
        $Script:Gui.ArcoPuntaje.Data = [System.Windows.Media.Geometry]::Parse($datos)
    }
    $Script:Gui.ArcoPuntaje.Stroke = Get-ColorPincel $Color
}

function Nueva-FilaAlerta {
    param([string]$Etiqueta, [string]$ColorEtiqueta, [string]$Texto)
    $dp = New-Object System.Windows.Controls.DockPanel
    $dp.Margin = New-Object System.Windows.Thickness(0, 0, 0, 9)
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-ColorPincel $ColorEtiqueta
    $b.CornerRadius = New-Object System.Windows.CornerRadius(5)
    $b.Padding = New-Object System.Windows.Thickness(7, 1, 7, 1)
    $b.Margin = New-Object System.Windows.Thickness(0, 1, 10, 0)
    $b.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $b.Child = Nuevo-TextoGui $Etiqueta 10 '#FFFFFF' -Negrita
    [System.Windows.Controls.DockPanel]::SetDock($b, [System.Windows.Controls.Dock]::Left)
    [void]$dp.Children.Add($b)
    [void]$dp.Children.Add((Nuevo-TextoGui $Texto 13 '#E2E8F0'))
    return $dp
}

function Mostrar-DetalleSeccion {
    param($Seccion)
    $texto = New-Object System.Text.StringBuilder
    foreach ($a in $Seccion.Alertas) {
        $et = 'ALERTA'
        if ($a.Critica) { $et = 'CRÍTICO' } elseif ($a.Info) { $et = 'NOTA' }
        [void]$texto.AppendLine(('[{0}] {1}' -f $et, $a.Texto))
    }
    if ($Seccion.Alertas.Count -gt 0) { [void]$texto.AppendLine('') }
    foreach ($l in $Seccion.Lineas) { [void]$texto.AppendLine("$l".Trim()) }
    [void](Mostrar-DialogoGui @{ Tipo = 'Info'; Titulo = $Seccion.Nombre; Texto = $texto.ToString() })
}

function Nueva-TarjetaGui {
    param($Seccion)
    $nAl = @($Seccion.Alertas | Where-Object { -not $_.Info }).Count
    $nCr = @($Seccion.Alertas | Where-Object { $_.Critica }).Count
    $nIn = @($Seccion.Alertas | Where-Object { $_.Info }).Count
    if ($nCr -gt 0) { $color = '#EF4444'; $badge = "$nAl problema(s)" }
    elseif ($nAl -gt 0) { $color = '#F59E0B'; $badge = "$nAl alerta(s)" }
    else {
        $color = '#22C55E'; $badge = 'OK'
        if ($nIn -gt 0) { $badge = "OK · $nIn nota(s)" }
    }
    $borde = New-Object System.Windows.Controls.Border
    $borde.Width = 300
    $borde.Margin = New-Object System.Windows.Thickness(0, 0, 14, 14)
    $borde.Padding = New-Object System.Windows.Thickness(16, 12, 16, 12)
    $borde.Background = Get-ColorPincel '#111827'
    $borde.BorderBrush = Get-ColorPincel $color
    $borde.BorderThickness = New-Object System.Windows.Thickness(4, 0, 0, 0)
    $borde.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $borde.Cursor = [System.Windows.Input.Cursors]::Hand

    $sp = New-Object System.Windows.Controls.StackPanel
    $cab = New-Object System.Windows.Controls.DockPanel
    $pastilla = New-Object System.Windows.Controls.Border
    $pastilla.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $pastilla.Padding = New-Object System.Windows.Thickness(8, 1, 8, 1)
    $pastilla.Background = Get-ColorPincel '#1F2937'
    $pastilla.Child = Nuevo-TextoGui $badge 11 $color -Negrita
    [System.Windows.Controls.DockPanel]::SetDock($pastilla, [System.Windows.Controls.Dock]::Right)
    [void]$cab.Children.Add($pastilla)
    [void]$cab.Children.Add((Nuevo-TextoGui $Seccion.Nombre 14 '#F1F5F9' -Negrita))
    [void]$sp.Children.Add($cab)
    foreach ($a in @($Seccion.Alertas | Select-Object -First 3)) {
        $t = Nuevo-TextoGui ("• " + $a.Texto) 12 '#CBD5E1'
        $t.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
        [void]$sp.Children.Add($t)
    }
    $pie = Nuevo-TextoGui 'Clic para ver el detalle' 11 '#64748B'
    $pie.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    [void]$sp.Children.Add($pie)
    $borde.Child = $sp
    $borde.Tag = $Seccion
    $borde.Add_MouseLeftButtonUp({ Mostrar-DetalleSeccion $this.Tag })
    return $borde
}

function Mostrar-DiagnosticoGui {
    $d = $Script:Sync.Diagnostico
    if (-not $d) { return }
    $p = $d.Puntaje
    Set-Medidor $p.Puntaje $p.Color
    $Script:Gui.TxtPuntaje.Text = "$($p.Puntaje)"
    $Script:Gui.TxtEstadoSalud.Text = $p.Estado
    $Script:Gui.BordeEstado.Background = Get-ColorPincel $p.Color
    $Script:Gui.GuiaInicio.Visibility = [System.Windows.Visibility]::Collapsed
    if ($p.Criticas -eq 0 -and $p.Alertas -eq 0) {
        $Script:Gui.TxtResumen.Text = 'No se encontraron problemas. El equipo está en buen estado.'
    }
    else {
        $Script:Gui.TxtResumen.Text = ("Se encontraron {0} problema(s) crítico(s) y {1} alerta(s). Los críticos conviene atenderlos primero. Haga clic en una tarjeta de abajo para ver el detalle, o pulse ""Reparar lo encontrado""." -f $p.Criticas, $p.Alertas)
    }
    $Script:Gui.TxtSubtitulo.Text = ("Equipo {0} analizado el {1}" -f $env:COMPUTERNAME, $d.Fecha.ToString('dd/MM/yyyy HH:mm'))

    $lista = $Script:Gui.ListaAlertas
    $lista.Children.Clear()
    foreach ($a in $d.Alertas) {
        if ($a.StartsWith('[CRÍTICO]')) { [void]$lista.Children.Add((Nueva-FilaAlerta 'CRÍTICO' '#DC2626' $a.Substring(9).Trim())) }
        elseif ($a.StartsWith('[ALERTA]')) { [void]$lista.Children.Add((Nueva-FilaAlerta 'ALERTA' '#D97706' $a.Substring(8).Trim())) }
        elseif ($a.StartsWith('[INFO]')) { [void]$lista.Children.Add((Nueva-FilaAlerta 'NOTA' '#0284C7' $a.Substring(6).Trim())) }
    }
    if ($lista.Children.Count -eq 0) { [void]$lista.Children.Add((Nuevo-TextoGui 'No se detectaron problemas.' 13 '#4ADE80' -Negrita)) }

    $sug = $Script:Gui.ListaSugerencias
    $sug.Children.Clear()
    $n = 1
    foreach ($s in $d.Sugerencias) {
        $t = Nuevo-TextoGui ("{0}. {1}" -f $n, $s) 13 '#E2E8F0'
        $t.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        [void]$sug.Children.Add($t)
        $n++
    }
    if ($sug.Children.Count -eq 0) { [void]$sug.Children.Add((Nuevo-TextoGui 'Nada que hacer: el equipo está bien.' 13 '#4ADE80')) }

    $tarjetas = $Script:Gui.PanelTarjetas
    $tarjetas.Children.Clear()
    foreach ($s in $d.Secciones) { [void]$tarjetas.Children.Add((Nueva-TarjetaGui $s)) }

    $Script:Gui.HayAcciones = (@($d.Acciones).Count -gt 0)
    if ($Script:Gui.HayAcciones) {
        $Script:Gui.BtnRepararTodo.ToolTip = "Aplicará: " + (@($d.Acciones) -join ', ')
    }
    else {
        $Script:Gui.BtnRepararTodo.ToolTip = 'No hay reparaciones automáticas para lo encontrado.'
    }
    $Script:Gui.BtnRepararTodo.IsEnabled = $Script:Gui.HayAcciones -and -not $Script:Sync.Ocupado
    $Script:Gui.BtnReporte.IsEnabled = [bool]$d.Html
}

function Publicar-Diagnostico {
    # (Corre en el runspace de tareas.) Copia el resultado del diagnóstico para la ventana.
    $p = Get-PuntajeSalud
    $secciones = @(foreach ($s in $Script:Secciones) {
            [pscustomobject]@{
                Nombre  = $s.Nombre
                Alertas = @($s.Alertas | ForEach-Object { [pscustomobject]@{ Texto = $_.Texto; Critica = [bool]$_.Critica; Info = [bool]$_.Info } })
                Lineas  = @($s.Lineas)
            }
        })
    $acciones = @($Script:NombresAcciones.Keys | Where-Object { $Script:AccionesSugeridas.Contains($_) } | ForEach-Object { $Script:NombresAcciones[$_] })
    $Sync.Diagnostico = [pscustomobject]@{
        Puntaje     = $p
        Secciones   = $secciones
        Alertas     = @(Get-AlertasOrdenadas)
        Sugerencias = @($Script:Sugerencias)
        Html        = $Script:UltimoHtml
        Acciones    = $acciones
        Fecha       = Get-Date
    }
    $Sync.Cola.Enqueue(@{ Tipo = 'Diagnostico' })
    return $true
}

function Set-OcupadoGui {
    param([bool]$Ocupado, [string]$Titulo = '')
    $Script:Sync.Ocupado = $Ocupado
    $Script:Gui.Progreso.IsIndeterminate = $Ocupado
    if ($Ocupado) { $Script:Gui.TxtEstado.Text = "Trabajando en: $Titulo... (puede tardar unos minutos, no cierre la ventana)" }
    $Script:Gui.BtnDiagnostico.IsEnabled = -not $Ocupado
    $Script:Gui.BtnCompleta.IsEnabled = -not $Ocupado
    $Script:Gui.BtnRepararTodo.IsEnabled = (-not $Ocupado) -and $Script:Gui.HayAcciones
    foreach ($b in $Script:Gui.PanelAcciones.Children) {
        if ($b.Tag -and -not $b.Tag.Ui) { $b.IsEnabled = -not $Ocupado }
    }
}

function Ejecutar-TareaGui {
    param([string]$Titulo, [string]$Comando)
    if ($Script:Sync.Ocupado) {
        [void](Mostrar-DialogoGui @{ Tipo = 'Info'; Titulo = 'Tarea en curso'; Texto = 'Ya hay una tarea en curso. Espere a que termine (vea el registro de actividad).' })
        return
    }
    Set-OcupadoGui $true $Titulo
    Agregar-LogGui '' 'Gray'
    Agregar-LogGui ("▶ {0}" -f $Titulo) 'White'
    $ps = [powershell]::Create()
    $ps.Runspace = $Script:RunspaceGui
    [void]$ps.AddScript($Script:EnvolturaTarea).AddArgument($Titulo).AddArgument($Comando)
    $Script:Sync.PsActual = $ps
    $Script:Sync.HandleActual = $ps.BeginInvoke()
}

function Finalizar-TareaGui {
    param($Mensaje)
    $ps = $Script:Sync.PsActual
    if ($ps) {
        try { [void]$ps.EndInvoke($Script:Sync.HandleActual) }
        catch { Write-Log ("Error en la tarea: {0}" -f $_.Exception.Message) 'ERROR' }
        try { foreach ($e in $ps.Streams.Error) { Write-Log ("Detalle de error: {0}" -f $e) 'ADVERTENCIA' -SoloArchivo } } catch { }
        $ps.Dispose()
        $Script:Sync.PsActual = $null
    }
    Set-OcupadoGui $false
    if ($Mensaje.Ok) { $Script:Gui.TxtEstado.Text = "✔ Listo: $($Mensaje.Texto)" }
    else { $Script:Gui.TxtEstado.Text = "⚠ Terminó con avisos o se canceló: $($Mensaje.Texto). Revise el registro de actividad." }
}

function Procesar-ColaGui {
    $mensaje = $null
    $n = 0
    while ($n -lt 300 -and $Script:Sync.Cola.TryDequeue([ref]$mensaje)) {
        $n++
        try {
            switch ($mensaje.Tipo) {
                'Log'         { Agregar-LogGui $mensaje.Texto $mensaje.Color }
                'Estado'      { $Script:Gui.TxtEstado.Text = $mensaje.Texto }
                'Diagnostico' { Mostrar-DiagnosticoGui; Mostrar-Categoria 'Inicio' }
                'Fin'         { Finalizar-TareaGui $mensaje }
            }
        }
        catch { }
    }
    if ($Script:Sync.Pregunta -and -not $Script:Gui.DialogoAbierto) {
        $Script:Gui.DialogoAbierto = $true
        $Script:Gui.Timer.Stop()
        try {
            $p = $Script:Sync.Pregunta
            $Script:Sync.Pregunta = $null
            $Script:Sync.Respuesta = [string](Mostrar-DialogoGui $p)
        }
        catch {
            $Script:Sync.Respuesta = 'No'
        }
        finally {
            $Script:Gui.DialogoAbierto = $false
            $Script:Gui.Timer.Start()
        }
    }
}

function Mostrar-Categoria {
    param([string]$Nombre)
    foreach ($b in $Script:Gui.BotonesNav) {
        if ("$($b.Tag)" -eq $Nombre) { $b.Background = Get-ColorPincel '#1E293B'; $b.Foreground = Get-ColorPincel '#FFFFFF' }
        else { $b.Background = [System.Windows.Media.Brushes]::Transparent; $b.Foreground = Get-ColorPincel '#CBD5E1' }
    }
    if ($Nombre -eq 'Inicio') {
        $Script:Gui.PaginaInicio.Visibility = [System.Windows.Visibility]::Visible
        $Script:Gui.PaginaCategoria.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }
    $Script:Gui.PaginaInicio.Visibility = [System.Windows.Visibility]::Collapsed
    $Script:Gui.PaginaCategoria.Visibility = [System.Windows.Visibility]::Visible
    $Script:Gui.TxtCategoria.Text = $Nombre
    $Script:Gui.TxtCategoriaDesc.Text = $Script:CategoriasGui[$Nombre].Desc
    $panel = $Script:Gui.PanelAcciones
    $panel.Children.Clear()
    foreach ($a in @($Script:Catalogo | Where-Object { $_.Cat -eq $Nombre })) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $Script:Gui.Ventana.FindResource('Tile')
        $sp = New-Object System.Windows.Controls.StackPanel
        [void]$sp.Children.Add((Nuevo-TextoGui $a.Titulo 14 '#F1F5F9' -Negrita))
        $desc = Nuevo-TextoGui $a.Desc 12 '#94A3B8'
        $desc.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
        [void]$sp.Children.Add($desc)
        if ($a.Aviso) {
            $aviso = Nuevo-TextoGui ("⚠ " + $a.Aviso) 11 '#FACC15'
            $aviso.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
            [void]$sp.Children.Add($aviso)
        }
        $btn.Content = $sp
        $btn.Tag = $a
        $btn.Add_Click({ Invoke-AccionCatalogo $this.Tag })
        if (-not $a.Ui -and $Script:Sync.Ocupado) { $btn.IsEnabled = $false }
        [void]$panel.Children.Add($btn)
    }
}

function Invoke-AccionCatalogo {
    param($Accion)
    if ($Accion.Ui) {
        try { & ([scriptblock]::Create($Accion.Cmd)) }
        catch { Agregar-LogGui ("No se pudo abrir {0}: {1}" -f $Accion.Titulo, $_.Exception.Message) 'Red' }
        return
    }
    Ejecutar-TareaGui -Titulo $Accion.Titulo -Comando $Accion.Cmd
}

function Validar-ClaveGui {
    $sal = [Convert]::FromBase64String($Script:ClaveSal)
    $hash = Get-HashClave -Clave $Script:Gui.TxtClave.Password -Sal $sal -Iteraciones $Script:ClaveIteraciones
    if ($hash -ceq $Script:ClaveHash) {
        try { Set-ClaveExportacion -Clave $Script:Gui.TxtClave.Password } catch { }
        $Script:Gui.PanelLogin.Visibility = [System.Windows.Visibility]::Collapsed
        $Script:Gui.Principal.Visibility = [System.Windows.Visibility]::Visible
        $Script:Gui.TxtClave.Clear()
        Write-Log ("Acceso concedido (usuario de Windows: {0})." -f $env:USERNAME) 'INFO' -SoloArchivo
        Iniciar-VisitaGui
        return
    }
    $Script:Gui.Intentos++
    $Script:Gui.TxtClave.Clear()
    Write-Log ("Contraseña incorrecta en la interfaz gráfica (intento {0} de 3)." -f $Script:Gui.Intentos) 'ADVERTENCIA' -SoloArchivo
    if ($Script:Gui.Intentos -ge 3) {
        Write-Log 'Acceso denegado: 3 intentos fallidos.' 'ERROR' -SoloArchivo
        $Script:Gui.CerrarSinPreguntar = $true
        $Script:Gui.Ventana.Close()
        return
    }
    $Script:Gui.TxtErrorClave.Text = ("Contraseña incorrecta (intento {0} de 3)." -f $Script:Gui.Intentos)
    Start-Sleep -Seconds $Script:Gui.Intentos
}

function New-RunspaceGui {
    # Crea el runspace de tareas con todas las funciones y variables de la herramienta.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $funciones = @{}
    foreach ($f in @(Get-ChildItem -Path function:)) {
        if (($Script:FuncionesIniciales -notcontains $f.Name) -or $f.Name -eq 'Clear-Host') { $funciones[$f.Name] = $f.Definition }
    }
    $variables = @{ Sync = $Sync; RequiereReinicio = $false }
    foreach ($v in @('Version', 'Base', 'BaseLocal', 'EnUsb', 'DirLogs', 'DirReportes', 'LogFile', 'NombresAcciones', 'CodigoCoreAudio', 'ClaveIteraciones', 'ModoInterfaz', 'InfoSO', 'VendoresPci', 'VendoresUsb', 'VendoresAcpi', 'TiposPci', 'TiposUsb')) {
        $variables[$v] = (Get-Variable -Name $v -Scope Script).Value
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $inicial = @'
param($Funciones, $Variables)
foreach ($k in $Funciones.Keys) { Set-Item -Path ("function:global:{0}" -f $k) -Value ([scriptblock]::Create($Funciones[$k])) }
foreach ($k in $Variables.Keys) { Set-Variable -Name $k -Value $Variables[$k] -Scope Global }
'@
    [void]$ps.AddScript($inicial).AddArgument($funciones).AddArgument($variables)
    [void]$ps.Invoke()
    foreach ($e in $ps.Streams.Error) { Write-Log ("Preparando tareas: {0}" -f $e) 'ADVERTENCIA' -SoloArchivo }
    $ps.Dispose()
    return $rs
}

function Iniciar-InterfazGrafica {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $Sync.HiloUI = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    [xml]$xaml = $Script:XamlPrincipal
    $ventana = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $Script:Gui = @{
        Ventana = $ventana; Intentos = 0; DialogoAbierto = $false; CerrarSinPreguntar = $false; HayAcciones = $false; AccesoOk = $false
        BotonesNav = New-Object System.Collections.Generic.List[object]
    }
    $nombres = @('Principal', 'PanelLogin', 'TxtClave', 'TxtErrorClave', 'BtnEntrar', 'TxtEquipo', 'TxtVersion', 'PanelNav',
        'PaginaInicio', 'PaginaCategoria', 'TxtSubtitulo', 'ArcoPuntaje', 'TxtPuntaje', 'BordeEstado', 'TxtEstadoSalud', 'TxtResumen',
        'BtnDiagnostico', 'BtnRepararTodo', 'BtnReporte', 'BtnCompleta', 'ListaAlertas', 'ListaSugerencias', 'PanelTarjetas',
        'TxtCategoria', 'TxtCategoriaDesc', 'PanelAcciones', 'Log', 'BtnLimpiarLog', 'Progreso', 'TxtEstado', 'GuiaInicio')
    foreach ($n in $nombres) { $Script:Gui[$n] = $ventana.FindName($n) }

    $ventana.Title = "Soporte Técnico v$($Script:Version) - $env:COMPUTERNAME"
    $Script:Gui.TxtEquipo.Text = "$env:COMPUTERNAME`n$($Script:InfoSO)"
    if ($Script:EnUsb) { $Script:Gui.TxtEquipo.Text += "`nGuardando reportes en la USB" }
    elseif ($Script:AvisoUsb) { $Script:Gui.TxtEquipo.Text += "`nNo se pudo usar la USB: reportes en $($Script:BaseLocal)" }
    $Script:Gui.TxtVersion.Text = "v$($Script:Version)`nLog: $($Script:LogFile)"

    foreach ($cat in $Script:CategoriasGui.Keys) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $ventana.FindResource('Nav')
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $ico = New-Object System.Windows.Controls.TextBlock
        $ico.Text = [string][char][int]$Script:CategoriasGui[$cat].Icono
        $ico.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
        $ico.FontSize = 16
        $ico.Width = 30
        $ico.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = $cat
        $txt.FontSize = 14
        $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$sp.Children.Add($ico)
        [void]$sp.Children.Add($txt)
        $btn.Content = $sp
        $btn.Tag = $cat
        $btn.Add_Click({ Mostrar-Categoria ([string]$this.Tag) })
        [void]$Script:Gui.PanelNav.Children.Add($btn)
        $Script:Gui.BotonesNav.Add($btn)
    }

    $Script:Gui.BtnDiagnostico.Add_Click({ Ejecutar-TareaGui -Titulo 'Diagnóstico completo' -Comando 'Invoke-Diagnostico -SinPreguntas; Publicar-Diagnostico' })
    $Script:Gui.BtnRepararTodo.Add_Click({ Ejecutar-TareaGui -Titulo 'Reparar lo encontrado' -Comando 'Invoke-ReparacionAutomatica' })
    $Script:Gui.BtnCompleta.Add_Click({ Ejecutar-TareaGui -Titulo 'Reparación completa' -Comando 'Invoke-ReparacionCompleta' })
    $Script:Gui.BtnReporte.Add_Click({
            if ($Script:Sync.Diagnostico -and $Script:Sync.Diagnostico.Html) { Abrir-ParaUsuario $Script:Sync.Diagnostico.Html }
        })
    $Script:Gui.BtnLimpiarLog.Add_Click({ $Script:Gui.Log.Document.Blocks.Clear() })
    $Script:Gui.BtnEntrar.Add_Click({ Validar-ClaveGui })

    if ($Script:ClaveHash) {
        $Script:Gui.Principal.Visibility = [System.Windows.Visibility]::Collapsed
        $Script:Gui.PanelLogin.Visibility = [System.Windows.Visibility]::Visible
        $ventana.Add_ContentRendered({ [void]$Script:Gui.TxtClave.Focus() })
    }
    else {
        $ventana.Add_ContentRendered({ Iniciar-VisitaGui })
    }

    $ventana.Add_Closing({
            if ($Script:Sync.Ocupado -and -not $Script:Gui.CerrarSinPreguntar) {
                $r = Mostrar-DialogoGui @{ Tipo = 'SiNo'; Texto = 'Hay una tarea en curso. Si cierra ahora se interrumpe (DISM o SFC pueden seguir solos en segundo plano). ¿Cerrar de todas formas?' }
                if ($r -ne 'Si') { $_.Cancel = $true; return }
            }
            if ($Script:Gui.CerrarSinPreguntar -or -not $Script:Gui.AccesoOk) { return }
            try {
                $tarea = "$($Script:Sync.Visita.TareaActual)"
                if ($tarea) {
                    $Script:Sync.Visita.TareaActual = ''
                    Registrar-AccionVisita $tarea 'Interrumpida'
                }
                if (Test-VisitaConActividad) {
                    $cliente = Mostrar-DialogoGui @{ Tipo = 'Texto'; Texto = 'Historial de la visita: nombre del cliente (opcional).'; Valor = $Script:Sync.Visita.ClienteAnterior }
                    $notas = Mostrar-DialogoGui @{ Tipo = 'Texto'; Texto = 'Historial de la visita: notas, por ejemplo qué problema tenía (opcional).' }
                    Cerrar-Visita -Cliente $cliente -Notas $notas
                    $zip = Finalizar-VisitaRemota
                    if ($zip) {
                        $limpio = ''
                        if ($Script:Sync.SinArchivosLocales) { $limpio = "`n`nNo quedó información legible de la herramienta en este equipo." }
                        [void](Mostrar-DialogoGui @{ Tipo = 'Info'; Titulo = 'Visita exportada'; Texto = ("No está trabajando desde la USB, así que la visita se guardó cifrada en:`n{0}`n`nCópielo a su USB, en la carpeta Clientes\Importar (por ejemplo con la transferencia de archivos de AnyDesk). Se carga solo la próxima vez que abra la herramienta desde la USB.{1}" -f $zip, $limpio) })
                    }
                }
                else {
                    $null = Finalizar-VisitaRemota -Exportar $false
                }
            }
            catch { Write-Log ("No se pudo cerrar la visita: {0}" -f $_.Exception.Message) 'ADVERTENCIA' -SoloArchivo }
        })

    $Script:RunspaceGui = New-RunspaceGui

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Procesar-ColaGui })
    $Script:Gui.Timer = $timer
    $timer.Start()

    Mostrar-Categoria 'Inicio'
    Set-Medidor 0 '#334155'
    Write-Host 'Bienvenido. Empiece con "Diagnóstico completo": revisa el equipo y le dice qué reparar.' -ForegroundColor Cyan
    Write-Log 'Interfaz gráfica iniciada.' 'INFO' -SoloArchivo

    [void]$ventana.ShowDialog()

    $timer.Stop()
    try { if ($Script:Sync.PsActual) { $Script:Sync.PsActual.Stop() } } catch { }
    try { $Script:RunspaceGui.Dispose() } catch { }
    try { if ($Script:Gui.PsFicha) { $Script:Gui.PsFicha.Stop(); $Script:Gui.PsFicha.Dispose() } } catch { }
    try { if ($Script:Gui.RunspaceFicha) { $Script:Gui.RunspaceFicha.Dispose() } } catch { }
}

#endregion

#region ==================== MENÚ PRINCIPAL ====================

function Ejecutar-Opcion {
    # Envuelve cada opción: registra inicio/fin, captura cualquier error y pregunta por el reinicio si hace falta.
    param([string]$Nombre, [scriptblock]$Accion)
    Clear-Host
    Write-Log "===== Inicio: $Nombre =====" 'INFO' -SoloArchivo
    $estado = 'Avisos'
    try {
        $salida = & $Accion
        $ok = [bool](@($salida)[-1])
        if ($ok) { $estado = 'OK'; Write-Log "===== Fin: $Nombre (OK) =====" 'INFO' -SoloArchivo }
        else     { Write-Log "===== Fin: $Nombre (con advertencias o cancelado) =====" 'INFO' -SoloArchivo }
    }
    catch {
        $estado = 'Error'
        Write-Log ("Error inesperado en '{0}': {1}" -f $Nombre, $_.Exception.Message) 'ERROR'
    }
    try { Registrar-AccionVisita $Nombre $estado } catch { }
    if ($Script:RequiereReinicio) { Preguntar-Reinicio }
    Pausa
}

function Mostrar-Menu {
    Clear-Host
    Write-Host ''
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host ("   SOPORTE TÉCNICO v{0}   |   Equipo: {1}" -f $Script:Version, $env:COMPUTERNAME) -ForegroundColor White
    Write-Host ("   {0}" -f $Script:InfoSO) -ForegroundColor DarkGray
    if ($Script:EnUsb) { Write-Host ("   Guardando en la USB: {0}" -f $Script:Base) -ForegroundColor DarkGray }
    elseif ($Script:AvisoUsb) { Write-Host ("   {0}" -f $Script:AvisoUsb) -ForegroundColor Yellow }
    if ($Sync.Visita.AvisoAnterior) { Write-Host ("   HISTORIAL: {0}" -f $Sync.Visita.AvisoAnterior) -ForegroundColor Yellow }
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '   DIAGNÓSTICO' -ForegroundColor Cyan
    Write-Host '     1. Diagnóstico completo + reporte visual + reparación automática' -ForegroundColor Green
    Write-Host '   REPARACIONES' -ForegroundColor Cyan
    Write-Host '     2. Reparar archivos de Windows (DISM + SFC)'
    Write-Host '     3. Reparar red / internet'
    Write-Host '     4. Limpiar archivos temporales'
    Write-Host '     5. Reparar Windows Update'
    Write-Host '     6. Reparar impresora (cola de impresión atascada)'
    Write-Host '     7. Revisar disco (CHKDSK)'
    Write-Host '     8. Reiniciar Explorador (barra de tareas / escritorio congelado)'
    Write-Host '     9. Reparar Microsoft Store y apps'
    Write-Host '    10. Sincronizar fecha y hora'
    Write-Host '    15. Diagnosticar y reparar SONIDO' -ForegroundColor Green
    Write-Host '    16. Outlook / Office (caché, contraseña, OST, reparar Office)' -ForegroundColor Green
    Write-Host '    17. Reparaciones avanzadas (drivers, Inicio, micrófono, Bluetooth, navegadores, antivirus...)' -ForegroundColor Green
    Write-Host '   OTROS' -ForegroundColor Cyan
    Write-Host '    11. Crear punto de restauración'
    Write-Host '    12. Reporte de batería (laptops)'
    Write-Host '    13. Herramientas de Windows'
    Write-Host '    14. REPARACIÓN COMPLETA (11 + 4 + 2 + 3 suave + 5)' -ForegroundColor Yellow
    Write-Host '     0. Salir'
    Write-Host ''
    Write-Host ("   Log: {0}" -f $Script:LogFile) -ForegroundColor DarkGray
    Write-Host ''
}

# ---------- Inicio ----------
try { $Host.UI.RawUI.WindowTitle = "Soporte Técnico v$($Script:Version) - $($env:COMPUTERNAME)" } catch { }

$Script:InfoSO = ''
try {
    $osInicio = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $versionInicio = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
    $Script:InfoSO = '{0} {1} (compilación {2})' -f $osInicio.Caption, $versionInicio, $osInicio.BuildNumber
}
catch { }

Write-Log ("Inicio de Soporte Técnico v{0} en {1} (usuario: {2}, modo {3}). {4}" -f $Script:Version, $env:COMPUTERNAME, $env:USERNAME, $Script:ModoInterfaz, $Script:InfoSO) 'INFO' -SoloArchivo
if ($Script:EnUsb) { Write-Log ("Ejecutando desde USB: logs y reportes en {0}" -f $Script:Base) 'INFO' -SoloArchivo }
if ($Script:AvisoUsb) { Write-Log $Script:AvisoUsb 'ADVERTENCIA' -SoloArchivo }

if ($Script:ModoInterfaz -eq 'Grafica') {
    try {
        Iniciar-InterfazGrafica
    }
    catch {
        Write-Log "No se pudo abrir la interfaz gráfica: $($_.Exception.Message)" 'ERROR' -SoloArchivo
        try {
            Add-Type -AssemblyName PresentationFramework
            [void][System.Windows.MessageBox]::Show("No se pudo abrir la interfaz gráfica:`n$($_.Exception.Message)`n`nUse la versión de consola (SoporteTecnico-Consola.exe o Ejecutar-Consola.bat).", 'Soporte Técnico')
        }
        catch { }
    }
    Write-Log 'Fin de la sesión de Soporte Técnico.' 'INFO' -SoloArchivo
    exit
}

if (-not (Test-Acceso)) { exit }

if ($Script:EnUsb) { try { $null = Importar-Visitas -Automatico } catch { } }
try { Abrir-HistorialLocal } catch { }
try { Iniciar-Visita } catch { }
Write-Host '  Recopilando los datos del equipo...' -ForegroundColor DarkGray
try { $null = Guardar-FichaEquipo } catch { Write-Log "No se pudo recopilar la ficha del equipo: $($_.Exception.Message)" 'ADVERTENCIA' -SoloArchivo }

$salir = $false
while (-not $salir) {
    try {
        Mostrar-Menu
        $opcion = Read-Host '  Elija una opción'
        if ($null -eq $opcion) { $opcion = '' }
        $opcion = $opcion.Trim()
        if ($opcion) { Write-Log "Opción elegida: $opcion" 'INFO' -SoloArchivo }
        switch ($opcion) {
            '1'  { Ejecutar-Opcion 'Diagnóstico completo'          { Invoke-Diagnostico } }
            '2'  { Ejecutar-Opcion 'Reparar archivos de Windows'   { Reparar-ArchivosSistema } }
            '3'  { Ejecutar-Opcion 'Reparar red'                   { Reparar-Red } }
            '4'  { Ejecutar-Opcion 'Limpiar temporales'            { Limpiar-Temporales } }
            '5'  { Ejecutar-Opcion 'Reparar Windows Update'        { Reparar-WindowsUpdate } }
            '6'  { Ejecutar-Opcion 'Reparar impresora'             { Reparar-Impresora } }
            '7'  { Ejecutar-Opcion 'Revisar disco'                 { Revisar-Disco } }
            '8'  { Ejecutar-Opcion 'Reiniciar Explorador'          { Reiniciar-Explorador } }
            '9'  { Ejecutar-Opcion 'Reparar Microsoft Store'       { Reparar-Store } }
            '10' { Ejecutar-Opcion 'Sincronizar fecha y hora'      { Sincronizar-Hora } }
            '11' { Ejecutar-Opcion 'Crear punto de restauración'   { New-PuntoRestauracion } }
            '12' { Ejecutar-Opcion 'Reporte de batería'            { Get-ReporteBateria } }
            '13' { Mostrar-Herramientas }
            '14' { Ejecutar-Opcion 'Reparación completa'           { Invoke-ReparacionCompleta } }
            '15' { Ejecutar-Opcion 'Reparar sonido'                { Reparar-Audio } }
            '16' { Reparar-Outlook }
            '17' { Mostrar-Avanzadas }
            '0'  { $salir = $true }
            ''   { }
            default {
                Write-Host '  Opción no válida.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Write-Log "Error inesperado en el menú: $($_.Exception.Message)" 'ERROR'
        Pausa
    }
}

if (Test-VisitaConActividad) {
    Write-Host ''
    Write-Host '  HISTORIAL DE LA VISITA' -ForegroundColor Cyan
    $sugerido = ''
    if ($Sync.Visita.ClienteAnterior) { $sugerido = ' (Enter = {0})' -f $Sync.Visita.ClienteAnterior }
    $cliente = Read-Host ("  Nombre del cliente, opcional{0}" -f $sugerido)
    $notas = Read-Host '  Notas, por ejemplo qué problema tenía (opcional)'
    try { Cerrar-Visita -Cliente $cliente -Notas $notas } catch { }
    Write-Host ("  Historial guardado en: {0}" -f (Get-RutaHistorialGeneral)) -ForegroundColor Cyan
    $zip = $null
    try { $zip = Finalizar-VisitaRemota } catch { }
    if ($zip) {
        Write-Host ''
        Write-Host '  No está trabajando desde la USB. La visita se exportó a:' -ForegroundColor Yellow
        Write-Host ("    {0}" -f $zip) -ForegroundColor Yellow
        Write-Host '  Cópielo a su USB en Clientes\Importar: se carga solo al abrir la herramienta desde la USB.' -ForegroundColor Yellow
        Read-Host '  Presione Enter para salir'
    }
}
else {
    try { $null = Finalizar-VisitaRemota -Exportar $false } catch { }
}
Write-Log 'Fin de la sesión de Soporte Técnico.' 'INFO' -SoloArchivo
Write-Host ''
if (-not $Sync.SinArchivosLocales) {
    Write-Host "  Log guardado en: $($Script:LogFile)" -ForegroundColor Cyan
    Write-Host "  Reportes en:     $($Script:DirReportes)" -ForegroundColor Cyan
}
Start-Sleep -Seconds 2

#endregion
