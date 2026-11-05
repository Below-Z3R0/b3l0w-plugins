# Auditoría — plugin Noctalia `cleboost/anilist` v1.1.3

- **Fuente auditada (read-only):** `/home/b3low-z3r0/.local/state/noctalia/plugins/materialized/community/anilist/`
- **Host:** Noctalia **v5.4.1-41-gf2cebd97e016**; fuente C++ local en `/home/b3low-z3r0/.cache/paru/clone/noctalia-git/src/noctalia/` (todas las citas de host son de ahí).
- **Fecha:** 2026-11-01 · Perfil `parallel`
- **Alcance:** diagnóstico del bug de carátulas que desaparecen + inventario completo (entries, API, imágenes, UI, IPC, límites).
- **No se modificó ningún archivo del plugin.**

Tamaño real: `service.luau` 1483 líneas · `panel.luau` 744 · `widget.luau` 126 · `plugin.toml` 67 · `scripts/oauth_login.py` 260 · `translations/{de,en,fr}.json` 76 hojas c/u.

---

## 1. Entries, settings y panel

### 1.1 Manifest (`plugin.toml`)

| Elemento | Evidencia | Notas |
|---|---|---|
| `id = "cleboost/anilist"`, `version = 1.1.3`, `plugin_api = 15` | `plugin.toml:1-4` | El host corre API 45 (`docs/plugin-api.json` llega a nivel 45); declara 15, así que todo lo de nivel ≥16 está “fuera de contrato” aunque el host lo acepte. |
| deps `python3`, `xdg-open` | `plugin.toml:10` | `python3` sólo para el OAuth; `zenity`/`kdialog` se usan de forma opcional para “descargar carátula” (`README.md:20`). |
| settings globales: `client_id`, `client_secret`, `access_token` (string) | `plugin.toml:12-31` | Los tres SIN `options` ni validación; `access_token` vacío ⇒ usa `token.json`. |
| widget `tracker` + settings `glyph` (glyph) y `count_mode` (select, 5 opciones) | `plugin.toml:33-55` | `count_mode`: `current\|completed\|total\|in_progress\|planning` (`plugin.toml:49-55`). |
| panel `library`: `width = 720`, `height = 640`, `placement = "floating"`, `position = "center"` | `plugin.toml:57-63` | Sin `persistent`, sin `capture_keys`, sin `max_height`. `height="content"` exigiría `plugin_api ≥ 42` (`docs/plugin-api.json`, feature `panel-content-height`). |
| service `api` | `plugin.toml:65-67` | `service-lifecycle` es nivel 17: con `plugin_api = 15` el service arranca al lanzar la shell, no al habilitar el plugin. |

Estado real del usuario (runtime, no del manifest): `~/.local/state/noctalia/settings.toml:431-435` inyecta
`library_placement = "attached"` y `library_open_near_click = true`, por eso el log dice
`opened "cleboost/anilist:library" as attached layer-shell`. Los defaults del manifest están **pisados**.

### 1.2 Settings (lectura en código)

| Clave | Dónde se lee | Comentario |
|---|---|---|
| `access_token` | `service.luau:108` | Si está vacío, cae a `token.json` (`service.luau:113`). |
| `client_id`, `client_secret` | `service.luau:1185-1190` | Se escriben en claro a `oauth_credentials.json` (`service.luau:1294-1298`) y se borran al terminar (`service.luau:1219-1224`). |
| `glyph` | `widget.luau:75` | |
| `count_mode` | `widget.luau:67` | |

### 1.3 Entries

| Entry | Callbacks globales | Evidencia |
|---|---|---|
| `service.luau` | `update()`, `onIpc()`, `init()`; se auto-invoca `init()` al final | `service.luau:1370`, `1462`, `1472`, `1483` |
| `panel.luau` | `onOpen`, `onClose`, `update`, más handlers de click (`onRefresh`, `onTabAnime`, …) | `panel.luau:665`, `675`, `683`, `696-742` |
| `widget.luau` | `update`, `onClick`, `onRightClick` | `widget.luau:114`, `118`, `122` |

Contrato correcto (globales, sin `return`) — cumplido en los tres.

---

## 2. API de AniList

