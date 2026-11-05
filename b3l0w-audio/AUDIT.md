# Auditoría — plugin Noctalia `blackbartblues/audio-switcher` v0.6.3

**Fecha:** 2026-11-01 03:43 EST
**Ruta auditada:** `/home/b3low-z3r0/.local/state/noctalia/plugins/materialized/community/audio-switcher`
**Entorno:** CachyOS, kernel 7.3.0-4, Noctalia `v5.4.1 (5.4.1-41-gf2cebd97e)`, PipeWire 1.6.10 (Arch `1:1.6.10-1`), WirePlumber 0.5.18, libpulse 17.0 (`pactl 17.0-134-g77d25`), BlueZ 5.87.
**Modo:** sólo lectura. No se modificó el plugin ni la configuración de audio. No se conectó ningún dispositivo Bluetooth.

Todas las referencias `archivo:línea` son relativas al directorio del plugin.

---

## 1. Archivos, entries y settings

| Archivo | Líneas | Rol |
|---|---|---|
| `plugin.toml` | 83 | manifest: 5 settings, widget, panel, launcher_provider, service |
| `service.luau` | 1526 | backend: único dueño de procesos `pactl`/`bluetoothctl`, publica snapshot |
| `panel.luau` | 633 | UI declarativa `ui.*`, sólo publica requests por state |
| `widget.luau` | 74 | widget de barra (glyph + texto + tooltip) |
| `launcher.luau` | 33 | provider del launcher (`/audio`) |
| `translations/en.json`, `tr.json` | 161 / 138 | i18n (no hay `es.json`) |
| `tests/*.lua` | 5 archivos | tests con stub de `noctalia` (dofile + asserts) |
| `README.md`, `thumbnail.webp`, `screenshots/panel.webp` | — | docs/asset |

### Manifest (`plugin.toml`)

- `id = "blackbartblues/audio-switcher"` (`:1`), `version = "0.6.3"` (`:3`), `plugin_api = 43` (`:4`).
- **`deprecated = true`** (`:7`) — el catálogo lo marca obsoleto.
- `dependencies = ["pactl", "bluetoothctl", "sleep"]` (`:11`). `sleep` como dependencia es por el polling BT (`service.luau:1007`).
- `icon = "switch-horizontal"` (`:8`), tags `audio/bar/hardware/launcher/panel/service/system/utility` (`:10`).

### Settings (5, todos con `label_key`/`description_key`)

| key | tipo | default | rango | línea |
|---|---|---|---|---|
| `show_percentage` | bool | true | — | `:13-18` |
| `show_notification_on_switch` | bool | true | — | `:20-25` |
| `show_actions_in_tooltip` | bool | true | — | `:27-32` |
| `refresh_interval_seconds` | int | 60 | 10–600, step 10 | `:34-42` |
| `panel_refresh_interval_seconds` | int | 5 | 1–60, step 1 | `:44-52` |

Uso: `show_percentage` → `widget.luau:50`; `show_actions_in_tooltip` → `widget.luau:54`; `show_notification_on_switch` → `service.luau:860`; intervalos → `service.luau:1457-1477` (`setUpdateInterval`).

### Entries

```toml
[[widget]]            id="widget" entry="widget.luau"                      (:54-56)
  [widget.actions]    scroll_up="volume-up"  scroll_down="volume-down"
                      left="panel-toggle blackbartblues/audio-switcher:audio-switcher"
                      right="plugin blackbartblues/audio-switcher:service all cycle-output"
                      middle="plugin blackbartblues/audio-switcher:service all cycle-input"   (:58-63)

[[panel]]             id="audio-switcher" entry="panel.luau"
                      width=620 height=650 placement="attached"
                      position="top_right" open_near_click=true            (:65-72)

[[launcher_provider]] id="launcher" entry="launcher.luau" prefix="audio"
                      glyph="switch-horizontal" include_in_global_search=true  (:74-79)

[[service]]           id="service" entry="service.luau"                    (:81-83)
```

`volume-up`/`volume-down` son acciones válidas del host (aparecen en el binario: `strings /usr/bin/noctalia | grep '^volume-up'` → `error: volume-up accepts at most one optional [step]`).

### Hallazgos de manifest
- **Sin `capture_keys`** (`:65-72`): el panel no recibe teclas; no hay atajos más allá de Escape/foco.
- `height = 650`, `width = 620` fijos. `plugin_api = 43` permitiría `height = "content"` + `max_height`.
- `settings.scroll_step` existe en `translations/en.json:116` y `tr.json:93` pero **no** está declarado como `[[setting]]` ni se lee en código (0 ocurrencias en `*.luau`) → clave muerta de una versión anterior. Igual `widget.tooltip` (el tooltip se arma por partes en `widget.luau:52-60`).
- No hay `es.json`; sólo `en` + `tr`.

---

## 2. Modelo de datos, state keys e IPC

Claves (`service.luau:6-9`, `panel.luau:3-6`):

| clave | escritor | consumidor | contenido |
|---|---|---|---|
| `audio_switcher_snapshot` | service (`publishSnapshot` `:538-543`) | panel, widget | `available, bluetoothAvailable, loading, busy, scanning, outputs[], inputs[], bluetooth[], defaultOutputId, defaultInputId, outputVolume, inputVolume, outputMuted, inputMuted, error, updatedAt, revision` (`:32-50`) |
| `audio_switcher_command` | panel (`panel.luau:60-67`) + `onIpc` | service (`service.luau:1506-1508`) | `{ action, requestId, ...campos }` |
| `audio_switcher_result` | service (`:545-552`) | panel (`:614-631`) | `{ requestId, action, ok, message }` |
| `audio_switcher_panel_open` | panel (`:489`, `:495`) | service (`:1509-1512`) | bool → cambia el intervalo de refresco |

`revision` se incrementa en cada publish (`:541`) pero **nadie lo lee**.

