# b3l0w wallpaper

Plugin de [Noctalia](https://noctalia.dev) que reemplaza **cuatro** plugins por uno:
Wallpaper Engine, videos con `mpvpaper`, imágenes de carpetas locales, Wallhaven como
fuente remota y, además, fondos de un solo color.

Escrito en Luau, `plugin_api = 43` (Noctalia v5.4.1). Reescritura propia del plugin
`tadomika_ari/w-engine`, con tres ideas detrás:

1. **Un solo selector** con cinco fuentes y un modo de vista (carrusel tipo coverflow o
   grilla), en vez de cuatro paneles distintos.
2. **Paridad de ajustes** con los originales: FPS, escalado, capa, volumen, pausa,
   propiedades por fondo, filtros de Wallhaven, orden del catálogo y favoritos.
3. **Un solo wallpaper vivo**: motor, reproductor o imagen, nunca dos.

## Modos

| Modo | Fuente | Qué usa |
|---|---|---|
| `engine` | Workshop `431960` de Steam | `linux-wallpaperengine` |
| `videos` | carpeta configurable (recursiva) | `mpvpaper` |
| `images` | carpeta configurable (recursiva) | `setWallpaper` de Noctalia |
| `wallhaven` | API de wallhaven.cc | `setWallpaper` + caché de miniaturas |
| color | — | PNG generado con `b3l0w we solid` |

El motor y el reproductor se lanzan con `setsid nohup` y dejan su PID en un archivo; el
barrido de procesos viejos va **dentro del mismo comando** de arranque. Si el barrido se
hace en un `runAsync` aparte, mata al proceso recién nacido.

## Qué hace

- **Catálogo** de las cuatro fuentes, escaneado por el CLI `b3l0w` (Go) y no en Luau: el
  host da 25 ms de CPU por callback y un recorrido del workshop medía 26–30 ms.
- **Aplica** el fondo elegido y detiene cualquier otro proceso de wallpaper que esté
  vivo (`linux-wallpaperengine` y `mpvpaper`).
- **Miniaturas**: videos con `b3l0w we still`, imágenes locales con `b3l0w we scan
  --thumbs` (ffmpeg, 4 en paralelo, cacheadas por hash de ruta).
- **Propiedades por fondo** (`--set-property`): las que el autor expuso en el
  `project.json`, con sus valores guardados por wallpaper.
- **Favoritos** por id, con filtro `sólo favoritos`.
- **Rotación** cada N minutos en orden o al azar, sobre una selección múltiple.
- **Medición de GPU** por fondo y blocklist de los que saturan (ver más abajo).
- **Sincronización de color**: si `sync_colors` está activo, deja una imagen fija del
  fondo para que el generador de paleta de Noctalia haga su trabajo.
- **Widget de barra** con glyph de estado, tooltip con el título y click que abre el panel.
- **Panel** de una sola ventana con tres pantallas: Browse, Opciones y GPU/diagnóstico.

## Instalación

El plugin se instala como enlace simbólico para que los cambios se vean sin copiar:

```bash
git clone https://github.com/Below-Z3R0/b3l0w-wallpaper ~/Documents/Github/b3l0w-wallpaper
ln -s ~/Documents/Github/b3l0w-wallpaper ~/.local/share/noctalia/plugins/b3l0w-wallpaper
```

Después, en Noctalia: **Settings → Plugins → b3l0w wallpaper** → habilitar. El panel se
abre desde el widget de la barra, desde una hover zone que apunte a
`b3l0w/wallpaper:panel`, o con `noctalia msg panel-open b3l0w/wallpaper:panel`.

Para abrirlo desde una hover zone (el caso normal, porque el panel tiene que salir en la
barra donde está el puntero), apuntá el widget a la entrada base
`b3l0w/wallpaper:panel`: el plugin resuelve el ancho que corresponde al abrir
(ver [El panel se dimensiona al contenido](#el-panel-se-dimensiona-al-contenido)).

Los plugins se materializan en `~/.local/state/noctalia/plugins/materialized/<autor>/`;
si el plugin no aparece en la lista, revisá ahí antes de reportar un problema.

### Dependencias

| binario | para qué | obligatorio |
|---|---|---|
| `b3l0w` (con el plugin `we`) | catálogo, miniaturas y fondos de color | sí |
| `linux-wallpaperengine` | renderizar el modo `engine` | sí |
| `mpvpaper` | modo `videos` | sí |
| `pkill`, `setsid` | barrido y desacople de procesos | sí |
| `ffmpeg` | miniaturas de video e imágenes | no |

```bash
command -v b3l0w linux-wallpaperengine mpvpaper pkill setsid ffmpeg
b3l0w we deps          # reporta qué falta, con ruta y versión
```

## Ajustes

Todos los del manifiesto. Los que además tienen control en el panel se indican.

| Ajuste | Tipo | Default | Qué hace |
|---|---|---|---|
| `grid_columns` | int | 4 | columnas de la grilla (2–8). Sólo se aplica en el primer arranque; después manda Opciones |
| `default_view` | select | `carousel` | vista al abrir (siembra el store en el primer arranque) |
| `animations` | bool | true | transiciones y fades |
| `debug` | bool | false | trazas detalladas en el log (ver abajo) |
| `apply_on` | bool | true | selector "Aplicar en" en la barra (todos los modos) · en Opciones |
| `view_label` | bool | true | etiqueta de texto en el selector carrusel/grilla · en Opciones |
| `carousel` | tabla | full/auto | `layout` (`full`/`minimal`), `w`, `h` (0 = auto), `progress` · en Opciones |
| `grid` | tabla | full/auto | `layout` (`full`/`minimal`), `w`, `h` (0 = auto) · en Opciones |
| `images_dir` | folder | `~/Pictures/Wallpapers` | raíz de imágenes locales |
| `videos_dir` | folder | `~/Videos` | raíz de videos locales |
| `scan_depth` | int | 2 | profundidad de escaneo (0–5) |
| `sync_colors` | bool | true | paleta de Noctalia desde el fondo |
| `download_dir` | folder | — | dónde guardar lo descargado de Wallhaven |
| `wallhaven_max` | number | 1200 | tope de items a acumular (120/480/1200/2400) |
| `wallhaven_api_key` | string | — | clave de la API (opcional) |
| `video_loop` | bool | true | `mpvpaper --loop` |
| `video_mute` | bool | true | `--mute` |
| `video_hwdec` | bool | true | `--hwdec` |
| `video_options` | string | — | flags extra para `mpvpaper` |
| `gpu_threshold` | int | 85 | % de GPU que bloquea un fondo |
| `probe_warmup_ms` | int | 3000 | espera antes de medir |
| `probe_sample_ms` | int | 4000 | ventana de muestreo |

## Atajos del panel

| Tecla | Acción |
|---|---|
| `←` `→` `↑` `↓` / `h` `j` `k` `l` | mover el foco (una columna en grilla) |
| `Prior` / `Next` | salto de página |
| `Home` / `End` | primero / último |
| `Enter` | aplicar el fondo enfocado |
| `f` | marcar / desmarcar favorito |
| `p` | pausar / reanudar el motor en pantalla |
| `g` | alternar carrusel ↔ grilla |
| `Esc` | volver a Browse desde Opciones o GPU |

`capture_keys` del manifiesto incluye esas teclas **menos** `Return`: si el panel la
captura, el buscador pierde el Enter.

## IPC

`noctalia msg plugin b3l0w/wallpaper:start all <acción> '<json>'`. 24 acciones:

| Acción | Payload | Qué hace |
|---|---|---|
| `apply` | `{id, output?, force?}` | aplica un fondo; `output="*"` = todas las salidas |
| `stop` | `{output?}` | detiene el wallpaper en pantalla |
| `pause` / `resume` | — | `SIGSTOP` / `SIGCONT` al proceso vivo |
| `cycle_start` | `{ids, minutes, order}` | rotación automática |
| `cycle_stop` | — | corta la rotación |
| `refresh` | — | reescanea la fuente activa |
| `set_source` | `{source}` | `engine` \| `images` \| `videos` \| `wallhaven` |
| `set_view` | `{mode?, columns?, spacing?, tile?}` | vista y densidad |
| `set_options` | `{id?, engine, restart?, clear_overrides?}` | opciones del motor, globales o por fondo |
| `set_property` | `{id, name, value}` | una propiedad del autor |
| `clear_properties` | `{id}` | vuelve a los valores del proyecto |
| `favorite` | `{id}` | alterna favorito |
| `set_theme` | `{enabled}` | paleta desde el fondo |
| `set_debug` | `{enabled}` | modo debug (trazas `[dbg]`) |
| `debug_dump` | — | escribe `debug-report.txt` y lo vuelca al log |
| `set_local_sort` | `{sort}` | `name` \| `date` \| `random` |
| `apply_color` | `{color}` | fondo de color `#rrggbb` |
| `set_wallhaven` | `{query?, purity?, categories?, sorting?, order?, ratios?, res?, page?}` | filtros de la API |
| `set_wh_max` | `{value}` | tope de items a acumular |
| `probe` | `{id}` | mide la GPU de un fondo |
| `probe_all` | — | mide los que no tienen perfil |
| `unblock` | `{id}` | saca un fondo de la blocklist |
| `open_screen` | `{screen, id?}` | abre `browse` \| `options` \| `gpu` |
| `screen` | `{name}` | alias viejo de `open_screen` |
| `nav` | `{delta}` | mueve el foco desde el widget |

Ejemplos:

```bash
noctalia msg plugin b3l0w/wallpaper:start all apply '{"id":"2688873830"}'
noctalia msg plugin b3l0w/wallpaper:start all set_source '{"source":"wallhaven"}'
noctalia msg plugin b3l0w/wallpaper:start all apply_color '{"color":"#1e1e2e"}'
```

## Wallhaven

Cliente HTTP real contra `https://wallhaven.cc/api/v1/search` (no es sólo lo descargado).

- **Filtros**: pureza y categorías como código de tres dígitos (`100` SFW, `010`
  sketchy, `001` NSFW; combinables → `110`), orden, sentido, proporción y resolución.
- **Paginación acumulativa**: 24 items por página, 1,2 s entre páginas y hasta 3
  reintentos, con el tope que elija el usuario. 2360 items / 99 páginas ≈ 130 s.
- **Default de orden `date_added`**: `toplist` + texto devuelve casi nada (`cyberpunk`:
  55 resultados contra 6200 con `relevance`); al escribir una búsqueda estando en
  `toplist` pasa solo a `relevance`.
- Sólo se cachean la miniatura y el wallpaper aplicado; el resto se pide en el momento.


## Disposición

Cada vista tiene su propia configuración: lo que elijas para el carrusel no toca la
grilla. Todo se ajusta desde **Opciones → Disposición**.

| Control | Carrusel | Grilla | Qué hace |
|---|:---:|:---:|---|
| Completo / Minimalista | sí | sí | `full` muestra nombres, contadores y barra; `minimal` deja sólo las imágenes |
| Ancho de tarjeta | sí | sí | px exactos; `auto` (slider en 0) usa el ancho por defecto |
| Alto de tarjeta | sí | sí | px exactos; `auto` usa la proporción 16:9 sobre el ancho elegido |
| Ancho del panel | sí | sí | ancho del panel completo; `auto` (slider en 0) lo deriva del contenido |
| Barra de progreso | sí | — | indicador de posición debajo de la tira |
| Wallpapers visibles | sí | — | cuántos se ven a la vez en la tira: **3** (el enfocado y uno a cada lado) o **5** (el coverflow completo) |
| Mostrar "Aplicar en" | global | global | el selector de salida aparece en **todos** los modos o en ninguno |
| Etiqueta del selector de vista | global | global | apagado deja sólo el icono del botón carrusel/grilla |

El marco de las tarjetas es **transparente**: las imágenes quedan sobre el mismo
fondo que el resto del plugin, sin un rectángulo de otro color alrededor. El
wallpaper aplicado sí se distingue, con un tinte `primary`.

Los valores viven en `view.carousel` / `view.grid` del store (`state.json`), así que
sobreviven al reinicio y no hay dos fuentes de verdad.

### El panel se dimensiona al contenido

El ancho del panel no es una constante: se deriva de lo que se va a dibujar.

```
ancho del panel = wallpapers visibles × ancho de tarjeta
                + separaciones
                + zonas de scroll
                + padding
```

El conteo de wallpapers fija el tamaño base — 3 pide un panel más angosto que 5 — y
el ancho de tarjeta lo alarga o lo achica desde ahí. Con los valores por defecto:

| Wallpapers visibles | Ancho de tarjeta | Panel |
|---|---|---|
| 5 | 260 px | 1500 px |
| 3 | 260 px | 1000 px |
| 3 | 120 px | 800 px |
| 3 | 300 px | 1100 px |

Con **Ancho del panel** distinto de `auto` manda ese valor y las tarjetas se
reparten el espacio.

#### Por qué hay varias entradas de panel

El host es dueño del tamaño y **no se puede cambiar en runtime**: el API de
`panel` es `render`, `close`, `openContextMenu`, `setWantsSecondTicks` y
`setNeedsFrameTick` — no hay `setWidth` — y el manifiesto sólo acepta un entero o
`"fill"` (no existe `width = "content"`).

Por eso el plugin declara una **escalera de entradas**, una por escalón de 100 px
entre 800 y 1900 (`panel_e800.luau` … `panel_e1900.luau`). Del launcher sólo se ve
`b3l0w/wallpaper:panel` (el escalón de 1500); el resto va en
`shell.launcher.panels.ignored` porque son la misma vista a otro ancho.

**Quien abre elige la entrada; el panel no se reabre.** El servicio publica el
escalón que pide la configuración vigente:

```lua
-- ~/.local/state/noctalia/panel-entries.json
{ "b3l0w/wallpaper:panel": "b3l0w/wallpaper:panel_w1000" }
```

y quien abre —el widget del plugin o una hover zone— lo lee en el momento del
toggle y abre esa entrada de una sola vez. Es un archivo y no `noctalia.state`
porque **el state no se comparte entre plugins**, y quien abre el panel casi
siempre es otro plugin.

Cerrar y reabrir el panel para cambiar de ancho, como se hacía antes, **no
funciona**: el host ancla un panel `attached` a la barra desde donde se abre
(`sourceBarName`), y esa información sólo viaja en la apertura que viene de un
widget. Una reapertura por `noctalia msg panel-open` no la lleva, así que el
panel aparecía en la barra principal en vez de en la del puntero.

Si alguien abre una entrada que no es la que pide la configuración (por ejemplo
`panel` a mano desde el launcher), el panel se queda en su barra y achica las
tarjetas para no desbordar; el ancho nuevo entra en la próxima apertura.

### Moverse por el carrusel

La API de paneles (`plugin_api 43`) **no expone la rueda del mouse**: `ui.scroll` es
sólo vertical y el único `onScroll` existe en los widgets de la barra. Por eso el
carrusel se mueve con:

- **hover en las zonas de los extremos** (avanza solo mientras el puntero está ahí),
- **rueda sobre el widget de la barra** (`widget.luau` la convierte en `nav`),
- **flechas ←/→** y `Prior`/`Next` con el panel abierto.

Las zonas de los extremos **no dibujan flechas**: son sólo el área de hover que
dispara el scroll. Dibujarlas competía con las imágenes.

#### Cuántos wallpapers se ven

En **Opciones → Disposición → Carrusel** se elige entre **3** y **5**. Con 5 se
ve el coverflow completo (el wallpaper enfocado al centro y dos a cada lado);
con 3, sólo el enfocado y uno a cada lado.

El ancho de cada tarjeta **no cambia** al cambiar el conteo: se calcula siempre
sobre 5 celdas. Si se repartiera el panel entre 3, cada una mediría un tercio
más y las imágenes se harían enormes al cambiar la opción. Lo que se acorta es
la **tira**, que queda centrada en el panel.

El slot que queda fuera del catálogo (cuando el foco está en el primer o en el
último wallpaper) repite el wallpaper del borde **atenuado al 35 %**, en vez de
ser un hueco vacío.


## Tests

El panel es un **módulo** (`return M`) y cada entry de la escalera publica los
hooks como globales, porque el host evalúa cada entry como script. Los tests
cargan lo mismo que el host: `tests/run.sh` concatena `tests/host_stub.luau` +
`lib/panel_size.luau` (inlinado: el `luau` de los tests no resuelve requires) +
`panel.luau` + `tests/panel_entry_shim.luau` + `tests/panel_spec.luau` y ejecuta
el resultado con `luau`. No hace falta sesión gráfica.

```bash
./tests/run.sh          # 117 checks: disposición, anchos de panel, cabecera, secciones, paginado
./tests/run.sh bench    # costo por render con 40 y 2400 items
```

El bench existe porque el host da **25 ms por callback**: si un render se pasa, la
acción se aborta a mitad y el panel queda sin publicar. Números actuales:

| Escenario | ms/render |
|---|---|
| carrusel · 2400 items | 0.03 |
| grilla · 2400 items (ventana de 120) | 0.42 |
| grilla minimal · 2400 items | 0.22 |
| opciones · 40 items | 0.11 |

Los stubs (`ui.*` devuelve un árbol inspeccionable, `noctalia.*` guarda el estado
falso) permiten afirmar sobre lo que el panel realmente dibuja: que el selector de
salida desaparece al apagarlo, que el minimal no tiene barra, que cada modo usa su
propio ancho.

## Debug

Interruptor **Modo debug** en *Opciones* del panel (y ajuste `debug` del manifiesto).
Apagado por defecto: con el log del host compartido por todos los plugins, el ruido tapa
los errores reales.

Encendido, cada evento deja una línea `[dbg] …` con pares `clave=valor`:

```
[dbg] ipc action=apply id=2688873830
[dbg] scan-engine root=/home/…/431960 force=true
[dbg] spawn argv=setsid nohup linux-wallpaperengine --screen-root 'eDP-1' …
[dbg] spawn-result ok=true output=eDP-1
[dbg] publish source=engine items=40
[dbg:panel] open source=engine items=40
```

Qué se traza: cada acción IPC recibida, cada escaneo (fuente, carpeta, items), cada
arranque de proceso con su resultado, cada publicación de catálogo, las páginas de
Wallhaven y el resultado de la sonda de GPU. El panel agrega `[dbg:panel]` con lo que
la UI pidió y con qué estado abrió.

Además hay un **reporte de diagnóstico** (botón en la pantalla GPU) que escribe
`debug-report.txt` en la carpeta de datos del plugin con estado, catálogo, procesos
vivos y las últimas 16 líneas de `engine.log`. Se genera sin depender del modo debug:

```
noctalia msg plugin b3l0w/wallpaper:start all debug_dump '{}'
```

## Cómo detecta los fondos pesados

**Criterio: medición real, nunca heurística por tipo.** Un `scene` puede ser liviano y un
`video` 4K puede saturar la GPU.

1. Se aplica el fondo a medir.
2. Se espera `probe_warmup_ms` para que terminen de compilarse los shaders.
3. Se lee dos veces `/sys/class/drm/cardN/power/rc6_residency_ms`, separadas por
   `probe_sample_ms`:

   ```
   busy_pct = 100 - (rc6_actual - rc6_previo) / ms_transcurridos * 100
   ```

4. Si `busy_pct >= gpu_threshold`, el fondo va a la blocklist con el valor medido y el
   timestamp; también se guarda la frecuencia del GPU como contexto.
5. Se restaura el fondo anterior.

Si el GPU no expone `rc6_residency_ms` (drivers sin `i915`/`xe`), la detección queda
desactivada y nada se bloquea: el plugin no inventa datos que el sistema no da.

## Estructura

```
plugin.toml          manifiesto: ajustes, widget, panel, servicio
widget.luau          widget de barra (glyph, tooltip, click)
panel.luau           UI: coverflow, grilla, opciones, GPU (módulo)
panel_e*.luau        una entry por escalón de ancho (800…1900)
service.luau         dueño de procesos, catálogos, IPC, rotación, medición
lib/panel_size.luau  geometría del ancho: escalera, celda, tope de tarjeta
lib/catalog.luau     workshop de Steam: raíces, project.json, find_by_id
lib/local.luau       escaneo de respaldo de carpetas (sin CLI)
lib/engine.luau      argv de linux-wallpaperengine + propiedades
lib/store.luau       estado persistido (validación, overrides, favoritos)
lib/wallhaven.luau   cliente de la API
lib/gpuprobe.luau    lectura de rc6 y clasificación
lib/util.luau        trim, clamp
translations/        es.json, en.json
types/               stubs de la API para el editor
```

Datos en `~/.local/state/noctalia/plugins/data/b3l0w/wallpaper/`:

| archivo | qué es |
|---|---|
| `state.json` | ajustes propios, favoritos, overrides, filtros |
| `pid-<salida>.pid` | PID del proceso vivo por salida |
| `engine.log` | stdout/stderr del motor o de mpvpaper |
| `thumbs/` | miniaturas `v-<hash>.jpg` |
| `wallhaven/` | miniaturas y fondos descargados |

## Contrato de layout con el host

Reglas verificadas en el source de Noctalia (`lib/ui/controls/flex.cpp`,
`lib/ui/builders.cpp`, `src/scripting/ui/ui_tree_reconciler.cpp`). Marcan la
diferencia entre un control que se dibuja y uno que no:

- **`flexGrow` solo se reparte si el contenedor tiene ancho conocido**
  (`mainKnown`). Un `ui.row` anidado dentro de otro `ui.row` se mide por
  contenido: el host salta el reparto y el hijo se queda en su mínimo. Para que
  funcione, el padre tiene que ser una `ui.column` con `align = "stretch"`, o
  el hijo necesita un `width` explícito.
- **En un `ui.input`, `width` es un mínimo**, no un ancho fijo: el reconciler
  llama a `setMinLayoutWidth`. Sin `width`, el campo cae a `kMinWidth` (48 px).
- **El `onChange` de un `ui.select` manda el índice en base 0**, no el valor.
  La API pública lo llama `selectedIndex`.
- **`ui.box({ opacity = 0 })` mide 0 px**: como espaciador hay que darle
  `flexGrow` en un contenedor con ancho conocido.
- **El host recorta 12 px del ancho pedido** del panel: el ancho útil real es
  `PANEL_W - 2 * PANEL_PAD_H - PANEL_CROP`.

## Auditoría

El plugin se audita a sí mismo en tres frentes, todos con comandos:

```bash
./tests/run.sh          # 117 checks del panel (lógica, IPC, layout)
./tests/run.sh bench    # rendimiento: presupuesto de 25 ms por render
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .
```

El auditor tiene 12 chequeos; el 12º detecta *shadowing* (dos locals con el
mismo nombre en una función), que fue la causa de un crash de autoref en la
tabla de estado.

Dos subagentes de auditoría (read-only) revisaron por separado las vistas de
navegación y el service. De sus 43 hallazgos se corrigieron 18 verificados en
el host; el resto quedó documentado aquí o descartado por no ser
reproducibles.

### Invariantes que los tests cubren

- La selección múltiple **arranca apagada** y la tarjeta de ciclo sólo se
  dibuja en ese modo (o con un ciclo corriendo, para poder detenerlo).
- **Minimal ≠ full**: minimal quita buscador de texto, selector de salida,
  contador, título y barra "reproduciendo ahora"; full los mantiene.
- El **scroll del grid sigue al foco** con el teclado (`revealKey`).
- La **tira del carrusel entra en el panel** con cualquier gap y ancho.
- La **fila de la grilla no se desborda** ni deja huecos a la derecha.
- Los **atajos de una letra** (`g`, `f`, `p`) no dispara mientras se escribe
  en el buscador.
- El **error de Wallhaven** llega al panel (una búsqueda fallida no se ve
  como una pantalla vacía).
- **Apply/pause/stop** dejan el estado coherente: `last` se limpia, `paused`
  se resetea y `apply("*")` no se mata a sí mismo.

## Limitaciones conocidas

- **Umbriel no repinta las superficies de fondo**: un video o un motor aplicado queda
  como imagen fija hasta que se recrea la superficie. El plugin lo fuerza con
  `repaint()` (destruye y recrea), así que se ve el primer cuadro, no la animación.
  Es del compositor, no del plugin.
- **No hay scroll horizontal** en la API de plugins: el carrusel se navega con las
  teclas, con hover en las zonas de los extremos y con la rueda sobre el widget de la
  barra. No hay flechas dibujadas.
- **El panel no se puede redimensionar en runtime**: el ancho sale de la entrada de la
  escalera con la que se abrió y el alto es por contenido, hasta 920. Si cambiás el
  ancho con el panel abierto, el panel no se mueve: el valor nuevo entra en la próxima
  apertura.
- **Los plugins no pueden escribir la config del shell**: `fill_mode`, transiciones y
  esquema de colores viven en `config.toml` y sólo los maneja Noctalia.
- **Click central del mouse no se puede capturar**: la API no expone el botón del medio;
  el favorito va por botón en la tarjeta y por la tecla `f`.
- **Un solo wallpaper por salida**: no hay fondos distintos por monitor con un mismo
  proceso.

## Desarrollo

```bash
# compilar (no hay build: el host carga el fuente)
luau-compile --binary panel.luau > /dev/null     # chequeo de sintaxis

# auditor: 12 chequeos (orden de declaración, duplicados, shadowing, etc.)
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .

# recargar tras un cambio
noctalia msg plugins disable b3l0w/wallpaper; sleep 2
noctalia msg plugins enable  b3l0w/wallpaper
```

Los chequeos 10, 11 y 12 existen por bugs reales de este plugin: una función llamada
antes de declararse (Lua la resuelve a un global nil y revienta en runtime), una función
definida dos veces y un `local` redeclarado en la misma función (el segundo gana y el
primero queda muerto). El log del host está en
`~/.local/state/noctalia/noctalia.log`.

## Licencia

MIT.
