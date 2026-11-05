# Auditoría — plugin Noctalia `cero800/arch-audit` (v0.1.0)

**Objeto:** `/home/b3low-z3r0/.local/state/noctalia/plugins/materialized/community/arch-audit`
**Host:** Noctalia `v5.4.1 (v5.4.1-41-gf2cebd97e016)` (noctalia-git `1:5.4.1.r6105.gf2cebd97e-1`), plugin_api actual `46`.
**Estado:** instalado y **enabled** (`noctalia msg plugins list` → `cero800/arch-audit [community] 0.1.0 enabled`), service corriendo, snapshot válido en disco.
**Fecha:** 2026-11-01. Sin modificaciones al plugin.

Archivos: `plugin.toml` (100), `service.luau` (491), `panel.luau` (614), `widget.luau` (177), `lib/audit.luau` (300), `translations/en.json` (173), `README.md` (115). Total 1970 líneas.

Evidencia de host (`noctalia-src`, árbol de `/home/b3low-z3r0/.hermes/profiles/parallel/cache/scratch/noctalia-src`) citada como `src/...:línea` cuando la conducta depende del binario y no del plugin.

---

## 1. Entries, settings, panel

### 1.1 Entries

| Entry | id | archivo | tipo |
|---|---|---|---|
| service | `service` | `service.luau` | headless, dueño de todos los procesos |
| panel | `panel` | `panel.luau` | declarativo `ui.*` |
| widget | `widget` | `widget.luau` | barra, imperativo (`barWidget.*`) |

`plugin.toml:14` → `plugin_api = 43`; `plugin.toml:19` → `dependencies = ["arch-audit","pacman","xdg-open"]`; `plugin.toml:11-20` id/name/version/license/icon/tags.

Contrato de entries respetado: los tres archivos definen callbacks **globales** (`function update()`, `function onIpc(...)`, `function onOpen()`, etc.), no `return tabla` (`service.luau:402,452,456`; `panel.luau:578,585,589,598`; `widget.luau:161,165,171`).

### 1.2 Settings del plugin

| clave | tipo | default | rango/opciones | archivo:línea |
|---|---|---|---|---|
| `check_hours` | `int` | `6` | min 1, max 168 | `plugin.toml:24-31` |
| `notify_new` | `bool` | `true` | — | `plugin.toml:35-40` |
| `notify_min_severity` | `select` | `"high"` | critical/high/medium/low | `plugin.toml:42-53` |
| `ignore_packages` | `string_list` | `[]` | — | `plugin.toml:57-62` |

Los cuatro tipos están soportados por el manifest parser: `string_list` en `src/scripting/plugin_manifest.cpp:81`, `select` en `:88`; las opciones se leen de `options = [{ value, label_key }]` (`plugin_manifest.cpp:266-296`) — la forma que usa este plugin es la correcta.

### 1.3 Settings del widget

| clave | tipo | default | archivo:línea |
|---|---|---|---|
| `glyph` | `glyph` | `"shield-exclamation"` | `plugin.toml:81-86` |
| `show_count` | `bool` | `true` | `plugin.toml:88-93` |
| `hide_on_clean` | `bool` | `false` | `plugin.toml:95-100` |

Lectura: `noctalia.getConfig("glyph"|"show_count"|"hide_on_clean")` en `widget.luau:31,125,136`. `getConfig` devuelve un `std::vector<std::string>` como tabla array de Lua para `string_list` (`src/scripting/plugin_bindings.cpp:854-859`), que es lo que espera `audit.ignore_set` (`audit.luau:161-174`).

### 1.4 Panel

```toml
width = 460
height = 580
placement = "attached"
position = "auto"
open_near_click = true
```
`plugin.toml:68-75`. Tamaño **fijo**: el host no expone `setSize`; `height = "content"` existe (plugin_api 42+, `kPanelContentHeightPluginApiVersion` en `src/scripting/plugin_api.h:45`) pero no se usa acá.

El host **inyecta** settings propios del panel, así que `placement`/`position`/`open_near_click` son sólo defaults y el usuario puede pasarlo a flotante desde Ajustes sin tocar el manifest: `src/scripting/plugin_panel_shell.cpp:95-113` (`injectStandardPanelShellSettings`, claves `panel_placement`, `panel_position`, `panel_layer`, `panel_open_near_click`), lectura en `:96-101` y `:143`.

