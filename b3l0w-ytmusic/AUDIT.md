# Auditoría — plugin Noctalia `yt-music` (aabidk20/yt-music v0.4.1, plugin_api 43)

Ruta auditada: `/home/b3low-z3r0/.local/state/noctalia/plugins/materialized/community/yt-music`
51 archivos `.luau/.sh/.toml/.json` + 1 `thumbnail.webp`, 9.701 líneas de código (excluye README/CHANGELOG).

Objetivo del informe: mapear el plugin y determinar por qué hoy **sólo se puede reproducir lo ya agregado (biblioteca/playlists cacheadas) o el resultado de una búsqueda puntual**, sin feed dinámico ni aleatorio tipo YouTube Music.

> Nota de fiabilidad: `api/constants.luau:11` contiene `EXPO.KEY = "AIzaSy...NX30"` (13 caracteres medidos con `awk length`). Una API key real de YouTube mide 39. O la copia materializada está redactada o el plugin está roto contra la API; todo lo demás del archivo (versión de cliente, BASE, contexto) es coherente, así que asumo redacción del snapshot y no lo cuento como bug propio.

---

## 1. Mapa de archivos

### Entradas / manifiesto
| Archivo | Qué hace |
|---|---|
| `plugin.toml` | Manifiesto: id `aabidk20/yt-music`, v0.4.1, plugin_api 43, deps `yt-dlp mpv mpv-mpris jq curl nc`; 1 setting (`debug_logging`), widget `widget`, paneles `mini` y `panel` (ambos `floating`), servicio `service`. |
| `widget.luau` | Widget de barra **estático**: glifo `brand-youtube-filled`, texto vacío, tooltip. Sin `onClick` (todo va por `[widget.actions]`). 14 líneas. |
| `service.luau` | Proceso de fondo: estado singleton, despacho de acciones IPC, probe de red cada ~20 s, boot (cookies, health, quick picks, sesión). 393 líneas. |
| `panel.luau` | Panel grande: sidebar + topbar + contenido por página + playerbar. 133 líneas. |
| `mini.luau` | Panel miniplayer (carátula 170px, scrub, transporte shuffle/prev/play/next/repeat, footer). 389 líneas, **estado propio**, sólo lee `yt_music.state`. |
| `README.md` / `CHANGELOG.md` | Doc y changelog. |

### `api/` (capa YouTube InnerTube, 1.453 líneas)
| Archivo | Qué hace |
|---|---|
| `api.luau` | Agregador: mezcla los exports de 7 módulos en una tabla `API` (19 líneas). |
| `constants.luau` | KEY, `CLIENT_VERSION=1.20240813.01.00`, BASE `music.youtube.com/youtubei/v1/`, CONTEXT `WEB_REMIX hl=en`, y todas las rutas de caché bajo `$XDG_CACHE_HOME/yt-music`. |
| `innerTube.luau` | POST autenticado a InnerTube: parsea `cookies.txt`, arma `SAPISIDHASH`, memoiza por segundo, gate offline. |
| `browse.luau` | `browse`: library landing, playlist page (+continuación), artist page, **home** (del que sólo extrae quick picks y mixes). |
| `search.luau` | `search`: songs/top/albums/artists (1 página) y playlists (paginado hasta 8 páginas). |
| `resolve.luau` | Resolución de stream con `yt-dlp -g`, descarga a `.opus`, prefetch, caché en RAM+disco. |
| `cache.luau` | Persistencia JSON: library, playlist por id, artist, session, recent playlists. |
| `thumbnails.luau` | Carátulas content-addressed (clave = id de recurso de la URL), descarga con `curl --parallel`, memo de existencia. |
| `stats.luau` | Views/likes vía `yt-dlp --print` desde `www.youtube.com`, caché 24 h. |
| `likes.luau` | `like/like` y `like/removelike`. |
| `filters.luau` (en `utils/`) | Los 6 filtros `jq` que parsean las respuestas crudas. |

### `modules/` (lógica de dominio del servicio, 2.532 líneas)
| Archivo | Qué hace |
|---|---|
| `store.luau` | Singleton de estado (`schema.new()`), `publish()` hace copia superficial y `noctalia.state.set("yt_music.state")`. |
| `auth.luau` | Login por navegador: abrir, extraer cookies, cargar cacheadas, health check, detectar navegadores. |
| `home.luau` | `refresh_quick_picks()` + `fetch_home_thumbs()`. 52 líneas: **todo el "descubrimiento" vive acá**. |
| `library.luau` | Meta offline/cacheada, auditoría de playlists descargadas, recently-played (máx 3), sync de liked, toggle_like. 589 líneas. |
| `playlist.luau` | Abrir/refrescar playlist, walk de continuaciones (cap 20), staging vs caché, cola, sugerencias. 574 líneas. |
| `player.luau` | Motor: play_index, resolve+mpv, skip coalescido, shuffle, repeat, seek, volumen, stream IPC. 785 líneas. |
| `mpv.luau` | Wrapper de `scripts/mpv.sh` (play/send/kill/stream). |
| `downloader.luau` | Cola de descargas con concurrencia 2, metadata offline. |
| `cacheops.luau` | Tamaños de caché por directorio y `clear` con allowlist. |
| `search.luau` | `Search.run` → `api.search(id, 25, cb, type)`. 29 líneas. |