### 2.1 Endpoint y auth

- GraphQL: `https://graphql.anilist.co` (`service.luau:5`), POST JSON con `Content-Type/Accept: application/json`, `User-Agent: noctalia-anilist-plugin` y `Authorization: Bearer <token>` (`service.luau:739-748`).
- Token: `getConfig("access_token")` o `<dataDir>/token.json` (`service.luau:59-114`). `token.json` guarda `{access_token, saved_at}` (`service.luau:88-98`); si el JSON está corrupto se **borra** el archivo (`service.luau:80-84`).
- Ante `invalid token` / `unauthorized`, `decodeParsed` normaliza el error (`service.luau:670-689`) y `setLoadError` **borra el token y vacía la lista** (`service.luau:691-703`).
- OAuth: `scripts/oauth_login.py` levanta un server local en `127.0.0.1:7823/callback` (`oauth_login.py:17-22`), canjea el `code` con Basic auth (`oauth_login.py:43-69`) y emite el token por stdout **y** por `oauth_result.json` (`oauth_login.py:25-30`). El service lo corre con `runStream` y además hace polling del archivo cada 500 ms (`service.luau:1339`, `1346-1368`, `OAUTH_POLL_MS = 500` en `service.luau:247`).
- **No hay `state` en el flujo OAuth** (`oauth_login.py:229-234`): callback loopback sin protección CSRF. Riesgo bajo (127.0.0.1), pero es un hallazgo real.

### 2.2 Queries exactas

**Lista** (`service.luau:607-643`), variables `$userId: Int, $type: MediaType, $chunk: Int, $perChunk: Int`:

```graphql
MediaListCollection(userId: $userId, type: $type, forceSingleCompletedList: true, chunk: $chunk, perChunk: $perChunk) {
  hasNextChunk
  lists { name isCustomList status
    entries { id mediaId status progress progressVolumes score(format: POINT_100) updatedAt
      media { id type episodes chapters volumes
        coverImage { color extraLarge large medium }
        title { userPreferred }
        nextAiringEpisode { airingAt episode } } } }
}
```

**Viewer** (`service.luau:645-652`): `Viewer { id name }`.

**Mutación** (`service.luau:654-668`): `SaveMediaListEntry(mediaId, progress, status) { id progress status media { id episodes chapters title { userPreferred } } }`.

### 2.3 Paginación

- `CHUNK_SIZE = 50` (`service.luau:10`), enviado como `perChunk` (`service.luau:822-826`).
- Máquina de estados por job: `chunk`, `awaitingChunk`, `hasNextChunk`, `needsMerge`, `done` (`service.luau:777-792`, `989-1024`).
- Un chunk por vez, ANIME y MANGA en paralelo lógico, disparados desde `update()` (`service.luau:1010-1049`), con `setUpdateInterval(300)` mientras hay fetch (`FETCH_UPDATE_MS`, `service.luau:13`, `254-256`).
- Merge por `mediaId` conservando el `updatedAt` más nuevo (`service.luau:187-200`), y armado de la lista final en lotes de 100 con orden alfabético (`FINALIZE_SORT_BATCH`, `service.luau:12`, `918-970`).
- **Sin reintentos ni backoff**: un fallo de red deja `job.error` y aborta todo el fetch (`service.luau:827-833`).

---

## 3. Gestión de imágenes

**No se usa la URL remota en la UI** (`ui.image` sólo acepta rutas locales). Flujo completo:

| Paso | Evidencia |
|---|---|
| URL de origen por entry: `coverImage.extraLarge or large or medium` → campo `coverUrl` | `service.luau:164`, `178` |
| El campo que consume la UI es `coverPath`, inicializado a `nil` en cada normalización | `service.luau:179` |
| Directorio de caché: `<pluginDataDir>/covers/v2` (`COVER_CACHE_VERSION = 2`) | `service.luau:236-237`, `264-278` |
| Nombre de archivo: `<mediaId>.jpg` + `<mediaId>.jpg.meta.json` | `service.luau:280-294` |
| El meta guarda `{url, version}`; la validez exige archivo + meta + `url` idéntica + `version == 2` | `service.luau:296-314` |
| Descarga: `noctalia.download(url, path, cb)`; al `ok` escribe meta y publica el path | `service.luau:486-495` |
| Borrado explícito: `removeCoverCache(mediaId)` (jpg + meta) | `service.luau:328-337`, llamado en `376`, `466` |
| Purga legacy: borra `.jpg`/`.meta.json` sueltos en `covers/` y contenidos de `v<N>` con `N ≠ 2` | `service.luau:339-363` (invocada en `init`, `service.luau:1472-1475`) |
| Sin TTL, sin límite de tamaño, sin GC de huérfanos | (no existe) |