---

## 2. Cómo detecta actualizaciones

**No detecta actualizaciones.** Cero referencias a `checkupdates`, `pacman -Qu`, `paru`, `yay` en todo el plugin (grep sobre `*.luau`, `*.toml`, `*.md`: únicas apariciones de `pacman` son texto de clipboard). El único dato que entra es el feed de avisos de seguridad.

Cadena exacta de un check (`start_check` → `finish_check` → `load_installed` → `complete_check`):

1. `noctalia.commandExists("arch-audit")` (`service.luau:376`); si falta, `phase = "missing"` y `binary_recheck_at = now + 10 min` (`service.luau:32-33, 380-387`).
2. `noctalia.runAsync({ "arch-audit", "--json" }, cb, 60000)` (`service.luau:389-391`). argv directo (sin shell), timeout 60 s.
3. Parseo: `noctalia.json.decode(result.stdout)`; si no es tabla → `fail(service.error.json)` (`service.luau:343-347`). Se valida `exitCode ~= 0` y se recorta `stderr` a 180 chars como detalle del error (`service.luau:327-340`, `MAX_ERROR_CHARS` en `:37`).
4. Recolección de nombres de paquete únicos del payload (`service.luau:349-360`).
5. **Enriquecido de versión instalada:** `noctalia.runAsync({ "pacman", "-Q", pkg1..pkgN }, cb, 15000)` con tope de 250 nombres (`service.luau:298-309`, `MAX_QUERY_PACKAGES` en `:36`). Parseo `^(%S+)%s+(%S+)` por línea en `audit.parse_installed` (`audit.luau:61-70`); **se ignora el exit code** porque `pacman -Q` sale 1 si algún nombre no existe y aun así imprime el resto (comentario en `audit.luau:58-60`).
6. Normalización + filtro de ignorados + publicación (`service.luau:266-290`).

Contrato del callback de `runAsync` verificado contra el host: la tabla trae `exitCode`, `stdout`, `stderr`, `timedOut` (`src/scripting/luau_host.cpp:3108-3120`) y **el tercer argumento sí es un timeout en ms** (`luau_host.cpp:276-311` + `commandTimeoutFromLua` en `:199-209`, clampeado entre `kMinCommandTimeout`/`kMaxCommandTimeout`). Es decir: este plugin usa la firma completa y funciona — el plugin está corriendo y el snapshot se escribió con datos reales.

### Caché por tiempo (todo con `os.time()`, tick de 1 s)

| Mecanismo | Valor | archivo:línea |
|---|---|---|
| intervalo entre checks | `check_hours` (6 h) | `service.luau:429-437` |
| gate anti-ráfaga | `DUE_TICKS = 2` ticks consecutivos vencidos antes de disparar | `service.luau:35, 441-449` |
| delay de arranque sin snapshot | 10 s | `service.luau:34, 438` |
| backoff tras fallo | 15 min (`RETRY_SECONDS`) | `service.luau:32, 214` |
| re-detección del binario | 10 min | `service.luau:33, 411-423` |
| tick del service | `setUpdateInterval(1000)` | `service.luau:491` |

Persistencia del último resultado bueno: `<pluginDataDir>/snapshot.json`, `version = 1`, campos `checkedAtMs`, `raw`, `installed`, `seen`, `initialized` (`service.luau:27-28, 150-173, 175-209`). Verificado en disco: 4.235 bytes, `checkedAtMs = 1793521718000`, `raw = 21` avisos, `installed = 17` versiones, `seen = 21`.

**Para el plugin nuevo:** `checkupdates` funciona sin root en esta máquina (27 paquetes pendientes, exit 0) y `pacman -Qu` **subreporta** (1 paquete, base local sin sincronizar). `paru -Qua` cubre AUR/VCS sin root (`noctalia-git 1:5.4.1.r6105.gf2cebd97e-1 -> latest-commit`, `umbriel-git 1:0.1.0.r1481.eb449f4-1 -> latest-commit`).

---

## 3. Cómo detecta vulnerabilidades / security

Herramienta: **`arch-audit --json`** (no `-u`; el plugin usa el listado completo de avisos que afectan paquetes instalados y filtra él mismo por ignorados).

Salida real capturada en esta máquina (`arch-audit 0.2.0-5.1`, 21 entradas, exit 0):