### `views/` (UI, 2.583 líneas)
| Archivo | Qué hace |
|---|---|
| `state.luau` | Estado local del panel (no del servicio): `view` + `data`, hover/expand, do_search con debounce, context menu, `apply(snapshot)`. 460 líneas. |
| `actions.luau` | `request(action, payload)` → `noctalia.state.set("yt_music.request")` con nonce monótono. 17 líneas. |
| `rerender.luau` | Setter/caller del render (16 líneas). |
| `common.luau` | Helpers: `thumb_or_placeholder`, `track_actions` (like/dl/play-next/add/copy/menu), `chunk_rows`, `drag_grip`, filtro fuzzy. 423 líneas. |
| `components/sidebar.luau` | Sidebar (256px) + topbar con input de búsqueda; nav: For you / Search / Queue / Offline / Library / Settings; recently played (3); biblioteca con iconos. |
| `components/home.luau` | Feed "For you": Quick Picks en grilla de 3 + "RECOMMENDED MIXES & RADIOS" (máx 6). Sección "YOUR LIBRARY" comentada (`:217-218`). |
| `components/discover.luau` | **No es discover**: es la página de resultados de búsqueda con chips Top/Songs/Playlists/Albums/Artists. |
| `components/playerbar.luau` | Barra inferior: carátula/título/like/stats/dl, scrub 900px, transporte, mute+volumen. |
| `components/queue.luau` | Cola paginada de 50, filtro, drag&drop (`move_queue_item`). |
| `components/playlist.luau` | Playlist: header, "Play all", filtro, lista, "SUGGESTED TRACKS". |
| `components/artist.luau` | Artista: hero, SONGS, ALBUMS & SINGLES. |
| `components/library.luau` | Grilla de la biblioteca. |
| `components/offline.luau` | Descargas/caché por filtro + playlists, paginado. |
| `components/settings.luau` | Cache stats por categoría + "Clear" + link a settings del plugin. |
| `components/auth.luau` | Login: lista de navegadores, health card, estado de extracción. |

### `utils/` y `scripts/`
`bash.luau` (spawn con `sh_quote`), `network.luau` (gate global offline + drops de `noctalia.http`), `schema.luau` (estado inicial completo), `log.luau` (debug log con trim 512K→128K), `helpers.luau` (`sanitize`, `clean_artist`, `fmt_seconds`), `queueorder.luau`, `scratch.luau` (pool de 128 slots en `/tmp/yt-music`), `sha1.luau` (SHA-1 puro en Luau), `browsers.luau` (9 navegadores), `theme.luau` (tamaños fijos).
`scripts/cookies.sh` (open browser + CDP/yt-dlp cookie extraction), `scripts/mpv.sh` (mpv + IPC por socket Unix vía `nc` + stream de eventos), `scripts/health.sh` (chequeo de deps).

---

## 2. Autenticación (cookies / token)

**No hay OAuth ni refresh token.** Todo se apoya en cookies de navegador copiadas a disco.

- Archivo de cookies: `~/.cache/yt-music/cookies.txt`, formato Netscape, definido en `api/constants.luau:17` (`COOKIE_PATH`).
- Obtención, dos caminos (`scripts/cookies.sh`):
  1. **CDP** (Chromium-likes): el plugin lanza el navegador con `--remote-debugging-port=9222 --user-data-dir=.../yt-music/profiles/<browser>` (`cookies.sh:28`), espera el puerto hasta 5 s (`:51-58`), toma el `webSocketDebuggerUrl` del target `page` (`:66`), y hace un **handshake WebSocket a mano por `nc`** enviando `Network.getCookies` con frame sin máscara y `Sec-WebSocket-Key` fija (`:78-88`). Del JSON resultante arma las líneas Netscape con `jq` (`:92-93`). Tras éxito **mata el navegador y borra el perfil** (`:110-111`).
  2. **Fallback yt-dlp** (Firefox/Zen o si CDP falla): `yt-dlp --cookies-from-browser "$browser" --cookies "$RAW"` (`:127`), y luego filtra sólo dominios de Google/YouTube (`:128`).
- Filtrado: `grep -iE '^#|(youtube.com|...|googlevideo.com)'` → quedan sólo cookies útiles (`:128`); `TOTAL`/`KEPT` se reportan a Luau (`:130-137`).
- **Headers enviados** (`api/innerTube.luau:109-119`): `Content-Type: application/json`, `Origin: https://music.youtube.com`, `User-Agent: Chrome/126`, `Authorization: SAPISIDHASH <ts>_<sha1>`, `Cookie: <todas las cookies concatenadas>`.
- **Token**: `SAPISIDHASH = sha1(ts .. " " .. SAPISID .. " " .. ORIGIN)` (`innerTube.luau:90`), con memo por segundo (`:86-92`) porque el SHA-1 es puro Luau (`utils/sha1.luau`).
- Carga/guardado en memoria: `load_cookie_values()` (`innerTube.luau:22-53`) re-lee el archivo y parsea `fields[6]=name`, `fields[7]=value`.
- **"Refresh"**: no existe. Lo único que hay es `EXPO.invalidate_auth()` (`innerTube.luau:60-63`) para invalidar el memo... **y ese export no llega a `api`**, ver bug B1.
- Persistencia de estado: `state.status="ready"` + `cookie_count` (`modules/auth.luau:78-89`), y al boot si el archivo existe (`service.luau:342-345`).
- Almacenamiento: cookies **en claro**, sin `chmod 600` (`cookies.sh:43`), incluyendo `SAPISID`/`__Secure-3PSID` → cualquiera con lectura de `~/.cache` puede actuar como el usuario.