Estado real en disco: **334 jpg + 334 meta = 668 archivos, 68 MB**, último `mtime` 2026-10-05. O sea: **el archivo no se borra**; el caché local está íntegro. Esto descarta de entrada la hipótesis “se borra el temporal”.

El host descarga de forma **atómica**: escribe `<dest>.part` y hace `rename()` al destino recién al terminar (`http_client.cpp:202`, `655-665`). Además deduplica por destino: dos `download()` al mismo path mientras vuela comparten callback (`http_client.cpp:191-198`). Por eso una descarga en curso nunca deja un JPG a medias visible para la UI.

---

## 4. DIAGNÓSTICO DEL BUG (carátulas que desaparecen)

### 4.1 Causa raíz

**`coverPath` no es un dato derivado del caché, es un campo del modelo que se reconstruye a `nil` en cada refresco de lista.** El refresco lo dispara el propio panel al abrirse, y el modelo con `coverPath = nil` se publica a la UI antes de que el pase de carátulas lo repueble. La UI no “pierde la textura”: recibe un snapshot en el que `coverPath` ya no existe y dibuja el placeholder.

Secuencia exacta, con líneas:

1. **El panel se abre** con el snapshot anterior, que **sí** tiene `coverPath` (se veían las carátulas). `panel.luau:665-673`:
   ```lua
   function onOpen(_context)
     noctalia.state.set("anilist_open", true)
     resetListView()
     if snapshot.viewer and snapshot.viewer.id then
       sendCommand("refresh", { mediaType = mediaTab, silent = true })   -- panel.luau:669
     end
   ```
   ⇒ cada apertura pide un **refresco silencioso** de la pestaña activa.

2. **El service acepta el refresco** (`service.luau:1458-1460` → `processCommand`, `service.luau:1406-1419`) y entra en `reloadMediaType(mediaType, silent=true)` (`service.luau:1093-1126`), que crea un `libraryFetch` de modo `reload` (`1122-1125`).

3. **Fetch por chunks** (50 por chunk, `service.luau:815-850`). Tarda **~1-3 s** según red: esto es el “unos segundos” del reporte.

4. **`finishFinalize` reemplaza la lista entera por filas nuevas** (`service.luau:895-916`):
   ```lua
   if queue.mode == "reload" then
     snapshot.anime = queue.rows        -- service.luau:898  (filas nuevas)
   ...
   resetBackgroundCovers()              -- 912
   queuePriorityCovers(lastCoverPriority) -- 913
   publishSnapshot()                    -- 914
   ```
   Esas filas vienen de `appendSortedRows` (`service.luau:224-234`) sobre `byMediaId`, cuyas filas se crearon en `normalizeEntry`, que **fija `coverPath = nil`** (`service.luau:179`). **El camino de finalize nunca llama a `attachCoverPathForEntry`**: en todo el archivo esa función sólo se invoca desde `processPriorityCovers` (`service.luau:527`) y `processBackgroundCovers` (`service.luau:590`).

5. **Se publica el modelo sin carátulas** (`publishSnapshot`, `service.luau:116-119`). El estado viaja como JSON al runtime del panel (`luau_host.cpp:2810`, `plugin_state_store.h`), así que `coverPath` **desaparece del payload**.

6. **El panel re-renderiza y cambia todos los nodos de imagen por cajas de color**: `renderCover` mira `entry.coverPath`; si es nil devuelve un `ui.column` con `fill = entry.coverColor` (`panel.luau:428-464`, placeholder en `447-463`). Efecto visual: **todas las carátulas se convierten en rectángulos planos de un saque**.

