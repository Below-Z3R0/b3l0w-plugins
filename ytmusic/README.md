# b3l0w YouTube Music

Cliente de YouTube Music para Noctalia v5. Las cuatro pantallas salen de la API
real de YouTube Music (innertube, cliente `WEB_REMIX`): **Inicio** (Quick picks y
mixes), **Rankings** (Top 100 de la región), **Búsqueda** (filtro *canciones*) y
**Cola**, con autoplay que sigue pidiendo la radio cuando se acaba lo que había.

No usa listas locales ni "reproducir al azar lo que ya agregaste": cada pantalla
es un `browse`/`search`/`next` de verdad, y `Siguiente` pide la siguiente tanda
de la cola (`continuation`) cuando la anterior se terminó.

```
panel ──state──▶ service ──runAsync──▶ b3l0w ytmusic ──▶ music.youtube.com/youtubei
   ▲                │                                    └▶ yt-dlp | mpv (setsid)
   └────state───────┘
```

## Requisitos

- `mpv` y `yt-dlp` en el `PATH` (son las dependencias declaradas en el manifest).
- La extensión `b3l0w-ytmusic` compilada en `~/.local/lib/b3l0w/plugins/`.

```bash
cd ~/Documents/Github/b3l0w
go build -o ~/.local/lib/b3l0w/plugins/b3l0w-ytmusic ./cmd/b3l0w-ytmusic
```

## Ajustes

| Ajuste | Tipo | Default | Qué hace |
| --- | --- | --- | --- |
| `show_label` | bool | `true` | Muestra el título que suena al lado del icono de la barra. |
| `panel_mode` | select | `compact` | `compact` = panel anclado 740×680; `float` = flotante 1160×840. |
| `glyph` | glyph | `brand-youtube` | Icono de la barra. |
| `animations` | bool | `true` | Fundido y escalonado al cambiar de pantalla. |
| `density` | select | `cozy` | Alto de fila (`compact` 54 / `cozy` 62 / `comfortable` 70 px). |
| `region` | string | `""` | País de dos letras para Rankings. Vacío = el que elige YouTube. |
| `covers` | bool | `true` | Baja las portadas a disco (`ui.image` no acepta URLs). |

## Pantallas y controles

| Pantalla | Contenido | Acciones |
| --- | --- | --- |
| Inicio | Recomendaciones de `FEmusic_home` (Quick picks, mixes). | Click en una fila = radio + play. `Cargar más` = `continuation`. |
| Rankings | `FEmusic_charts`: se abre el ranking Top (100/50) de la región. | Igual que Inicio. |
| Buscar | `search` con filtro de canciones; Enter busca. | Igual que Inicio; `Cargar más` pagina. |
| Cola | Las 50 canciones del automix, con la actual marcada. | Click = reproducir esa. |

Barra inferior (siempre visible): título y artista, barra de progreso arrastrable
(`seek`), ‹anterior, play/pausa, siguiente›, mezclar y parar.

| Gesto | Dónde | Efecto |
| --- | --- | --- |
| Click izquierdo | widget | Abre el panel según `panel_mode`. |
| Click medio | widget | Play / pausa. |
| Click derecho | widget | Siguiente tema. |
| `g` | panel | Alterna Inicio ↔ Cola. |
| `Prior` / `Next` | panel | Página anterior / siguiente. |
| `Home` | panel | Vuelve a Inicio. |

## CLI (`b3l0w ytmusic`)

Todos los comandos aceptan `--json`, `--data-dir DIR` y `--thumbs DIR` (destino de
las portadas). Cualquier fallo de red o de forma del JSON devuelve
`{"error":"..."}` con exit 1 en vez de una lista vacía.

| Comando | Qué hace |
| --- | --- |
| `home [--continuation TOK]` | `browse FEmusic_home`; pagina con el token. |
| `charts [--country XX]` | `browse FEmusic_charts` y abre la tarjeta Top. |
| `search <texto> [--continuation TOK]` | `/youtubei/v1/search` con el filtro de canciones. |
| `radio <videoId>` | Crea una sesión de automix (`/youtubei/v1/next`, `RDAMVM<id>`). |
| `next --session ID [--play]` | Avanza; pide más cola si hace falta. Si la radio se agota, siembra otra. |
| `prev --session ID [--play]` | Vuelve una canción. |
| `queue --session ID` | La cola completa. |
| `shuffle --session ID` | Fisher-Yates sobre la cola traída, dejando la actual primera. |
| `play <videoId>` | Lanza `yt-dlp \| mpv` detached (`setsid`), con socket IPC. |
| `pause` / `resume` / `stop` | Control de mpv por IPC (`pause`, `quit`/kill de grupo). |
| `seek <segundos>` | Salto absoluto en la pista. |
| `status` | `{playing,paused,position,duration,videoId,title,ended}`. |