---

## 3. Endpoints usados

Base: `https://music.youtube.com/youtubei/v1/<ep>?key=<KEY>&prettyPrint=false` (`constants.luau:13`, `innerTube.luau:121`). Contexto fijo `{clientName:"WEB_REMIX", clientVersion:"1.20240813.01.00", hl:"en"}` (`constants.luau:31-39`) — sin `gl`, sin `visitorData`, sin `X-Goog-*`.

| Endpoint | Dónde | Params |
|---|---|---|
| `browse` | `browse.luau:42` | `browseId: "FEmusic_library_landing"` (biblioteca) |
| `browse` | `browse.luau:114-119` | `browseId: <playlist id>` **o** `continuation: <token>` |
| `browse` | `browse.luau:185` | `browseId: "UC..."` (artista) |
| `browse` | `browse.luau:246` | `browseId: "FEmusic_home"` (sólo para quick picks/mixes) |
| `search` | `search.luau:113-117` | `query`, `params` (ver abajo) |
| `search` | `search.luau:42-48` | `continuation` (sólo playlists) |
| `like/like` | `likes.luau:27` | `target.videoId` |
| `like/removelike` | `likes.luau:46` | `target.videoId` |
| *(no InnerTube)* `yt-dlp -g` | `resolve.luau:19-36` | `--extractor-args youtube:player_client=mweb,web -f bestaudio/best -g --cookies` |
| *(no InnerTube)* `yt-dlp -o *.opus` | `resolve.luau:98-103` | descarga para caché offline |
| *(no InnerTube)* `yt-dlp --print view_count/like_count` | `stats.luau:99-109` | `https://www.youtube.com/watch?v=` |
| *(no InnerTube)* `curl --parallel -K` | `thumbnails.luau:141` | carátulas |
| *(no InnerTube)* `curl -m 6 music.youtube.com` | `service.luau:322` | probe de conectividad cada ~20 s |

**Params de búsqueda** (`search.luau:105-112`): `songs = EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D`, `albums = EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D`, `artists = EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D`, `top = ""`, y `playlists = EgeKAQQoADgBKAI6AklTUAFQBRAFEAkQBA%3D%3D` (`search.luau:26`) con paginación de shelf.

**Construcción de queries**: no hay constructor de queries; cada llamada arma a mano la tabla `{context = CONTEXT.context, ...}`. El parseo de la respuesta **no** se hace en Luau: se escribe el body crudo a `/tmp/yt-music/<prefix>-N` (`scratch.luau:13-16`) y se lanza `jq` con un filtro estático de `utils/filters.luau` (`browse.luau:47-49`, `search.luau:127`, etc.), y recién el stdout reducido se decodifica con `noctalia.json.decode`.

**Endpoints que NO existen en el plugin** (verificado con grep sobre todo el árbol):
- `/youtubei/v1/next` — **cero usos**. No hay "up next", no hay radio/mix a partir de una canción, no hay continuación infinita de cola.
- `/youtubei/v1/player` — no se usa (todo el stream va por `yt-dlp`).
- `FEmusic_moods_and_genres`, `FEmusic_charts`, `FEmusic_new_releases`, `FEmusic_explore`, `FEmusic_liked_*` — **ninguno**. El único `FEmusic_*` usado son `FEmusic_home` y `FEmusic_library_landing` (`browse.luau:42,246`).

---

## 4. Reproducción

Cadena: **InnerTube no interviene**. `yt-dlp -g` resuelve la URL de audio → **mpv** reproduce por HTTP(S) con IPC por socket Unix. No hay pipe, no hay archivo temporal para streaming.