7. **La restauración es diferida y no se publica a tiempo.** `attachCoverPathForEntry` repone el path desde el meta del disco (`service.luau:365-378`), pero el resultado sólo se marca como pendiente:
   ```lua
   local function requestCoverSnapshot() pendingCoverSnapshot = true end        -- 412-414
   function flushCoverSnapshot() if pendingCoverSnapshot then ... publishSnapshot() end end -- 416-421
   ```
   Y `flushCoverSnapshot` **sólo** corre en tres casos: (a) cuando hay descargas en vuelo, dentro de `update()` (`service.luau:1387-1389`); (b) cuando el pase de fondo **termina de recorrer toda la lista** (`service.luau:585-586` → `syncUpdateInterval` → `service.luau:259-260`); (c) al quedar todo idle.
   El pase de fondo avanza de a `BACKGROUND_COVER_BATCH = 12` entradas por tick de 120 ms (`service.luau:11`, `14`, `568-600`). Con ~600 entradas son **~50 ticks ≈ 6 s** hasta el flush si no hay ninguna descarga que lo fuerce antes.

**Resultado:** carátulas visibles → ~1-3 s después se abre el refresco → **todo desaparece** → vuelven de a tandas cuando el pase de fondo termina (o antes, si casualmente hay descargas en vuelo que hagan flush cada tick). Si el usuario cierra el panel antes (auto-cierre medido: **2,5 s**), ve el hueco y nunca la reposición.

### 4.2 Agravantes verificados

| # | Agravante | Evidencia |
|---|---|---|
| A1 | El refresco silencioso también ocurre en cada reapertura; no hay “sólo si el snapshot está viejo”. | `panel.luau:668-670` |
| A2 | Cualquier recarga del plugin (**service incluido**) reinicia el modelo en memoria: `snapshot.anime/manga` vuelven a `{}` y todo `coverPath` se pierde. En el log hay **20+ `loaded plugin 'cleboost/anilist'` entre 03:28 y 03:44**. | `service.luau:19-30`, `1472-1481`; log `~/.cache/noctalia/noctalia.log` |
| A3 | `applyProgressDelta` publica `snapshot` antes de mutar y guarda una referencia a `entry` que puede haber sido reemplazada por un finalize en vuelo: el `+1` “no se refleja” aunque la mutación haya ido bien. | `service.luau:1133-1181` (fetch y mutación asíncronos conviviendo) |
| A4 | El panel re-renderiza la lista completa (hasta **200 filas** × ~10 nodos con closures) en cada publicación; con descargas activas hay una publicación por tick de 120 ms. | `panel.luau:612-631`, `9-10`, `service.luau:1387-1389` |
| A5 | `update()` del panel reprograma el intervalo a **80 ms** mientras `visibleRowLimit < cap`, incluso con el panel cerrado (`onClose` pone 1000 ms pero `update` lo vuelve a bajar). | `panel.luau:11-12`, `75-81`, `675-681`, `683-694` |

### 4.3 Hipótesis del pedido: veredicto

| Hipótesis | Veredicto | Evidencia |
|---|---|---|
| Descarga a temporal/caché que se borra o se reemplaza | **Descartada** como causa visible | `http_client.cpp:202,655-665` (`.part` + rename atómico); 334 jpg intactos en disco |
| `ui.image` apuntando a una ruta que cambia | **Parcial** | La ruta no cambia de valor, **desaparece** (`coverPath = nil`) y el nodo se recrea como placeholder (`panel.luau:432-463`) |
| Límite de edad de caché / TTL | **No existe** | no hay TTL ni GC en `service.luau:236-378` |
| Re-render que pierde el campo `image` | **SÍ — causa raíz** | `service.luau:179` + `895-916` + `panel.luau:428-464` |
| Descarga en curso que pisa el archivo | **No** (el host deduplica por destino y renombra atómico) | `http_client.cpp:191-198` |
| El host descarta la textura al cambiar de key | **No** | el nodo se recrea bien; lo que falla es que ya no hay path que cargar |

### 4.4 Bug secundario real (borrado prematuro, no es la causa del síntoma)

`downloadCoverForEntry` borra el caché **antes** de comprobar si ya hay una descarga en vuelo:

