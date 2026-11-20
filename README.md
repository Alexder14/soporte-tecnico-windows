# Soporte Técnico para Windows 10/11 (v2.4)

> **Estado: en desarrollo.** La versión 2.4 todavía no se ha probado en un equipo Windows real. Úsela primero en un equipo de prueba.

Herramienta portable para técnicos de soporte. Diagnostica el equipo, le pone un puntaje de salud, sugiere qué reparar y aplica las reparaciones. Todo lo que hace queda registrado en un log.

- Funciona en Windows 10 y 11 con **Windows PowerShell 5.1**, que ya viene instalado. No instala nada en el equipo del cliente.
- No necesita internet, salvo para DISM, la reparación en línea de Office y la actualización de firmas del antivirus.

## Dos versiones

| Archivo | Qué es |
|---|---|
| `SoporteTecnico.exe` | **Interfaz gráfica** (tema oscuro): panel de salud, tarjetas por área, botones por categoría y registro en vivo |
| `SoporteTecnico-Consola.exe` | Menú de texto. Para sesiones remotas lentas o si la interfaz gráfica falla |
| `Ejecutar.bat` / `Ejecutar-Consola.bat` | Lo mismo, sin compilar (lanzan el `.ps1`) |

Las dos versiones piden permisos de administrador por sí solas y usan la misma contraseña.

## Uso (interfaz gráfica)

1. Abra `SoporteTecnico.exe` desde su USB (no hace falta copiarlo al equipo). Los reportes se guardan en la USB.
2. Escriba la contraseña, si hay una configurada.
3. En **Inicio**, pulse **Diagnóstico completo**. El análisis tarda 1 o 2 minutos y muestra:
   - El puntaje de 0 a 100 y el estado: bueno, requiere atención o crítico.
   - Los problemas detectados (críticos, alertas y notas) y qué hacer con cada uno.
   - Una tarjeta por área. Al hacer clic en una tarjeta se ve el detalle.
4. Pulse **Reparar lo encontrado** para aplicar las reparaciones automáticas que correspondan. Antes crea un punto de restauración y pide confirmación. El diagnóstico **no cambia nada por sí solo**.
5. Las demás reparaciones están en las categorías del menú izquierdo. Las preguntas aparecen como ventanas de confirmación y el avance se ve abajo, en **Registro de actividad**.

Solo se ejecuta una tarea a la vez. Las **Herramientas** (Administrador de dispositivos, Visor de eventos, etc.) se abren aunque haya una tarea en curso.

> Si cierra la ventana mientras corre DISM o SFC, esos procesos siguen solos en segundo plano hasta terminar.

## Qué revisa el diagnóstico

| Área | Qué detecta |
|---|---|
| Equipo | Modelo, serie, Windows 10 sin soporte, días sin reiniciar |
| RAM y CPU | Uso alto, poca memoria, procesos que más consumen |
| Disco | Espacio, salud, SMART, **desgaste del SSD, temperatura y errores de lectura**, disco mecánico |
| Eventos | Pantallazos azules **con el código traducido a causa probable**, apagados inesperados, errores de disco y de hardware |
| Aplicaciones | Programas que se cierran solos |
| Drivers | Dispositivos con error y qué significa cada código, **qué es cada dispositivo desconocido** (por ejemplo, "Realtek - tarjeta de red de cable", a partir de su identificador de hardware y sin internet), drivers sin firma, drivers que no cargaron, si Windows Update puede instalar drivers, la herramienta del fabricante instalada e **inventario de drivers** de terceros |
| Video y drivers | **Driver de video básico de Microsoft** y drivers de más de 5 años |
| Sonido | Servicios, tarjeta, driver genérico o reciente, salidas deshabilitadas o desconectadas, volumen y silencio |
| Micrófono y cámara | **Permisos de privacidad bloqueados**, micrófono silenciado, cámara deshabilitada, políticas de la empresa |
| Impresoras | Impresoras sin conexión, trabajos atascados, impresoras de red que no responden |
| Outlook / Office | Cierres y congelamientos con el módulo que falla, relación con la última actualización, OST/PST grandes, complementos |
| Red | Puerta de enlace, internet, DNS, DHCP |
| WiFi, proxy y VPN | **Señal y velocidad del WiFi**, proxy configurado, VPN conectada |
| Antivirus | Defender o el antivirus instalado, firmas viejas |
| Seguridad | **Firewall apagado, UAC desactivado, escritorio remoto sin NLA, archivo hosts modificado, programas de inicio sospechosos, amenazas detectadas**, políticas de navegador |
| Licencia y BitLocker | **Activación de Windows y Office**, últimos 5 caracteres de la clave de la BIOS, BitLocker activo |
| Actualizaciones | **Última actualización instalada y actualizaciones fallidas con el error explicado** |
| Arranque | **Segundos que tarda en arrancar y qué programa, driver o servicio lo retrasa** |
| Perfil de usuario | **Perfil temporal o dañado** |
| Otros | Reinicio pendiente, servicios clave, batería, temporales, programas de inicio |