```json
{"name":"AVG-2842","packages":["libtiff"],"status":"Unknown","type":"unknown",
 "severity":"Unknown","fixed":null,"issues":["CVE-2022-48281", ...]}
```

Campos del payload y su uso:

| campo JSON | destino | archivo:línea |
|---|---|---|
| `name` (ID de aviso, p.ej. `AVG-2901`) | `item.id`, dedupe, URL del tracker | `audit.luau:113, 127, 135` |
| `packages[]` | `item.packages`, clave de ignorados | `audit.luau:114, 128` |
| `severity` (`"High"`, `"Unknown"`…) | normalizado a minúsculas; desconocido → `"unknown"` | `audit.luau:34-40, 125` |
| `status` (`Vulnerable`/`Unknown`/`Fixed`) | `item.status`, traducido por clave `status.<slug>` | `audit.luau:131`; `panel.luau:121-129` |
| `type` | `item.type`, texto libre | `audit.luau:132` |
| `fixed` (string o `null`) | `item.fixed`; `null` → `nil` → "No fixed version yet" | `audit.luau:133`; `panel.luau:265` |
| `issues[]` (CVEs) | `item.issues`, se muestran hasta 4 | `audit.luau:134`; `panel.luau:148-161` |

Versión **instalada** por paquete: `pacman -Q` (sección 2), guardada como `item.installed = [{name, version}]` (`audit.luau:116-123`).

No hay parseo del JSON del tracker (`https://security.archlinux.org/all.json`): eso lo hace `arch-audit` (decisión explícita, `service.luau:16-18`). No se consultan repos ni advisory DBs propias.

Orden y agregados: `table.sort` por rank de severidad desc y luego por primer paquete (`audit.luau:145-156`); conteos por severidad (`:50-56`, `:140`); `max_severity` para el color del badge (`:257-264`).

URL del aviso: `https://security.archlinux.org/<ID>` sólo si el ID matchea `^[A-Z][A-Z0-9]*%-%d+$` (`audit.luau:74-80`) — defensa contra un payload manipulado que intente inyectar una URL arbitraria en `xdg-open`.

---

## 4. Acciones

**El plugin es 100 % read-only.** No ejecuta `sudo`, `pkexec`, `polkit`, ni `runInTerminal` en ningún lado (grep en todo el árbol: `sudo` aparece únicamente como texto para el clipboard en `lib/audit.luau:32` y `panel.luau:344,485`). El `README` lo declara (`README.md:8, 114-115`) y el manifiesto lo confirma (no hay settings de acción).

Acciones reales:

| Acción | Implementación | archivo:línea |
|---|---|---|
| Abrir aviso en el navegador | `noctalia.runAsync({ "xdg-open", item.url })` (sin callback: si falla, no se entera) | `panel.luau:43-48` |
| Copiar `sudo pacman -Syu` | `noctalia.copyToClipboard(text, "text/plain")` + flash 2 s | `panel.luau:34-41`; comando en `audit.luau:32` |
| Copiar `sudo pacman -S arch-audit` | idem, en el banner y el empty state de dependencia faltante | `panel.luau:344, 485` |
| Forzar check | `state.set(arch_audit_request, {nonce, action="check"})` | `panel.luau:28-32`; `widget.luau:24-28` |
| Abrir ajustes del plugin | `noctalia.openSettings()` | `panel.luau:443`; `service.luau:461` |
| Historial | no existe | — |

**Elevación de privilegios: ninguna, y por diseño.** Para el "actualizar todo" del plugin nuevo las opciones reales del host son:

- `noctalia.runInTerminal(cmd)` (`src/scripting/luau_host.cpp:334-340`) → abre la terminal configurada y el usuario teclea la contraseña ahí. **Recomendada**: sin dependencia de polkit, sin credenciales en el plugin, salida visible.
- `pkexec` vía `runAsync` → requiere agente polkit y no hay salida legible (no hay pty en `runAsync`).
- Nada de capturar progreso de un proceso privilegiado: `runAsync` no da pty, sólo stdout/stderr al final.

---

## 5. UI, pantalla por pantalla

Todas en `panel.luau`, un solo `render()` (`:406-576`) que recompone el árbol completo en cada `state.watch` (`:604-612`) o cambio local de filtro.