```lua
removeCoverCache(mediaId)            -- service.luau:466
if coverDownloadsInFlight[mediaId] then return end   -- 468
```

No corrompe el archivo en vuelo (vive en `.part`), pero sí borra un JPG **válido** cuando la URL cambió, y provoca un ciclo borrar→re-descargar que gasta red y CPU. Mismo patrón en `attachCoverPathForEntry` (`service.luau:370-377`: si el meta no valida, borra el jpg).

### 4.5 Fix recomendado (sin tocar el plugin, para el fork)

1. **Publicar las carátulas en una clave de estado aparte e inmutable**: `anilist_covers = { [mediaId] = path }`. El panel resuelve `covers[mediaId]` en el render (`panel.luau:428`), así un refresco de lista **no puede** borrar imágenes. Elimina de raíz la clase de bug.
2. Si se mantiene el campo en la fila: llamar `attachCoverPathForEntry(row)` para cada fila en `finishFinalize`, antes de `publishSnapshot()` (`service.luau:905-914`), y `flushCoverSnapshot()` inmediato tras el pase de prioridad.
3. Quitar el refresco automático en `onOpen` (`panel.luau:669`) o condicionarlo a antigüedad (`updatedAt` del snapshot / `revision`).
4. `removeCoverCache` **después** del guard de in-flight (`service.luau:466-470`).

### 4.6 Verificación empírica (qué se pudo y qué no)

- **Sí verificado en runtime**: el panel abre y renderiza la vista de biblioteca (`surface prepareFrame ... 772x656 logical`, log 03:46:16); el auto-cierre ocurre a los **2,5 s** (`opened 03:48:09.687` / `closing 03:48:12.159`).
- **No verificable por píxeles**: hay un video de fondo (`mpvpaper`) animando; el diff entre capturas da 10-30 % de cambio sin tocar nada, así que no aísla el panel (misma limitación que documenta la skill `noctalia-plugin-development`). Las capturas `p_*.png` y `o*.png` en el scratch no son evidencia válida y no se usaron para el veredicto.
- El veredicto se apoya en: código del plugin (secuencia de las 7 etapas), semántica del host (`stateSet` = JSON, `Image::setSourceFile` sin reintento) y estado del caché en disco (intacto).

---

## 5. UI pantalla por pantalla, state keys, IPC

### 5.1 Pantallas (`panel.luau`)

| Pantalla | Disparador | Contenido | Evidencia |
|---|---|---|---|
| **Login** | `snapshot.viewer == nil` | título + botón settings + help + (`login_waiting` \| progreso \| botón *Connect*) + error | `245-273`, selector en `636-648` |
| **Biblioteca** | `snapshot.viewer.id` presente | header (título, `logged_in_as`, settings/refresh/logout/close), tabs Anime/Manga, fila de filtros en `ui.scroll`, aviso de estado, `ui.scroll` con las filas | `539-634` |
| **Preview de carátula** | `coverPreview ~= nil` (click en `ui.image`) | título + botón descargar + cerrar + `ui.image` 280×394 | `381-426` |

Fila de entry: carátula 44×62 (o placeholder de color con spinner si `anilist_cover_loading` la incluye), título (2 líneas), subtítulo (progreso + próximo episodio), estrellas de score (`score/20`), y 4 botones: −, +, completar, abrir en AniList. `panel.luau:466-537`, `148-190`.

### 5.2 State keys

| Clave | Productor | Consumidor | Contenido |
|---|---|---|---|
| `anilist_snapshot` | service `publishSnapshot()` (`service.luau:116-119`) | panel (`panel.luau:650-656`), widget (`widget.luau:107-112`) | `{revision, oauthLoading, loading, refreshing, busy, error, viewer, anime[], manga[], loadProgress}` |
| `anilist_cover_loading` | service `publishCoverLoadingState()` (`service.luau:380-386`) | panel (`panel.luau:36-45`, `658-661`) | array de `mediaId` descargando |
| `anilist_command` | panel `sendCommand()` (`panel.luau:56-64`) | service (`service.luau:1458-1460`) | `{action, ...}`: `refresh`, `start_oauth`, `login`, `logout`, `prioritize_covers`, `increment`, `decrement`, `complete`, `open_media` (`service.luau:1406-1456`) |
| `anilist_open` | panel `onOpen`/`onClose` (`panel.luau:666`, `677`) | widget (`widget.luau:102-105`) | bool, pinta el glyph en `primary` |

