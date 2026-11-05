# noctalia-b3l0w-wallpaper — SPEC de implementación

Plugin de Noctalia (Luau) que unifica cuatro plugins de wallpaper: Wallpaper Engine,
videos (`mpvpaper`), imágenes locales, Wallhaven y fondos de un solo color. Reescritura
desde cero con carrusel tipo coverflow, grilla conmutable, paridad de ajustes con los
originales y **rechazo de los fondos que saturan la GPU** por medición.

El trabajo pesado (catálogo del workshop, miniaturas, PNG de color) lo hace el CLI
`b3l0w we` en Go: el host de plugins da 25 ms de CPU por callback y un recorrido del
workshop en Luau medía 26–30 ms.

---

## 1. Hechos de API VERIFICADOS (no inventar nada fuera de esto)

Fuente: `docs.noctalia.dev/noctalia/plugins/development/*` + binario local `noctalia v5.4.1-41`.

### Restricciones duras (investigadas, no negociables)
- `ui.scroll` es **SOLO vertical**. Props: mismo layout que `ui.column` + `fill`, `radius`,
  `border`, `borderWidth`, `stickToBottom`, `onScroll(offset, maxOffset)`, `scrollToBottomRev`,
  `revealKey`.
- **NO existe** `ui.grid`, `flexWrap`, `flexDirection`, ni scroll horizontal.
- `onScroll(dx, dy)` con delta de rueda **solo existe en `ui.pixelStream`** (requiere socket
  companion + render propio). NO se usa.
- Contenedores disponibles: `ui.column`, `ui.row` (`gap`, `padding`, `paddingH`, `paddingV`,
  `align` = start/center/end/stretch, `justify` = start/center/end/space_between, `fill`,
  `radius`, `border`).
- Todo control acepta: `width`, `height`, `flexGrow`, `opacity`, `visible`, `key`, `tooltip`.
- Controles: `ui.label`, `ui.glyph`, `ui.image` (`path`, `width`, `height`, `radius`,
  `fit`=contain/cover/stretch, `onClick`, `onHover`), `ui.box`, `ui.separator`, `ui.spacer`,
  `ui.progress`, `ui.button` (`text`, `glyph`, `variant`=default/primary/secondary/
  destructive/outline/ghost, `controlSize`=sm/md/lg), `ui.graph`, `ui.toggle` (`checked`,
  `onChange`), `ui.slider` (`min`,`max`,`step`,`value`,`onChange`,`onDragEnd`), `ui.select`
  (`options` array de strings, `selectedIndex`, `onChange`), `ui.input` (`value` inicial,
  `placeholder`, `multiline`, `onSubmit`), `ui.markdown`, `ui.colorPicker`, `ui.pixelStream`.
- **El ancho de un panel es INMUTABLE en runtime.** El API de `panel` es `render`,
  `close`, `openContextMenu`, `setWantsSecondTicks` y `setNeedsFrameTick` — no existe
  `setWidth` (verificado con `strings` sobre el binario instalado). El manifiesto sólo
  acepta `width = <entero>` o `"fill"`; **no** existe `width = "content"`. El host
  ajusta el ALTO al contenido (`measureContentHeight`), nunca el ancho: `m_contentWidth
  = panelW - padding*2`. Por eso el plugin declara una escalera de entries y cambia de
  escalón cerrando y reabriendo el panel.
- Callbacks: función Luau (plugin_api >= 9) o **nombre de una función global** del script.
- Módulos: `require("./lib/x.luau")` — ruta relativa, empieza con `./` o `../`, termina en
  `.luau`, **debe retornar exactamente un valor no-nil**. Requiere `plugin_api >= 22`.