Shape de device de salida (`service.luau:285-303`): `id, targetName, name, description, active, available, bluetooth, address, hidden, slot, volume, muted, icon, iconStyle, group, groupModuleId, groupMembers`.
Device de entrada (`:326-344`): idem + `ports[], activePort, activePortDescription`.

IDs estables: `bluetooth:<MAC>:output|input` (`:179-189`), si no el nombre PulseAudio (`alsa_output...`).

Preferencias persistidas en `pluginDataDir()/preferences.json` (`:19-20`, carga `:147-160`, guardado `:162-177`): `aliases, hiddenOutputs, hiddenInputs, slots, knownBluetoothInputs, icons`.

### IPC (`service.luau:1438-1455`)

| evento | payload | efecto |
|---|---|---|
| `cycle-output` | — | `cycleDevice("output")` |
| `cycle-input` | — | `cycleDevice("input")` |
| `connect` | nº de slot (1–99) | resuelve MAC por slot (`findAddressBySlot` `:1198-1205`) → `connectBluetooth` |
| `refresh` | — | `refreshAll()` |

Las acciones internas (`executeCommand` `:1386-1428`) son 18: `refresh, set_output, set_input, set_input_port, create_output_group, remove_output_group, cycle_output, cycle_input, connect_bluetooth, disconnect_bluetooth, scan_bluetooth, set_alias, set_hidden, set_slot, update_device, set_output_volume, set_input_volume, toggle_output_mute, toggle_input_mute`.

> No hay acción `open_screen` ni `set_card_profile`: el contrato panel↔service está cerrado a lo que lista `:1386-1428`.

---

## 3. Cómo enumera los dispositivos

Cadena completa en `loadAudio` (`service.luau:656-733`). Comandos exactos, con `env LC_ALL=C` antepuesto (`runPactl` `:109-113`) y quoting propio (`shellQuote` `:82-84`):

1. `env LC_ALL=C pactl -f json info` → `default_sink_name`, `default_source_name`, `server_name` (`parseInfo` `:355-363`).
2. `env LC_ALL=C pactl list short modules` → detecta grupos `module-combine-sink` (`parseOutputGroups` `:369-387`).
3. `env LC_ALL=C pactl -f json list sinks` → `snapshot.outputs` (`parseOutputs` `:389-401`).
4. `env LC_ALL=C pactl -f json list sources` → `snapshot.inputs` (`parseInputs` `:403-415`).

Bluetooth (`loadBluetooth` `:735-785`):
5. `bluetoothctl devices` → `Device <MAC> <Nombre>` (`parseBluetoothDeviceLines` `:417-426`).
6. `bluetoothctl info <MAC>` **por cada dispositivo, en serie** (`:776`) → `parseBluetoothInfo` (`:432-479`).

**Nunca** usa `pactl list cards`, ni `pw-dump`, ni `wpctl`, ni `pw-cli` (0 ocurrencias verificadas).

### Campos parseados

`makeOutput` (`:277-304`) / `makeInput` (`:306-345`):
- nombre: `properties["device.alias"]` → `item.description` → `item.name` (`:282`, `:314`), luego alias de usuario (`displayName` `:191-194`).
- BT: `properties["api.bluez5.address"]`, con fallback `device.bus == "bluetooth"` + `device.string` (`:269-275`).
- default: `item.name == info.default_sink_name` (`:290`, `:331`).
- volumen: `firstVolumePercent(item.volume)` (`:207-216`) — toma el **primer canal que devuelve `pairs()`** y parsea `value_percent` (`"115%"`).
- mute: `item.mute == true`.
- puertos de entrada: `parseInputPorts` (`:246-266`) — `item.ports[]` con `name/description/availability`, activo según `item.active_port` (acepta string o `{name=...}`), `available = availability ~= "not available"`.
- ícono: `device.icon_name` no se usa; se infiere por `resolvedDeviceIcon` (`:196-205`) con 4 estilos (`speaker, over_ear, tws, wired`).
- fuentes monitor se descartan (`:308`: `device.class == "monitor"` o nombre `*.monitor`).

### Verificación contra la máquina real

```
$ pactl info
Server Name: PulseAudio (on PipeWire 1.6.10)
Default Sink: alsa_output.pci-0000_00_1f.3.analog-stereo
Default Source: alsa_input.pci-0000_00_1f.3.analog-stereo

$ pactl list short sinks
55  alsa_output.pci-0000_00_1f.3.analog-stereo  PipeWire  s32le 2ch 48000Hz  RUNNING

$ pactl list short sources
55  alsa_output.pci-0000_00_1f.3.analog-stereo.monitor  PipeWire  s32le 2ch 48000Hz  RUNNING
56  alsa_input.pci-0000_00_1f.3.analog-stereo           PipeWire  s32le 2ch 48000Hz  SUSPENDED

$ pactl list short cards
44  alsa_card.pci-0000_00_1f.3  alsa
```

JSON real de un sink (recortado) — confirma los campos que el parser usa:

```json
[{"index":55,"state":"RUNNING",
  "name":"alsa_output.pci-0000_00_1f.3.analog-stereo",
  "description":"Built-in Audio Analog Stereo","driver":"PipeWire",
  "mute":false,
  "volume":{"front-left":{"value":75366,"value_percent":"115%","db":"3.64 dB"},
            "front-right":{"value":75366,"value_percent":"115%","db":"3.64 dB"}},
  "active_port":"analog-output-speaker",
  "ports":[{"name":"analog-output-speaker","description":"Speakers","type":"Speaker",
            "priority":10000,"availability":"availability unknown"},
           {"name":"analog-output-headphones","description":"Headphones","type":"Headphones",
            "priority":9900,"availability":"not available"}],
  "properties":{"device.alias":..., "device.icon_name":"audio-card-analog",
                "device.profile.name":"analog-stereo", "media.class":"Audio/Sink", ...}}]
```

