<#
    Pruebas automáticas de la herramienta. No necesitan administrador y no cambian nada del equipo.
    Uso (desde cualquier carpeta):
        powershell -NoProfile -ExecutionPolicy Bypass -File build\Probar.ps1
    Opciones:
        -Rapido        solo pruebas de archivos y de lógica (sin ventanas ni compilación)
        -SinVentanas   omite las pruebas que abren ventanas de WPF
        -Fuente <ruta> prueba otro script en vez de src\SoporteTecnico.ps1
    Termina con código 0 si todo pasó y 1 si algo falló. Los AVISOS no hacen fallar.
    Ejecutar con Windows PowerShell 5.1. Conviene correrlo antes de compilar y antes de cada commit.
#>
param([string]$Fuente = '', [switch]$Rapido, [switch]$SinVentanas)

# Las ventanas de WPF necesitan un hilo STA: si no lo es, se vuelve a lanzar así.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $reenviar = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Fuente) { $reenviar += @('-Fuente', $Fuente) }
    if ($Rapido) { $reenviar += '-Rapido' }
    if ($SinVentanas) { $reenviar += '-SinVentanas' }
    & powershell.exe @reenviar
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Continue'
$raiz = Split-Path -Path $PSScriptRoot -Parent
if (-not $Fuente) { $Fuente = Join-Path $raiz 'src\SoporteTecnico.ps1' }
if (-not (Test-Path -LiteralPath $Fuente)) { Write-Host "No se encontró el script: $Fuente" -ForegroundColor Red; exit 1 }
$Fuente = (Resolve-Path -LiteralPath $Fuente).Path
$inicioTotal = Get-Date

# ---------- Mini marco de pruebas ----------
$Script:Resultados = New-Object System.Collections.Generic.List[object]
$Script:GrupoActual = ''

function Imprimir {
    # Escribe directo en la consola. Más abajo se silencia Write-Host (para el script bajo prueba), así que
    # el marco de pruebas no puede depender de él.
    param([string]$Texto, [string]$Color = 'Gray')
    [Console]::ForegroundColor = $Color
    [Console]::WriteLine($Texto)
    [Console]::ResetColor()
}

function Grupo {
    param([string]$Nombre)
    $Script:GrupoActual = $Nombre
    Imprimir ''
    Imprimir ("== {0}" -f $Nombre) 'Cyan'
}

function Afirmar {
    param([bool]$Condicion, [string]$Mensaje)
    if (-not $Condicion) { throw $Mensaje }
}

function Avisar {
    # Como Afirmar, pero solo avisa (no hace fallar las pruebas).
    param([bool]$Condicion, [string]$Mensaje)
    if (-not $Condicion) { throw "AVISO: $Mensaje" }
}

function Caso {
    param([string]$Nombre, [scriptblock]$Cuerpo)
    $estado = 'OK'
    $mensaje = ''
    try { $null = & $Cuerpo }
    catch {
        $m = "$($_.Exception.Message)"
        if ($m.StartsWith('AVISO:')) { $estado = 'AVISO'; $mensaje = $m.Substring(6).Trim() }
        else { $estado = 'FALLA'; $mensaje = $m }
    }
    $Script:Resultados.Add([pscustomobject]@{ Grupo = $Script:GrupoActual; Nombre = $Nombre; Estado = $estado; Mensaje = $mensaje })
    $color = 'Green'
    if ($estado -eq 'FALLA') { $color = 'Red' } elseif ($estado -eq 'AVISO') { $color = 'Yellow' }
    Imprimir ("  [{0,-5}] {1}" -f $estado, $Nombre) $color
    if ($mensaje) { Imprimir ("          {0}" -f ($mensaje -replace "\r?\n", ' | ')) $color }
}

function Omitir {
    param([string]$Nombre, [string]$Motivo)
    $Script:Resultados.Add([pscustomobject]@{ Grupo = $Script:GrupoActual; Nombre = $Nombre; Estado = 'OMITIDA'; Mensaje = $Motivo })
    Imprimir ("  [OMIT ] {0}  ({1})" -f $Nombre, $Motivo) 'DarkGray'
}

function Distancia-Texto {
    # Distancia de Levenshtein (cuántas letras hay que cambiar para pasar de un texto a otro).
    param([string]$A, [string]$B)
    $A = $A.ToLowerInvariant(); $B = $B.ToLowerInvariant()
    if ([math]::Abs($A.Length - $B.Length) -gt 2) { return 99 }
    $d = New-Object 'int[,]' ($A.Length + 1), ($B.Length + 1)
    for ($i = 0; $i -le $A.Length; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $B.Length; $j++) { $d[0, $j] = $j }
    for ($i = 1; $i -le $A.Length; $i++) {
        for ($j = 1; $j -le $B.Length; $j++) {
            $costo = 1; if ($A[$i - 1] -eq $B[$j - 1]) { $costo = 0 }
            $borrar = $d[($i - 1), $j] + 1
            $insertar = $d[$i, ($j - 1)] + 1
            $cambiar = $d[($i - 1), ($j - 1)] + $costo
            $d[$i, $j] = [math]::Min([math]::Min($borrar, $insertar), $cambiar)
        }
    }
    return $d[$A.Length, $B.Length]
}

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Imprimir 'PRUEBAS AUTOMÁTICAS' 'White'
Imprimir ("  PowerShell {0} | administrador: {1} | script: {2}" -f $PSVersionTable.PSVersion, $esAdmin, $Fuente) 'DarkGray'

$texto = [System.IO.File]::ReadAllText($Fuente)
$tokens = $null
$errores = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Fuente, [ref]$tokens, [ref]$errores)
$funciones = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$nombresFunciones = @($funciones | ForEach-Object { $_.Name })

