# Auditoría: plugins Noctalia `containers` y `mini-docker`

- Fecha: 2026-11-01
- Rutas auditadas (solo lectura, **ningún archivo modificado**):
  - `/home/b3low-z3r0/.local/state/noctalia/plugins/materialized/community/containers`
  - `/home/b3low-z3r0/.local/state/noctalia/plugins/materialized/community/mini-docker`
- Host: Noctalia v5 (`plugin_api = 43` en ambos), CachyOS, `docker 29.9.2`, `podman` **no instalado**, `awk` → `gawk`, `luau-compile` limpio en los 7 `.luau`.
- Evidencia de runtime usada abajo: 1 contenedor real (`seanime`), `ss` con 10 sockets, `systemctl show '*.service'` con 438 líneas (60 unidades).
- Referencias cruzadas: skill `noctalia-plugin-development` y `strings /usr/bin/noctalia` (para claves de manifest soportadas por este build).

---

## 1. Manifest: entries, settings, panel

### 1.1 `containers` (`davinci13/containers`, v1.2.1)

Identidad y dependencias (`containers/plugin.toml`):

| Campo | Valor | Línea |
|---|---|---|
| id | `davinci13/containers` | 4 |
| version | `1.2.1` | 6 |
| plugin_api | `43` | 7 |
| dependencies | `awk, cut, docker, podman, ss, systemctl, xdg-open` | 10 |
| icon | `container` | 11 |

**Entries** (4):

| Entry | id | entry file | Línea |
|---|---|---|---|
| service | `service` | `service.luau` | 85-87 |
| widget | `bar` | `widget.luau` | 89-91 |
| panel | `panel` | `panel.luau` | 125-131 |
| shortcut | `shortcut` | `shortcut.luau` | 133-135 |

**Panel** (`plugin.toml:125-131`): `width = 480`, `height = 560`, `placement = "attached"`, `position = "auto"`. **No** declara `max_height`, `capture_keys`, `keyboard_focus`, `persistent`, `open_near_click`, ni `actions`.

**Settings de plugin** (top-level `[[setting]]`, todos con `label_key`/`description_key`):

| clave | tipo | default | extra | línea |
|---|---|---|---|---|
| `view_mode` | select | `table` | options `table` \| `cards` | 19-28 |
| `hide_missing_runtimes` | bool | `true` | — | 30-35 |
| `refresh_seconds` | int | `5` | min 1, max 300 | 37-44 |
| `show_stopped` | bool | `false` | — | 46-51 |
| `show_host_services` | bool | `true` | — | 53-58 |
| `open_host` | string | `localhost` | — | 60-65 |
| `command_prefix` | string | `""` | — | 67-72 |
| `browser_command` | string | `""` | — | 74-79 |

**Settings del widget** (`[[widget.setting]]`, plugin.toml:93-123):

| clave | tipo | default | opciones | línea |
|---|---|---|---|---|
| `glyph` | glyph | `container` | — | 94-97 |
| `label_format` | select | `web_and_total` | `web_and_total`/`web_only`/`total_only` | 99-109 |
| `show_label` | bool | `true` | — | 111-116 |
| `hide_when_empty` | bool | `false` | — | 118-123 |

El panel del shortcut no declara settings propios.

### 1.2 `mini-docker` (`8bury/mini-docker`, v1.0.7)

| Campo | Valor | Línea |
|---|---|---|
| id | `8bury/mini-docker` | 1 |
| version | `1.0.7` | 3 |
| plugin_api | `43` | 4 |
| dependencies | `docker` (solo) | 10 |
| icon | `brand-docker` | 7 |

**Entries** (3, **sin shortcut**):

| Entry | id | entry file | Línea |
|---|---|---|---|
| widget | `mini-docker` | `widget.luau` | 35-37 |
| panel | `manager` | `panel.luau` | 96-103 |
| service | `docker-service` | `service.luau` | 105-107 |

**Panel** (`plugin.toml:96-103`): `width = 860`, `height = 620`, `placement = "floating"`, `position = "center"`, `open_near_click = true`. Sin `max_height`/`capture_keys`/`keyboard_focus`/`persistent`/`actions`.

**Settings de plugin**:

| clave | tipo | default | extra | línea |
|---|---|---|---|---|
| `refresh_interval` | int | `5` | min 1, max 30 | 12-19 |
| `respect_socket_activation` | bool | `false` | — | 21-26 |
| `default_network` | string | `bridge` | — | 28-33 |

**Settings del widget** (`plugin.toml:39-94`):