1. **Header** (`:412-455`): glyph 24 px (`shield` / `shield-x` / `shield-check`, `:108-119`), color según peor severidad o error (`:89-106`), título `panel.title`, subtítulo con conteo de avisos + paquetes afectados + desglose por severidad (`:68-87`), y tres botones ghost: *refresh* (`enabled = not checking`), *settings*, *close* (`panel.close()`).
2. **Banner de dependencia faltante** (`:319-348`): fondo `error/0.12`, `alert-triangle`, texto + botón "Copy install command".
3. **Banner de último check fallido** (`:350-379`): fondo `tertiary/0.12`, muestra `snapshot.err` (recortado a 2 líneas) + botón "Try again".
4. **Estados vacíos** (`empty_state`, `:280-312`), en este orden de precedencia (`:462-516`):
   - `snapshot == nil` → "Waiting for the service";
   - `checking and total == 0` → "Checking advisories…";
   - `total == 0 and binaryMissing` → "arch-audit is not installed" + copiar comando;
   - `total == 0 and err` → error + reintentar;
   - `total == 0 and phase == "clean"` → "No known advisories";
   - `total == 0` (resto) → "Not checked yet" + "Check now".
5. **Fila de filtros** (`:518-543`): `ui.select` 0-based con `All severities (21)`, `Critical (n)`… usando conteos vivos (`:163-176`, `selectedIndex` en `:178-185`, `onChange` con `tonumber(value)+1` en `:524-528`); botón toggle **"With fix"** (`selected`, `variant` cambia a `primary`).
6. **Lista scrolleable de cards** (`ui.scroll` con `flexGrow = 1`, `:559-563`). Cada card (`:187-278`): punto de color de severidad, `paquete versión` en bold (truncado a 1 línea), etiqueta de severidad; segunda fila `status · type`; tercera `Fixed in X` (bold, color primary) o `No fixed version yet`; cuarta `CVEs: …` (máx. 4 + `+N`, 2 líneas); quinta fila de acciones: **Open advisory** (sólo si `item.url`) y **Copy upgrade** (siempre, con tooltip).
7. **Filtro sin resultados** (`:546-557`): texto centrado.
8. **Footer** (`:384-404` + separador `:567`): "Checked X ago" (plural vía `trp`, `audit.age_text` en `audit.luau:288-294`), "N ignored" si aplica, y flash "Copied to clipboard" que se borra a los 2 s (`:589-596`, requiere `panel.setWantsSecondTicks(true)` en `:581` — confirmado que el host tickea `update()` del panel: `src/shell/panel/plugin_panel.cpp:328-335`).

Widget de barra (`widget.luau:121-152`): glyph + color, texto = total (o `!` si falta dependencia/error), `setVisible` según `hide_on_clean`, tooltip de 4-5 filas (estado, severidades, nuevos, último check, hint).

---

## 6. State keys e IPC

### Claves de estado (`noctalia.state`, namespace por plugin: `src/scripting/plugin_state_store.cpp:12-50`)

| clave | quién escribe | quién lee | shape |
|---|---|---|---|
| `arch_audit_state` | service, en `publish()` (`service.luau:83-113`) | widget (`widget.luau:154-159`), panel (`panel.luau:604-612`) | `{ phase, total, packageCount, counts{critical..unknown}, items[], severity, checkedAtMs, newCount, ignoredCount, binaryMissing, err }` |
| `arch_audit_request` | panel (`:31`) y widget (`:27`) | service (`service.luau:465-477`) | `{ nonce, action = "check" }`; el service descarta `nonce <= last_request_nonce` |

`phase` ∈ `idle | checking | missing | error | ready | clean`, resuelto por precedencia en `resolve_phase()` (`service.luau:115-129`).

`items[]` (post-normalización, `audit.luau:126-136`): `{ id, packages[], installed[{name,version}], severity, status, type, fixed?, issues[], url? }`.

### IPC

```bash
noctalia msg plugin cero800/arch-audit:service all check          # service.luau:457-459 (también "refresh")
noctalia msg plugin cero800/arch-audit:service all open-settings  # service.luau:460-461
noctalia msg plugin cero800/arch-audit:panel  all check           # panel.luau:598-602
noctalia msg panel-toggle cero800/arch-audit:panel                # README.md:45-49
```