**No hay `nonce` en los comandos** (`panel.luau:56-64`): dos acciones idénticas seguidas (dos `+1` rápidos) pueden perder la segunda si el host deduplica por valor; además `snapshot.busy` bloquea el segundo intento de todos modos (`service.luau:1129-1131`).

### 5.3 IPC

`onIpc` del service (`service.luau:1462-1470`) expone sólo `refresh`, `logout`, `login <jwt>`. **No** reusa `processCommand`, así que `prioritize_covers`, `increment`, `complete`, `open_media` y `start_oauth` **no son operables por CLI** — a diferencia del patrón recomendado (skill `noctalia-plugin-development`).

```sh
noctalia msg plugin cleboost/anilist:api all refresh
noctalia msg plugin cleboost/anilist:api all logout
noctalia msg plugin cleboost/anilist:api all login "<jwt>"
```

`noctalia msg panel-toggle cleboost/anilist:library` abre el panel (verificado en runtime).

### 5.4 Props de UI inválidas (verificado contra el reconciler del host)

| Uso en el plugin | Realidad del host | Efecto |
|---|---|---|
| `ui.scroll({ horizontal = true })` (`panel.luau:576`) | `kScroll` no tiene `horizontal` (`ui_tree_reconciler.cpp:543-547`); el scroll es **sólo vertical** | **Warning real capturado**: `ui tree: 'scroll' has no prop 'horizontal', ignored` ×3 en el log al abrir. Los 7 filtros se cortan sin forma de alcanzar los últimos. |
| `ui.button({ disabled = coverDownloadBusy })` (`panel.luau:410`) | `kButton` tiene `enabled`, no `disabled` (`ui_tree_reconciler.cpp:518-523`) | El botón nunca se deshabilita (warning `has no prop`, `ui_tree_reconciler.cpp:1361`) |
| `ui.label({ padding = {...} })` en 5 lugares (`panel.luau:601,603,605,607,611`) | `kLabel` no incluye `padding` (`ui_tree_reconciler.cpp:494-498`) | Espaciado ignorado |
| `ui.image({ tooltip = ... })` (`panel.luau:440`) | Sí existe (nivel 32) | OK |

---

## 6. Qué se puede delegar a un CLI en Go

Criterio: sacar de Luau todo lo que sea **I/O de volumen, red con reintentos o estado que hoy vive en `update()`**.

| Comando propuesto | Reemplaza | Por qué |
|---|---|---|
| `anilist fetch --type anime\|manga --out catalog.json` | `LIST_QUERY` + `newFetchJob` + `startChunkFetch` + `mergeEntries` + `processFinalizeQueue` (~250 líneas, `service.luau:607-1091`) | Paginación, reintentos con backoff, timeout y merge en un binario; el service queda en `runAsync` + leer un JSON. Elimina el riesgo de “fetch a medias” y el `setUpdateInterval(300)` permanente. |
| `anilist covers sync --catalog catalog.json --dir <dataDir>/covers --workers 6 --size 96,384` | `downloadCoverForEntry` + `processPriorityCovers` + `processBackgroundCovers` + `isCoverCacheValid` + `writeCoverMeta` (~250 líneas, `service.luau:236-600`) | Un proceso con pool de workers descarga y **redimensiona** (hoy se guarda el JPG original de ~200 KB y el host lo decodifica a 132 px); escritura atómica propia, `.meta.json`, y salida `{mediaId: path}` en un solo JSON. Mata la carrera de in-flight y el tick de 120 ms. |
| `anilist covers gc --keep 500 --max-age 90d` | no existe | Hoy el caché crece sin límite (68 MB / 334 ítems). |
| `anilist mutate --media-id N --progress +1\|--complete` | `applyProgressDelta` (`service.luau:1128-1182`) | Opcional: da idempotencia y reintento; el service sólo publica el result. |
| `anilist oauth --client-id … --port 7823` | `scripts/oauth_login.py` (260 líneas) | Quita la dependencia de `python3` (`plugin.toml:10`) y permite agregar `state` (CSRF) como corresponde. |
| `anilist sort --catalog … --status CURRENT` | `sortEntries` (`panel.luau:96-116`) | Opcional; sólo si se quiere filtrar antes de publicar (hoy el panel ordena 600+ filas en cada render). |