| clave | tipo | default | opciones | línea |
|---|---|---|---|---|
| `show_count` | bool | `true` | — | 39-44 |
| `glyph_color` | select | `on_surface` | on_surface/primary/secondary/tertiary | 46-57 |
| `status_mode` | select | `always` | always/running_only/hidden | 59-69 |
| `active_color` | select | `tertiary` | primary/secondary/tertiary | 71-81 |
| `inactive_color` | select | `error` | error/on_surface_variant/primary/tertiary | 83-94 |

---

## 2. Claves de state compartidas y formato del payload

### `containers`

| Clave | Dirección | Formato | Evidencia |
|---|---|---|---|
| `snapshot` | service → widget/panel/shortcut | tabla anidada (abajo) | service 12, 779; widget 5, 76; panel 4, 473; shortcut 5, 18 |
| `refresh` | widget/panel → service (nonce entero incremental) | número | service 13, 831-833; widget 6, 85-86; panel 5, 47-49 |

Payload de `snapshot` (construido en `service.luau:721-780`):

```
{ total: int, running: int, web: int, updatedAt: epoch, runtimes: [ {
    id = "docker"|"podman"|"host",
    label: string (tr de panel.runtime.*),
    glyph: string, available: bool, errorKey: string,
    emptyKey: string, count: int, runningCount: int, webCount: int,
    containers: [ {
      key = "<runtime>:<name>" | "host:<pid>:<name>",
      id, name, image, state, status, runtime,
      running: bool, webCount: int, publishedCount: int, webUrl: string,
      ports: [ { hostIp, host, hostPort, containerPort, protocol,
                 url, internal?: true } ]
} ] } ] }
```

El panel usa `key/name/image/status/running/ports/webUrl`; `id`, `publishedCount` y `containerPort` no se usan en ninguna vista (ver §9).

### `mini-docker`

| Clave | Dirección | Formato | Evidencia |
|---|---|---|---|
| `docker_snapshot` | service → widget/panel | tabla plana (abajo) | service 5-17, 183-186; widget 4, 57; panel 3, 387 |
| `docker_command` | panel/widget → service | `{ action, requestId, ... }` | service 563; panel 67-79; widget 81 |
| `docker_action_result` | service → panel | `{ requestId, action, ok, message, exposedPort? }` | service 395-408; panel 403-422 |

```
docker_snapshot = { available, loading, busy, error, updatedAt, revision,
  runningCount, containers[], images[], volumes[], networks[] }
containers[i] = { id, name, image, state, status, ports(string crudo), created }
images[i]     = { repository, tag, name, id, size, created, isRunning }
volumes[i]    = { name, driver, mountpoint }
networks[i]   = { name, id, driver, scope, isDefault }
```

Ninguna clave está prefijada con el id del plugin (`snapshot`, `refresh`, `docker_snapshot`, `docker_command`): si `noctalia.state` fuese un espacio global compartido entre plugins, colisionan con cualquier otro plugin que use esos nombres. **No encontré evidencia** en el binario ni en docs locales de que el state esté namespaceado por plugin — riesgo abierto, no confirmado.

---

## 3. Acciones / IPC aceptadas y emitidas

### `containers`

- Service acepta **una sola** acción por dos vías:
  - `onIpc(event, payload)` → solo `event == "refresh"` (`service.luau:848-852`).
  - `state.watch("refresh")` → cualquier cambio del nonce dispara `refresh()` (`service.luau:831-833`).
  - CLI: `noctalia msg plugin davinci13/containers:service all refresh` (README:182).
- El service **no** expone start/stop/restart/logs: no hay tabla de acciones ni `[[actions]]` en el manifest.
- El panel emite: nonce `refresh` (`panel.luau:47-51`) y un shell-out `noctalia msg settings-open-plugin davinci13/containers` (`panel.luau:445-447`). Nada más.
- El widget emite: nonce `refresh` en right-click (`widget.luau:84-87`).
- El shortcut no emite nada; solo `noctalia.togglePanel` (`shortcut.luau:23-25`).

### `mini-docker`

- `onIpc` → solo `"refresh"` (`service.luau:585-589`).
- Acciones por `state.set("docker_command", …)` (`executeAction`, `service.luau:467-561`):