`pactl -f json list sources` confirma `active_port` como **string** (`"analog-input-internal-mic"`) y `ports[]` con `availability: "availability unknown" | "not available"` → el manejo de `:247` y `:259` es correcto.

Nota: en esta máquina el volumen del sink está en **115 %**, y el slider del panel tiene `max = 100` (ver bug #1).

---

## 4. Cambio de dispositivo por defecto

`setDefaultTarget` (`service.luau:845-863`):

```lua
pactl set-default-sink   <device.targetName>   -- output  (:846, :853)
pactl set-default-source <device.targetName>   -- input   (:846, :853)
```

Después mueve **todos** los streams existentes (`moveStreams` `:821-843`):

```lua
pactl -f json list sink-inputs            -- o source-outputs
pactl move-sink-input <index> <targetName> -- uno por stream
pactl move-source-output <index> <targetName>
```

Entrada con puertos: `pactl set-source-port <source> <port>` **y luego** `set-default-source` (`:1133-1144`).

Si el device es BT desconectado (`available == false`), `setOutput` deriva a `connectBluetooth` (`:1080-1083`).

Resultado: `resultMessage` + `notify` (según `show_notification_on_switch`) + `publishSnapshot` + `refreshAll` (`finishAction` `:563-569`). `actionBusy` serializa acciones (`:851`, `:899`, `:1048`…).

**No existe** `pactl set-card-profile` ni `pactl set-sink-port` en todo el plugin (verificado: 0 ocurrencias).

---

## 5. Volumen y mute

| Operación | Comando exacto | Línea |
|---|---|---|
| leer volumen | `pactl -f json get-sink-volume @DEFAULT_SINK@` / `get-source-volume @DEFAULT_SOURCE@` | `:601-614` |
| leer mute | `pactl -f json get-sink-mute @DEFAULT_SINK@` / `get-source-mute` | `:604-627` |
| fijar volumen | `pactl set-sink-volume @DEFAULT_SINK@ "<N>%"` (o `set-source-volume`) | `:1312-1314` |
| mute | `pactl set-sink-mute @DEFAULT_SINK@ toggle` (o `set-source-mute`) | `:1331-1337` |

Formato: porcentaje entero con `%` literal; clamp `0..150` (`:1287`). Parseo de lectura: JSON `volume[ch].value_percent` (`"115%"`) o regex `(%d+)%%` de fallback (`:218-224`); mute JSON `{"mute":false}` o regex `Mute:\s*(%a+)` (`:226-235`).

Salida real:

```
$ pactl -f json get-sink-volume @DEFAULT_SINK@
{"volume":{"front-left":{"value":75366,"value_percent":"115%","db":"3.64 dB"},
           "front-right":{"value":75366,"value_percent":"115%","db":"3.64 dB"}},"balance":0.00}
$ pactl -f json get-sink-mute @DEFAULT_SINK@
{"mute":false}
```

Detalles de diseño que sí están bien resueltos:
- **Coalescing de rueda/slider**: una operación en vuelo + un `pending` con el último valor (`:1302-1326`); publica el valor pedido de inmediato (`:1290-1300`).
- **Reconciliación visual**: `reconcileVolumeDisplay` mantiene el valor pedido hasta que un refresco posterior lo confirma con ±1 (`:575-588`).
- Eventos `change` de `pactl subscribe` → `refreshCurrentVolume` en lugar de rescan completo (`:1490-1497`).
- Mute optimista + inversión local (`:1336-1355`).

Volumen **siempre** sobre el default; no hay volumen por dispositivo ni por stream (no hay sliders en la lista).

---

## 6. Grupos de salida (multi-output)

- Crear: `pactl load-module module-combine-sink sink_name=noctalia_group_<epoch>_<n> <sinks|slaves>=<a,b,c> sink_properties=device.description=Noctalia_Output_Group` (`:901-907`), luego `set-default-sink` y `moveStreams` (`:914-923`); si falla el default, `unload-module` (`:916`).
- Opción de miembros: `sinks` si `server_name` contiene `PipeWire`, si no `slaves` (`:669`).
- Disolver: `pactl unload-module <id>`, con fallback al primer miembro disponible y `set-default-sink` antes de descargar (`:929-976`).
- Detección de grupos: `pactl list short modules` filtrando `module-combine-sink` y prefijo `noctalia_group_` (`:369-387`), miembros desde `sink_name=`/`sinks=`/`slaves=` (`:365-367`).

Límite: `module-combine-sink` no permite volumen por miembro ni compensación de latencia; el grupo aparece como un sink más (`group = true`, ícono `link`).

---

## 7. Bluetooth

- Listar: `bluetoothctl devices` (`:742`); enriquecer con `bluetoothctl info <MAC>` (`:776`).
- Emparejar/conectar: `bluetoothctl pair <MAC>` si `Paired: no`, luego `bluetoothctl connect <MAC>` (`:1013-1035`).
- Handoff: **desconecta todos los demás BT conectados** antes de conectar el nuevo (`:1051-1067`).
- Espera del endpoint: sondea `pactl -f json list sinks` cada `sleep 0.25`, hasta 16 intentos (4 s) (`:992-1011`, constantes `:14-15`).
- Desconectar: `bluetoothctl disconnect <MAC>` (`:1366`).
- Escanear: `bluetoothctl --timeout 6 scan on` con timeout de proceso 10 s (`:1379-1383`).
- Batería: del bloque `Battery Percentage: 0x64 (100)` de `info` (`:461-463`).
- Detección de audio: UUIDs `0000110b` (A2DP sink), `0000110a`, `0000111e` (HFP), `0000184e`, `00001850`, `00001853`, o `Icon: *audio*` (`:453-475`).
- Slots: número persistente por MAC, asignado automáticamente al conectar (`:978-990`) y usable por IPC (`connect <n>`).

Estado real en esta máquina (read-only):

```
$ bluetoothctl devices
Device 31:92:D9:51:AF:84 Cubitt Headphones
Device 27:CB:CF:69:29:1E HP H23C Earbuds
Device 9F:DB:70:DC:9A:00 T09

$ bluetoothctl devices Connected
(vacío)
```

Es decir: hay 3 dispositivos emparejados, **ninguno conectado**, por lo que no existe `bluez_card.*` en `pactl list cards` en este momento (sólo `alsa_card.pci-0000_00_1f.3`).

---

## 8. `launcher.luau` (33 líneas)

Entry de `[[launcher_provider]]` (`plugin.toml:74-79`), prefijo `/audio`, `include_in_global_search = true`.

- `resultFor(query)` (`:6-24`): un único resultado `id = "open-panel"`, título `tr("launcher.open")` ("Open Audio Switcher"), subtítulo `tr("launcher.description")`, glyph `switch-horizontal`, `score`.
- Query vacía → `score = 0` y siempre devuelve el ítem (`:12-15`).
- Query no vacía → `noctalia.fuzzyScore(trimmed, title .. " " .. subtitle)`; `nil` ⇒ sin resultados (`:13-14`).
- `onQuery(query)` → `launcher.setResults(query, result and { result } or {})` (`:26-29`).
- `onActivate(id)` → si `id == "open-panel"` llama `noctalia.togglePanel("blackbartblues/audio-switcher:audio-switcher")` (`:31-33`).

No enumera dispositivos ni acepta acciones (`/audio ldac`, `/audio mute`, etc. no existen). Es sólo un atajo para abrir el panel, lo que da acceso por teclado sin poner el widget en la barra.

Tests: `tests/launcher_test.lua` (9 asserts) cubre query vacía, match, no-match, y activate con id inválido/válido.

---

## 9. UI del panel, pantalla por pantalla

No hay navegación de pantallas: **un solo panel** (620×650) con dos tabs y tres modos inline. `render()` (`panel.luau:453-482`) arma siempre:

```
header()
row [ volumeCard("output") | volumeCard("input") ]
toolbar()
groupingToolbar()          -- sólo visible en tab Outputs
column statusRows          -- loading / switching / error / feedback
scroll( deviceList(activeTab) )
label(keybind_hint)
```

### 9.1 Header (`:387-409`)
Glyph `switch-horizontal` + título "Audio Switcher" + subtítulo `salida · entrada`. Botones: **escanear BT** (deshabilitado si `bluetoothAvailable` es false; variante `primary` mientras escanea), **refresh**, **ajustes del plugin** (`noctalia.openSettings()` `:507`), **cerrar**.

### 9.2 Tarjetas de volumen (`volumeCard` `:116-155`)
Dos columnas iguales (`flexGrow = 1`, `fill = surface_container/0.45`): glyph volumen/micrófono, nombre del device activo (para entrada, la **descripción del puerto activo** — `inputDisplayName` `:77-81`), `NN%`, botón mute (`volume-off`/`microphone-mute`, variante `destructive` si está muteado), y `ui.slider` 0–100 con `onChange`/`onDragEnd` (`:144-153`).
El slider lleva `key = "volume-<kind>-<volumeControlRevision>"`; la revisión sólo sube cuando falla un set de volumen (`:622-629`) para re-sembrar el control nativo.

### 9.3 Toolbar (`:411-451`)
Tab **Outputs** / tab **Inputs** (con `selected`), spacer, contador "Visible N", botón **Hidden** (muestra `Hidden N`, toggle `showHidden`, deshabilitado si no hay ocultos) y botón **Cycle**.

### 9.4 Lista de dispositivos (`deviceList` `:370-385`, fila `deviceRow` `:219-336`)
Cada fila: glyph (19 px, color `primary` si activo), nombre en bold (`maxLines = 1`), subtítulo `estado · descripción [· puerto]` (`deviceSubtitle` `:164-172`; estados: Active / Bluetooth connected / Bluetooth disconnected / Available), chip `#N` para BT, y a la derecha:
- modo normal: botón **Use / Current / Connect & use** (deshabilitado si ya es activo o `busy`), luego **editar** (lápiz) y **ocultar/mostrar** (ojo). Si es un grupo: **Disband** en lugar de editar/ocultar (`:278-296`).
- modo agrupación (sólo tab Outputs): botón **Select/Selected** (check/plus) y el borde pasa a `primary` (`:261-269`, `:319`).
Para entradas con >1 puerto se agrega una fila extra con `ui.select` de puertos (`:322-333`), etiquetando los no disponibles como `"{port} (unavailable)"`.
Empty state: glyph + "No audio devices found." / "All devices in this list are hidden." (`:378-383`).

### 9.5 Toolbar de agrupación (`:338-368`)
Botón **Group outputs**; al activarlo, la barra cambia a "N selected. Choose at least two available outputs." + **Cancel** + **Create group (N)** (habilitado con `count >= 2`).

### 9.6 Editor inline (`editor` `:174-217`)
Se abre dentro de la fila del device. Campos: **Display name** (`ui.input`, placeholder = descripción), **Device icon** (`ui.select` con Automatic/Speaker/Over-ear/TWS/Wired, `width = 220`), y si es BT **Keybind number** (`ui.input`, placeholder `1`) + hint "Use this number with the connect IPC command, for example: connect 2.". Botones Cancel/Save. Guarda con `update_device` (`:566-582`).

### 9.7 Estado y feedback
`statusRows` (`:454-466`): "Loading audio devices…", "Switching audio device…", error del snapshot, y `feedback` (mensaje de `audio_switcher_result`, color `secondary`/`error`). Sólo se aceptan resultados con `requestId` que empiece en `panel-` (`:615`).

### 9.8 Ciclo de vida
- `onOpen` (`:484-492`): resetea feedback/agrupación, publica `panel_open = true`, manda `refresh`, renderiza.
- `onClose` (`:494-496`): `panel_open = false`.
- `onConfigChanged` (`:498-500`): re-render.
- Watchers de snapshot y result (`:607-631`): re-render en cada publicación.

---

## 10. Widget de barra (`widget.luau`)

- No tiene `onClick`/`onScroll`: las acciones son **declarativas** en `plugin.toml:58-63` (el host las ejecuta y `volume-up`/`volume-down` son acciones nativas del host).
- Glyph: `volume-off` si muteado; si no, `device.icon` del output activo (`:36-40`).
- Color: `secondary` si `busy`, `default` si `available`, `error` si no (`:42-48`).
- Texto: `showPercentage and not barWidget.isVertical() and "<N>%" or ""` (`:50-51`).
- Tooltip: pares "Output"/"Input" con nombre y %, y 4 líneas de acciones si `show_actions_in_tooltip` (`:52-60`).
- `onConfigChanged` → `render()` (`:70-72`); `render()` inicial al cargar (`:74`).

---

## 11. Códec de audio por dispositivo: estado real y qué falta

### 11.1 Evidencia recolectada (sólo lectura)

**(a) No hay dispositivo Bluetooth conectado ahora**, así que no existe una card `bluez_card.*` viva:

```
$ bluetoothctl devices Connected
(vacío)
$ pactl list short cards
44  alsa_card.pci-0000_00_1f.3  alsa
$ pactl -f json list cards | jq '.[].name'
"alsa_card.pci-0000_00_1f.3"
```

**(b) Nombres de perfil reales de este sistema**, tomados del estado persistido de WirePlumber (`~/.local/state/wireplumber/default-profile` y `default-routes`), escritos cuando los auriculares estuvieron conectados:

```
[default-profile]
bluez_card.31_92_D9_51_AF_84=a2dp-sink-sbc_xq
bluez_card.9F_DB_70_DC_9A_00=a2dp-sink-sbc_xq
bluez_card.27_CB_CF_69_29_1E=a2dp-sink-sbc_xq
alsa_card.pci-0000_00_1f.3=output:analog-stereo+input:analog-stereo

[bluetooth-autoswitch]
saved-headset-profile:bluez_card.31_92_D9_51_AF_84=headset-head-unit-cvsd
saved-headset-profile:bluez_card.9F_DB_70_DC_9A_00=headset-head-unit-cvsd
saved-headset-profile:bluez_card.27_CB_CF_69_29_1E=headset-head-unit

default-routes:
bluez_card.31_92_D9_51_AF_84:profile:a2dp-sink=["headset-output"]
bluez_card.31_92_D9_51_AF_84:profile:a2dp-sink-sbc_xq=["headset-output","headset-input"]
bluez_card.31_92_D9_51_AF_84:profile:headset-head-unit=["headset-hf-output","headset-input"]
bluez_card.31_92_D9_51_AF_84:profile:headset-head-unit-cvsd=["headset-hf-output","headset-input"]
bluez_card.31_92_D9_51_AF_84:profile:off=["headset-output"]
```

→ **El códec se selecciona por nombre de perfil de card**, con el patrón `a2dp-sink-<codec>` (`sbc_xq` con guión bajo). Y WirePlumber **persiste por dispositivo** el último perfil (esto ya es gratis: no hay que guardarlo en el plugin).

**(c) Códecs que este PipeWire puede ofrecer** (plugins SPA instalados, `ls /usr/lib/spa-0.2/bluez5/`):

```
libspa-codec-bluez5-sbc.so      libspa-codec-bluez5-aac.so     libspa-codec-bluez5-ldac.so
libspa-codec-bluez5-aptx.so     libspa-codec-bluez5-faststream.so
libspa-codec-bluez5-lc3.so      libspa-codec-bluez5-lc3plus.so libspa-codec-bluez5-opus-g.so
libspa-codec-bluez5-opus.so     libspa-codec-bluez5-g722.so
libspa-codec-bluez5-hfp-cvsd.so libspa-codec-bluez5-hfp-msbc.so
libspa-codec-bluez5-hfp-lc3-swb.so libspa-codec-bluez5-hfp-lc3-a127.so
```

Enum completo compilado en `libspa-bluez5.so` (`strings`):

```
Spa:Enum:BluetoothAudioCodec:{aac, aac_eld, aptx, aptx_hd, aptx_ll, aptx_ll_duplex,
  cvsd, faststream, faststream_duplex, g722, lc3, lc3_a127, lc3plus_hr, lc3_swb,
  ldac, mpeg, msbc, opus_05, opus_05_51, opus_05_71, opus_05_duplex, opus_05_pro,
  opus_g, sbc, sbc_xq}
```

Y las propiedades que exponen el estado actual existen en esta build:

```
$ strings -a /usr/lib/spa-0.2/bluez5/libspa-bluez5.so | grep '^api\.bluez5\.'
api.bluez5.address   api.bluez5.codec   api.bluez5.profile   api.bluez5.transport
api.bluez5.connection  api.bluez5.class  api.bluez5.role ...
```

**(d) El comando para fijar el códec existe en el `pactl` instalado:**

```
$ pactl help | grep card
pactl [options] set-card-profile  CARD PROFILE
pactl [options] set-port-latency-offset CARD-NAME|CARD-#N PORT OFFSET
```
(`wpctl` también expone `set-profile ID INDEX`, `wpctl status`.)

**(e) Forma del JSON de cards** (clave para parsear; ejemplo de la card ALSA):

```json
{"index":44,"name":"alsa_card.pci-0000_00_1f.3","driver":"alsa",
 "properties":{...},
 "profiles":{"off":{"description":"Off","sinks":0,"sources":0,"priority":0,"available":true},
             "output:analog-stereo":{"description":"Analog Stereo Output","sinks":1,"sources":0,
                                     "priority":6500,"available":true}, ...},
 "active_profile":"output:analog-stereo+input:analog-stereo",
 "ports":[...]}
```

`profiles` es un **dict nombre→{description, sinks, sources, priority, available}** y `active_profile` es el nombre activo. Para una card BT esa misma estructura lista `a2dp-sink-sbc`, `a2dp-sink-sbc_xq`, `a2dp-sink-aac`, `a2dp-sink-ldap`… con `available` indicando si el peer lo soporta.

### 11.2 Cómo se fija el códec (comandos exactos)

```bash
# listar cards y perfiles (códec = sufijo del perfil)
env LC_ALL=C pactl -f json list cards | jq -r '.[] | select(.name|startswith("bluez_card.")) | .name, .active_profile, (.profiles|keys|join(" "))'

# leer el códec actual (dos vías)
pactl -f json list cards | jq -r '.[] | select(.name|startswith("bluez_card.")) | .active_profile'   # a2dp-sink-sbc_xq
pw-dump | jq -r '.[] | select(.info.props["device.api"]=="bluez5") | .info.props["api.bluez5.codec"]'  # sbc_xq

# fijar códec A2DP (perfil de card)
pactl set-card-profile bluez_card.31_92_D9_51_AF_84 a2dp-sink-ldac

# volver a HFP (manos libres, usa el micrófono, calidad baja)
pactl set-card-profile bluez_card.31_92_D9_51_AF_84 headset-head-unit

# alternativa por índice (wpctl status → Devices)
wpctl set-profile <device-id> <profile-index>

# allowlist global (NO per-device, requiere reiniciar wireplumber)
# ~/.config/wireplumber/wireplumber.conf.d/60-bluez-codecs.conf
monitor.bluez.properties = { bluez5.codecs = [ "ldac", "aac", "sbc_xq", "sbc" ] }
```

Puntos finos:
- `bluez5.codecs` es **global** y sólo ordena/limita; no hay setting de WirePlumber por dispositivo para códec. La persistencia por dispositivo es el `default-profile` de WirePlumber (evidencia 11.1b), que se actualiza solo al hacer `set-card-profile`.
- Cambiar de perfil **destruye y recrea el sink** (`bluez_output.<MAC>.1`); hay que volver a mirar el default y, si el sink era el default, re-aplicarlo. Mismo patrón que `waitForBluetoothOutput` (`service.luau:992-1011`).
- El perfil HFP y el A2DP son excluyentes: elegir códec A2DP implica no usar el micrófono del auricular (o pasar a `headset-head-unit*`), y eso el usuario lo tiene que ver en la UI.
- `sbc_xq` requiere `bluez5.enable-sbc-xq` (default true). `faststream`, `msbc`, `lc3-a127` tienen flags propios (`bluez5.enable-*`) visibles en los strings del SPA.

### 11.3 Qué falta en el plugin (lista cerrada)

1. **No lee cards.** Cero llamadas a `pactl list cards` (`service.luau`, 0 ocurrencias) ⇒ no hay `profiles`, ni `active_profile`, ni `api.bluez5.codec`.
2. **No hay campo de códec/perfil en el snapshot.** `snapshot` (`:32-50`) y `makeOutput` (`:285-303`) no tienen `codec`, `profile`, `cardName`.
3. **No hay mapeo sink→card.** El sink BT trae `properties["device.name"] = bluez_card.XX` y `api.bluez5.address`; hoy sólo se usa la address (`:269-275`).
4. **No hay acción en el contrato.** `executeCommand` (`:1386-1428`) no tiene `set_card_profile` / `set_codec`; `onIpc` (`:1438-1455`) tampoco.
5. **No hay UI.** `deviceRow` (`:219-336`) no tiene selector de códec; el único `ui.select` es el de puertos de entrada (`:325-331`) y el de ícono del editor (`:189-200`).
6. **No hay persistencia de preferencia de códec** (y no hace falta: la lleva WirePlumber). Si se quiere forzar por dispositivo, hay que escribir `monitor.bluez.rules` en `~/.config/wireplumber/` — eso es config, no plugin.
7. **No hay espera post-cambio.** Falta el equivalente a `waitForBluetoothOutput` para re-detectar el sink nuevo y re-aplicar default (`:992-1011`).
8. **No hay filtro de disponibilidad.** `profiles[n].available` hay que respetarlo o se ofrecen códecs que el auricular no soporta y el `set-card-profile` falla en silencio (pactl devuelve 0 en algunos casos).
9. **No hay distinción A2DP vs HFP** en la UI: sin eso, elegir "LC3" o "mSBC" (que son HFP) se lee como si fuera calidad alta.
10. **Sin superficie para el caso "salida virtual"** (`easyeffects_sink` aparece en `default-nodes` de esta máquina): si el usuario enruta por un sink virtual, el códec no aplica y hay que decirlo.

### 11.4 Diseño mínimo propuesto (si se implementa)

```lua
-- service: nueva etapa en loadAudio, tras sources
runPactl({ "-f", "json", "list", "cards" }, ...)   -- 1 proceso extra por refresco
-- merge en makeOutput: buscar card cuyo properties["device.name"] == item.properties["device.name"]
--   o cuya properties["api.bluez5.address"] == device.address
-- campos: cardName, activeProfile, codec = activeProfile:match("^a2dp%-sink%-(.+)$") or activeProfile,
--         codecProfiles = { { name, description, available } }  -- sólo perfiles del grupo actual
-- acción: set_card_profile { card = cardName, profile = "a2dp-sink-ldac" }
--   -> pactl set-card-profile <card> <profile>
--   -> esperar sink (reusar waitForBluetoothOutput) -> set-default-sink si era el default
-- UI: en la fila BT, ui.select con los perfiles disponibles; etiqueta "SBC-XQ · 660 kbps" etc.
```

---

## 12. Trabajo delegable a un CLI en Go

El service hace hoy, por refresco: 4 procesos `pactl` + 1 `bluetoothctl devices` + N `bluetoothctl info`, todo en Luau dentro del presupuesto de **25 ms de CPU por callback** del host. Todo eso es mecánico y testeable fuera del plugin.

| Comando propuesto | Reemplaza | Por qué en Go |
|---|---|---|
| `b3l0w audio snapshot --json` | `loadAudio` + `loadBluetooth` (4+N execs) | un solo proceso; parseo JSON nativo; junta sinks/sources/cards/codecs/ports/defaults/batería/grupos |
| `b3l0w audio watch --jsonl` | `pactl subscribe` parseado en Luau (`:1481-1503`) | long-lived, dedup por `(facility,index,event)`, debounce 150 ms, reconexión automática |
| `b3l0w audio set-output\|set-input <id>` | `setDefaultTarget` (`:845`) | resuelve id→target, `set-default-*`, mueve streams, verifica post-condición |
| `b3l0w audio set-card-profile <card> <profile>` | **no existe** | nueva capacidad de códec |
| `b3l0w audio set-port <sink\|source> <port>` | sólo input (`:1133`) | habilita Speakers/Headphones y HDMI en salidas |
| `b3l0w audio volume --kind out --delta +5 \| --set 40` | `setVolume` (`:1281`) | debounce/serialización de la rueda fuera de Luau |
| `b3l0w audio mute --kind out [--toggle]` | `toggleMute` (`:1331`) | idem |
| `b3l0w audio group create\|remove\|list` | `:877-976` | maneja `module-combine-sink`, rollback y miembros |
| `b3l0w audio bt scan\|pair\|connect\|disconnect\|battery` | `:992-1083`, `:1372-1384` | `bluetoothctl info` en paralelo, timeouts reales |
| `b3l0w audio prefs get\|set` | `preferences.json` desde Luau (`:147-177`) | escritura atómica (`rename`) + flock; una sola fuente de verdad |

Ventajas concretas: elimina N+1 procesos por refresco, quita el parseo de líneas (`bluetoothctl info`, `module-combine-sink`) del hilo del service, permite tests unitarios reales (hoy `tests/*.lua` usan stubs), y deja el plugin como pura UI + `runAsync(cmd, cb)`. El `snapshot` puede publicarse tal cual desde el JSON del CLI.

---

## 13. Bugs y límites (con evidencia)

| # | Ubicación | Severidad | Problema / síntoma |
|---|---|---|---|
| 1 | `panel.luau:146-149` vs `service.luau:1287` | **alta** | Slider con `max = 100`, pero el volumen real va hasta 150 %. En esta máquina el sink está a **115 %**: el slider satura y cualquier arrastre lo baja a ≤100 (pérdida de volumen audible). |
| 2 | `panel.luau:322`, `service.luau:1107-1155` | **alta** | Sólo hay selector de puerto de **entrada**. `pactl set-sink-port` no se usa en ninguna parte: no se puede elegir Speakers/Headphones/HDMI de la placa interna. |
| 3 | `service.luau:209-213` | media | `for _, channel in pairs(volume)` — con canales desbalanceados el % mostrado es arbitrario (orden de `pairs`). Debería usar `front-left` o el máximo. |
| 4 | `service.luau:753-783` | media | `bluetoothctl info` **en serie** por dispositivo, en cada refresco. Con 5 BT y panel abierto (5 s) son 6 procesos cada 5 s. |
| 5 | `service.luau:816` | media | `refreshAll` se re-invoca a sí misma desde el callback si `refreshAgain`; una tormenta de eventos de `pactl subscribe` encadena refrescos sin backoff. |
| 6 | `service.luau:1051-1067` | media | Conectar un BT **desconecta todos los demás** conectados. Handoff no configurable y no avisado al usuario. |
| 7 | `service.luau:1003-1009` | media | Espera del endpoint BT = hasta 16 × `sleep 0.25` ⇒ 16 procesos `sleep` por conexión. |
| 8 | `service.luau:1481-1503` | media | No hay `onExit`/teardown: un reinicio del service deja `pactl subscribe` huérfano (y cada instancia nueva abre otro stream). |
| 9 | `service.luau:538-543` + `:32-50` | media (a confirmar) | El snapshot es una tabla **mutable reutilizada**: se publica la misma referencia en cada `state.set`. Si el host compara por identidad para deduplicar, hay updates que no llegan al widget/panel. |
| 10 | `service.luau:1312-1314` | media | Volumen siempre sobre `@DEFAULT_SINK@`/`@DEFAULT_SOURCE@`; no hay volumen por dispositivo ni por app (stream). |
| 11 | `panel.luau:540-547` | baja | `onCreateGroup` arma ids desde `selectedGroupOutputs` sin descartar ids que ya no existen; el contador "Create group (N)" puede mentir tras un refresh. |
| 12 | `service.luau:1257-1269` | baja | `update_device` con `address == ""` y `slot` no vacío **ignora el slot en silencio** (validación pasa, no se guarda). |
| 13 | `service.luau:315` | baja | `setPreference(knownBluetoothInputs, ...)` dentro del parseo: efecto de escritura durante una lectura, y `savePreferences()` en el primer refresco. |
| 14 | `service.luau:1432` | baja | `requestId = "ipc-" .. os.time()`: dos IPC en el mismo segundo comparten id (no hay dedup, pero rompe trazabilidad en logs). |
| 15 | `service.luau:614-631` (panel) | baja | Sólo se procesan resultados `panel-*`; los errores de IPC (`ipc-*`) nunca se muestran en la UI (sólo hay notificación). |
| 16 | `plugin.toml:65-72` | baja | Sin `capture_keys`: no hay navegación por teclado (sólo Escape del host). |
| 17 | `plugin.toml:68-69` | baja | `620×650` fijos; en pantallas chicas se clampa y el `keybind_hint` final roba alto al scroll. |
| 18 | `plugin.toml:7` | informativa | `deprecated = true`: el catálogo ya lo marca obsoleto. |
| 19 | `translations/en.json:116`, `tr.json:93` | baja | `settings.scroll_step` sin `[[setting]]` ni uso → clave muerta (el paso de scroll lo controla el host, `volume-up [step]`). |
| 20 | `translations/` | baja | No hay `es.json`; el shell está en `lang = "en"` (settings.toml:498). |
| 21 | todo el plugin | media (límite) | No lee cards ⇒ sin perfiles, sin códecs, sin latencia/formato de muestra, sin "off" de la card. |

Límites estructurales (no bugs): un solo set de acciones a la vez (`actionBusy`, `:851`); los grupos no permiten volumen por miembro; el volumen máximo real (150 %) no está expuesto en la UI; no hay routing por aplicación.

---

## 14. Ocultar la label y panel flotante

### 14.1 Ocultar la label de la barra

Estado actual (`widget.luau:50-51`):

```lua
local showPercentage = noctalia.getConfig("show_percentage") ~= false
barWidget.setText(showPercentage and not barWidget.isVertical() and outputVolume or "")
```

- **Camino 1 (ya existe, sin tocar código):** poner `show_percentage = false`. El texto desaparece (y también el %, que sigue en el tooltip, `widget.luau:52-53`). Es lo único que hay hoy.
- **Camino 2 (correcto si querés conservar el %):** agregar un `[[setting]]` propio y gatear el texto:

```toml
[[setting]]
key = "show_label"
type = "bool"
label_key = "settings.show_label.label"
description_key = "settings.show_label.description"
default = true
```
```lua
-- widget.luau:51
barWidget.setText(showLabel == true and outputVolume or "")
```
Es el patrón que usan otros plugins: `community/todo/plugin.toml:76-80` + `todo.luau:84` (`if noctalia.getConfig("show_label") == false then ... end`), `community/containers/widget.luau:9`.

> Importante: `show_label` **no** es un prop del host para widgets de plugin. En `settings.toml:735-737` (`[widget.volume] show_label = false`) es el widget **built-in**, y `[widget.widget_6]` (audio-switcher, `:748-749`) no admite props propios. Por eso el plugin tiene que declararlo.

### 14.2 Panel flotante

No requiere cambios de código: `placement`, `position`, `open_near_click` y `layer` son **defaults** que el host inyecta como settings del panel (`<panel-id>_placement`, …). Verificado con otros plugins en `settings.toml:409-451` (`manager_placement`, `panel_placement`, `library_placement`, `mini_placement`, `result_placement`).

Dos formas:

```toml
# ~/.local/state/noctalia/settings.toml  (o Settings → Plugins → Audio Switcher)
[plugin_settings."blackbartblues/audio-switcher"]
audio-switcher_placement = "floating"
# opcional:
# audio-switcher_position = "center"
# audio-switcher_open_near_click = false
```

o desde la UI de ajustes del plugin (botón de engranaje del header, `panel.luau:406` → `noctalia.openSettings()`).

Si además querés que el alto se adapte al contenido: cambiar `plugin.toml:69` a

```toml
height = "content"
max_height = 700
```
(requiere `plugin_api >= 42`; ya está en 43, `plugin.toml:4`). Con `height = "content"` el `ui.scroll` de `panel.luau:474` necesita alto explícito, si no mide 0. `"fill"` en cualquier eje exigiría `placement = "floating"` obligatoriamente.

---

## 15. Verificación (comandos ejecutados, todos de lectura)

```
pactl info | pactl --version | pactl help
pactl list short {sinks,sources,cards,modules}
pactl -f json list sinks | sources | cards
pactl -f json get-sink-volume @DEFAULT_SINK@ | get-sink-mute @DEFAULT_SINK@
pw-dump            (filtrado con python: devices/nodes, props api.bluez5.*)
wpctl status
bluetoothctl devices | devices Connected | info 31:92:D9:51:AF:84
strings /usr/lib/spa-0.2/bluez5/libspa-bluez5.so   (perfiles, enum de códecs, props)
ls /usr/lib/spa-0.2/bluez5/
cat ~/.local/state/wireplumber/{default-profile,default-routes,bluetooth-autoswitch,default-nodes}
grep -rn setting keys in translations/en.json
pacman -Q pipewire wireplumber libpulse bluez bluez-utils
```

No se ejecutó `set-*`, `set-card-profile`, `connect` ni ninguna escritura.

**Límite de la evidencia:** no hay dispositivo Bluetooth conectado en este momento, así que **no fue posible** volcar `pactl -f json list cards` de una card `bluez_card.*` con su lista viva de perfiles/códecs disponibles. Los nombres de perfil y la persistencia se verificaron contra el estado real de WirePlumber de esta máquina (sección 11.1b) y los códecs contra los plugins SPA instalados (11.1c). Para cerrar esa verificación hay que conectar uno de los tres dispositivos emparejados y volver a correr:

```bash
pactl -f json list cards | jq '.[] | select(.name|startswith("bluez_card."))'
pw-dump | jq '.[] | select(.info.props["api.bluez5.codec"]!=null) | .info.props["api.bluez5.codec"]'
```

---

## 16. Prioridades sugeridas

1. **Códec por dispositivo** (sección 11): es la funcionalidad que falta por completo y la única que requiere tocar los tres entries (service: cards + acción; panel: selector; nada en widget).
2. **Puerto de salida** (`set-sink-port`) — mismo trabajo estructural que el códec, muchísimo más barato.
3. **Bug del slider 0–100 vs 150 %** (`panel.luau:147`): una línea.
4. **Mover enumeración a un CLI Go** (`snapshot`/`watch`): elimina el N+1 de `bluetoothctl` y el parseo de líneas del presupuesto de 25 ms.
5. `show_label` + `placement = "floating"` (sección 14): dos cambios triviales, cero riesgo.
6. Teardown de `pactl subscribe` en `onExit` y backoff en `refreshAll`.