1. `Player.play_index(index, queue)` (`player.luau:169`) fija `state.player.status="loading"` y llama `api.resolve_stream(id, cb)` (`:292`).
2. `resolve_stream` (`resolve.luau:119`) mira en orden: `.opus` en disco (`:127` → hit inmediato), cache RAM (`:136`, TTL 4 h), `.url` en disco (`:146-171`, `STREAM_DISK_TTL = 4*3600` en `:50`), dedupe de in-flight (`:173-176`) y recién ahí lanza `yt-dlp -g` (`:185-226`, timeout 30 s, 1 reintento si el host rechaza el spawn `:227-253`).
3. `player_set` (`player.luau:53`) publica metadatos, dispara `track_stats` (views/likes), `cache_audio` (descarga `.opus` **siempre**, para offline: `:92-107`), `mpv.play(url, title, volume, cb, thumb)` (`:109`) y `prefetch_queue` (`:118-129`).
4. `mpv.play` (`modules/mpv.luau:9`) escribe url/título en scratch y llama `mpv.sh mpv_play` (`scripts/mpv.sh:37`): mata mpv previo con `flock` (`:52-55`), espera liberación del socket (`:65-71`), lanza `nohup mpv <dummy> <URL> <dummy> --playlist-start=1 --no-video --keep-open=always --force-media-title=... --input-ipc-server=/tmp/yt-music/mpv.sock --ao=pulse,pipewire,alsa,auto` (`:74-81`). Los dos `anullsrc` existen para que mpv-mpris exponga ambas direcciones de transporte (`:9-10`).
5. Estado en vivo: `mpv_stream` (`mpv.sh:130`) mantiene una conexión `nc -U` con `observe_property` de pause/duration/eof/audio-codec/samplerate/playlist-pos y `get_property time-pos` cada 1 s (+ bitrate cada 10 s). En Luau lo consume `handle_stream_line` (`player.luau:668-772`): `eof-reached` → `Player.next(true)` (`:715-721`), `playlist-pos` 0/2 → skip (`:723-733`), `duration` corrige duración real (`:746-751`).
6. **Siguiente/anterior**: `Player.next` (`:441`) con `repeat=one` re-seekea; si no, `queue_skip(1)`. `Player.prev` (`:516`) reinicia si `position > 3`, si no `queue_skip(-1)`. `queue_skip` (`:499`) acumula `pending_steps` y difiere 0.25 s para que un burst de clicks sólo resuelva el destino final (`advance_steps`, `:464-495`). Fin de cola sin `repeat=all` → `status="stopped"` (`:482-487`): **no hay continuación automática**.
7. **Aleatorio / shuffle**: `Player.toggle_shuffle` (`:569-607`) hace Fisher-Yates **sólo sobre la cola ya existente**, desde `index+1` en adelante, y guarda `original_queue` para restaurar. Origen de las canciones del aleatorio = **exactamente la lista que se clickeó**: quick picks (15), una playlist (sus tracks), resultados de búsqueda (25), o artist tracks (30). No hay fuente aleatoria propia, no hay "radio", no hay re-mezcla al terminar. Segundo "aleatorio" menor: en cada fetch de home se barajan los mixes candidatos y se cortan a 24 (`browse.luau:270-281`), de los que la UI muestra 6 (`components/home.luau:147-150`).
8. Volumen/seek/mute: `set_property volume` / `seek absolute` por IPC (`player.luau:529-567`).
9. Offline: `play_index` salta tracks sin `.opus` (`player.luau:196-219`).

---

## 5. Búsqueda

- Origen: input del topbar (`components/sidebar.luau:71-83`) → `state.on_search_type` (debounce 0.4 s y mínimo 2 chars, `views/state.luau:133-152`) → `do_search` (`:117-131`) que cambia `content_page="discover"` y manda `request("search", {query, type})`.
- Servicio: `modules/search.luau:8-27` valida el tipo y llama `api.search(q, 25, cb, stype)`. **`count` está fijo en 25** (`:17`).
- API: `api/search.luau:92-176` — un solo POST, `params` según tipo, `jq` con `SEARCH_TRACKS` o `SEARCH_TOP` (`filters.luau:76` / `:32`), y normaliza a `{id,title,artist,album,duration,duration_text,thumbnail_url}` o `{type="playlist"|"artist",...}`. `search_playlists` (`:30-90`) pagina continuaciones por shelf hasta 8 páginas.
- Resultado en UI: `components/discover.luau` — chips de tipo, filas de track con `media_row` que al click hacen `replace_queue_and_play` con **`queue = s.results` completo** (`:135`).
- Sin historial, sin sugerencias, sin "buscar en radio", sin paginación de canciones (sólo playlists paginan).

---

## 6. FEED / DESCUBRIMIENTO — lo que hay y lo que falta

### Lo que existe (y es poco)
1. **Quick Picks**: `fetch_quick_picks` (`browse.luau:244-287`) hace `browse FEmusic_home` y el filtro `QUICK_PICKS` (`filters.luau:13`) extrae de **todo** el documento: hasta 15 tracks de cualquier `musicResponsiveListItemRenderer` (`.[0:15]`) y hasta 60 candidatos de `musicTwoRowItemRenderer` cuyo id matchea `^(VL)?RD` (`filters.luau:14`). Después se barajan y se cortan a 24 (`browse.luau:270-281`). Se cachea en `quick_picks.json` (`browse.luau:234-242`). **No se lee ningún shelf/estante por nombre**: no hay home rows, no hay "Listen again", no hay "Trending", no hay continuaciones de `FEmusic_home`.
2. **Mixes/Radios del home**: los `RD*` de arriba, mostrados como máximo 6 cartas (`components/home.luau:140-215`), filtrados contra la biblioteca y el shuffle. Al click → `open_playlist({id=mix.id})` → `browse` con ese id. Es un mix real de YT **pero congelado**: el track list que devuelve `browse` es lo que hay; nunca se pide `next` para seguir la radio.
3. **Biblioteca**: `browse FEmusic_library_landing` (`browse.luau:42`) → playlists (Liked primero, `:68-76`), cacheada en `library.json`.
4. **Recently played**: propio, máximo **3** (`library.luau:470-488`), sin relación con el historial de YT.
5. **Sugerencias al final de playlist**: la cola de continuación de YT trae un shelf de sugerencias; el plugin lo separa de los tracks reales por `count` (`playlist.luau:393-451`) y lo muestra como "SUGGESTED TRACKS" (`components/playlist.luau:370`). Es el único "related" real, y sólo aparece al fondo de una playlist.
6. **Artista**: `browse UC...` → 30 tracks + 8 related (`filters.luau:11`).
7. **Búsqueda puntual** (sección 5).