| action | args | comando | línea |
|---|---|---|---|
| `refresh` | `details: bool` | — (re-lanza `refreshAll`) | 471-474 |
| `inspect_image` | `image` | `docker image inspect --format '{{json .Config.ExposedPorts}}'` | 436-465 |
| `start_container` | `id` | `docker start <id>` | 485-486 |
| `stop_container` | `id` | `docker stop <id>` | 487-488 |
| `restart_container` | `id` | `docker restart <id>` | 489-490 |
| `remove_container` | `id` | `docker rm <id>` | 491-492 |
| `remove_image` | `id` | `docker rmi <id>` | 493-494 |
| `remove_volume` | `name` | `docker volume rm <name>` | 495-496 |
| `remove_network` | `name`+`id` | `docker network rm <id>` (rechaza bridge/host/none) | 497-503 |
| `run_image` | `image,name,network,port,environment[]` | `docker run -d [--name][-e][-p P:P][--network] <image>` | 504-546 |
| (desconocida) | — | `actionResult(ok=false, "Unknown Docker action: …")` | 548-551 |

- Emite `docker_snapshot` (`183-186`) y `docker_action_result` (`395-408`).
- Panel emite `docker_command` con `requestId = "panel-<n>"` (`panel.luau:62-79`) y consume `docker_action_result` (`403-422`).
- Widget emite `docker_command` con `requestId = "widget-<n>"` (`widget.luau:79-83`).
- Guard de concurrencia: `actionBusy` → `result.command_busy` (`service.luau:437-441`, `479-482`).

---

## 4. Binarios externos y comandos exactos

### `containers`

| Comando | Flags | Línea |
|---|---|---|
| `docker ps` | `--format '{{json .}}'`, `-a` si `show_stopped` | service 463-471 |
| `podman ps` | `--format json`, `-a` idem | service 464-471 |
| `<cli> ps -q` | (probe interno) | service 426 |
| `<cli> inspect -f '{{.State.Pid}}|{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}|{{.Name}}' <id>` | una vez **por contenedor** | service 427 |
| `cut -d'|' -f1..3`, `printf`, `echo`, `case` | — | service 428-435 |
| `awk 'FNR>1 && $4=="0A" {… strtonum("0x" a[2])}' /proc/<pid>/net/tcp /proc/<pid>/net/tcp6` | requiere **gawk** (`strtonum`) | service 433 |
| `ss -ltnpH` (fallback `ss -ltnp`), errores a `/dev/null` | `-l -t -n -p -H` | service 448-450 |
| `systemctl show --no-pager --property=Id --property=Description --property=SubState --property=MainPID '*.service'` | — | service 452 |
| `systemctl --user show …` (mismas propiedades) | — | service 454 |
| `xdg-open '<url>'` o `<browser_command> '<url>'` | `shellQuote` | panel 20-39 |
| `noctalia msg settings-open-plugin davinci13/containers` | — | panel 446 |

- `command_prefix` (p. ej. `sudo -n`) se aplica a `ss` (448-450) y a `docker`/`podman` (457-463), **no** a los dos `systemctl` (452-454) — contradice README:75 y README:115 ("That prefix applies to every lookup the plugin runs").
- Timeout: **ninguno**. `noctalia.runAsync(cmd, cb)` sin tercer argumento (`service.luau:807`).
- Verificado en esta máquina: el probe interno devuelve `seanime|172.18.0.2|43213,43211,43213,` (puerto 43213 **duplicado**, ver §9).

### `mini-docker`

| Comando | Flags | Línea |
|---|---|---|
| `docker ps -a` | `--format '{{json .}}'` | 350 |
| `docker images` | `--format '{{json .}}'` | 327 |
| `docker volume ls` | `--format '{{json .}}'` | 328 |
| `docker network ls` | `--format '{{json .}}'` | 329 |
| `docker image inspect` | `--format '{{json .Config.ExposedPorts}}'` | 443 |
| `docker start/stop/restart/rm/rmi` | `<id>` | 485-494 |
| `docker volume rm` / `docker network rm` | `<name>` / `<id>` | 495-503 |
| `docker run` | `-d --name -e -p --network` | 521-545 |
| `docker context inspect` | `--format '{{.Endpoints.docker.Host}}'` | 54 |
| `systemctl is-active --quiet docker.service` / `--user …` | — | 64, 66 |
| `id -u` | — | 61 |

- Args pasados por `shellQuote` y unidos por espacio (`37-50`): no hay argv-table, todo va como string.
- Timeouts: `30 000 ms` para refresh (`50`), `60 000 ms` para acciones (`555`), `3 000 ms` para el chequeo de daemon (`77`). Verificado que el build soporta el 3.er argumento: `strings /usr/bin/noctalia` expone `process::runAsync(..., RunOptions)` (la nota "no hay tercer argumento de timeout" de la skill está desactualizada para este build).

---

## 5. Funcionalidad visible de `containers`, pantalla por pantalla

### 5.1 Bar widget (`widget.luau`)