`onIpc(event, payload)` del service ignora el payload y mapea por nombre de evento (`service.luau:456-463`). El panel sólo acepta `check`/`refresh` (`panel.luau:598-602`). El dispatcher del host exige que el entry tenga el global (`src/scripting/plugin_ipc.cpp:157-166`), cosa que se cumple.

### Persistencia

`<pluginDataDir>/snapshot.json` (`service.luau:27, 75-81`) — ver §2. Ruta real: `~/.local/state/noctalia/plugins/data/cero800/arch-audit/snapshot.json`.

---

## 7. Qué haría falta para añadir auditorías de Noctalia, Umbriel y el CLI propio

### (a) Noctalia — versión instalada vs upstream y plugins caídos

Datos disponibles hoy en esta máquina:

| Dato | Comando | Salida real |
|---|---|---|
| versión instalada | `noctalia --version` | `noctalia v5.4.1 (v5.4.1-41-gf2cebd97e016)` |
| paquete | `pacman -Qi noctalia-git` | `1:5.4.1.r6105.gf2cebd97e-1` |
| release upstream | `GET api.github.com/repos/noctalia-dev/noctalia/releases/latest` | `v5.4.1` (2026-10-29) |
| commit upstream | `git ls-remote https://github.com/noctalia-dev/noctalia HEAD` | `e7c55972a505…` ≠ instalado `f2cebd97e` → **adelantado** |
| plugins habilitados | `noctalia msg plugins list` / `noctalia msg config-get plugins` | lista `[community] enabled/disabled/deprecated` + `enabled = [...]` en TOML |
| plugins caídos por error | **sólo log** | `plugin widget '<id>' disabled after repeated timeouts` (`src/shell/bar/widgets/plugin_widget.cpp:683`), `plugin panel '<id>' …` (`src/shell/panel/plugin_panel.cpp:360`), notificación `plugins.auto-disabled.*` (`src/scripting/script_runtime.cpp:1080-1087`), `script callback '…' exceeded its CPU budget` (`src/scripting/luau_host.cpp:3204`) |

Implicancias de diseño:

- **No hay API para el estado "auto-deshabilitado"**: es efímero, sólo se loguea (no se persiste; `plugin_state_store` sólo guarda lo que escribe el plugin). Hay que leer `~/.cache/noctalia/noctalia.log*` y cruzar con `plugins list`. `noctalia.readFile` acepta rutas absolutas (`resolveHostPath`, `src/scripting/luau_host.cpp:994-1005`), así que es viable desde Luau, pero parsear 7k líneas de log en el callback revienta el presupuesto de 25 ms (`src/scripting/script_runtime.cpp:53`).
- **Comparación de versiones git**: `v5.4.1-41-g<sha>` no es semver; hay que comparar `<sha>` contra `git ls-remote`, no contra el tag del release (acá release y versión local coinciden y aun así hay 41 commits de diferencia).
- Lo que falta concretamente: un `[[setting]]` (o nada: fijo), un campo nuevo en el state (`noctalia = { version, upstream, behind, pluginsDisabled[] }`), ~2 `runAsync` extra y una sección en el panel. **Costo estimado en Luau puro: 150-200 líneas, y queda frágil** (cache del log, parseo de texto). Ver §9.

### (b) Umbriel — estado del servicio y versión

| Dato | Comando | Salida real |
|---|---|---|
| servicio | `systemctl --user is-active umbriel` | `active`, exit 0 |
| detalle | `systemctl --user show umbriel -p ActiveState,SubState,NRestarts,MemoryCurrent` | — |
| versión binario | `umbriel --version` | `umbriel 0.1.0 (eb449f45887d)` |
| paquete | `pacman -Qi umbriel-git` | `1:0.1.0.r1481.eb449f4-1` |
| upstream | `git ls-remote https://github.com/noctalia-dev/umbriel HEAD` | `422784526984…` ≠ `eb449f4` → **atrasado** |

Falta: 3 `runAsync` (`is-active`, `--version`, `ls-remote`) + un bloque de UI. Ojo: `systemctl` es barato, pero `ls-remote` es red (2-4 s) → tiene que ir en el service con timeout propio y cache por intervalo, nunca en `onOpen`.

### (c) CLI propio en Go (`~/.local/bin/b3l0w`)

Verificado:

```
$ b3l0w version        → b3l0w dev          # sin semver: no hay versión comparable
$ b3l0w status         → "▸ Estado de las actualizaciones / ✓ sistema base: al día / ✓ boot-preview: v0.2.3 / ✓ kitty-shapes: v1.0.1"
$ b3l0w update --check → idéntico a status (read-only, exit 0)
$ b3l0w doctor         → chequeos de dependencias (cachy-update, pacman, terminal, plugins)
$ b3l0w status --json  → NO existe: imprime el mismo texto, ignora el flag
```

Falta para auditarlo desde un plugin: **salida machine-readable**. Dos caminos:

1. añadir `--json` real a `b3l0w status`/`update --check` (ideal: es el CLI del sistema, sirve a todo);
2. exponerlo en el CLI del repo `b3l0w-widgets` como módulo `audit` (que ya tiene el puente `shared/cli.luau:21-42` esperando JSON por módulo).

Además `b3l0w version` → `dev` significa que la auditoría de "¿está actualizado el CLI?" necesita otra fuente: el manifiesto propio (`~/.local/lib/b3l0w/plugins`, programas registrados con `--source/--asset`) o el release de GitHub del repo. Sin eso, "CLI actualizado" no es respondible.

---

## 8. Botón "actualizar todo lo que se pueda"

Inventario de qué es actualizable y con qué:

| Capa | Comando | Privilegio | Notas |
|---|---|---|---|
| repos oficiales/CachyOS | `sudo pacman -Syu` (o `cachy-update` / `arch-update`, como hace `b3l0w update --system`) | **root** | Arch no soporta upgrade parcial: `-Syu` completo es la única forma correcta (ya razonado en `audit.luau:30-32`) |
| AUR / VCS | `paru -Sua` (tras el `-Syu`, mismo run) | root sólo para el `pacman -U` final | `paru -Qua` lista `noctalia-git`, `umbriel-git` |
| plugins Noctalia | `noctalia msg plugins update <source>` | usuario | source `community`/`official`/custom; después `plugins enable` del que falle |
| CLI propio / programas | `b3l0w update --self`, `b3l0w install <name>` | usuario (~/.local/bin) | `b3l0w update` ya encadena sistema + programas |

Qué falta en el plugin para el botón:

1. **Elevación**: `noctalia.runInTerminal("sudo pacman -Syu && paru -Sua")` para la parte root (`src/scripting/luau_host.cpp:334-340`). Alternativa polkit sólo si se acepta un agente y perder la salida.
2. **Máquina de estados de la operación** en el service (no en el panel): `update = { phase = "idle|running|done|failed", steps = [{name, state, detail}], startedAt }` publicado en el state. Hoy el service no tiene ningún concepto de trabajo en curso más allá de `checking` (`service.luau:49, 367-400`).
3. **Orden no negociable**: sync pacman → `-Syu` → AUR → plugins → CLI. Actualizar plugins/CLI antes del `-Syu` deja binarios viejos en `PATH`.
4. **Serialización**: un solo worker. `checking` es un bool único; hace falta un mutex equivalente para que un check de seguridad no se pise con el update (hoy `start_check` retorna si `checking`).
5. **Confirmación**: el patrón del host es `panel.openContextMenu` (`src/scripting/plugin_bindings.cpp:786-792`) o una pantalla de confirmación dentro del panel — un botón que lanza `sudo` sin confirmar es lo que el usuario va a rechazar.
6. **Post-update**: refrescar el snapshot de seguridad (el `-Syu` cambia versiones), invalidar cachés de versión (Noctalia/Umbriel) y avisar si el shell quedó viejo hasta reiniciar (noctalia-git actualizado ≠ shell recargado).

Advertencia concreta: **`noctalia msg plugins update` y `b3l0w update` no son idempotentes respecto del plugin que los lanza** — reemplazar el plugin en ejecución a mitad de la operación deja el service con código viejo en memoria y el state huérfano. El paso "plugins" debe ir último o excluir el propio plugin.

---

## 9. Trabajo delegable al CLI en Go

Todo lo que hoy hace el service en Luau es *trabajo de datos*, no de UI, y choca con tres límites del host: 25 ms de CPU por callback (`script_runtime.cpp:53`), ausencia de pty, y la cadena de dos procesos con argv limitado.

**Un solo comando** (`b3l0w-widgets audit check --json`) devolvería el snapshot completo:

