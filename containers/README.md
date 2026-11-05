# b3l0w-containers

Plugin propio de Noctalia que **fusiona** `containers` (davinci13) y
`mini-docker` (8bury): contenedores, imágenes, volúmenes y redes en un widget.

## Qué agrega sobre los dos originales

| | containers | mini-docker | b3l0w-containers |
|---|---|---|---|
| Start / stop / restart / rm | ❌ | ✅ | ✅ |
| Imágenes / volúmenes / redes | ❌ | ✅ | ✅ |
| Health, uptime, compose project | parcial (ocultos) | ❌ | ✅ visibles |
| Puertos con URL clickeable | ✅ (duplicados) | ❌ | ✅ deduplicados |
| Logs por contenedor | ❌ | ❌ | ✅ |
| Formulario run con host:contenedor | ❌ | ❌ (forzaba P:P) | ✅ |
| Panel compacto o flotante grande | ❌ | flotante fijo | ✅ ambos |
| Panel tipo Docker Desktop (1400×900) | ❌ | ❌ | ✅ sidebar + dashboard + compose + terminal |
| Acciones de Docker Desktop | parcial | ❌ | ✅ pause, rename, exec, commit, tag, top, history, cp, build, prune |
| Logs en vivo (`--follow`) | ❌ | ❌ | ✅ con Stop y Refresh |
| YAML del stack de Compose | ❌ | ❌ | ✅ con el path de origen |
| Búsqueda en Docker Hub | ❌ | ❌ | ✅ |
| Límites de CPU/RAM en caliente | ❌ | ❌ | ✅ |
| Respaldo y restauración de volúmenes | ❌ | ❌ | ✅ tar.gz |
| Desglose de disco por tipo | ❌ | ❌ | ✅ imágenes, contenedores, volúmenes, build cache |

## Los dos paneles

| Entry | Tamaño | Para qué |
|---|---|---|
| `:panel` | 760 px, alto según contenido | lista por pestañas, detalle, formulario run |
| `:float` | 1240×860 | el mismo panel con más aire |
| `:desktop` | **1400×900** | **el panel grande tipo Docker Desktop** |

El grande tiene barra lateral con secciones (Dashboard, Containers, Images,
Volumes, Networks, Compose, Terminal, Build, Disk, Events), dashboard con
métricas, vista de Compose por stack, terminal para correr comandos dentro de
un contenedor y todas las acciones de Docker Desktop.

**Se abre desde el panel compacto**: el botón de la cabecera (icono de
dashboard) llama `noctalia.togglePanel("b3l0w/containers:desktop")`.

También se puede abrir en una sección concreta por IPC:

```bash
noctalia msg plugin b3l0w/containers:desktop all section '{"section":"compose"}'
```

## Arquitectura

```
panel.luau    lista por pestaña, detalle con logs, formulario run
desktop.luau  panel grande: sidebar, dashboard, compose, terminal, acciones
service.luau  dueño del CLI; refresco por intervalo; cola de acciones
widget.luau   corriendo / parados / unhealthy
lib/          capa compartida (anim, cli, layout, prefs, state, store, theme)
```

- `lib/layout.luau`: el ancho y el alto del layout. El host es dueño del
  tamaño (no hay `measure()`): el plugin pide `align = "stretch"` y deja que
  el host mida.
- `lib/state.luau`: la caché del estado. El watcher entrega el valor nuevo y
  `state.get` devuelve el anterior: sin la caché la UI va un frame atrás.

Backend: `b3l0w docker snapshot|start|stop|restart|pause|unpause|remove|rmi|volume-rm|network-rm|run|logs|stats|inspect|events|compose|info|df|prune|exec|cp|commit|rename|tag|top|history`.

Dos acciones no salen del CLI de b3l0w y el service las corre directo:

- **build**: `b3l0w docker` no expone `docker build`; el service lo corre.
- **cp**: `b3l0w docker cp` arma el comando sin quitar el `--from` y docker lo
  rechaza con `unknown flag: --from`; el service corre `docker cp` directo.

## Bugs de los originales que corrige el backend

1. **Puertos duplicados**: `docker ps` publica el mismo puerto en `0.0.0.0` y
   `[::]`, y repite el interno cuando conviven tcp/tcp6. `ParsePorts` deduplica
   por `host:contenedor/proto`. Cubierto por test con el caso real.
2. **awk/cut sin strtonum** fallaba en silencio y cortaba el parseo.
3. **Decodificación de 25 filas por tick** en Luau: ahora es un solo JSON
   armado en Go.