- Glifo configurable (`setGlyph`, 45) + texto `"<web> / <total>"` (56), `"<web>"` (52) o `"<total>"` (54) según `label_format`; con `show_label=false` → texto vacío (59).
- Tooltip como filas clave/valor: `Web UI`, `Total`, una fila por runtime (`runtimeSummary`, 15-24) y la pista de click (26-39).
- `setVisible(not (hide_when_empty and total == 0))` (62).
- Click → `togglePanel("davinci13/containers:panel")` (83). Right-click → bump del nonce de refresh (84-87).

### 5.2 Panel (`panel.luau`)

- Header (348-405): glifo + título "Containers" + resumen `"<web> / <total> with a web UI"` (303-311); 4 botones fantasma: toggle tabla/tarjetas (368-376), Options → settings del plugin (377-385), Refresh (386-394), Close (395-403).
- Buscador (406-415): filtra por nombre, imagen y puertos (`matchesSearch`, 53-64).
- Cuerpo `ui.scroll` (417) con una sección por runtime (242-301): banda con glifo + label + `"<n> containers"` (248-268), separador entre secciones (327-332), fila de error ("not installed" / "daemon not reachable" / "query failed") o de vacío (271-291).
- Fila **tabla** (87-158): punto `●`/`○` (100-101), nombre en 135 px (124-134), segunda línea `imagen · status` (102-105, 135-142), chips de puerto (máx. 4 + `"+N"`, 88-98). Click en la fila → primera URL (119-121); click en chip → esa URL (82); right-click en chip → copia al portapapeles (83, 41-45).
- Fila **tarjeta** (160-240): mismo contenido en columna, nombre/imagen con `maxWidth`, status aparte si está parado (197-206).
- Footer con la pista de uso (419-426).

**Qué muestra por contenedor**: nombre, estado (punto + `Status` crudo de docker, p. ej. `Up 4 hours (healthy)`), imagen, puertos publicados `host->container` con URL clickeable, y puertos internos del contenedor (chip `outline` + tooltip "inside the container", 76-81).
**Qué NO muestra**: salud como campo propio (`HealthStatus` se ignora), uptime (`RunningFor` se ignora), tamaño, mounts, redes, labels, created, logs, y **ninguna acción** (start/stop/restart/rm/exec).

### 5.3 Shortcut (control center, `shortcut.luau`)

Label `"Containers  <web>"`, icono `container`, `setActive(web > 0)`, click → toggle del panel (9-25).

---

## 6. Funcionalidad visible de `mini-docker`

### 6.1 Bar widget (`widget.luau`)

- Un solo árbol `barWidget.render`: glifo `brand-docker` con color configurable (28-32), contador de **running** si `show_count` (34-40), punto de 7×7 px con `active_color`/`inactive_color` según `status_mode` (41-48), en columna si la barra es vertical (50-51).
- Tooltip: `"Running containers: N"` o `"Docker is not available"` (52-54).
- Click → panel si `available`, si no `notifyError` (71-77). Right-click → `docker_command{action=refresh}` + toast (79-83). `setUpdateInterval(5000)` fijo (64).

### 6.2 Panel (`panel.luau`) — 4 pestañas

- Header: glifo, "Mini Docker", Refresh, cerrar (340-346). Fila de pestañas + hora de última actualización (347-358). Filas de estado: loading / busy / error / feedback (321-333, 359).
- **Containers** (214-219): resumen `nombre · imagen · status` (170); detalles `Image/Status/Ports` (144-148); acciones Start / Stop / Restart / Remove con enable según `state == "running"`; Remove solo si está parado.
- **Images** (220-222): `nombre · size · created`; detalles `ID/Size/Created`; Run (abre formulario) y Remove (deshabilitado si `isRunning`).
- **Volumes** (223-224): `nombre · driver · mountpoint`; detalles `Driver/Mountpoint`; Remove.
- **Networks** (225-226): `nombre · driver · scope`; detalles `ID/Driver/Scope`; Remove deshabilitado para `bridge`/`host`/`none` (`isDefault`).
- Formulario Run (259-308): título "Run <imagen>", nombre opcional, select de red (default de `default_network`), toggle "Publish a port", puerto (precargado por `guessPort`, 81-90, o por `docker image inspect` 436-465), variables de entorno multilínea `KEY=value`, error inline y Cancel/Run.
- Detalle de selección (207-235): toolbar con título + botones dentro de `fill = "surface_container/0.45"`.

**Qué tiene**: containers (con acciones), imágenes, volúmenes, redes, run de imagen.
**Qué NO tiene**: URL de UI web, chips de puerto navegables, salud, uptime formateado, logs, exec, host services, podman, compose, pull de imágenes, stats, búsqueda, selección múltiple.