### Lo que NO existe
| Falta | Evidencia |
|---|---|
| `/youtubei/v1/next` (radio/mix/up-next desde una canción) | grep sin resultados en todo el árbol |
| `FEmusic_moods_and_genres` (Moods & Genres, "Chill", "Energy"…) | grep `FEmusic` sólo devuelve `:42` y `:246` de `browse.luau` |
| `FEmusic_charts` (Top songs/artists, tendencias por país) | no existe |
| `FEmusic_new_releases`, `FEmusic_explore` | no existen |
| Shelves de `FEmusic_home` (filas con título: "Quick picks", "Mixed for you", "Forgotten favorites"…) | `filters.QUICK_PICKS` aplana el documento y descarta títulos de shelf; `components/home.luau` sólo renderiza 2 secciones |
| Continuaciones del home | `browse.luau:246` no guarda ni pide tokens |
| Continuaciones de búsqueda de canciones/top | sólo `search_playlists` pagina (`search.luau:40-87`) |
| Continuación de artista | `filters.ARTIST_PAGE` corta `.[0:30]` / `.[0:8]` |
| Autoplay al terminar la cola | `player.luau:482-487` para en seco; `toggle_autoplay` (`service.luau:272-275`) es **código muerto**, nadie lo dispara ni lo lee (`schema.luau:51` es el único otro hit) |
| Shuffle con fuente propia (aleatorio del gusto del usuario) | `player.luau:569-607` sólo reordena la cola actual |
| Historial / "Escuchado recientemente" de YT | no hay endpoint |
| Página de navegación por género/estado de ánimo en UI | `NAV_ITEMS` (`sidebar.luau:7-14`) no tiene Discover; el id `discover` es la página de resultados de búsqueda (`discover.luau:7-148`) |

**Conclusión del punto**: el usuario tiene razón. El plugin expone sólo **4 superficies de contenido**: quick picks (15 tracks de un solo fetch de home), mixes RD (24 candidatos, 6 visibles, sin continuación), biblioteca/playlists cacheadas, y búsqueda de 25 resultados. No hay ninguna llamada que pida contenido nuevo a partir de contexto (canción/artista/género), que es lo que hace "YouTube Music" en el producto real.

---

## 7. Caché y persistencia

Todo bajo `~/.cache/yt-music` (`constants.luau:6-29`).

| Archivo/dir | Contenido | Formato | TTL / política |
|---|---|---|---|
| `cookies.txt` | cookies Netscape filtradas | texto | sin TTL, se reescribe al extraer |
| `library.json` | playlists de la biblioteca | JSON array `{id,title,subtitle,count,thumbnail_url}` | sin TTL; se reemplaza en cada `library()` OK (`browse.luau:77-80`) |
| `recent_playlists.json` | hasta 3 playlists | JSON array | sin TTL; se borra al quedar sin cookies (`service.luau:360-366`) |
| `playlists/<id>.json` | tracks por playlist | JSON array | sin TTL; "frescura" sólo en RAM: `walk_stamps` 30 min (`playlist.luau:57-75`) |
| `artists/<id>.json` | `{artist,tracks,related}` | JSON | sin TTL; se revalida siempre online (`service.luau:245-254`) |
| `session.json` | track, posición, volumen, índice, cola completa | JSON | sin TTL; se guarda en cada `player_set` (`player.luau:135-139`) y en `onStop` |
| `quick_picks.json` | hasta 15 tracks | JSON array | sin TTL, sólo botón Refresh |
| `streams/<id>.url` | URL googlevideo | texto plano | **4 h** (`resolve.luau:50`), se borra si está stale (`:156-158`) |
| `audio/<id>.opus` | descarga completa | opus | permanente (es el "offline"), con partición descargas/caché por `offline_meta` |
| `offline_meta.json` | metadata de descargas explícitas | JSON map | sin TTL |
| `cached_meta.json` | metadata para reconstruir "Saved tracks" del caché | JSON | sin TTL |
| `thumbnails/<resource_id>.jpg` | carátulas content-addressed | jpg | permanente |
| `stats.json` | views/likes por video | JSON map `{views,likes,fetched}` | **24 h** (`stats.luau:13`), purga al guardar |
| `debug.log` | log de debug (opt-in) | texto | trim a 128K cuando pasa 512K (`log.luau:12-21`) |