### Arranque y arquitectura de la reproducción

`play` escribe un `player.json` con el **PID del grupo** y arranca:

```sh
setsid sh -c 'yt-dlp -f bestaudio -o - --no-playlist URL | mpv - --no-video \
  --input-ipc-server=<data>/mpv.sock --idle=yes'
```

- `setsid` + `Kill(-pid)`: matar el grupo se lleva `yt-dlp` y `mpv` juntos. Matar
  sólo a `mpv` deja a `yt-dlp` escribiendo a un pipe sin lector.
- `--idle=yes`: al terminar la pista el proceso **no** muere; `eof-reached` es la
  señal con la que el service pide la siguiente (autoplay real).
- La posición y la duración se leen del socket IPC de mpv, no de un reloj propio:
  una pausa o un buffer lento no mienten.

## Estructura

```
plugin.toml            manifest (service, widget, panel compacto y flotante)
service.luau           dueño del CLI y del estado; único que lanza procesos
panel.luau             Home / Rankings / Buscar / Cola + barra de controles
widget.luau            icono + título, click abre el panel
lib/{cli,anim,prefs}.luau   capa compartida de los plugins b3l0w
translations/{en,es}.json   mismas claves en los dos idiomas
```

El backend Go vive en el repo `b3l0w`:
`internal/plugins/ytmusic/` (cliente innertube, parseo, sesiones, mpv) y
`cmd/b3l0w-ytmusic`.

## Claves de estado

| Clave | Contenido |
| --- | --- |
| `b3l0w_ytmusic_home` / `_charts` / `_search` | `{kind, title, items[], continuation, loading, at}` |
| `b3l0w_ytmusic_queue` | `{session, seed, items[], cursor, at}` |
| `b3l0w_ytmusic_player` | `{playing, paused, position, duration, title, artist, videoId, ended}` |
| `b3l0w_ytmusic_status` | `{busy, phase, error, session, playing, *Count}` |
| `b3l0w_ytmusic_request` | lo que manda el panel: `{action, nonce, ...}` |
| `b3l0w_ytmusic_screen` | navegación por IPC: `{screen}` |

## Acciones (IPC / panel)

`home`, `charts`, `search`, `more`, `play_item`, `radio`, `next`, `prev`, `pause`,
`stop`, `shuffle`, `seek`, `queue`, `status`, `screen`.

```bash
noctalia msg plugin b3l0w/ytmusic:start all charts '{}'
noctalia msg plugin b3l0w/ytmusic:start all search '{"query":"daft punk"}'
noctalia msg plugin b3l0w/ytmusic:start all radio  '{"videoId":"kJQP7kiw5Fk"}'
noctalia msg plugin b3l0w/ytmusic:start all screen '{"screen":"queue"}'
```

## Depuración

```bash
grep -a "\[b3l0w-ytmusic\]" ~/.cache/noctalia/noctalia.log | tail
#  feed=home items=20 cont=si primera=Thriller
#  pantalla=queue|50|Thriller|playing=true|42/357|p1
#  play=Z85lxckrtzg titulo=Thriller pid=2254187
#  step=next cancion=Billie Jean (1/50) pid=2255001
```

`pantalla=…` lo emite el panel con la geometría y el estado reales (pantalla,
cantidad de items, primer título, posición/duración): es la forma de verificar
que se dibujó sin mirar la pantalla.

## Requisitos

- `b3l0w` con la extensión `ytmusic`
- `mpv`
- `yt-dlp`

## Instalación

```bash
git clone https://github.com/Below-Z3R0/b3l0w-ytmusic ~/.local/share/noctalia/plugins/b3l0w-ytmusic
```

Después habilitá el plugin desde **Ajustes → Plugins** de Noctalia, o
reiniciá Noctalia para que lo descubra:

```bash
kill $(pgrep -x noctalia); nohup noctalia >/dev/null 2>&1 &
```

## Licencia

MIT — ver [LICENSE](LICENSE).