# =====================================================================
Grupo 'Archivos y seguridad'
# =====================================================================
$archivosPs1 = @($Fuente) + @(Get-ChildItem -LiteralPath (Join-Path $raiz 'build') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
foreach ($arch in $archivosPs1) {
    $corto = Split-Path $arch -Leaf
    Caso "Sintaxis correcta: $corto" {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($arch, [ref]$t, [ref]$e)
        Afirmar (@($e).Count -eq 0) ("{0} error(es), el primero en la línea {1}: {2}" -f @($e).Count, $e[0].Extent.StartLineNumber, $e[0].Message)
    }
    Caso "UTF-8 con BOM y saltos CRLF: $corto" {
        $b = [System.IO.File]::ReadAllBytes($arch)
        Afirmar ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'No tiene BOM UTF-8: las tildes se verán mal en PowerShell 5.1.'
        $suelto = [regex]::Matches([System.IO.File]::ReadAllText($arch), "(?<!\r)\n").Count
        Afirmar ($suelto -eq 0) "$suelto salto(s) de línea LF sueltos (debe ser CRLF)."
    }
}
foreach ($bat in @(Get-ChildItem -LiteralPath $raiz -Filter '*.bat' -ErrorAction SilentlyContinue)) {
    Caso "El .bat es ASCII sin BOM: $($bat.Name)" {
        $b = [System.IO.File]::ReadAllBytes($bat.FullName)
        Afirmar (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB)) 'Tiene BOM: cmd.exe lo lee mal.'
        Afirmar (@($b | Where-Object { $_ -gt 127 }).Count -eq 0) 'Tiene caracteres no ASCII (tildes): cmd.exe los lee mal.'
    }
}
Caso 'Sin marcadores de conflicto de git' {
    Afirmar ([regex]::Matches($texto, '(?m)^(<<<<<<< |=======$|>>>>>>> )').Count -eq 0) 'Quedaron marcadores <<<<<<< / ======= / >>>>>>> sin resolver.'
}
Caso 'Sin funciones duplicadas' {
    $dup = @($funciones | Group-Object Name | Where-Object { $_.Count -gt 1 })
    Afirmar ($dup.Count -eq 0) ("Funciones definidas más de una vez (la última pisa a la primera): " + (($dup | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '))
}
Caso 'El script no lleva contraseña puesta (ClaveHash vacío)' {
    $hash = [regex]::Match($texto, "(?m)^\`$Script:ClaveHash\s*=\s*'([^']*)'").Groups[1].Value
    Avisar ($hash -eq '') 'El script tiene un hash de contraseña. No lo suba a git: use el archivo .env (vea .env.example).'
}
$tieneGit = [bool](Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $raiz '.git'))
if ($tieneGit) {
    Caso 'git no sigue ningún .env ni .exe' {
        $sigue = @(git -C $raiz ls-files 2>$null | Where-Object { $_ -match '(^|/)\.env$|\.exe$' })
        Afirmar ($sigue.Count -eq 0) ("git está siguiendo archivos que no deben subirse: " + ($sigue -join ', '))
    }
    Caso '.gitignore protege .env y los .exe' {
        $ign = [System.IO.File]::ReadAllText((Join-Path $raiz '.gitignore'))
        Afirmar ($ign -match '(?m)^\.env\s*$') 'Falta ".env" en .gitignore.'
        Afirmar ($ign -match '(?m)^\*\.exe\s*$') 'Falta "*.exe" en .gitignore.'
    }
}
else {
    Omitir 'Comprobaciones de git' 'no hay repositorio git aquí'
}

# =====================================================================
Grupo 'Código: llamadas y catálogo'
# =====================================================================
Caso 'Todas las llamadas existen (sin errores de tecleo en nombres)' {
    $conocidos = @{}
    foreach ($n in $nombresFunciones) { $conocidos[$n] = $true }
    $faltan = New-Object System.Collections.Generic.HashSet[string]
    foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $nombre = $c.GetCommandName()
        if (-not $nombre -or $conocidos.ContainsKey($nombre)) { continue }
        if (-not (Get-Command -Name $nombre -ErrorAction SilentlyContinue)) { [void]$faltan.Add($nombre) }
    }
    # Si el nombre se parece mucho a una función propia, casi seguro es un error de tecleo (falla);
    # si no, puede ser un comando que solo existe en otro Windows (aviso).
    $typos = @(); $otros = @()
    foreach ($n in @($faltan | Sort-Object)) {
        $cercano = $nombresFunciones | Where-Object { (Distancia-Texto $n $_) -le 2 } | Select-Object -First 1
        if ($cercano) { $typos += "$n (¿quiso decir $cercano?)" } else { $otros += $n }
    }
    Afirmar ($typos.Count -eq 0) ("Llamadas a funciones que no existen: " + ($typos -join '; '))
    Avisar ($otros.Count -eq 0) ("Comandos que no existen en este equipo (¿error de tecleo, o solo existen en otro Windows?): " + ($otros -join ', '))
}
$catalogo = @()
$categorias = $null
foreach ($asig in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
    $izq = $asig.Left.Extent.Text
    try {
        if ($izq -eq '$Script:Catalogo') { $catalogo = @(& ([scriptblock]::Create($asig.Right.Extent.Text))) }
        elseif ($izq -eq '$Script:CategoriasGui') { $categorias = & ([scriptblock]::Create($asig.Right.Extent.Text)) }
    }
    catch { }
}
Caso 'Catálogo de acciones: cada acción apunta a una función que existe' {
    Afirmar ($catalogo.Count -gt 0) 'No se pudo leer $Script:Catalogo.'
    $malas = @()
    foreach ($a in $catalogo) {
        $t = $null; $e = $null
        $p = [System.Management.Automation.Language.Parser]::ParseInput([string]$a.Cmd, [ref]$t, [ref]$e)
        $cmd = $p.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        $nombre = ''
        if ($cmd) { $nombre = $cmd.GetCommandName() }
        if (-not $nombre -or ($nombresFunciones -notcontains $nombre -and -not (Get-Command -Name $nombre -ErrorAction SilentlyContinue))) { $malas += "'$($a.Titulo)' -> $($a.Cmd)" }
    }
    Afirmar ($malas.Count -eq 0) ("Acciones cuyo comando no existe: " + ($malas -join '; '))
}
Caso 'Catálogo de acciones: títulos únicos y categorías válidas' {
    $dup = @($catalogo | Group-Object { $_.Titulo } | Where-Object { $_.Count -gt 1 })
    Afirmar ($dup.Count -eq 0) ("Títulos repetidos: " + (($dup | ForEach-Object { $_.Name }) -join ', '))
    if ($categorias) {
        $malas = @($catalogo | Where-Object { $categorias.Keys -notcontains $_.Cat } | ForEach-Object { "$($_.Titulo) ($($_.Cat))" })
        Afirmar ($malas.Count -eq 0) ("Acciones en una categoría que no existe en el menú: " + ($malas -join '; '))
    }
}

# ---------- Carga de funciones para las pruebas siguientes ----------
# Se definen las funciones del script (menos las que reemplazan Write-Host/Read-Host en modo gráfico) y
# después se silencian las que escriben en pantalla o preguntan.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
foreach ($f in $funciones) {
    if ($f.Name -in @('Write-Host', 'Read-Host', 'Clear-Host')) { continue }
    try { . ([scriptblock]::Create($f.Extent.Text)) } catch { }
}
$Script:ModoInterfaz = 'Consola'
$Script:EnUsb = $false
$Script:InfoSO = 'Windows de prueba'
$Script:DirReportes = Join-Path $env:TEMP 'probar_reportes'
$Script:Version = '0'
$Script:LogPrueba = New-Object System.Collections.Generic.List[string]
$Script:RespuestasRead = New-Object System.Collections.Generic.Queue[string]
$Script:ConfirmarCuando = $false
$Sync = [hashtable]::Synchronized(@{ Cancelado = $false; Visita = @{ Ficha = $null; Acciones = (New-Object System.Collections.ArrayList); PuntajeAntes = $null; PuntajeDespues = $null; Activa = $false }; Diagnostico = $null; ClaveExportacion = $null })
function Write-Log { param([string]$Mensaje, [string]$Nivel, [switch]$SoloArchivo) $Script:LogPrueba.Add("[$Nivel] $Mensaje") }
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)]$Objeto, $ForegroundColor, $BackgroundColor, [switch]$NoNewline, $Separator) }
function Clear-Host { }
function Mostrar-Titulo { param([string]$Titulo) }
function Pausa { }
function Confirmar { param([string]$Pregunta) return [bool]$Script:ConfirmarCuando }
function Read-Host { param($Prompt, [switch]$AsSecureString) if ($Script:RespuestasRead.Count -gt 0) { return $Script:RespuestasRead.Dequeue() } return '' }