### Runtime API usada
```
noctalia.log(msg)                     noctalia.notify(t,b) / notifyError(t,b)
noctalia.runAsync(cmd|argv)           noctalia.runAsync(cmd, cb(result))
noctalia.runStream(cmd, onLine)       noctalia.commandExists(name)
noctalia.processMatches(cb, ...n)     noctalia.readFile(path) -> s | nil,err
noctalia.readFileAsync(path, cb)      noctalia.writeFile(path, s) -> bool,err
noctalia.fileExists(p)                noctalia.fileInfo(p) -> {size,mtime,isDir}
noctalia.listDir(p) -> array | nil,err  noctalia.mkdirAll(p)
noctalia.removeFile(p)                noctalia.expandPath(p)
noctalia.pluginDir()                  noctalia.pluginDataDir() -> s | nil,err
noctalia.getConfig(key)               noctalia.getSetting(dotted.path)
noctalia.getColor(role)               noctalia.isDarkMode()
noctalia.outputs() -> {name,description,width,height,x,y,scale,focused}
noctalia.focusedOutputName()          noctalia.setWallpaper(path)
noctalia.setWallpaper(connector, p)   noctalia.setWallpaperEnabled(connector, bool)
noctalia.tr(key[,subst])              noctalia.trp(key, count[,subst])
noctalia.json.decode(s) -> v | nil,err  noctalia.json.encode(v[,pretty]) -> s | nil,err
noctalia.string.trim(s)               noctalia.nowMs()
noctalia.state.set(k, v)              noctalia.state.get(k)
noctalia.state.watch(k, fn)           noctalia.setUpdateInterval(ms)
noctalia.togglePanel("author/plugin:panel")
```

### Entradas de plugin (entries)
Callbacks de panel: `onOpen(context)`, `onClose()`, `onKey(chord, pressed)`.
Servicio: `onEnable()`, `onDisable()`, `update()` (con `setUpdateInterval`).
Widget de barra: `render()`, `onClick()`, `onScroll(axis, steps, startsGesture)`.

`plugin_api = 43` (el que soporta la build instalada; no usar features > 43).

### Escalera de paneles

`panel.luau` es un **módulo** (`return M`) y cada escalón es un entry propio que
publica los hooks como globales y pasa su ancho:

```
panel_e800.luau … panel_e1900.luau    (uno por escalón de 100 px)
```

| id | entry | width |
|---|---|---|
| `panel` | `panel_e1500.luau` | 1500 |
| `panel_w<N>` | `panel_e<N>.luau` | `N` (800…1900, sin 1500) |

`lib/panel_size.luau` calcula el ancho que la vista necesita y devuelve el id
(`b3l0w/wallpaper:panel_w<N>`). Sólo `panel` es visible en el launcher: el resto
va en `shell.launcher.panels.ignored`.

**Quien abre resuelve la entrada, no el panel.** El host ancla un panel
`attached` a la barra desde donde se abre: `sourceBarName` sólo viaja cuando la
apertura viene de un widget, y un `noctalia msg panel-open` no lo lleva. Por eso
el panel **no** se cierra y reabre para cambiar de ancho: esa reapertura lo
mandaba a la barra principal en vez de a la barra desde donde se lo abrió.

En su lugar el servicio publica la entrada que corresponde:

```lua
noctalia.state.set("panel_entry", mapa)         -- para este plugin
noctalia.writeFile("~/.local/state/noctalia/panel-entries.json",
                   noctalia.json.encode(mapa))  -- para los demás
```

`noctalia.state` **no** se comparte entre plugins, y quien abre el panel casi
siempre es otro plugin (una hover zone): el archivo es el canal. El widget y las
hover zones leen ese mapa en el momento del toggle y abren la entrada correcta
de una sola vez, con su barra.

Si alguien abre una entrada que no es la que pide la configuración, el panel se
queda donde está y achica las tarjetas para no desbordar (`carouselSlotWidth`
recorta contra el ancho real). No se mueve de barra.

---

## 2. Layout del repo

```
b3l0w-wallpaper/
├── plugin.toml            manifiesto: 18 ajustes, widget, panel, servicio
├── README.md              uso, ajustes, IPC, atajos, limitaciones
├── SPEC.md                este archivo
├── CHANGELOG.md
├── translations/{es,en}.json
├── types/noctalia.d.luau  stubs de la API para el editor
├── .luaurc                resolución de requires
├── lib/
│   ├── util.luau          trim, clamp
│   ├── catalog.luau       Workshop: raíces, project.json, scan, find_by_id
│   ├── local.luau         escaneo de respaldo de carpetas (sin CLI)
│   ├── engine.luau        FIELDS, to_argv, properties_argv, resolve
│   ├── store.luau         state.json: validación, overrides, favoritos, filtros
│   ├── wallhaven.luau     cliente HTTP de la API
│   └── gpuprobe.luau      rc6_residency_ms y clasificación
├── service.luau           [[service]] id="start"
├── panel.luau             MÓDULO de la vista (no es una entry)
├── panel_e<N>.luau        un entry por escalón de ancho (800…1900)
└── widget.luau            [[widget]] id="widget"
```

