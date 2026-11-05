## 0.4.1 — el panel abre en la barra del puntero

### Corregido

- **El panel se abría en la barra principal.** Al cambiar de ancho el panel se cerraba y
  se reabría por IPC, y una reapertura por IPC **no lleva la barra de origen**
  (`sourceBarName` sólo viaja cuando la apertura viene de un widget), así que el host lo
  anclaba en la primera barra. Ahora quien abre elige la entrada correcta y el panel no
  se reabre.
- **El widget no hacía toggle**: abría siempre `b3l0w/wallpaper:panel`, así que con otra
  entrada abierta el segundo click la reabría en vez de cerrarla.

### Añadido

- **`~/.local/state/noctalia/panel-entries.json`**: el servicio publica ahí el escalón que
  pide la configuración vigente. Lo leen el widget del plugin y las hover zones en el
  momento del toggle. Es un archivo y no `noctalia.state` porque el state **no se comparte
  entre plugins**, y quien abre el panel casi siempre es otro plugin.
- **`lib/panel_size.luau`**: la geometría del ancho (escalera, celda, tope de tarjeta) en
  un solo lugar, compartida por el panel, el servicio y el widget.
- Las tarjetas se recortan contra el ancho real del panel abierto, así que una entrada que
  no coincide con la configuración no desborda.

### Cambiado

- **El ancho nuevo se aplica al abrir, no en vivo.** Si cambiás el ancho con el panel
  abierto, el panel se queda como está y el valor entra en la próxima apertura. Antes se
  reabría solo; esa reapertura era justamente la que lo mandaba a la barra equivocada.

## 0.4.0 — el panel se adapta al contenido

### Añadido

- **El panel se dimensiona a lo que dibuja.** El ancho ya no es una constante de
  1500 px: sale de `wallpapers visibles × ancho de tarjeta + separaciones + zonas
  + padding`. Con 3 wallpapers el panel se achica a ~1000 px; si agrandás las
  tarjetas vuelve a crecer.
- **Ancho del panel por modo** (Opciones → Disposición): carrusel y grilla eligen
  el ancho del panel por separado. `0` = automático.
- **Escalera de entradas de panel**: `panel_e800.luau` … `panel_e1900.luau`, una
  por escalón de 100 px. El plugin abre la que corresponde y se oculta del
  launcher salvo la de 1500 (`shell.launcher.panels.ignored`).

### Corregido

- **`MAX_FOCUS_W` no estaba definido**: el slider del ancho de tarjeta recibía
  `max = nil` y el host lo ignoraba. Ahora el tope es el que entra en el panel más
  ancho, y crece cuando hay menos wallpapers visibles (558 px con 3, 328 con 5).
- **El ancho por celda ya no se reparte sobre 5 fijo.** Antes, con 3 wallpapers,
  la tira se acortaba pero las tarjetas conservaban el tamaño de 5; ahora la
  celda y el panel salen del mismo cálculo, así que el panel entero cambia.
- **La tabla de Disposición del README** estaba partida por un párrafo en el medio.

### Cambiado

- `panel.luau` pasa a ser un **módulo** (`return M`) y cada entry de la escalera
  publica los hooks como globales, igual que `b3l0w-audio`. El runner de tests
  concatena módulo + `tests/panel_entry_shim.luau` + spec.

## 0.3.0 — carrusel sin flechas, con el fondo del plugin y el conteo a la vista

### Añadido

- **Cuántos wallpapers se ven a la vez** en el carrusel: **3** (el enfocado y uno
  a cada lado) o **5** (el coverflow completo). Vive en Opciones → Disposición →
  Carrusel y en `view.carousel.slots` del store.
  - El ancho por celda se calcula siempre sobre 5: si se repartiera el panel
    entre 3, cada una mediría un tercio más y las imágenes se harían enormes al
    cambiar el conteo. Lo que se acorta es la tira, que queda centrada.
  - El slot fuera del catálogo (foco en el primer o el último wallpaper)
    repite el wallpaper del borde atenuado al 35 %, en vez de ser un hueco.

### Corregido

- **Las flechas del carrusel** (`‹ ›` en los extremos) ya no se dibujan. Las
  zonas siguen, porque son las que disparan el scroll por hover, pero sin glifo:
  competían con las imágenes.
- **El fondo de las tarjetas** era un tinte `surface_container/0.30` que se veía
  como un rectángulo de otro color alrededor de cada wallpaper. Ahora el marco es
  transparente y las tarjetas quedan sobre el fondo del plugin. El wallpaper
  aplicado sigue distinguido con un tinte `primary`.
  - El transparente va como hex explícito (`#00000000`) y no como clave ausente:
    el host no tiene `clearFill`, así que si el `fill` se omite en un nodo que se
    reusa (misma key) el color anterior se queda pegado.
- **La tira no se centraba** con 3 wallpapers: la fila de celdas lacked `flexGrow`,
  así que el host la medía por contenido y, dentro de la tira (`space_between`),
  quedaba pegada a un borde.
- **`slots` no llegaba al panel**: el service lo persistía, pero `cleanLayout`
  reconstruía el layout con una lista fija de claves y lo descartaba al cargar el
  estado.

## 0.2.0 — disposición por modo

### Añadido