```json
{
  "generatedAtMs": 0,
  "security": { "items": [...], "counts": {...}, "total": 0, "ignored": 0 },
  "packages": { "repo": {"count": 27, "items": [{"name":"kmod","from":"34.2-1","to":"34.3-1.1"}]},
                "aur":  {"count": 2,  "items": [{"name":"noctalia-git","vcs":true}]} },
  "noctalia": { "installed": "v5.4.1-41-gf2cebd97e", "upstream": "e7c5597", "behind": true,
                "pluginsDisabled": [{"id":"...","reason":"timeouts"}] },
  "umbriel":  { "active": true, "version": "0.1.0 (eb449f4)", "behind": true },
  "cli":      { "version": "dev", "behind": null, "programs": [...] }
}
```

Qué se gana y por qué conviene:

| Tarea | Hoy (Luau) | En Go |
|---|---|---|
| `arch-audit --json` + `pacman -Q` | 2 procesos, 250 paquetes tope, JSON.parse del payload completo | un `exec`, sin tope, join en memoria |
| `checkupdates` / `paru -Qua` | no existe | nativo, sin root |
| versión Noctalia/Umbriel vs upstream | no existe | `git ls-remote` + cache con TTL en disco |
| plugins caídos | requeriría parsear el log en Luau (caro) | lectura incremental del log con offset guardado |
| persistencia | `snapshot.json` reescrito entero (4 KB hoy) | cache con mtime + escritura atómica |

Lógica que **debe quedar en Luau** (es contrato de host, no datos): suscripción a `noctalia.state`, `onIpc`, `getConfig`, traducciones, y todo el árbol `ui.*`.

Lógica que **debe quedar en el service** aunque sea barata: disparar el CLI, decidir la ventana de refresh (`check_hours`), dedupe de `nonce` y notificaciones de novedades.

---

## 10. Bugs, límites y lo que falta para "ocultar label" y "panel flotante"

### Bugs / defectos verificables

| # | Defecto | Evidencia | Impacto |
|---|---|---|---|
| B1 | **No detecta actualizaciones** (ni repo ni AUR): el badge sólo refleja avisos de seguridad | grep sin hits de `checkupdates`/`pacman -Qu`/`paru`; único input `service.luau:389` | en esta máquina hay 27 actualizaciones y el widget puede estar en verde |
| B2 | Tope silencioso de 250 paquetes al pedir versiones | `service.luau:36, 299` | los paquetes que excedan se muestran sin versión (`panel.luau:136-139`) y nadie se entera |
| B3 | `newCount` no se resetea en un fallo | `fail()` en `service.luau:211-218` no toca `new_count`; lo consume `widget.luau:143-148` | el tooltip sigue diciendo "N nuevos" de la corrida anterior aunque el último check falló |
| B4 | Doble escritor del request sin coordinación | `panel.luau:29-31` y `widget.luau:25-27` (mismo read-modify-write) + descarte `nonce <= last` en `service.luau:470` | click perdido en silencio si panel y widget disparan juntos |
| B5 | Sólo se valida `arch-audit`; `pacman` y `xdg-open` se declaran y nunca se chequean | `plugin.toml:19` vs `service.luau:376,414,481` | "Open advisory" no hace nada si falta `xdg-open`, sin mensaje (`panel.luau:47` sin callback) |
| B6 | `Fixed in X` no se compara nunca contra la versión instalada | `audit.luau:133` + `panel.luau:265`; no hay comparador de versiones en el módulo | la frescura del veredicto depende por completo de la DB de `arch-audit`; el plugin no puede detectar un aviso ya resuelto |
| B7 | `hide_on_clean` oculta el widget y con él la única entrada al panel si no hay keybinding | `widget.luau:137` + `README.md:76` | usuario sin atajo `panel-toggle` se queda sin panel |
| B8 | Panel de tamaño fijo con CVE truncados a 4 | `plugin.toml:71-72`; `panel.luau:153` | con 21 avisos y avisos de 19 CVEs (`AVG-2842`), el detalle real sólo se ve en el tracker |
| B9 | No hay `es.json` | `translations/` contiene sólo `en.json` | UI en inglés para locale es-AR; rompe la convención del repo nuevo (`README.md:26`) |
| B10 | `snapshot.json` se reescribe completo en cada check y `seen` no se poda | `service.luau:150-173, 275` | 4 KB hoy; crece con el catálogo del tracker, sin límite |
| B11 | Regex de ID descarta variantes legítimas | `audit.luau:76` (`^[A-Z][A-Z0-9]*%-%d+$`) | un ID con sufijo (p.ej. `AVG-1234-1`) deja la fila sin botón "Open advisory" |
| B12 | `onConfigChanged` no reprograma el check | `service.luau:452-454` sólo hace `rebuild()` | benigno (el tick de 1 s recalcula `due`), pero un cambio de `check_hours` a la baja no dispara de inmediato |