---

## 7. Tabla comparativa (base de la fusión)

| Feature | containers | mini-docker |
|---|---|---|
| Service + widget + panel | ✅ | ✅ |
| Shortcut / tile de control center | ✅ (`shortcut.luau`) | ❌ |
| Podman | ✅ | ❌ |
| Host services (ss + systemctl) | ✅ | ❌ |
| Puertos parseados + URL clickeable | ✅ | ❌ (string crudo) |
| Puertos internos del contenedor (/proc) | ✅ | ❌ |
| Copiar URL al portapapeles | ✅ | ❌ |
| Abrir en navegador / `browser_command` | ✅ | ❌ |
| Buscador | ✅ | ❌ |
| Vistas tabla/cards | ✅ | ❌ (lista única) |
| start / stop / restart / rm contenedor | ❌ | ✅ |
| rm imagen / volumen / red | ❌ | ✅ |
| Run de imagen (form UI) | ❌ | ✅ |
| Inspección de ExposedPorts | ❌ | ✅ |
| Tabs por recurso (images/volumes/networks) | ❌ | ✅ |
| Estado busy + `docker_action_result` | ❌ | ✅ |
| Detección "docker missing" | ✅ (`commandExists`, 111-117) | ✅ (220-235) |
| Detección daemon caído | ✅ (`exitCode != 0`, 699-707) | ✅ (+ `respect_socket_activation`) |
| Panel flotante grande | ❌ (`attached` 480×560) | ✅ (`floating` 860×620) |
| Hide when empty | ✅ | ❌ |
| Formato de label en barra | ✅ 3 formatos | ❌ (solo contador on/off) |
| Color de glifo/indicador | ❌ | ✅ 4 selects |
| Intervalo configurable | ✅ 1-300 s | ✅ 1-30 s |
| Click derecho en widget | refresh silencioso | refresh + toast |
| Health / uptime / logs / exec / stats | ❌ | ❌ |
| i18n | solo `en.json` | solo `en.json` |

---

## 8. Trabajo caro en Luau que conviene delegar a un CLI en Go

Medido en esta máquina: `docker ps` 42 ms, probe interno 62-81 ms **con 1 contenedor**, `ss` 19 ms, `systemctl show` 146 ms. El costo caro no es el wall-time de los comandos sino el **parseo por fila dentro de callbacks con presupuesto de 25 ms de CPU**.

1. **Parseo de `docker ps` / `podman ps`** — `containers/service.luau:382-411`. Una fila NDJSON por contenedor, `noctalia.json.decode` completa (una fila real de `seanime` mide **1 273 bytes**, dominada por `Labels` y `Mounts` que nadie usa). Go puede leer el stream, ignorar `Labels/Mounts/Command/Size` y emitir ya normalizado.
2. **Parser de `Ports`** — `service.luau:161-235`: split por comas, `->`, IPv6 entre corchetes, rangos `8000-8005` con cap de 64, dedupe, `hostIp` wildcard → `open_host`, scheme https solo en 443. Es lógica pura y la más propensa a bugs (§9): tiene que vivir en un binario testeable.
3. **Probe de puertos internos** — `service.luau:422-440`: `ps -q` + **un `docker inspect` por contenedor** + 2 lecturas `awk` de `/proc/<pid>/net/tcp{,6}` + `cut`. Con Go se resuelve sin subprocesos por ítem (leer `/proc/<pid>/net/tcp` directo, sin `inspect`), y desaparece la dependencia de `gawk`/`strtonum`.
4. **Parseo de `systemctl show '*.service'`** — `service.luau:532-555`: **438 líneas** (60 unidades: 27 running / 33 exited) cada 5 s, convertidas a `byPid` con `string.match` por línea, más el mismo trabajo para `--user` (144 líneas). Un CLI puede devolver solo `{pid, unit, description}` de las unidades running.
5. **Parseo de `ss -ltnp`** — `service.luau:486-529`: 10 sockets aquí, agrupados por pid, dedupe por puerto, preferencia loopback/wildcard, filtro link-local/zone, filtro `HOST_SKIP_PROCESSES`. Toda esa política es de binario, no de UI.
6. **Agregación y orden** — `service.luau:592-627` (sort de entradas y bindings) y `721-780` (conteos total/running/web por runtime). Trivial en Go, y evita republicar el snapshot completo en cada tick.
7. **mini-docker: máquina de estados de decodificación** — `mini-docker/service.luau:83-121`: el propio autor documenta que Noctalia aborta el callback a las **~40-70 filas** decodificadas, y por eso decodifica 25 filas por tick de 50 ms. Ese `decodeQueue` + `setUpdateInterval(50)` + restauración de intervalo desaparece si un CLI entrega `{containers, images, volumes, networks}` compacto en **una** llamada.
8. **mini-docker: 4 invocaciones secuenciales por refresh con detalles** — `service.luau:326-350` (`ps -a`, `images`, `volume ls`, `network ls`) encadenadas una tras otra; un CLI las corre y agrega.
9. **mini-docker: `markRunningImages` O(imágenes × contenedores)** — `service.luau:168-181`, comparando nombre/repo/`id:sub(1,12)` a mano. Es un join, va en Go.
10. **URLs y shell quoting** — `containers/service.luau:86-88,134-145` y `mini-docker/service.luau:33-43`: construir URLs y escapar args es lógica de binario; en Luau ya produjo un bug (§9, `[::]`).