- **Disposición por vista**: carrusel y grilla eligen por separado el estilo
  (`full` / `minimal`), el ancho y el alto de tarjeta, con `0` = automático.
- **Minimal**: sin nombres, contadores ni barra; sólo las imágenes.
- **Barra de progreso del carrusel** con interruptor propio.
- **"Aplicar en" en todos los modos** (antes sólo con el motor) y con interruptor
  para esconderlo.
- **Etiqueta opcional** en el selector carrusel/grilla (sólo icono si se apaga).
- Traza `[dbg:panel] anim t=… foco=… delta=…` para verificar transiciones.

### Corregido

- **El panel dejó de aparecer** por un `tableAt(nil, …)` en el primer render:
  `storeTable()` todavía no tenía el store y el render moría en silencio.
  `tableAt` ahora tolera `nil`.
- **Scroll de la grilla en Wallhaven**: `revealKey` viajaba en cada render y el host
  devolvía la vista a la tarjeta enfocada en cada tick de rueda. Ahora sólo se envía
  cuando el foco lo pidió.
- **Transición del carrusel**: el delta del `onFrameTick` se normaliza si llega en
  segundos; con `FOCUS_MS` en ms una transición podía durar minutos y parecer un
  salto. Duración a 260 ms.
- **Scroll por hover del carrusel**: las zonas `‹ ›` tienen clave fija y viven en los
  extremos, así el gesto no se corta al re-renderizar las tarjetas.

# CHANGELOG

Formato: [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/). Versión según
`plugin.toml`.

## [0.1.0] — 2026-11-01

Primera versión publicable. Reescritura propia del plugin `tadomika_ari/w-engine` que
absorbe los cuatro plugins de wallpaper de Noctalia.

### Fuentes

- **Wallpaper Engine**: catálogo del Workshop `431960`, aplicación con
  `linux-wallpaperengine`, propiedades por fondo (`--set-property`).
- **Videos locales**: `mpvpaper` con `loop`, `mute`, `hwdec` y flags extra.
- **Imágenes locales**: `setWallpaper` de Noctalia, escaneo recursivo con `scan_depth`.
- **Wallhaven**: cliente HTTP real, pureza y categorías como código de tres dígitos,
  paginación acumulativa con reintentos, tope configurable.
- **Color sólido**: PNG generado por `b3l0w we solid` y aplicado como cualquier imagen.

### Panel

- Carrusel coverflow de cinco celdas con foco escalado y animación por `onFrameTick`.
- Grilla con ventanas de 120 tarjetas, `revealKey` para el foco por teclado y alto
  explícito (dentro de `height="content"` un `flexGrow` mide 0).
- Buscador condicional: sólo en grilla o Wallhaven (ahí la búsqueda va a la API).
- Favoritos con filtro, propiedades por wallpaper, selector "Aplicar en" (una salida o
  todas) y orden del catálogo local (nombre / fecha / aleatorio).
- Tres pantallas: Browse, Opciones y GPU/diagnóstico.

### Correcto/robusto

- **Un solo wallpaper vivo**: el barrido de `linux-wallpaperengine` y `mpvpaper` va
  dentro del mismo comando de arranque (`setsid nohup … & echo $! > pidfile`).
- **`repaint()`**: recrea la superficie de fondo porque Umbriel no repinta las
  layer-shell existentes.
- **Presupuesto de CPU**: el trabajo pesado (catálogo, miniaturas, PNG) pasó al CLI
  `b3l0w we` en Go. Un recorrido en Luau medía 26–30 ms contra 25 ms de presupuesto y
  el `set_source` moría a mitad.
- **Escaneo con token reservado antes de lanzar**: sin eso, `ensure_catalog` (cada
  500 ms) relanzaba el escaneo y descartaba el anterior; el catálogo tardaba 8 s.
- **Publicación en dos fases** para imágenes: catálogo al instante, miniaturas cuando
  ffmpeg termina.
- **Memo de la lista filtrada** invalidado por render (sin invalidar, el panel mostraba
  la primera lista para siempre).
- **`storeValue`** para leer escalares del store: `tableAt` devuelve `{}` con strings y
  la fuente activa caía siempre al default.

### CLI (`b3l0w`)

- `we list --json` ahora incluye `properties` (los 8 tipos de Wallpaper Engine) y el
  escaneo de imágenes emite `title` y `thumb`.
- Nuevos comandos usados por este plugin: `we scan --thumbs`, `we solid`.

### Debug

- Ajuste `debug` (default **false**) y botón **Modo debug** en Opciones.
- Trazas `[dbg]` en cada acción IPC, escaneo, arranque de proceso con su resultado,
  publicación de catálogo, página de Wallhaven y resultado de la sonda de GPU.
- Trazas `[dbg:panel]` del lado de la UI: qué se pidió y con qué estado abrió el panel.
- Acción `debug_dump`: escribe `debug-report.txt` con estado, catálogo, procesos vivos y
  el final de `engine.log`, sin depender de que el modo esté activo.

### Documentación

- README con los 18 ajustes, las 24 acciones IPC, atajos del panel, datos en disco y
  limitaciones reales.
- SPEC con el contrato `noctalia.state`, el modelo de datos y los 11 chequeos del
  auditor.