Las **notas** (por ejemplo, "BitLocker activo" o "VPN conectada") son avisos informativos y no bajan el puntaje.

## Reparaciones

| Categoría | Reparaciones |
|---|---|
| Drivers | **Buscar e instalar drivers desde Windows Update** (marca cuáles corrigen un dispositivo con problema), **página de drivers del fabricante** (Dell, HP, Lenovo, ASUS, Acer, MSI...; copia el número de serie), **respaldar todos los drivers** a carpeta o USB, **restaurar o instalar drivers desde carpeta/USB**, **reinstalar un dispositivo**, **revertir el driver** a la versión anterior, **bloquear o permitir que Windows Update instale drivers** |
| Sistema | DISM + SFC, Windows Update, **desinstalar una actualización**, temporales, disco, **optimizar rendimiento**, **menú Inicio y búsqueda**, **iconos y miniaturas**, Explorador, Store, hora, punto de restauración |
| Red e internet | Reparar red (completo o suave), **quitar proxy y restablecer hosts**, **limpiar caché de navegadores** |
| Sonido y dispositivos | Sonido, **micrófono y cámara**, **Bluetooth y USB**, impresora (vacía la cola y la pone en línea), reporte de batería |
| Outlook y Office | Reparación rápida, modo seguro, "pide contraseña", reconstruir OST, reparar Office (rápida o en línea), panel de carpetas, perfiles de correo, **OneDrive**, **Teams** |
| Seguridad | **Escaneo rápido, completo y sin conexión de Defender**, firmas, **activar firewall**, **ver la clave de recuperación de BitLocker** (solo en pantalla, no se guarda en el log) |
| Herramientas | Accesos directos a las herramientas de Windows |

**Optimizar rendimiento** muestra los programas de inicio y usted elige cuáles desactivar. Funciona igual que en el Administrador de tareas, así que es reversible. También ofrece el plan de energía, los efectos visuales y desactivar el inicio rápido.

En la versión de consola, estas reparaciones nuevas (incluidas las de drivers) están en la opción **17. Reparaciones avanzadas**.

**Flujo recomendado para formatear un equipo:**
1. Drivers > **Respaldar todos los drivers** a una USB.
2. Formatee e instale Windows.
3. Drivers > **Restaurar o instalar drivers desde carpeta/USB**.
4. Para lo que siga sin driver: **Buscar drivers en Windows Update** y luego **Página de drivers del fabricante**.

**Revertir el driver** solo funciona si la versión anterior sigue guardada en Windows. Si no, la herramienta lo avisa y propone las alternativas. Antes de revertir crea un punto de restauración.

## Historial de visitas

Cada vez que abre la herramienta en un equipo queda registrada la **visita**: qué equipo es, de quién es, qué se hizo y cómo quedó.