---

## 9. Bugs, límites y código muerto

### Confirmados por ejecución / lectura

1. **Chips de puerto duplicados en `containers`** — `service.luau:215-220` divide `Ports` por comas sin deduplicar por `hostPort`, y `panel.luau:66-71` usa `key = "port_"..hostPort`. Docker publica dual-stack por defecto: el contenedor real devuelve `"0.0.0.0:43211->43211/tcp, [::]:43211->43211/tcp"` → dos chips idénticos `43211`, **con la misma `key` en el mismo padre** (colisión en el reconciler) y `webCount = 2`. Reproducible en cualquier publish v4+v6. El camino de host sí deduplica (`service.luau:576-588`), el de contenedor no.
2. **Puertos internos duplicados** — `parseInternal` (`service.luau:365-380`) concatena todos los números sin dedupe; el probe real devolvió `43213,43211,43213,` porque `awk` lee `tcp` **y** `tcp6`. Todo contenedor que escuche en wildcard v4+v6 mostrará el chip dos veces.
3. **`awk` sin `strtonum` falla en silencio** — `service.luau:433` con `2>/dev/null`; en sistemas con `mawk` (o sin gawk) el probe devuelve vacío y el feature "container-only ports" simplemente no aparece, sin log ni error. README:199 lo reconoce como requisito, el código no lo verifica (`commandExists("gawk")` no se consulta).
4. **Sin timeout en `containers`** — `service.luau:807`: si `docker ps` cuelga (daemon bloqueado/socket colgado), `outstanding` nunca baja y `refresh()` sale siempre por el guard de `792-794` → el panel queda **congelado con datos viejos para siempre**, sin error visible. `mini-docker` sí pasa timeout (30 s/60 s).
5. **`command_prefix` no cubre `systemctl`** — `service.luau:448-450` prefija `ss`, `457-463` prefija `docker/podman`, pero `452-454` no. Contradice README:75 y README:115.
6. **Cap de rango off-by-one** — `service.luau:151-153`: `if high - low > MAX_PORT_RANGE then high = low + MAX_PORT_RANGE` produce **65** puertos (low..low+64) con un "capped at 64" declarado (README:133-134).
7. **`generation`/`mine` es código muerto** — `service.luau:40, 798-799, 808-810`: `refresh()` retorna si `outstanding > 0` (792), así que `generation` no puede cambiar mientras hay callbacks en vuelo; el guard nunca descarta nada. Si algún día se permite refresh concurrente, el `return` de 809 **no llama a `finish()`** y `outstanding` queda trabado.
8. **Rama muerta en el handler de host** — `service.luau:690-697`: `… or numberOr(result.exitCode, 1) == 0 then return end` hace que, con `ss` OK, nunca se llegue al bloque de error de `699-707` para el runtime host; las dos primeras condiciones son irrelevantes.
9. **`publishedCount` / `container.id` sin consumidor** — `service.luau:307, 318` + `countPublished` (251-259): ningún entry lee `publishedCount` ni `id` (grep en widget/panel/shortcut sin resultados). `countPublished` existe solo para alimentar ese campo muerto.
10. **`script:gsub("@@MARK@@", …)` inútil** — `service.luau:438`: no hay `@@MARK@@` en el script (425-437).
11. **`hide_missing_runtimes` no llega al service** — `readSettings` (`service.luau:90-97`) no lo lee; el service sigue lanzando `docker`/`podman` aunque el usuario haya ocultado el runtime en el panel (`panel.luau:435`). Solo afecta costo, no corrección.
12. **`viewMode` no persiste** — `panel.luau:449-452` cambia el modo en memoria; `onOpen` vuelve a `loadConfig()` (`459-463`), así que el toggle se pierde al cerrar y contradice el setting `view_mode` como "Default view layout".
13. **`onOptions` con id hardcodeado** — `panel.luau:446`: `davinci13/containers`. En una fusión con otro id, el botón abre los settings del plugin equivocado.
14. **Inconsistencia de clave de vacío** — `service.luau:763` usa `panel.empty.body` como default; `widget.luau:18` usa `panel.empty.title` para el mismo caso.
15. **mini-docker: `run_image` publica `-p P:P` fijo** — `service.luau:537-540`: no hay mapeo host→contenedor pese a que el label dice "Host and container port" (`translations/en.json:64`). Además el puerto sugerido por `guessPort` para nginx/apache es `80` (`panel.luau:87`), que en rootless falla por privilegio.
16. **mini-docker: validación duplicada** — `service.luau:513-520` repite exactamente lo que valida el panel (`panel.luau:509-521`); dos fuentes que pueden divergir.
17. **mini-docker: widget con intervalo fijo** — `widget.luau:64` `setUpdateInterval(5000)` ignora `refresh_interval` (1-30 s) y re-renderiza cada 5 s aunque el snapshot no cambie (`update()` → `render()`, 67-69), duplicando el trabajo del `state.watch` de 57-62.
18. **mini-docker: `itemTitle` es un no-op ramificado** — `panel.luau:129-133`: las tres ramas devuelven `item.name`.
19. **mini-docker: sin `onClose`** — `panel.luau:437` cierra con `panel.close()` pero no hay `onClose` que apague `panel.setWantsSecondTicks(true)` (`424`), a diferencia del patrón de `github-kanban/panel.luau:1158-1163`.
20. **mini-docker: claves de i18n muertas** — `panel.showing_limit`, `panel.image_in_use`, `panel.image_unused`, `actions.select`, `actions.close`, `colors.success` (`translations/en.json:36-37, 44, 9, 4, 19`) no se referencian en ningún `.luau`.
21. **mini-docker: `checkDaemonActive` es un falso negativo posible** — `service.luau:63-66`: si el daemon se activa por **socket** (`docker.socket`), `systemctl is-active docker.service` da `inactive` y el plugin reporta "docker unreachable" aunque Docker funcione. Además depende de `$HOME`/`$XDG_RUNTIME_DIR` en el entorno del service (65).
22. **mini-docker: `snapshot` se republica por referencia** — `service.luau:183-186` muta y re-setea la **misma** tabla; el panel compara `value.revision ~= snapshot.revision` (`panel.luau:389-393`) contra su copia. Si el state entrega la misma referencia, la comparación es siempre falsa y `dirty` no se activa por cambio de datos (solo por `feedback`/estado inicial). No pude confirmarlo sin inspeccionar el state del host: **riesgo, no bug probado**.
23. **Ruido del auditor** (falsos positivos, para no perseguirlos): `audit_plugin.py` marca `shortcut`, `render`, `onRefresh` etc. como "fuera de alcance" porque no modela las globales del host ni los callbacks por nombre (`onClick = "onRefresh"`). Los 7 `.luau` compilan limpio con `luau-compile --binary` (exit 0).