Caché en RAM además: `stream_cache` (TTL 4 h), `resolving_in_flight`, `known_thumb_files`, `walk_stamps`, y `stats_cache`.
Temporales: `/tmp/yt-music/` (scratch pool 128 slots, socket y pid de mpv, configs de curl) — **fuera de XDG, se pierde al reiniciar**.

---

## 8. UI, state keys e IPC

### Superficies
- **Widget de barra** (`widget.luau`): glifo + tooltip, texto vacío fijo. Acciones declaradas en `plugin.toml:23-26`: left → `panel-toggle ...:mini`, right → `panel-toggle ...:panel`, middle → `settings-open-plugin`.
- **Panel `mini`** (`mini.luau`, 380×460, floating): si no hay login muestra "Not Logged In" + botón al panel; si hay, carátula 170, título/artista, botones like/spec/expandir, scrub con drag, transporte (shuffle, prev, play/pause, next, repeat) y footer (chip OFFLINE, settings).
- **Panel `panel`** (`panel.luau`, fill×fill, floating): sidebar 256px con marca, nav, indicador offline, recently played, biblioteca con scroll; topbar con búsqueda; contenido de una página; playerbar 300px + scrub 900px + transporte + volumen.

Páginas (`panel.luau:24-32`): `playlist`, `discover`(búsqueda), `queue`, `settings`, `offline`, `artist`, `library`; fallback = `home` o prompt de login (`:39-47`).

### State keys (IPC real)
| Key | Escritor | Lectores | Payload |
|---|---|---|---|
| `yt_music.state` | `modules/store.luau:64` (snapshot superficial con `nonce`) | `panel.luau:119-127`, `mini.luau:375-385` | todo el estado: status/auth, player (incl. cola), playlist, search, library, quick_picks, home_mixes, likes, cache |
| `yt_music.request` | `views/actions.luau:14` | `service.luau:278-297` | `{action, nonce, ...payload}` |

`nonce` monótono (`nowMs*1000 + random`, `actions.luau:6-9`) y `handled_nonce` en el servicio (`service.luau:279-282`) descartan duplicados y ecos. El panel mantiene su propio `view` (página, hover, expand, filtros, paginación) en `views/state.luau:8-30`, que **nunca se publica**.

### Acciones IPC (39 en `service.luau:65-276`)
`extract`, `open_login`, `search`, `play`, `play_next`, `add_to_queue`, `play_suggestion`, `play_queue_index`, `move_queue_item`, `replace_queue_and_play`, `play_playlist`, `open_playlist`, `refresh_playlist`, `refresh_library`, `fetch_next_page`, `toggle_like`, `toggle_shuffle`, `cycle_repeat`, `refresh_quick_picks`, `refresh_health`, `download_track`, `remove_download`, `download_playlist`, `toggle`, `next`, `prev`, `seek`, `volume`, `toggle_mute`, `stop`, `prefetch`, `fetch_cache_stats`, `fetch_offline`, `fetch_artist`, `clear_cache`, `toggle_autoplay`.
Comandos de shell: `noctalia msg panel-toggle aabidk20/yt-music:mini|panel` (README:34-40), y dentro del panel `noctalia.togglePanel(...)` (`mini.luau:99,203`).

---

## 9. Qué conviene delegar a un CLI en Go

El patrón ya está definido en tu repo (`shared/cli.luau`: `b3l0w-widgets <módulo> <args…>` → JSON por stdout), y `yt-music` es el candidato más claro porque **cada request cuesta 3 procesos**: `noctalia.http` (host) + `writeFile` del body crudo + `jq` sobre 1-3 MB. Prioridad:

1. **InnerTube + parseo (mayor ganancia)**. `b3l0w-widgets ytmusic home|search|playlist|artist|next|charts|moods` haciendo POST y devolviendo JSON ya normalizado y chico (`{tracks[],shelves[],token}`). Elimina `api/innerTube.luau`, `api/browse.luau`, `api/search.luau`, `utils/filters.luau` (98 líneas de jq) y el scratch de `/tmp` para bodies. Ganancia concreta: el filtro `QUICK_PICKS` recorre el documento entero con `..` (recursivo) dos veces; en Go es un walk tipado sobre structs.
2. **`next` / radio**: implementar acá lo que hoy no existe — `ytmusic next <videoId>` (radio), `ytmusic radio <playlistId|RD…>` para continuación infinita de mix, `ytmusic charts <country>`, `ytmusic moods`. Es el habilitador del punto 6, no un refactor.
3. **Resolución de stream**. Dos opciones: (a) envolver `yt-dlp -g` en Go con caché y concurrencia (rápido de escribir, sigue el bug de 0.5-2 s por track); (b) implementar `player` + descifrado de `signatureCipher`/`n` en Go (más trabajo, ~200 ms por track y sin dependencia de `yt-dlp`). Recomiendo (a) ahora, (b) después, con el mismo contrato de salida.
4. **Caché**. Hoy son ~12 archivos JSON sueltos sin índice ni TTL uniforme, y cada lectura es `readFile` + `json.decode` completo en el hilo del servicio (`load_cached_playlist` en `cache.luau:76` decodifica 434 tracks en cada apertura). Un `cache.db` (SQLite o bbolt) con `(kind, key, fetched_at, ttl, payload)` centraliza: playlists, artists, streams, stats, quick picks, charts. Beneficio medible: apertura de playlist cacheada sin re-decodificar y TTLs reales en vez de stamps en RAM que se pierden al reiniciar (`playlist.luau:57`).
5. **Descargas**. `downloader.luau` maneja concurrencia 2 con una cola en memoria que se pierde si el servicio se reinicia, y no hay reanudación ni verificación de integridad. En Go: cola persistida, `--continue`, checksum, límite de ancho de banda, y progreso por track vía stdout JSON-lines.
6. **Carátulas**. `thumbnails.luau` genera un config de curl con N entradas y lo lanza con `--parallel` (`:119-156`). Un CLI con un pool de workers y dedupe por hash de URL haría lo mismo sin escribir archivos de config ni depender de curl ≥7.68 (`health.sh:50-55`).