`plugin.toml` declara `[[service]] entry="service.luau"`, doce `[[panel]]` (una por
escalón, `height="content"`, `max_height=920`, `placement="attached"`) y
`capture_keys = ["Left","Right","Up","Down","Prior","Next","Home","End","Return","g","f","p"]`
(`Return` aplica el wallpaper enfocado; el buscador de Wallhaven lo distingue con
`searchDirty`).

---

## 3. Modelo de datos

### Wallpaper (elemento de catálogo)
```lua
{
  id      = "3796026374",              -- nombre de carpeta del Workshop
  title   = "The Winter Nothingness",  -- project.json .title, fallback id
  type    = "scene"|"video"|"web"|"other",   -- normalizado a minúsculas
  path    = "/home/.../431960/3796026374",
  file    = "scene.json",              -- project.json .file (o ruta absoluta en imágenes/videos)
  preview = "/abs/preview.gif",        -- project.json .preview resuelto, o nil
  thumb   = "/abs/cache/3796026374.png", -- PNG cacheado (generado por service), o nil
  tags    = {"Relaxing"},              -- normalizado a array de strings
  props   = { ... },                   -- .general.properties crudo (o {})
  load    = nil | { busy_pct = 100, freq_mhz = 1200 },
}
```

### Engine options (paridad con el plugin actual)
```lua
{
  fps = nil|number, scaling = "default"|"fill"|"fit"|"stretch",
  clamp = "clamp"|"border"|"repeat", layer = "background"|"below"|"default",
  volume = nil|number, silent = false,
  disable_mouse = false, disable_parallax = false, disable_particles = false,
  no_audio_processing = false, no_fullscreen_pause = false,
  fullscreen_pause_only_active = false, noautomute = false,
}
```
Reglas: `false`/`nil` = no emitir flag. `defaults` globales + `overrides[id]` por wallpaper;
el override gana campo por campo (merge superficial, no profundo).

### Persistencia (`pluginDataDir/state.json`)
```lua
{
  version = 1,
  defaults   = { engine... },
  overrides  = { ["id"] = { engine... } },
  blocklist  = { ["id"] = { busy_pct=100, freq_mhz=1200, at=1760000000, reason="gpu"|"manual" } },
  cycle      = { active=false, minutes=15, order="sequential"|"random", ids={...} },
  last       = { id="...", output="eDP-1" },
  view       = { mode="carousel"|"grid", columns=4 },
}
```

---

## 4. Contrato entre entradas (`noctalia.state`)

Claves con prefijo `wes_` para no colisionar con otros plugins:

| clave | quién escribe | contenido |
|---|---|---|
| `wes_store` | service | `state.json` vigente: `source`, `view`, `favorites`, `properties`, `blocklist`, `overrides`, `defaults`, `wallhaven_filters`, `local_sort`, `color` |
| `wes_catalog` | service | `{ items = {Wallpaper...}, ts, root, wallhaven = { page, lastPage } }` |
| `wes_status` | service | `{ id, title, output, since, fps, paused, cycle = { active, minutes, order, count }, probe = { phase, queue, results } }` |
| `wes_nav` | panel/widget | `{ delta, nonce }` — mueve el foco |
| `wes_screen` | service | `{ screen, id, nonce }` — abre Browse / Options / GPU |

`nonce` = timestamp + random; el service descarta un pedido con un nonce ya visto.

### Acciones (`wes_request.action`)

La tabla `ACTIONS` del service (24 entradas). Un pedido sin acción conocida se registra y
se ignora.