Contrato mínimo sugerido:

```json
{ "revision": 12, "viewer": {"id": 1, "name": "..."},
  "anime": [ {"mediaId": 21, "status": "CURRENT", "progress": 7, "total": 26,
              "title": "...", "coverPath": "/…/covers/21.jpg", "coverColor": "#334155",
              "score": 80, "mediaType": "ANIME", "updatedAt": 1690000000} ],
  "manga": [] }
```

Con `coverPath` **ya resuelto por el CLI**, el bug de la sección 4 desaparece sin cambiar la forma del snapshot.

---

## 7. Bugs y límites (file:line) + qué falta para ocultar label y panel flotante

### 7.1 Bugs

| # | Severidad | Bug | Evidencia |
|---|---|---|---|
| B1 | **Alta** | El refresco de lista resetea `coverPath` y publica el modelo vacío: las carátulas desaparecen segundos después de abrir. | `service.luau:179`, `895-916`; `panel.luau:428-464`, `669` |
| B2 | **Alta** | La reposición de carátulas no se publica hasta que el pase de fondo termina o hay descargas: `flushCoverSnapshot` sólo corre en 3 rutas. | `service.luau:412-421`, `535-537`, `585-586`, `1387-1389` |
| B3 | Media | El panel se refresca **solo** al abrir, siempre, sin mirar antigüedad. | `panel.luau:668-670` |
| B4 | Media | `removeCoverCache` antes del guard de in-flight: borra JPG válidos y re-descarga. | `service.luau:466-470`; `365-378` |
| B5 | Media | Filtros inalcanzables: `horizontal` no existe en `ui.scroll`. | `panel.luau:576`; `ui_tree_reconciler.cpp:543-547` (warning en runtime) |
| B6 | Media | Panel con `update()` a 80 ms incluso cerrado; render de hasta 200 filas por publicación. | `panel.luau:9-12`, `75-81`, `683-694` |
| B7 | Media | `entry` capturado por referencia en la mutación: si un finalize reemplaza las filas, el update se pierde en la UI. | `service.luau:1133-1181` |
| B8 | Media | Sin reintento en fetch GraphQL: un 500/timeout deja la biblioteca vacía y borra el token si el mensaje matchea `invalid token`. | `service.luau:827-833`, `691-703` |
| B9 | Baja | Comandos sin `nonce`: dos acciones iguales seguidas pueden deduplicarse. | `panel.luau:56-64` |
| B10 | Baja | `disabled` y `padding` en `ui.button`/`ui.label` son props inexistentes. | `panel.luau:410`, `601-611`; `ui_tree_reconciler.cpp:494,518` |
| B11 | Baja | OAuth sin `state` (CSRF loopback). | `oauth_login.py:229-234` |
| B12 | Baja | `pt-BR` tiene 11 de 76 hojas y `tr` 54 de 76: el usuario de esos locales ve claves crudas. No hay `es.json`. | `translations/` |
| B13 | Baja | `plugin_api = 15` pero el código usa `service-lifecycle` (17), `panel.setWantsSecondTicks` (frame/ticks) y `runStream`: puede comportarse distinto en hosts viejos. | `plugin.toml:4`; `panel.luau:663`; `service.luau:1339` |
| B14 | Info | `coverColor` sí se usa como placeholder; si el entry no trae `color`, cae a `#334155`. | `service.luau:177`, `panel.luau:460` |

### 7.2 Límites de diseño