### Límites estructurales (no bugs)

- Sin `[[actions]]` en ninguno de los dos manifests → ninguno expone acciones al sistema de acciones del host.
- Ninguno declara `capture_keys`: no hay `onKey`, así que no hay navegación por teclado en la lista.
- Ninguno declara `keyboard_focus` (`strings /usr/bin/noctalia` lista la clave como válida): el foco de teclado al abrir no está definido, lo que afecta al buscador de `containers` (406-415) y a los inputs del formulario de `mini-docker` (267-300).
- Solo `en.json` en ambos; sin `es.json` (paridad i18n incompleta para el resto del ecosistema).

---

## 10. Qué falta para (a) ocultar el label del icono y (b) abrir un panel flotante grande

### (a) Ocultar el label del icono en la barra

- **`containers`: ya está resuelto.** `show_label` (bool, default `true`) en `plugin.toml:111-116`; `widget.luau:48-60` hace `barWidget.setText("")` y deja solo el glifo (`setGlyph` en 45). No falta nada de API.
- **`mini-docker`: resuelto por partes, no con un switch.** `show_count = false` (`plugin.toml:39-44`, `widget.luau:34`) oculta el número; el punto de estado queda y se quita con `status_mode = "hidden"` (`plugin.toml:59-69`, `widget.luau:20-25`). Falta **una** opción "solo icono" que combine ambas.
- **Para el plugin fusionado**: dos estilos incompatibles, hay que elegir uno —
  - imperativo (containers): `barWidget.setGlyph()` + `barWidget.setText(show_label and label or "")` + `barWidget.setVisible()`;
  - declarativo (mini-docker): `barWidget.render(ui.row/column{...})` y omitir el nodo `ui.label` cuando `show_label` es falso. Con este estilo el "label" es simplemente un hijo del árbol: no hay API nueva que agregar.