4. **Sin timeout** en `runAsync`: un `docker ps` colgado congelaba el panel.
5. **`run_image` forzaba `-p P:P`**: ahora acepta `host:contenedor`, valida el
   formato y rechaza lo que no entiende.
6. **Redes nativas**: `bridge`/`host`/`none` no se ofrecen para borrar.
7. **Sin nulos en JSON**: slices vacíos salen `[]`, no `null` (en Luau un `null`
   rompe `#payload.images`).
8. **Carrera de datos** en el snapshot paralelo (detectada con `go test -race`).

## Acciones del panel grande

| Acción | Qué corre |
|---|---|
| start / stop / restart | `b3l0w docker start\|stop\|restart <id>` |
| pause / unpause | `b3l0w docker pause\|unpause --id <id>` |
| remove | `b3l0w docker remove <id>` (doble click para confirmar) |
| rename | `b3l0w docker rename --id <id> --name <n>` |
| logs | `b3l0w docker logs <id> --tail 80` |
| inspect | `b3l0w docker inspect <id> --json` |
| stats | `b3l0w docker stats --json` (muestra del dashboard) |
| exec | `b3l0w docker exec --id <id> <cmd>` (la terminal del panel) |
| commit | `b3l0w docker commit --id <id> --repo <r> --tag <t>` |
| tag | `b3l0w docker tag --id <id> --repo <r> --tag <t>` |
| top / history | `b3l0w docker top\|history <id>` |
| cp | `docker cp <id>:<origen> <destino>` (del contenedor al host) |
| build | `docker build -t <tag> -f <dockerfile> <contexto>` |
| prune | `b3l0w docker prune containers\|images\|volumes\|builder\|system` |
| compose | `b3l0w docker compose <proyecto> --action up\|down\|restart\|pull` |
| run | `b3l0w docker run --image <img> --name <n> --port <p> --env <k=v>` |

## Ajustes

`show_stopped`, `refresh_seconds`, `show_label`, `panel_mode` (compact|float),
`glyph`, `animations`, `density`, `open_url_on_click`, `layout_mode`
(auto|fixed).

`layout_mode` no aplica al panel grande: ese tiene el tamaño fijo del
manifest (1400×900) porque el host no deja cambiarlo en runtime.

## Verificación

```bash
b3l0w docker snapshot --all --json          # backend
noctalia msg plugin b3l0w/containers:start all view '{"tab":"images"}'
noctalia msg plugin b3l0w/containers:start all logs '{"id":"<id>"}'
noctalia msg plugin b3l0w/containers:desktop all section '{"section":"terminal"}'
grep 'b3l0w-containers]' ~/.cache/noctalia/noctalia.log | tail -1
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .
```


## Logs en vivo

Noctalia no tiene timers ni exec asíncrono en Luau, así que un
`docker logs -f` no se puede mantener desde el plugin. El seguimiento lo
hace el CLI: `b3l0w-docker logs-stream <id>` lanza el proceso desacoplado
(`setsid` + `exec`) escribiendo a `~/.cache/noctalia/docker-logs/<id>.log`, y
el panel lo lee con `readFile`.

- **Follow live** arranca el seguimiento; **Stop** lo corta (mata el grupo
  de procesos, sin dejar huérfanos).
- **Refresh** vuelve a leer el archivo. Se muestran las últimas 200 líneas.
- Los escapes ANSI del contenedor se limpian, así que se lee
  `2026-11-04 18:49:52 TRC - method=GET status=200` y no `[0m[90mTRC[0m`.

## El YAML de un stack

Cada fila de Compose tiene un botón que abre el `docker-compose.yml` del
proyecto. `docker compose` no tiene un verbo que imprima el archivo, así que
`b3l0w-docker compose-file <proyecto>` resuelve la ruta con
`docker compose ls --format json` y la lee.

## Desglose del disco

La tarjeta del dashboard muestra el reclaimable total y una línea por tipo
(imágenes, contenedores, volúmenes locales, build cache), en vez de los
cuatro valores concatenados que se cortaban.

## Requisitos

- `docker` (daemon corriendo)
- `b3l0w` con la extensión `docker` (`b3l0w-docker`)

## Instalación

```bash
git clone https://github.com/Below-Z3R0/b3l0w-containers ~/.local/share/noctalia/plugins/b3l0w-containers
```

Después habilitá el plugin desde **Ajustes → Plugins** de Noctalia, o
reiniciá Noctalia para que lo descubra:

```bash
kill $(pgrep -x noctalia); nohup noctalia >/dev/null 2>&1 &
```

## Licencia

MIT — ver [LICENSE](LICENSE).