Lo que **no** conviene mover: la UI (`views/*`), el estado de hover/expand/paginación, y el control de mpv (IPC por socket es barato y ya funciona).

---

## 10. Bugs y límites (con línea)

**B1 — `api.invalidate_auth` es inalcanzable (auth rancio tras re-login).**
`invalidate_auth` se define en `api/innerTube.luau:60`, pero `api.luau:3-11` no incluye `./api/innerTube.luau` en `REQUIRED_MODULES`. Los dos llamadores están guardados con `if api and api.invalidate_auth` (`modules/auth.luau:93-95`, `:146-148`), así que **nunca se ejecutan**. Consecuencia: si el proceso arrancó con sesión válida y el usuario re-extrae cookies (otra cuenta, o sesión revocada), `auth_state.ready` sigue `true` y se siguen mandando `SAPISID`/`Cookie` viejos hasta reiniciar el servicio. El caso opuesto (sin cookies → con cookies) sí se auto-cura porque `build_auth` re-lee cuando `not ready` (`innerTube.luau:66`).

**B2 — La cola de búsqueda contiene entidades que no son tracks.**
`components/discover.luau:135` manda `queue = s.results` completo, pero `api/search.luau:139-154` inserta en ese mismo array objetos `{type="playlist"}` y `{type="artist"}` con `browseId`. Al hacer next/prev sobre esos índices, `play_index` toma un `id` tipo `MPREb…`/`UC…` y `resolve_stream` falla → `status="stopped"` con "Could not resolve stream" (`player.luau:274-279`). Repro: buscar en "Top"/"Albums", reproducir un track del medio y avanzar.

**B3 — `toggle_autoplay` es código muerto y no hay autoplay.**
`service.luau:272-275` expone la acción y `schema.luau:51` el flag, pero ningún componente la dispara ni lee `settings.autoplay`, y al final de la cola sin `repeat=all` el player corta (`player.luau:482-487`). El usuario percibe "se termina y no sigue".

**B4 — Mixes sin continuación y con id potencialmente inválido.**
`filters.luau:14` acepta ids `^(VL)?RD`, o sea puede devolver `RDCLAK…` sin prefijo `VL`, y `browse.luau:118` lo manda tal cual como `browseId`. YT normalmente espera `VL` + playlistId para mixes; cuando no matchea, el mix abre vacío. Además, aun abriendo bien, nunca se pide la continuación del radio (`next`), así que el mix es una foto.

**B5 — El filtro de mixes en home compara ids sin normalizar.**
`components/home.luau:125-138` arma `lib_ids` con y sin prefijo `VL`, pero `:144-145` compara `mid` (el id crudo del mix) contra ese set; con ids `RD…` vs `VL…` en la biblioteca el filtro falla y se re-muestran mixes ya guardados.

**B6 — Extracción de cookies CDP frágil y con re-login forzado.**
Handshake WebSocket escrito a mano por `nc`, con `Sec-WebSocket-Key` fija y sin máscara (`cookies.sh:78-88`), y lectura del resultado con `strings | grep cookies` (`:88`) — cualquier cambio de framing o de tamaño (>128 bytes de payload sin máscara) rompe la extracción. Peor: `open_login` crea un perfil nuevo (`:24-28`) y tras extraer **borra el perfil** (`:110-111`), así que cada extracción obliga a loguearse de nuevo dentro del perfil efímero.

**B7 — Cookies de sesión en claro.**
`cookies.sh:43` crea `~/.cache/yt-music/cookies.txt` con el umask del shell; no hay `chmod 600` ni `umask 077`. El archivo incluye `SAPISID`, `__Secure-3PSID`, `HSID`, `SSID`.

**B8 — `search` limita a 25 resultados y sólo pagina playlists.**
`modules/search.luau:17` fija 25; `api/search.luau` no pide continuaciones para songs/top/albums/artists. No hay "ver más".