| Acción | Payload | Efecto |
|---|---|---|
| `apply` | `{id, output?, force?}` | aplica; `output = "*"` recorre todas las salidas |
| `stop` | `{output?}` | mata el proceso vivo y devuelve el fondo propio de Noctalia |
| `pause` / `resume` | — | `SIGSTOP` / `SIGCONT` sobre el PID del pidfile |
| `cycle_start` | `{ids, minutes, order}` | arranca la rotación |
| `cycle_stop` | — | la corta |
| `refresh` | — | reescanea la fuente activa |
| `set_source` | `{source}` | guarda y publica antes de escanear |
| `set_view` | `{mode?, columns?, spacing?, tile?, apply_on?, view_label?, carousel?, grid?}` | vista, densidad y disposición. `carousel`/`grid` son parches parciales: `{layout?, w?, h?, progress?}`; `w`/`h` en 0 = automático |
| `set_options` | `{id?, engine, restart?, clear_overrides?}` | opciones del motor (globales o por fondo) y relanza |
| `set_property` | `{id, name, value}` | propiedad del autor |
| `clear_properties` | `{id}` | descarta los overrides de propiedades |
| `favorite` | `{id}` | alterna favorito y notifica |
| `set_theme` | `{enabled}` | `sync_colors` |
| `set_debug` | `{enabled}` | trazas `[dbg]` en el log; se persiste en el store |
| `debug_dump` | — | escribe `debug-report.txt` (estado, procesos, cola de engine.log) |
| `set_local_sort` | `{sort}` | `name` \| `date` \| `random`; reescanea |
| `apply_color` | `{color}` | genera el PNG con `b3l0w we solid` y lo aplica |
| `set_wallhaven` | `{query?, purity?, categories?, sorting?, order?, ratios?, res?, resmode?, page?}` | filtros; reinicia la búsqueda salvo que venga `page` |
| `set_wh_max` | `{value}` | tope de acumulación; reinicia desde la página 1 |
| `probe` | `{id}` | mide ese fondo (o lo encola) |
| `probe_all` | — | mide todos los que no tienen perfil |
| `unblock` | `{id}` | saca de la blocklist y relanza si estaba en pantalla |
| `open_screen` | `{screen, id?}` | publica `wes_screen` |
| `screen` | `{name}` | alias viejo (`name` en vez de `screen`) |
| `nav` | `{delta}` | publica `wes_nav` |

Toda acción que cambia estado guarda `state.json`, publica `wes_store` y — si el catálogo
cambió — `wes_catalog`.

---

## 5. UI del panel (lo central del pedido)

### Pantalla 1 — Browse (2 modos)

Barra superior: buscador (sólo en grilla o Wallhaven), selector de fuente, selector de
vista, "Aplicar en" (una salida o todas), refrescar y acceso a Opciones/GPU.

**Modo carrusel** (coverflow, por defecto):
- **Cinco celdas fijas** en un `ui.row`: el foco ocupa la del centro y las dos de cada
  lado se achican con `focusScale(d) = max(0.74, 1/(1+0.15·d))`.
- El ancho de celda sale del panel, no del ajuste de tarjeta:
  `slot = max(80, min(tile_size, (PANEL_INNER − (slots−1)·TILE_GAP) / slots))`
  con `PANEL_INNER = 984` y `TILE_GAP = 4` → 193 px por celda.
- Al mover el foco, el ancho se interpola durante `FOCUS_MS = 200`; el desplazamiento
  del contenido dura `SLIDE_MS = 170`. No hay primitivo de animación en la API: la curva
  la maneja `onFrameTick` y sólo se re-renderiza cuando cambia un ancho entero ≥ 1 px.
- Debajo: `ui.progress` con la posición del foco y un caption con el título.
- Las celdas vecinas se ven más chicas y pegadas a propósito: es el efecto coverflow.

**Modo grid**:
- `ui.scroll` vertical con filas de `columns` tarjetas armadas a mano (`ui.row` por fila).
  `columns` viene de `view.columns` (2–8).
- El alto del scroll es **explícito** (`min(filas·alto_fila, visible·alto_fila)`): dentro
  de un panel `height="content"` un `flexGrow` mide 0 y la grilla queda invisible.
- Se dibujan ventanas de `GRID_WINDOW = 120` tarjetas; con 2.400 items de Wallhaven el
  panel sigue abriendo sin timeouts.