- **Sin búsqueda ni orden configurable**: 7 filtros fijos por estado, orden hardcodeado (progreso para `CURRENT`, A-Z para el resto). `panel.luau:96-131`.
- **Lista capada a 200 filas** (`MAX_VISIBLE_ROWS`): bibliotecas grandes muestran sólo las primeras 200 del filtro. `panel.luau:10`.
- **Caché sin TTL, sin tope y sin GC**: 68 MB hoy, crece con cada media nueva. `service.luau:236-378`.
- **Una sola descarga de carátula a la vez por mediaId, 6 en paralelo, tick de 120 ms**: `service.luau:15`, `14`.
- **Sin teclado**: no hay `capture_keys` en el manifest ni `onKey`, así que no hay navegación ni atajos. `plugin.toml:57-63`.
- **Persistencia**: `snapshot` vive sólo en memoria; cada recarga del plugin pierde progreso visual y carátulas resueltas. `service.luau:19-30`.
- **Credenciales en claro** en `~/.local/state/noctalia/settings.toml:432-433` (`client_id`/`client_secret`) y token en `token.json` (dir 0700, archivo 0644).

### 7.3 Qué falta para **ocultar el label**

1. **Label de la barra (el número).** El widget siempre escribe texto: `barWidget.setText(tostring(count))` (`widget.luau:94`) y `setText("")` sólo cuando el count es 0 (`widget.luau:97`). **No existe ajuste para ocultarlo**: falta
   - `[[widget.setting]] key = "show_count" type = "bool" default = true` en `plugin.toml` (junto a `glyph`/`count_mode`, `plugin.toml:37-55`), y
   - la guarda en `render()`: `if not show_count then barWidget.setText("") end` antes de la rama de conteo (`widget.luau:91-99`).
   Alternativa sin manifest: agregar `"hidden"` a las opciones de `count_mode` (`plugin.toml:49-55`) y devolver `""` en `render` cuando ese valor esté activo.
2. **Labels del panel (título / “logged in as”).** `panel.luau:544-553` inserta `tr("title")` y `tr("logged_in_as")` sin condición. Para poder ocultarlos hace falta un flag propio, y **el panel no puede escribir settings** (no hay `setConfig`): hay que agregarlo al `view` del service o a un `[[setting]]` leído con `getConfig` en el render. Lo más barato: `[[setting]] key="show_header" type="bool" default=true` y `if noctalia.getConfig("show_header") ~= false then ... end` en `renderLibrary`.

### 7.4 Qué falta para que el **panel no sea flotante**

- En el manifest es `placement = "floating"` + `position = "center"` (`plugin.toml:62-63`). El host inyecta esos dos como settings (`library_placement`, `library_open_near_click`) y **el usuario ya los pisó a `attached` / `true`** en `settings.toml:434-435` — por eso el panel abre pegado a la barra.
- Para que sea el default del fork: `placement = "attached"` y `open_near_click = true` en `[[panel]]`. Si se busca “panel pegado sin capa flotante”, además `layer = "top"`/`"overlay"` (nivel 30) según dónde deba quedar.
- **Tamaño**: hoy 720×640 fijos. Para que el alto siga al contenido hace falta `height = "content"` + `max_height`, **pero eso exige `plugin_api ≥ 42`** (`docs/plugin-api.json`), o sea subir `plugin_api` de 15 a 42 (y revisar B13 de paso).
- Para que el panel no se cierre al perder foco (hoy muere a los 2,5 s si se abre por CLI): `persistent = true` en `[[panel]]` (nivel 11).

---

## Anexo — evidencia cruda

```
$ noctalia --version
noctalia v5.4.1 (v5.4.1-41-gf2cebd97e016)

# apertura real del panel (render OK) y auto-cierre
03:46:16.397 [panel] panel manager: opened "cleboost/anilist:library" as attached layer-shell
03:46:16.423 [ui-tree] ui tree: 'scroll' has no prop 'horizontal', ignored
03:46:16.523 [surface] surface prepareFrame callback took 85.1ms (... 772x656 logical)
03:48:09.687 [panel] opened ...   →   03:48:12.159 [panel] closing ...   (2,5 s)

# caché de carátulas intacto
$ du -sh <dataDir>/covers ; ls covers/v2/*.jpg | wc -l
68M
334

# ejemplo de meta
{"url":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx100112-eExFpnYG2QAK.jpg","version":2}
```

Rutas: `dataDir = ~/.local/state/noctalia/plugins/data/cleboost/anilist`.