- **No encontré evidencia** de un ajuste de barra a nivel Noctalia que oculte el label de un widget puntual; el control es plugin-side.

### (b) Panel flotante grande

- **`containers` sí declara placement, pero no el que hace falta**: `placement = "attached"`, `position = "auto"`, `width = 480`, `height = 560` (`plugin.toml:125-131`). Además el alto está **duplicado en código**: `ROOT_HEIGHT = 560` (`panel.luau:7`) aplicado como `height` del `ui.column` raíz (`panel.luau:347`), así que subir el manifest sin tocar el Luau deja el árbol a 560 px dentro de una superficie más alta.
- **`mini-docker` ya es el patrón correcto**: `placement = "floating"`, `position = "center"`, `860×620`, `open_near_click = true` (`plugin.toml:96-103`), y el árbol raíz usa `flexGrow = 1` sin alto fijo (`panel.luau:340`), con `ui.scroll{flexGrow=1}` adentro (337).
- **Para la fusión, lo que falta**:
  1. `[[panel]]` con `placement = "floating"`, `position = "center"`, `width` 860-1000, `height` 620-700;
  2. borrar `ROOT_HEIGHT` y el `height` fijo de `panel.luau:7,347` (usar `flexGrow`, como mini-docker);
  3. opcional `height = "content"` + `max_height` — **restringido por el host**: `strings /usr/bin/noctalia` → `': max_height requires height = "content"'` y `': height = "content" requires max_height'`; viable porque ambos plugins ya son `plugin_api = 43` (requiere ≥42);
  4. opcional `open_near_click = true`, `keyboard_focus`, `persistent = true` — el binario exige `persistent = true requires placement = "floating"`, y `width/height "fill" requires placement = "floating"` (mismas strings).
- **Matiz importante**: según la skill `noctalia-plugin-development`, `placement`/`position`/`open_near_click`/`layer` son **defaults** que el host inyecta como settings del entry, así que el usuario puede cambiar el placement desde Ajustes sin editar el manifest — pero el **tamaño** (480×560) solo cambia en `plugin.toml`.

---

## 11. Animaciones

- **`containers`**: no usa `onFrameTick` ni `panel.setNeedsFrameTick` ni `panel.setWantsSecondTicks`. Todo es reactivo por `state.watch` (`panel.luau:473-476`) y `update()` del widget (`widget.luau:81`). El único "timing" es `noctalia.setUpdateInterval(1000)` + `tickCount % intervalTicks()` en el service (`service.luau:26, 828, 835-841`). **Sin animaciones.**
- **`mini-docker`**: tampoco usa `onFrameTick`. Usa `panel.setWantsSecondTicks(true)` (`panel.luau:424`) más `update()` que re-renderiza solo si `dirty` (`431-435`). **Sin animaciones.**
- Referencia de cómo se haría en este build: `github-kanban/panel.luau:1165-1168` (`onFrameTick(_deltaMs)`) con `panel.setNeedsFrameTick(true/false)` (`1161`, `1188`). La API declarativa no tiene transiciones: la animación se escribe a mano en `onFrameTick` y hay que tener en cuenta que cada tick fuerza un repaint completo y que `setNeedsFrameTick(false)` es una puerta de una sola dirección.

---

## Anexo: verificación ejecutada (comandos y resultados)

```
luau-compile --binary *.luau            → exit 0 en los 7 archivos
docker --version                        → 29.9.2
docker ps -a --format '{{json .}}'      → 1 contenedor (seanime, running, healthy,
                                          "0.0.0.0:43211->43211/tcp, [::]:43211->43211/tcp",
                                          RunningFor "36 hours ago", HealthStatus "healthy")
claves del JSON de docker ps            → Command, CreatedAt, HealthStatus, ID, Image, Labels,
                                          LocalVolumes, Mounts, Names, Networks, Platform,
                                          Ports, RunningFor, Size, State, Status
probe interno (script literal de 422-440) → "seanime|172.18.0.2|43213,43211,43213,"
ss -ltnpH                               → 10 sockets, solo 3 con users:() (no-root)
systemctl show '*.service'              → 438 líneas, 60 unidades (27 running / 33 exited)
tiempos                                 → docker ps 42 ms · probe interno 62-81 ms · ss 19 ms ·
                                          systemctl 146 ms
awk strtonum("0x1F90")                  → 8080 (awk → gawk en esta máquina)
```