**B9 — Prefetch deliberadamente mínimo.**
`resolve.luau:287-293` precarga **1** track (el comentario en `:287` lo justifica por saturación del pool). Con `yt-dlp` a ~1 s por resolve y skip coalescido de 0.25 s (`player.luau:503`), adelantarse es lo normal.

**B10 — Pool de procesos como cuello de botella estructural.**
Cada `clear`/`fetch` de paneles usa `noctalia.runAsync("true", ...)` como "post al event loop" (`player.luau:131,136`, `playlist.luau:86`, etc.); cuando el pool se satura hay ramas de recuperación manual (`resolve.luau:227-253` con `sleep 1.5` y reintento). Síntoma: "loading" eterno bajo bursts.

**B11 — La selección de chip de búsqueda se revierte sola.**
`views/state.luau:154-165` escribe `data.search.type = stype` **sólo en el estado del panel** cuando no hay query; cualquier `publish()` posterior (y hay uno por segundo con `time-pos` mientras suena algo, `player.luau:692-702`) reemplaza `data.search` completo por la copia del servicio (`store.luau:44-49`), que mantiene el tipo viejo. Efecto: elegir "Albums" sin haber buscado y ver cómo el chip vuelve a "Top" al segundo. `schema.luau:30` fija el default `type = "top"` en ambos lados, así que no hay conflicto de defaults, sólo de propiedad del campo.

**B12 — Mezcla de gates de red.**
`api/search.luau:60` y `:127` usan `noctalia.runAsync` para lanzar `jq`, mientras `browse.luau:49` usa `network.runAsync`; el gate offline no cubre esas rutas (inocuo porque es local, pero inconsistente y confuso al auditar).

### Qué falta para "ocultar label y panel flotante"
Contrastado con tu plantilla (`templates/plugin.toml:10-23`, `shared/prefs.luau:10-27`), `yt-music` está al revés:

- **Label**: `widget.luau:8-10` ya hace `setText("")` **incondicionalmente**. No hay `[[widget.setting]]` en todo `plugin.toml` (sólo `[[setting]]` global de `debug_logging`, `:12-17`), así que no existe `show_label`. Además el widget **no observa `yt_music.state`** (no hay `noctalia.state.watch` en `widget.luau`), o sea hoy no podría mostrar el título aunque se quisiera. Para paridad con tus plugins: (a) agregar `[[setting]] show_label` (bool, default true) — el input ya lo lee `noctalia.getConfig`, mismo patrón que `log.luau:6`; (b) en `widget.luau` leer `noctalia.getConfig("show_label")` y alternar `setText("")` vs título recortado; (c) si se quiere el título, hay que suscribir el widget al state key (el shell no permite `onClick`, así que sólo queda `watch`).
- **Panel flotante**: `plugin.toml:28-40` declara **los dos** paneles como `placement = "floating"`, sin `position`, sin `open_near_click`, sin `dismiss_on_outside_click` ni `keyboard_focus` — se abren centrados y grandes. Para el modelo `panel_mode` de tu plantilla: declarar un tercer `[[panel]] id="compact"` con `placement="attached"`, `open_near_click=true`, `width≈380`, `height≈520`, `keyboard_focus="exclusive"`, `dismiss_on_outside_click=true`, y elegir el destino del click en el widget según `noctalia.getConfig("panel_mode")` (no se puede cambiar placement en runtime, `prefs.luau:4-6`). Hay un detalle extra: `mini` ya es 380×460 pero flotante; lo natural es que **ese** pase a `attached` y el "float" quede como el panel grande.
- **Extra**: `plugin.toml:3` declara `version = "0.4.1"` con `plugin_api = 43`; el `panel-toggle` de las acciones depende de ids — si se agrega un panel `compact`, hay que actualizar `[widget.actions]` (`plugin.toml:23-26`) y `README.md:34-40`.

---

## Resumen ejecutivo

- Autenticación: cookies de navegador a `~/.cache/yt-music/cookies.txt` + `SAPISIDHASH` con SHA-1 puro en Luau. Sin refresh; `invalidate_auth` inalcanzable (bug).
- API: 3 endpoints InnerTube (`browse`, `search`, `like/*`) y todo el resto por `yt-dlp`/`curl`. Sin `next`, sin charts, sin moods, sin continuaciones de home/artista.
- Reproducción: `yt-dlp -g` → mpv + IPC por socket `nc`; cola propia; shuffle sólo reordena la cola existente; no hay aleatorio con fuente propia ni continuación al terminar.
- Descubrimiento: Quick Picks (15) + mixes RD (6 visibles) desde un único `FEmusic_home`, biblioteca cacheada y búsqueda de 25. Nada pide contenido nuevo por contexto.
- Caché: 12 archivos JSON sueltos bajo `~/.cache/yt-music` con TTLs dispares (streams 4 h, stats 24 h, walk-stamp 30 min en RAM, el resto permanente).
- Delegable a Go: InnerTube+parseo (elimina jq y 3 procesos por request), `next`/radio/charts/moods, resolve, caché unificada, descargas y carátulas.
- 12 bugs/límites; los que más duelen son B1 (sesión rancia), B2 (cola con entidades no reproducibles), B3 (autoplay muerto) y B4/B5 (mixes).