# =====================================================================
Grupo 'Lógica'
# =====================================================================
Caso 'Elegir-Opcion en consola (número, vacío y fuera de rango)' {
    $ops = @('uno', 'dos', 'tres')
    $Script:RespuestasRead.Enqueue('2'); Afirmar ((Elegir-Opcion -Pregunta 'x' -Opciones $ops) -eq 1) "'2' debía dar el índice 1."
    $Script:RespuestasRead.Enqueue('');  Afirmar ((Elegir-Opcion -Pregunta 'x' -Opciones $ops) -eq -1) 'Vacío debía dar -1.'
    $Script:RespuestasRead.Enqueue('9'); Afirmar ((Elegir-Opcion -Pregunta 'x' -Opciones $ops) -eq -1) "'9' (fuera de rango) debía dar -1."
}
Caso 'Elegir-Opciones en consola (varias, "todos" y vacío)' {
    $ops = @('uno', 'dos', 'tres')
    $Script:RespuestasRead.Enqueue('1,3');   Afirmar ((@(Elegir-Opciones -Pregunta 'x' -Opciones $ops) -join ',') -eq '0,2') "'1,3' debía dar 0,2."
    $Script:RespuestasRead.Enqueue('todos'); Afirmar ((@(Elegir-Opciones -Pregunta 'x' -Opciones $ops) -join ',') -eq '0,1,2') "'todos' debía dar 0,1,2."
    $Script:RespuestasRead.Enqueue('');      Afirmar (@(Elegir-Opciones -Pregunta 'x' -Opciones $ops).Count -eq 0) 'Vacío debía dar ninguna.'
}
Caso 'Elegir-Varias en consola (rangos, "todos" y predeterminadas)' {
    $ops = @('a', 'b', 'c', 'd', 'e')
    $Script:RespuestasRead.Enqueue('1,3-4'); Afirmar ((@(Elegir-Varias -Pregunta 'x' -Opciones $ops) -join ',') -eq '0,2,3') "'1,3-4' debía dar 0,2,3."
    $Script:RespuestasRead.Enqueue('todos'); Afirmar ((@(Elegir-Varias -Pregunta 'x' -Opciones $ops) -join ',') -eq '0,1,2,3,4') "'todos' debía dar todas."
    $Script:RespuestasRead.Enqueue('');      Afirmar ((@(Elegir-Varias -Pregunta 'x' -Opciones $ops -Predeterminadas @(1, 2)) -join ',') -eq '1,2') 'Vacío debía dar las predeterminadas.'
}
Caso 'Selectores en modo ventana (con la ventana simulada)' {
    $Script:ModoInterfaz = 'Grafica'
    $Script:UltimaPeticion = $null
    $Script:RespuestaVentana = ''
    function Solicitar-Gui { param([string]$Tipo, [string]$Texto, [string]$Valor = '', [hashtable]$Extra) $Script:UltimaPeticion = @{ Tipo = $Tipo; Texto = $Texto; Extra = $Extra }; return $Script:RespuestaVentana }
    try {
        $ops = @('uno', 'dos', 'tres')
        $Script:RespuestaVentana = '1'
        Afirmar ((Elegir-Opcion -Pregunta 'Número de la impresora (Cancelar = salir)' -Opciones $ops) -eq 1) 'La ventana devolvió 1 y debía dar el índice 1.'
        Afirmar ($Script:UltimaPeticion.Tipo -eq 'Lista' -and -not $Script:UltimaPeticion.Extra.Multi) 'Elegir-Opcion debía abrir una Lista de una sola opción.'
        Afirmar ($Script:UltimaPeticion.Texto -notmatch 'Cancelar') 'El texto de la ventana no debe llevar el "(Cancelar = ...)" de la consola.'
        $Script:RespuestaVentana = ''
        Afirmar ((Elegir-Opcion -Pregunta 'x' -Opciones $ops) -eq -1) 'Cancelar debía dar -1.'
        $Script:RespuestaVentana = '0,2'
        Afirmar ((@(Elegir-Opciones -Pregunta '' -Opciones $ops -Marcadas @(0, 2)) -join ',') -eq '0,2') 'Elegir-Opciones debía dar 0,2.'
        Afirmar ($Script:UltimaPeticion.Extra.Multi -and (@($Script:UltimaPeticion.Extra.Marcadas) -join ',') -eq '0,2') 'Las marcadas no llegaron a la ventana.'
        $Script:RespuestaVentana = '9,x,1'
        Afirmar ((@(Elegir-Opciones -Pregunta '' -Opciones $ops) -join ',') -eq '1') 'Los valores inválidos debían ignorarse.'
        $Script:RespuestaVentana = '3,1,1'
        Afirmar ((@(Elegir-Varias -Pregunta 'x' -Opciones @('a', 'b', 'c', 'd')) -join ',') -eq '1,3') 'Elegir-Varias debía dar 1,3 (ordenado y sin repetidos).'
        $Script:RespuestaVentana = ''
        Afirmar ($null -eq (Elegir-Varias -Pregunta 'x' -Opciones @('a', 'b'))) 'Cancelar en Elegir-Varias debía dar $null.'
    }
    finally {
        Remove-Item Function:\Solicitar-Gui -ErrorAction SilentlyContinue
        $Script:ModoInterfaz = 'Consola'
    }
}
Caso 'Resumen para el ticket' {
    $acc = New-Object System.Collections.ArrayList
    [void]$acc.Add('Reparar sonido (OK)')
    $Sync.Visita = @{ Ficha = [pscustomobject]@{ Marca = 'HP'; Modelo = 'OMEN'; Serie = 'ABC123'; Procesador = 'i7'; RAM = '16 GB' }; Acciones = $acc; PuntajeAntes = 18; PuntajeDespues = 64 }
    $Sync.Diagnostico = [pscustomobject]@{ Puntaje = [pscustomobject]@{ Puntaje = 64; Estado = 'Requiere atención' }; Alertas = @('[CRÍTICO] Disco lleno.', '[ALERTA] Falla Windows Update.', '[INFO] BitLocker activo.') }
    $r = Get-ResumenTicket
    foreach ($esperado in @('EQUIPO:', 'Serie: ABC123', 'SALUD: 64/100', 'CRÍTICO: Disco lleno.', 'ALERTA: Falla Windows Update.', 'TRABAJO REALIZADO:', 'Reparar sonido (OK)', '18 -> 64')) {
        Afirmar ($r.Contains($esperado)) "El resumen no contiene '$esperado'."
    }
    Afirmar (-not $r.Contains('BitLocker')) 'Las notas informativas no deben ir en el resumen.'
    $Sync.Diagnostico = $null; $Sync.Visita = @{ Ficha = $null; Acciones = (New-Object System.Collections.ArrayList); PuntajeAntes = $null; PuntajeDespues = $null }
    Afirmar ((Get-ResumenTicket).Contains('Sin diagnóstico')) 'Sin diagnóstico debía decirlo.'
}
Caso 'Contraseña: lectura del .env, hash e inyección en el script' {
    . (Join-Path $PSScriptRoot 'Clave.ps1')
    $arch = Join-Path $env:TEMP ('probar_env_{0}.txt' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($arch, ([string][char]0xFEFF + "# comentario`r`n`r`nOTRA = x`r`nSOPORTE_CLAVE = `"abc=123 #z`"`r`nVACIA=`r`nSIN_IGUAL`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $v = Read-DotEnv $arch
        Afirmar ($v['SOPORTE_CLAVE'] -ceq 'abc=123 #z') "SOPORTE_CLAVE leída: [$($v['SOPORTE_CLAVE'])] (esperaba [abc=123 #z])."
        Afirmar ($v['OTRA'] -eq 'x' -and $v.ContainsKey('VACIA') -and -not $v.ContainsKey('SIN_IGUAL')) 'El .env no se leyó bien (comentarios, vacías o líneas sin =).'
    }
    finally { Remove-Item -LiteralPath $arch -Force -ErrorAction SilentlyContinue }
    Afirmar ((Read-DotEnv (Join-Path $env:TEMP 'no_existe_probar.env')).Count -eq 0) 'Un .env inexistente debía dar una lista vacía.'
    $clave = 'Prueba#=123 ñ'
    $datos = New-DatosClave -Clave $clave
    $nuevo = Set-ClaveEnTexto -Texto $texto -Datos $datos
    $cambiadas = @(Compare-Object ($texto -split "`r?`n") ($nuevo -split "`r?`n") | Where-Object { $_.SideIndicator -eq '=>' }).Count
    Afirmar ($cambiadas -eq 2) "Debían cambiar 2 líneas (sal y hash) y cambiaron $cambiadas."
    Afirmar (-not $nuevo.Contains($clave)) 'La contraseña quedó escrita en texto plano en el script.'
    $t2 = $null; $e2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($nuevo, [ref]$t2, [ref]$e2)
    Afirmar (@($e2).Count -eq 0) 'El script con la contraseña inyectada no compila.'
    $sal = [regex]::Match($nuevo, "(?m)^\`$Script:ClaveSal = '([^']*)'").Groups[1].Value
    $hash = [regex]::Match($nuevo, "(?m)^\`$Script:ClaveHash = '([^']*)'").Groups[1].Value
    $iter = [int][regex]::Match($nuevo, "(?m)^\`$Script:ClaveIteraciones = (\d+)").Groups[1].Value
    Afirmar ((Get-HashClave -Clave $clave -Sal ([Convert]::FromBase64String($sal)) -Iteraciones $iter) -ceq $hash) 'La clave correcta NO valida con Get-HashClave del script.'
    Afirmar ((Get-HashClave -Clave 'otra' -Sal ([Convert]::FromBase64String($sal)) -Iteraciones $iter) -cne $hash) 'Una clave incorrecta SÍ valida.'
    Afirmar ((New-DatosClave -Clave $clave).Sal -ne $datos.Sal) 'La sal no es aleatoria: dos hashes de la misma clave salieron con la misma sal.'
}
Caso 'Programas instalados: una clave dañada del registro no tumba la lista' {
    $lista = @(Get-EntradasDesinstalar -Rutas @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'))
    Afirmar ($lista.Count -gt 0) 'No devolvió ninguna entrada de programas instalados.'
    $perfil = Get-PerfilUsuarioActivo
    Afirmar (@(Get-ProgramasInstalados $perfil).Count -gt 0) 'Get-ProgramasInstalados no devolvió programas.'
}
Caso 'Datos del equipo y del usuario' {
    $i = Get-InfoFabricante
    Afirmar ([bool]$i.Marca) 'Get-InfoFabricante no devolvió marca.'
    $p = Get-PerfilUsuarioActivo
    Afirmar ([bool]$p.SID -and [bool]$p.Ruta) 'Get-PerfilUsuarioActivo no devolvió SID o ruta.'
}
Caso 'Programas de inicio: lista con los tres tipos de origen' {
    $lista = @(Get-ProgramasInicio)
    Afirmar ($lista.Count -ge 0) 'Get-ProgramasInicio falló.'
    $malos = @($lista | Where-Object { @('Registro', 'Carpeta', 'Tarea') -notcontains $_.Tipo })
    Afirmar ($malos.Count -eq 0) 'Hay elementos de inicio con un Tipo desconocido.'
}

# =====================================================================
Grupo 'Funciones que solo leen (deben cancelar sin cambiar nada)'
# =====================================================================
if ($esAdmin) {
    Omitir 'Funciones de reparación en modo lectura' 'se ejecutan solo SIN administrador, por seguridad'
}
else {
    function Get-Instantanea {
        $e = [ordered]@{}
        try { $e['LegacyDefaultPrinterMode'] = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -ErrorAction Stop).LegacyDefaultPrinterMode } catch { $e['LegacyDefaultPrinterMode'] = '(no existe)' }
        try { $e['RpcAuthn'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Print' -Name RpcAuthnLevelPrivacyEnabled -ErrorAction Stop).RpcAuthnLevelPrivacyEnabled } catch { $e['RpcAuthn'] = '(no existe)' }
        $e['PointAndPrint'] = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
        $e['WUPolicies'] = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $e['ProfileList'] = (@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName } | Sort-Object)) -join ','
        $e['Servicios'] = (@(Get-Service -Name 'wuauserv', 'bits', 'cryptsvc', 'UsoSvc', 'DoSvc', 'Spooler', 'msiserver' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.StartType)" })) -join ','
        $e['Impresoras'] = (@(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)) -join ','
        $e['SoftwareDistribution'] = Test-Path (Join-Path $env:windir 'SoftwareDistribution')
        $e['SoftwareDistribution.old'] = Test-Path (Join-Path $env:windir 'SoftwareDistribution.old')
        return (($e.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
    }
    $antes = Get-Instantanea
    $Script:ConfirmarCuando = $false
    foreach ($fn in @('Reparar-ImpresoraRpc', 'Reparar-ImpresoraPredeterminada', 'Reparar-ImpresoraDriverBloqueado', 'Reinstalar-Impresora', 'Reparar-PerfilUsuario', 'Reparar-WindowsUpdateProfundo')) {
        Caso "$fn (cancelando no cambia nada)" {
            $Script:RespuestasRead.Clear()
            $null = @(& $fn)
        }
    }
    Caso 'El equipo quedó exactamente igual (registro, servicios, impresoras y carpetas)' {
        $despues = Get-Instantanea
        Afirmar ($antes -ceq $despues) ("El estado cambió durante las pruebas.`n--- antes ---`n$antes`n--- después ---`n$despues")
    }
}

# =====================================================================
Grupo 'Ventanas (XAML)'
# =====================================================================
$xamls = @{}
foreach ($m in [regex]::Matches($texto, "(?s)\`$Script:(Xaml\w+) = @'\r?\n(.*?)\r?\n'@")) { $xamls[$m.Groups[1].Value] = $m.Groups[2].Value }
Caso 'Hay ventanas XAML definidas' { Afirmar ($xamls.Count -ge 4) "Se esperaban al menos 4 XAML (Principal, Dialogo, Lista, Inicio) y hay $($xamls.Count)." }
$ventanasCargadas = @{}
foreach ($claveXaml in @($xamls.Keys | Sort-Object)) {
    # (No llamar a esta variable $nombre: PowerShell no distingue mayúsculas y chocaría con el parámetro $Nombre de Caso.)
    Caso "XAML válido y carga en WPF: $claveXaml" {
        [xml]$x = $xamls[$claveXaml]
        $obj = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
        Afirmar ($null -ne $obj) 'XamlReader no devolvió nada.'
        $ventanasCargadas[$claveXaml] = $obj
    }
}
Caso 'Ventana principal: todos los controles que busca el código existen' {
    $nombresXaml = @([regex]::Matches($xamls['XamlPrincipal'], 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $bloque = [regex]::Match($texto, "(?s)\`$nombres = @\(('Principal'.*?)\)\s*\r?\n\s*foreach \(\`$n in \`$nombres\)")
    Afirmar $bloque.Success 'No se encontró la lista $nombres de controles en Iniciar-InterfazGrafica.'
    $pedidos = @([regex]::Matches($bloque.Groups[1].Value, "'([A-Za-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
    Afirmar ($pedidos.Count -gt 20) 'La lista de controles parece incompleta.'
    $faltan = @($pedidos | Where-Object { $nombresXaml -notcontains $_ })
    Afirmar ($faltan.Count -eq 0) ("El código busca controles que no están en el XAML: " + ($faltan -join ', '))
}
Caso 'Cuadros secundarios: sus controles existen en el XAML' {
    $esperados = @{
        XamlDialogo = @('Titulo', 'Mensaje', 'Entrada', 'BtnSi', 'BtnNo')
        XamlLista   = @('Titulo', 'Mensaje', 'Lista', 'BtnTodos', 'BtnCancelar', 'BtnAceptar', 'TxtAviso')
        XamlInicio  = @('TxtResumen', 'TxtArranque', 'Lista', 'TxtMensaje', 'BtnDesactivar', 'BtnActivar', 'BtnCerrar')
    }
    foreach ($k in $esperados.Keys) {
        if (-not $xamls.ContainsKey($k)) { throw "Falta $k." }
        $presentes = @([regex]::Matches($xamls[$k], 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $faltan = @($esperados[$k] | Where-Object { $presentes -notcontains $_ })
        Afirmar ($faltan.Count -eq 0) ("$k no tiene: " + ($faltan -join ', '))
    }
}
Caso 'Estilos de botones disponibles y estilo oscuro aplicable' {
    $v = $ventanasCargadas['XamlPrincipal']
    Afirmar ($null -ne $v) 'La ventana principal no cargó.'
    foreach ($s in @('BotonBase', 'Primario', 'Exito', 'Secundario', 'Nav', 'Tile')) { [void]$v.FindResource($s) }
    $Script:Xamlcache = $xamls
    $Script:XamlEstilos = $xamls['XamlEstilos']
    Add-EstilosOscuros $v
    Afirmar ($v.Resources.MergedDictionaries.Count -ge 1) 'Add-EstilosOscuros no agregó el diccionario (el XAML de estilos tiene un error).'
}

# =====================================================================
Grupo 'Ventanas (comportamiento)'
# =====================================================================
if ($Rapido -or $SinVentanas) {
    Omitir 'Pruebas con ventanas abiertas' 'omitidas por -Rapido / -SinVentanas'
}
else {
    foreach ($k in $xamls.Keys) { Set-Variable -Scope Script -Name $k -Value $xamls[$k] }
    $Script:Gui = @{ Ventana = $ventanasCargadas['XamlPrincipal'] }

    function Pulsar { param($Boton) $Boton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    function Probar-Lista {
        param($Pregunta, [scriptblock]$Accion)
        $Script:AccionLista = $Accion; $Script:TickLista = 0; $Script:ErrorLista = $null
        $tm = New-Object System.Windows.Threading.DispatcherTimer
        $tm.Interval = [TimeSpan]::FromMilliseconds(250)
        $tm.Add_Tick({
                $Script:TickLista++
                try {
                    if ($Script:TickLista -gt 20) { throw 'la ventana no se cerró (tiempo agotado)' }
                    & $Script:AccionLista $Script:TickLista
                }
                catch { $Script:ErrorLista = $_.Exception.Message; $Script:ListaGui.Ventana.Close() }
            })
        $tm.Start()
        $r = Mostrar-ListaGui $Pregunta
        $tm.Stop()
        if ($Script:ErrorLista) { throw $Script:ErrorLista }
        return "$r"
    }
    $opsLista = @('Opción A', 'Opción B', 'Opción C')
    Caso 'Ventana de lista: elegir una opción y aceptar' {
        $r = Probar-Lista @{ Texto = 'Elija'; Titulo = 'Prueba'; Opciones = $opsLista; Multi = $false } { param($n) if ($n -eq 1) { $Script:ListaGui.Lista.Children[1].Child.IsChecked = $true; Pulsar $Script:ListaGui.BtnAceptar } }
        Afirmar ($r -eq '1') "Devolvió [$r] y debía devolver [1]."
    }
    Caso 'Ventana de lista: aceptar sin elegir avisa y no se cierra' {
        $Script:AvisoVisto = ''
        $r = Probar-Lista @{ Texto = 'Elija'; Opciones = $opsLista; Multi = $false } { param($n)
            if ($n -eq 1) { Pulsar $Script:ListaGui.BtnAceptar; $Script:AvisoVisto = $Script:ListaGui.TxtAviso.Text }
            if ($n -eq 2) { Pulsar $Script:ListaGui.BtnCancelar } }
        Afirmar ($Script:AvisoVisto -like '*Elija*') "No avisó (texto: [$Script:AvisoVisto])."
        Afirmar ($r -eq '') 'Cancelar debía devolver vacío.'
    }
    Caso 'Ventana de lista: varias casillas, las marcadas de antemano y "Marcar todos"' {
        $Script:Previas = ''
        $r = Probar-Lista @{ Texto = 'Marque'; Opciones = $opsLista; Multi = $true; Marcadas = @(0, 2) } { param($n)
            if ($n -eq 1) { $Script:Previas = (@($Script:ListaGui.Lista.Children | ForEach-Object { $_.Child.IsChecked }) -join ','); Pulsar $Script:ListaGui.BtnAceptar } }
        Afirmar ($Script:Previas -eq 'True,False,True') "Casillas al abrir: [$Script:Previas] (esperaba True,False,True)."
        Afirmar ($r -eq '0,2') "Devolvió [$r] y debía devolver [0,2]."
        $r2 = Probar-Lista @{ Texto = 'Marque'; Opciones = $opsLista; Multi = $true; Marcadas = @(0) } { param($n) if ($n -eq 1) { Pulsar $Script:ListaGui.BtnTodos }; if ($n -eq 2) { Pulsar $Script:ListaGui.BtnAceptar } }
        Afirmar ($r2 -eq '0,1,2') "'Marcar todos' devolvió [$r2] y debía devolver [0,1,2]."
        $r3 = Probar-Lista @{ Texto = 'Marque'; Opciones = $opsLista; Multi = $true; Marcadas = @(0, 1, 2) } { param($n)
            if ($n -eq 1) { Pulsar $Script:ListaGui.BtnTodos }
            if ($n -eq 2) { Pulsar $Script:ListaGui.BtnAceptar; $Script:AvisoVisto = $Script:ListaGui.TxtAviso.Text }
            if ($n -eq 3) { $Script:ListaGui.Lista.Children[2].Child.IsChecked = $true; Pulsar $Script:ListaGui.BtnAceptar } }
        Afirmar ($r3 -eq '2') "Quitar todas y marcar una devolvió [$r3] y debía devolver [2]."
        Afirmar ($Script:AvisoVisto -like '*al menos*') 'Aceptar sin nada marcado debía avisar.'
    }

    # Los cuadros de diálogo: se abren, se miden y se cierran solos.
    $textoFn = ($funciones | Where-Object { $_.Name -eq 'Mostrar-DialogoGui' } | Select-Object -First 1).Extent.Text
    $gancho = '$Script:DlgPrueba = $dlg; $tmD = New-Object System.Windows.Threading.DispatcherTimer; $tmD.Interval = [TimeSpan]::FromMilliseconds(500); $Script:TmD = $tmD; $tmD.Add_Tick({ $Script:TmD.Stop(); $d = $Script:DlgPrueba; $caja = $d.FindName(''Entrada''); $Script:DlgInfo = @{ Titulo = $d.FindName(''Titulo'').Text; Alto = $d.ActualHeight; Ancho = $d.ActualWidth; Sel = $caja.SelectionLength; Largo = $caja.Text.Length; Si = "$($d.FindName(''BtnSi'').Content)"; No = "$($d.FindName(''BtnNo'').Content)"; NoVisible = ($d.FindName(''BtnNo'').Visibility -eq ''Visible'') }; $d.Close() }); $tmD.Start(); [void]$dlg.ShowDialog()'
    $textoFnPrueba = $textoFn.Replace('[void]$dlg.ShowDialog()', $gancho)
    if ($textoFnPrueba -ne $textoFn) { . ([scriptblock]::Create($textoFnPrueba)) }
    function Probar-Dialogo { param($Pregunta) $Script:DlgInfo = $null; $r = Mostrar-DialogoGui $Pregunta; if (-not $Script:DlgInfo) { throw 'el cuadro no llegó a mostrarse' }; return $Script:DlgInfo }

    Caso 'Cuadro de dato: el valor que ya viene escrito queda seleccionado' {
        Afirmar ($textoFnPrueba -ne $textoFn) 'No se pudo preparar la prueba (cambió la forma de llamar a ShowDialog).'
        $i = Probar-Dialogo @{ Tipo = 'Texto'; Texto = 'Nombre del cliente.'; Valor = 'Panadería El Trigal' }
        Afirmar ($i.Titulo -eq 'Ingresar dato') "Título: [$($i.Titulo)]."
        Afirmar ($i.Largo -eq 19 -and $i.Sel -eq 19) "Seleccionados $($i.Sel) de $($i.Largo) caracteres (debían ser todos)."
        Afirmar ($i.Si -eq 'Aceptar' -and $i.No -eq 'Cancelar') "Botones: [$($i.Si)] / [$($i.No)]."
    }
    Caso 'Cuadro de dato: admite un título propio' {
        $i = Probar-Dialogo @{ Tipo = 'Texto'; Texto = 'x'; Titulo = 'Reporte de entrega' }
        Afirmar ($i.Titulo -eq 'Reporte de entrega') "Título: [$($i.Titulo)]."
    }
    Caso 'Cuadro de confirmación: botones "Sí, continuar" y "Cancelar"' {
        $i = Probar-Dialogo @{ Tipo = 'SiNo'; Texto = 'Hay una tarea en curso. ¿Cerrar de todas formas?' }
        Afirmar ($i.Si -eq 'Sí, continuar' -and $i.No -eq 'Cancelar') "Botones: [$($i.Si)] / [$($i.No)]."
        Afirmar ($i.Alto -gt 100 -and $i.Alto -lt 700) "Alto raro: $($i.Alto)."
    }
    Caso 'Cuadro de información: solo el botón Cerrar, con título propio' {
        $i = Probar-Dialogo @{ Tipo = 'Info'; Titulo = 'Disco'; Texto = "Línea 1`nLínea 2" }
        Afirmar ($i.Titulo -eq 'Disco' -and $i.Si -eq 'Cerrar' -and -not $i.NoVisible) "Título [$($i.Titulo)], botón [$($i.Si)], Cancelar visible: $($i.NoVisible)."
    }
    Caso 'Cuadro con una lista de texto larga no se sale de la pantalla' {
        $largo = (1..60 | ForEach-Object { "Línea $_ de una lista larga de prueba" }) -join "`n"
        $i = Probar-Dialogo @{ Tipo = 'Info'; Titulo = 'Largo'; Texto = $largo }
        Afirmar ($i.Alto -lt 700) "Alto $($i.Alto): el cuadro creció demasiado (debe tener barra de desplazamiento)."
    }
    Caso 'Barra de tareas: progreso al trabajar' {
        $v = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xamls['XamlPrincipal'])))
        $b = $v.FindName('BarraTareas')
        Afirmar ($null -ne $b) 'No existe BarraTareas en la ventana principal.'
        $b.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::Indeterminate
        Afirmar ($b.ProgressState -eq 'Indeterminate') 'No se pudo poner el progreso.'
        $b.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::None
    }
    Caso 'Parpadeo de la barra de tareas (FlashWindowEx)' {
        Afirmar (Initialize-FlashNativo) 'No compiló el acceso a user32.dll.'
        $w = New-Object System.Windows.Window
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($w)).EnsureHandle()
        $fw = New-Object 'SoporteTecnico.Nativo+FLASHWINFO'
        $fw.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf([type]'SoporteTecnico.Nativo+FLASHWINFO')
        $fw.hwnd = $h; $fw.dwFlags = [uint32]15
        Afirmar ([SoporteTecnico.Nativo]::FlashWindowEx([ref]$fw)) 'FlashWindowEx devolvió falso.'
        $w.Close()
    }
}

# =====================================================================
Grupo 'Compilación (aislada, con un ps2exe falso)'
# =====================================================================
if ($Rapido) {
    Omitir 'Compilación de prueba' 'omitida por -Rapido'
}
else {
    $tmp = Join-Path $env:TEMP ('probar_compilar_{0}' -f [guid]::NewGuid().ToString('N'))
    $psmPrevio = $env:PSModulePath
    try {
        New-Item -ItemType Directory -Path (Join-Path $tmp 'src'), (Join-Path $tmp 'build'), (Join-Path $tmp 'modulos\ps2exe') -Force | Out-Null
        Copy-Item -LiteralPath $Fuente -Destination (Join-Path $tmp 'src\SoporteTecnico.ps1')
        foreach ($b in @(Get-ChildItem -LiteralPath (Join-Path $raiz 'build') -Filter '*.ps1' | Where-Object { $_.Name -ne 'Probar.ps1' })) { Copy-Item -LiteralPath $b.FullName -Destination (Join-Path $tmp 'build') }
        if (Test-Path -LiteralPath (Join-Path $raiz 'icon.ico')) { Copy-Item -LiteralPath (Join-Path $raiz 'icon.ico') -Destination $tmp }
        # ps2exe falso: solo copia el script al .exe (así no hace falta internet ni compilar de verdad)
        [System.IO.File]::WriteAllText((Join-Path $tmp 'modulos\ps2exe\ps2exe.psm1'), @'
function Invoke-ps2exe {
    param([string]$inputFile,[string]$outputFile,[switch]$noConsole,[switch]$noOutput,[switch]$noError,[switch]$requireAdmin,[switch]$x64,[switch]$STA,[string]$title,[string]$product,[string]$description,[string]$version,[string]$iconFile)
    Copy-Item -LiteralPath $inputFile -Destination $outputFile -Force
}
Export-ModuleMember -Function Invoke-ps2exe
'@)
        $env:PSModulePath = "$(Join-Path $tmp 'modulos');$psmPrevio"
        $compilar = Join-Path $tmp 'build\Compilar.ps1'
        $srcCopia = Join-Path $tmp 'src\SoporteTecnico.ps1'
        $hashSrcAntes = (Get-FileHash -LiteralPath $srcCopia).Hash
        function Compilar-Prueba { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compilar 2>&1; return $LASTEXITCODE }
        function Borrar-Exes { Remove-Item -LiteralPath (Join-Path $tmp 'SoporteTecnico.exe'), (Join-Path $tmp 'SoporteTecnico-Consola.exe') -Force -ErrorAction SilentlyContinue }

        Caso 'Sin .env: compila y avisa que no hay contraseña' {
            $codigo = Compilar-Prueba
            Afirmar ($codigo -eq 0) "Compilar.ps1 terminó con código $codigo."
            Afirmar ((Test-Path (Join-Path $tmp 'SoporteTecnico.exe')) -and (Test-Path (Join-Path $tmp 'SoporteTecnico-Consola.exe'))) 'No se generaron los dos .exe.'
            $c = [System.IO.File]::ReadAllText((Join-Path $tmp 'SoporteTecnico.exe'))
            Afirmar ($c -match "(?m)^\`$Script:ClaveHash = ''") 'Sin .env el .exe no debía llevar contraseña.'
        }
        Borrar-Exes
        $claveCompilar = 'ClavePrueba2026'
        [System.IO.File]::WriteAllText((Join-Path $tmp '.env'), "SOPORTE_CLAVE=$claveCompilar`r`n")
        Caso 'Con .env: los dos .exe llevan el hash y validan la contraseña' {
            $codigo = Compilar-Prueba
            Afirmar ($codigo -eq 0) "Compilar.ps1 terminó con código $codigo."
            foreach ($par in @(@('SoporteTecnico.exe', 'Grafica'), @('SoporteTecnico-Consola.exe', 'Consola'))) {
                $c = [System.IO.File]::ReadAllText((Join-Path $tmp $par[0]))
                $sal = [regex]::Match($c, "(?m)^\`$Script:ClaveSal = '([^']*)'").Groups[1].Value
                $hash = [regex]::Match($c, "(?m)^\`$Script:ClaveHash = '([^']*)'").Groups[1].Value
                $iter = [int][regex]::Match($c, "(?m)^\`$Script:ClaveIteraciones = (\d+)").Groups[1].Value
                Afirmar ($hash.Length -gt 20) "$($par[0]) no tiene hash."
                Afirmar ((Get-HashClave -Clave $claveCompilar -Sal ([Convert]::FromBase64String($sal)) -Iteraciones $iter) -ceq $hash) "$($par[0]): la contraseña del .env no valida."
                Afirmar (-not $c.Contains($claveCompilar)) "$($par[0]): la contraseña quedó en texto plano."
                Afirmar ($c.Contains("`$Script:ModoInterfaz = '$($par[1])'")) "$($par[0]): el modo de interfaz no es $($par[1])."
            }
        }
        Caso 'Con .env: el script fuente no se modifica y no quedan temporales' {
            Afirmar ((Get-FileHash -LiteralPath $srcCopia).Hash -eq $hashSrcAntes) 'Compilar.ps1 modificó src\SoporteTecnico.ps1.'
            Afirmar (-not (Test-Path (Join-Path $env:TEMP 'SoporteTecnico_grafica.ps1'))) 'Quedó el temporal SoporteTecnico_grafica.ps1.'
            Afirmar (-not (Test-Path (Join-Path $env:TEMP 'SoporteTecnico_consola.ps1'))) 'Quedó el temporal SoporteTecnico_consola.ps1.'
        }
        Borrar-Exes
        [System.IO.File]::WriteAllText((Join-Path $tmp '.env'), "SOPORTE_CLAVE=abc`r`n")
        Caso 'Contraseña de menos de 6 caracteres: se rechaza y no genera .exe' {
            $codigo = Compilar-Prueba
            Afirmar ($codigo -ne 0) 'Debía terminar con error.'
            Afirmar (-not (Test-Path (Join-Path $tmp 'SoporteTecnico.exe'))) 'Generó un .exe pese a la contraseña inválida.'
        }
    }
    finally {
        $env:PSModulePath = $psmPrevio
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Resumen ----------
Remove-Item -LiteralPath $Script:DirReportes -Recurse -Force -ErrorAction SilentlyContinue
$ok = @($Script:Resultados | Where-Object { $_.Estado -eq 'OK' }).Count
$fallas = @($Script:Resultados | Where-Object { $_.Estado -eq 'FALLA' })
$avisos = @($Script:Resultados | Where-Object { $_.Estado -eq 'AVISO' }).Count
$omitidas = @($Script:Resultados | Where-Object { $_.Estado -eq 'OMITIDA' }).Count
Imprimir ''
Imprimir ('Resultado: {0} OK, {1} FALLA(S), {2} aviso(s), {3} omitida(s) en {4:N0} s' -f $ok, $fallas.Count, $avisos, $omitidas, ((Get-Date) - $inicioTotal).TotalSeconds) $(if ($fallas.Count -gt 0) { 'Red' } else { 'Green' })
if ($fallas.Count -gt 0) {
    Imprimir 'Fallaron:' 'Red'
    foreach ($f in $fallas) { Imprimir ("  - [{0}] {1}: {2}" -f $f.Grupo, $f.Nombre, ($f.Mensaje -replace "\r?\n", ' | ')) 'Red' }
    exit 1
}
exit 0