- **Al entrar**, si ya atendió ese equipo, se lo avisa: cuántas veces, la fecha de la última visita, qué se hizo y las notas. El equipo se reconoce por el **número de serie**, así que lo encuentra aunque le hayan cambiado el nombre o lo hayan formateado. Si la serie es de relleno (PCs armadas y máquinas virtuales), se usa el nombre del equipo.
- **Durante la visita** se anota cada tarea y si salió bien, con avisos, con error o si se interrumpió, más el puntaje del primer y del último diagnóstico. El historial se guarda después de cada tarea, así que no se pierde si se va la luz o se desconecta la USB.
- **Al cerrar** se piden dos datos opcionales: el nombre del cliente (se rellena con el de la visita anterior) y notas, por ejemplo qué problema tenía.

Además se guarda la **ficha del equipo**. Solo datos de identificación, **nunca contraseñas**:
- usuario de Windows, su nombre y la cuenta Microsoft o de empresa con la que inicia sesión;
- cuentas de Office;
- dominio o grupo de trabajo;
- marca, modelo, número de serie y versión de Windows;
- **ID de AnyDesk y de TeamViewer**, para conectarse la próxima vez;
- procesador, RAM y discos;
- lista de programas instalados.

| Archivo | Qué tiene |
|---|---|
| `Clientes\Historial.csv` | Todas las visitas a todos los equipos. Se abre en Excel |
| `Clientes\<equipo>\Historial.txt` | Las visitas de ese equipo, fáciles de leer |
| `Clientes\<equipo>\Ficha_equipo.txt` | Ficha del equipo de la última visita |
| `Clientes\<equipo>\Programas_<fecha>.csv` | Programas instalados ese día (útil antes de formatear) |

### Trabajo remoto (sin la USB)

Cuando atiende por AnyDesk o TeamViewer, la herramienta corre en el equipo del cliente y no en su USB. Para que esas visitas también lleguen a su historial:

1. **Al cerrar** la herramienta, la visita se exporta sola a `C:\SoporteTecnico\Exportar\Visita_<equipo>_<fecha>.zip` y se abre esa carpeta. El `.zip` lleva las visitas de ese equipo, su ficha, la lista de programas, el log y los reportes de la sesión. No lleva los respaldos de drivers, porque pesan demasiado.
2. **Copie el `.zip`** a su PC con la transferencia de archivos de AnyDesk o TeamViewer.
3. **Póngalo en la USB**, en `Clientes\Importar\`. La próxima vez que abra la herramienta desde la USB, se carga sola en el historial y en la carpeta del equipo. Los ya cargados se mueven a `Clientes\Importar\Importados\`.

También puede usar **Herramientas > Importar visitas remotas** para cargar un `.zip` o una carpeta en cualquier momento, y **Herramientas > Exportar esta visita** para generar el `.zip` sin cerrar. La misma visita no se duplica aunque la importe dos veces.

En el equipo del cliente, el historial de sus propias visitas queda en `C:\SoporteTecnico\Historial.csv`. Si el `Historial.csv` está abierto en Excel, no se puede actualizar: ciérrelo antes de terminar la visita.

## Usuario del cliente y usuario administrador

Outlook, el audio, el micrófono, los navegadores, OneDrive y Teams se revisan sobre el **usuario que tiene la sesión abierta**, aunque usted haya elevado la herramienta con otra cuenta de administrador.

Los programas del usuario (Outlook, el Panel de sonido, el reporte HTML, el Explorador) se abren en su sesión y sin permisos de administrador. Para eso se usa una tarea programada temporal que se borra sola.

## Qué se borra y qué se respalda

- Los **OST y PST nunca se borran**. Los PST no se tocan.
- El OST, RoamCache, OneAuth e IdentityCache se renombran a `.old_<fecha>`.
- El archivo hosts y la configuración de proxy se copian a la carpeta Reportes antes de cambiarlos.
- La clave `Identities` de Office se exporta a un `.reg` antes de borrarla.
- Los temporales y las cachés (adjuntos de Outlook, navegadores, Teams, iconos) se borran porque se regeneran solos. De los navegadores **no** se borran contraseñas, historial ni favoritos.

## Contraseña

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\CambiarContrasena.ps1
```