No encontré evidencia de: fugas de procesos, escrituras fuera de `pluginDataDir`, uso de `io.*`/`os.*` fuera de `os.time`, ni llamadas a `ui.*` inexistentes. Los props usados existen todos en los sets del reconciler (`width/height/flexGrow/opacity/visible`, `fill/radius/border/borderWidth`, `label.maxLines/fontWeight/textAlign/fontSize`, `button.controlSize/selected/enabled/variant/glyph/tooltip`, `select.options/selectedIndex/onChange`, `scroll.gap/padding*`) — `src/ui/ui_tree_reconciler.cpp:485-560`; `key` se extrae antes de validar props (`src/scripting/plugin_bindings.cpp:503-519`), así que no genera warnings. En el log no hay ni un `has no prop` atribuible a este plugin.

### Ocultar el label del widget

Ya está resuelto a medias: `show_count = false` vacía el texto (`widget.luau:125-134`) y el glyph queda solo. Lo que **falta** para el estándar del repo nuevo (`show_label`, `README.md:33`):

1. renombrar/alias el setting a `show_label` (o mapear ambos) para paridad entre plugins;
2. `barWidget.setText("")` deja el hueco del label en algunas barras — si molesta, el camino es no llamar `setText` y usar sólo `setGlyph` cuando `show_label == false`;
3. nada de `visible=false` para "ocultar el label": eso esconde el widget entero (eso ya lo hace `hide_on_clean`).

### Panel flotante

Dos niveles:

1. **Gratis, sin tocar el manifest**: el host inyecta `panel_placement` (`src/scripting/plugin_panel_shell.cpp:96-113`), así que el usuario puede ponerlo flotante desde Ajustes. Pero `width=460, height=580` son fijos (`plugin.toml:71-72`): flotante queda un panel chico flotando.
2. **Patrón del repo (`panel_mode compact|float`)**: hace falta un **segundo `[[panel]]`** con `placement = "floating"` y tamaño grande, y que el widget elija `:panel` o `:float` al hacer `togglePanel` (`widget.luau:16, 162`).

   Trampa concreta detectada en la plantilla del repo nuevo: `templates/plugin.toml` declara los selects con `values = ["compact","float"]`, pero el manifest parser **sólo lee `options = [{ value, label_key }]`** (`src/scripting/plugin_manifest.cpp:266-296`; `values` sólo se usa en `visible_when`, `:314-321`). Con `values`, esos dos selects quedan sin opciones. El plugin `arch-audit` sí usa `options` (`plugin.toml:48-53`) y por eso funciona.

   Y con `height = "content"` (si se adopta) todo `ui.scroll` necesita `height` explícito, si no mide 0.

---

## Resumen ejecutivo

- Plugin de 1.970 líneas, correcto y funcionando: 3 entries con contrato global, estado compartido por `state` con nonce, caché en disco, read-only de verdad (cero `sudo`/`pkexec`/`runInTerminal`).
- Su única fuente es `arch-audit --json` + `pacman -Q`; **no sabe nada de actualizaciones** de repo ni de AUR, que es justo el hueco del plugin nuevo.
- Para el reemplazo: el CLI en Go (`b3l0w-widgets audit check --json`) debe absorber `arch-audit` + `pacman -Q` + `checkupdates` + `paru -Qua` + versión Noctalia/Umbriel (`--version` + `git ls-remote`) + plugins caídos (log, porque el host no lo persiste). Luau queda para render, state e IPC.
- "Actualizar todo" necesita `runInTerminal` para la parte root (no polkit), un estado `update{phase,steps}` en el service y orden fijo: pacman → AUR → plugins → CLI, con el propio plugin excluido del paso de plugins.
- `b3l0w status` no tiene `--json` y `b3l0w version` responde `dev`: sin eso, auditar el CLI propio no es respondible.