- `revealKey` en el scroll hace que el foco por teclado traiga la tarjeta a la vista.

**Tarjeta** (común a los dos modos):
- `ui.image` con `thumb` (o `preview`), `radius`, `fit="cover"`, `key="tile-<id>"`.
- Borde por pureza en Wallhaven: `nsfw` → `error` de 3 px, `sketchy` → `tertiary` de 2 px.
- Estrella si es favorito, alerta si está bloqueado, marca si es el que está en pantalla.
- Al hacer click aplica; hay botones de favorito y de opciones por fondo.

**Modo grid**:
- `ui.scroll` vertical con filas de `columns` tiles construidas a mano (`ui.row` por fila).
- `columns` viene de `view.columns` (2..8), configurable en settings.

**Tile** (común a ambos modos):
- `ui.image` con `thumb` (o `preview` si no hay thumb), `width=tileW`, `height=tileW*9/16`,
  `radius`, `fit="cover"`, `onClick` → aplicar.
- Marco de selección: `ui.box` con `border` de color `primary` cuando está seleccionado
  o cuando está aplicado ahora.
- Badge de GPU: si `blocklist[id]` existe → glyph de advertencia + `tooltip` con el `busy_pct`
  medido. Si el wallpaper se aplicó pero nunca se midió → punto neutro.
- En modo selección múltiple: check visual encima del tile.

**Selección múltiple + ciclo**: botón que alterna `selecting`; los clicks agregan/quitan de
`selected`. Con `selected >= 1`: `[Start cycle] [every N min] [order select]`.

### Pantalla 2 — Options (por wallpaper o defaults)
- `ui.select`/`ui.slider`/`ui.toggle` para cada campo de `engine`.
- Botones: `Apply`, `Reset to defaults`, `Clear overrides`.
- Si el proyecto expone `properties`, listarlas como toggles/sliders (autor podría no tener
  nombres → agrupar bajo "Show N options the author left unnamed").

### Pantalla 3 — GPU / diagnóstico
- Estado de la medición en curso (progreso de `probe_all`).
- Lista de blocklist con `busy_pct` medido y botón "Allow anyway".
- Texto explicando el criterio (medición real de RC6, no heurística por tipo).

### Reglas de UI
- Renderizar siempre en `onOpen` y después de cada cambio de estado (el host diffea).
- Teclado: `onKey` → izquierda/derecha mueve offset en carrusel; Enter aplica el enfocado;
  `g` alterna vista; `Escape` vuelve de Options.
- Sin estados vacíos mudos: `no_wallpapers`, `list_failed`, `missing_project_json`.

---

## 6. Detección de wallpapers problemáticos (lo nuevo)

**Criterio: medición real, nunca por tipo.** Un `scene` puede ser liviano y un `video` 4K
puede saturar. El tipo no predice la carga.

`lib/gpuprobe.luau`:
```lua
M.readCounters(cardIndex) -> { rc6 = number|nil, freq = number|nil }
-- lee /sys/class/drm/cardN/power/rc6_residency_ms y
--      /sys/class/drm/cardN/gt_cur_freq_mhz (detecta el card con i915/xe)
M.profile(prev, cur, elapsedMs) -> { idle_pct, busy_pct, freq_mhz }
-- idle_pct = (cur.rc6 - prev.rc6) / elapsedMs * 100, clamp 0..100
M.classify(profile, threshold) -> "ok" | "heavy"
-- heavy si busy_pct >= threshold (default 85) durante la ventana
```
El **service** hace el ciclo: aplicar el wallpaper → esperar `WARMUP_MS` (3000) para que
compile shaders → medir `SAMPLE_MS` (4000) → restaurar el wallpaper anterior → guardar en
`blocklist` si `heavy`. El probe de `probe_all` procesa de a uno, con `runAsync` +
`setUpdateInterval`, nunca bloqueando el hilo del servicio.

Auto-rechazo: al aplicar o ciclar, si `blocklist[id].reason == "gpu"` → no aplicar, notificar
`tr("gpu.blocked", {name=...})`, salvo que el request traiga `force = true`.

---

## 7. Reglas de código (obligatorias para todos los módulos)