1. Escriba la contraseña dos veces (mínimo 6 caracteres). Déjela vacía para quitarla.
2. Vuelva a compilar. La contraseña aplica a las dos versiones.

Funciona así:
- Se guarda solo un hash con sal (PBKDF2), nunca la contraseña.
- Tiene 3 intentos; después la herramienta se cierra.
- Los intentos fallidos quedan en el log.

Es una barrera para que el cliente o un curioso no use la herramienta. No es seguridad fuerte: alguien con conocimientos puede extraer el script del `.exe`.

## Dónde quedan los archivos

**Si abre la herramienta desde una USB** (o un disco externo USB), todo se guarda en la USB, en una carpeta por equipo, junto al `.exe`:

```
USB\
├── SoporteTecnico.exe
├── SoporteTecnico-Consola.exe
└── Clientes\
    └── PC-CONTABILIDAD\
        ├── Logs\                 log de cada sesión
        ├── Reportes\             diagnósticos, batería y respaldos de configuración
        └── Drivers_<PC>_<fecha>\ respaldo de drivers (si eligió la carpeta predeterminada)
```

Así queda el historial de cada cliente en la USB y no se deja nada en su equipo. Si la USB está protegida contra escritura o le quedan menos de 100 MB, la herramienta lo avisa y guarda en `C:\SoporteTecnico`, como cuando se abre desde el disco del equipo:

| Qué | Dónde |
|---|---|
| Logs | `C:\SoporteTecnico\Logs\log_yyyyMMdd_HHmmss.txt`, uno por sesión |
| Diagnósticos | `C:\SoporteTecnico\Reportes\Diagnostico_<PC>_<fecha>.txt` y `.html` |
| Batería | `C:\SoporteTecnico\Reportes\bateria_<fecha>.html` |
| Respaldos | `C:\SoporteTecnico\Reportes\` (hosts, proxy, identidad de Office) |

Los scripts temporales que se ejecutan en la sesión del usuario siempre van a `C:\SoporteTecnico\Temp`.

> Los reportes incluyen modelo, número de serie y nombre de cada equipo. Si pierde la USB, esos datos quedan expuestos: considere cifrarla con BitLocker To Go.

## Compilar

En un equipo Windows, con internet solo la primera vez (para descargar `ps2exe`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\Compilar.ps1
```

`Compilar.ps1` hace lo siguiente:

1. Valida la sintaxis con el parser de PowerShell 5.1. Si encuentra errores, no compila.
2. Verifica que el script esté en UTF-8 con BOM.
3. Avisa si no hay contraseña configurada.
4. Instala `ps2exe` si falta.
5. Genera `SoporteTecnico.exe` (gráfico) y `SoporteTecnico-Consola.exe`, ambos de 64 bits y con permisos de administrador.

Si existe `icon.ico` en la raíz, se usa como icono. La versión sale de `$Script:Version`.

## Advertencias

- **Falsos positivos del antivirus:** algunos antivirus marcan los `.exe` de ps2exe como amenaza. Firme el ejecutable (`Set-AuthenticodeSignature`) o use los `.bat`.
- **Sesión remota:** "Reparar red (completo)" corta AnyDesk/TeamViewer, y el escaneo sin conexión reinicia el equipo. La herramienta avisa antes de hacerlo.
- **Archivos del script:** guárdelos en **UTF-8 con BOM** y con saltos de línea **CRLF**. Los `.bat` deben quedar en ASCII, sin BOM.

## Licencia

© 2026 Alexander Salazar. **Todos los derechos reservados.** Software propietario: no se permite usarlo, copiarlo, modificarlo ni distribuirlo sin autorización por escrito del autor. Vea [LICENSE](LICENSE).

Se entrega "tal cual", sin garantía: cree un punto de restauración antes de reparar.