1. `--!strict` en todos los archivos, con anotaciones de tipo en firmas públicas.
2. Sin globales mutables: cada módulo devuelve una tabla `M` con funciones.
3. Sin código muerto, sin funciones sin llamador, sin `if false`.
4. Sin duplicar parsing/validación: helpers en `lib/util.luau`.
5. Todo acceso a disco con manejo de error (`local ok, err`) y `noctalia.log` en fallo.
6. Sin `os.execute`/`io.*` (sandbox); solo `noctalia.*`.
7. Strings de UI **siempre** por `noctalia.tr`, nunca hardcodeados.
8. Comentarios solo donde la intención no es obvia; nada de banners decorativos.
9. Nombres en inglés; strings de UI traducidos (en/es).
10. Ninguna función debe superar ~60 líneas; si pasa, extraer.

## 8. Validación antes de entregar

```bash
for f in lib/*.luau *.luau; do
  luau-compile --binary "$f" > /dev/null || echo "FALLA $f"
done
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .
```

El auditor corre **12 chequeos** y ninguno es decorativo; cada uno existe por un bug real
de este plugin:

| # | Chequeo | Bug que previene |
|---|---|---|
| 1 | manifiesto válido (`label_key`, deps, entries) | un `label` en un ajuste hacía que el host ignorara el plugin entero |
| 2 | `capture_keys` sin `Return` | el panel se comía el Enter del buscador |
| 3 | requires resueltos | un `require` roto deja la entrada sin cargar |
| 4 | exports sin llamador | código muerto (`M.is_favorite`, `M.refresh`) |
| 5 | acciones emitidas ↔ atendidas | el panel pide una acción que el service ignora |
| 6 | archivos fuera de lugar | temporales dentro del repo |
| 7 | identificadores usados antes de declararse | `emptyState`, `isFavorite`, `CAPTION_H` |
| 8 | globals implícitos | un `total_pages = …` sin `local` |
| 9 | nombres fuera del alcance de su función | bloques movidos a la función equivocada |
| 10 | llamadas a funciones declaradas más abajo | `wallhavenFilters` en `wallhavenBar` |
| 11 | definiciones duplicadas | `wallhavenFilters` definido dos veces (gana el viejo) |
| 12 | `local` redeclarado en la misma función | `local source` tabla y después string: los filtros y el flag de debug se perdían |

El modo debug (`debug` en el store) tiene que quedar **apagado por defecto**: deja
`[dbg]` en cada acción, escaneo, arranque y publicación, más `[dbg:panel]` del lado de la
UI. Para diagnosticar sin mirar la máquina está `debug_dump`, que escribe el reporte en
la carpeta de datos.

Además, antes de dar algo por terminado: recargar el plugin y verificar en
`~/.local/state/noctalia/noctalia.log` que no haya `[ERR]`, `CPU budget` ni
`disabled after repeated timeouts`.

## Extensiones (v0.2)

- `b3l0w we solid --color #rrggbb --out archivo.png [--size WxH]`: genera el wallpaper
  de un solo color. El plugin lo produce en su carpeta de datos y lo aplica con
  `setWallpaper`, igual que hace el panel built-in al elegir un color.
- `b3l0w we scan --sort name|date|random`: orden del catálogo local. `random` mezcla en
  cada escaneo; `date` ordena por mtime descendente.
- Acción `apply_color {color}`: valida `#rrggbb`, genera el PNG y aplica con `repaint()`.
- Acción `set_local_sort {sort}`: guarda el orden y reescanea la fuente activa.
- `apply {id, output}` acepta `output = "*"` para aplicar en todas las salidas.

## Miniaturas de imágenes locales

`b3l0w we scan --thumbs DIR [--thumb-size 320]` genera una miniatura JPEG por imagen en
`DIR`, con nombre `v-<djb2(ruta)>.jpg` — el mismo esquema que usa el plugin para las
miniaturas de video, así `apply_cached_thumbs` las reconoce sin cambios. El item del JSON
sale con `thumb` y `title` (sin eso la tarjeta mostraba la ruta absoluta como título).

El service publica el catálogo en dos fases: primero la lista (escaneo, ~20 ms) y después
el mismo catálogo con los `thumb` puestos, cuando el segundo pase del CLI terminó.
