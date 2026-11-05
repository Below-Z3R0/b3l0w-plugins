# TEST-MATRIX — E2E b3l0w/anilist + b3l0w/containers

Ejecutado 2026-11-01 04:41–04:52 (Noctalia v5, log DBG). Sólo lectura: ningún contenedor
arrancado/parado, ninguna mutación de AniList (no se envió `mutate` con `mediaId` real).
Evidencia: `[b3l0w-*]` en `~/.cache/noctalia/noctalia.log` (rota a `.log.1` cada 1 MB),
traza de panel, `prepareFrame`, diff de píxeles (grim) y `docker ps` como ground truth.
Únicos procesos fuera de juego: `linux-wallpaperengine` (fondo animado) — ruido medido 0.0–0.6 %.

Comando base: `noctalia msg plugin <id>:start all <accion> '<json>'` (siempre responde
`ok: dispatched 1` aunque el handler falle: el IPC es fire-and-forget).

## Matriz

| # | Caso | Comando (acción + payload) | Esperado | Obtenido | OK/FALLA |
|---|---|---|---|---|---|
| C1 | containers refresh | `refresh {}` | snapshot publicado | traza `1/1/containers/detail/p1` | OK |
| C2 | containers view images | `view {"tab":"images"}` | tab cambia | traza `3/1/images/list/p1` | OK |
| C3 | containers view containers | `view {"tab":"containers"}` | tab vuelve | traza `1/1/containers/list/p1` | OK |
| C4 | containers logs id inexistente | `logs {"id":"no-such-container-xyz"}` | error visible + servicio vivo | rc0, 0 toast, 0 línea de log (error sólo en `LOGS_KEY`) | FALLA |
| C5 | containers start id inexistente | `start {"id":"no-such-container-xyz"}` | falla con error visible | rc0 + 1 toast, servicio sigue publicando | OK |
| C6 | containers stop id inexistente | `stop {"id":"no-such-container-xyz"}` | idem | rc0 + 1 toast | OK |
| C7 | containers restart id inexistente | `restart {"id":"no-such-container-xyz"}` | idem | rc0 + 1 toast | OK |
| C8 | containers remove id inexistente | `remove {"id":"no-such-container-xyz"}` | idem | rc0 + 1 toast | OK |
| C9 | containers rmi id inexistente | `rmi {"id":"no-such-image-xyz"}` | idem | rc0 + 1 toast | OK |
| C10 | containers volume-rm inexistente | `volume-rm {"id":"no-such-volume-xyz"}` | idem | rc0 + 1 toast | OK |
| C11 | containers network-rm inexistente | `network-rm {"id":"no-such-network-xyz"}` | idem | rc0 + 1 toast | OK |
| C12 | containers acción desconocida | `frobnicate {"id":"x"}` | error visible | rc0, 0 toast, 0 log: se descarta en silencio | FALLA |
| C13 | containers payload JSON roto | `view {"tab":` | error visible, sin romper | rc0, sin diagnóstico; servicio sigue OK | FALLA |
| C14 | containers run imagen vacía | `run {"image":""}` | falla sin crear nada | rc0 + 1 toast; `docker ps`=1 (seanime, ajeno al test) | OK |
| C15 | containers view tab inválido | `view {"tab":"basura"}` | rechazo limpio | fallback a tab previa (whitelist `TABS`), sin crash | OK |
| C16 | containers refresh x2 (cola busy) | `refresh` dos veces | ambos procesados | 2× rc0, snapshot consistente, 0 errores | OK |
| C17 | containers logs id real | `logs {"id":"seanime"}` | estado logs publicado | rc0; `LOGS_KEY` no tiene traza → no verificable | FALLA |
| C18 | containers disable/enable | `plugins disable/enable b3l0w/containers` | estado + 0 huérfanos | tab `images` preservado, traza `3/1/images/list/p1`, `pgrep -c 'b3l0w docker'`=0 | OK |
| C19 | containers panel abre/dibuja/cierra | `panel-toggle b3l0w/containers:{panel,float}` | abierto, pintado, cerrado | `panelOpen=true→false`, diff región 12.45 %, `prepareFrame` ausente (render <50 ms) | OK |
| C20 | containers panel warnings | mismo open | 0 warnings | `ui tree: 'box' cannot have children, 1 dropped` ×2 por render (362 en `.log.1`) | FALLA |
| A1 | anilist status | `status {}` | publica estado | traza `334/349/ANIME/library/discover/p1/q1/f334/d24/...` | OK |
| A2 | anilist view library MANGA | `view {"view":"library","tab":"MANGA"}` | vista+tab | traza `0/349/MANGA/library/library/...` | OK |
| A3 | anilist view library ANIME | `view {"view":"library","tab":"ANIME"}` | vista+tab | traza `334/…/ANIME/library/library/...` | OK |
| A4 | anilist view discover p1 | `view {"view":"discover","page":1,"kind":"trending"}` | fetch p1 | traza `…/discover/p1/…/d24` | OK |
| A5 | anilist discover trending p2 | `discover {"kind":"trending","page":2}` | página 2 | `q2/d24`, título distinto, covers 407→414 | OK |
| A6 | anilist kind inventado | `discover {"kind":"inventado","page":1}` | error visible | CLI sale 1 (`kind inválido "inventado"`), pero service: 0 toast, 0 log (sólo `S.error`) | FALLA |
| A7 | anilist status tras inválido | `status {}` | servicio vivo | rc0, estado íntegro | OK |
| A8 | anilist mutate mediaId no numérico | `mutate {"mediaId":"abc","progress":1}` | error visible | descartado por `tonumber` sin aviso | FALLA |
| A9 | anilist acción desconocida | `frobnicate {}` | error visible | descartado en silencio | FALLA |
| A10 | anilist discover seasonal | `discover {"kind":"seasonal","page":1}` | temporada, no trending | `q1/d24` con títulos de temporada; `kind` no está en la traza | OK |
| A11 | anilist sync | `sync {}` | refresca biblioteca | rc0, `library.json` mtime 04:48→04:49, 334 entradas | OK |
| A12 | anilist view inválida | `view {"view":"basura","tab":"ANIME"}` | fallback, sin crash | `vista=basura` → cuerpo library, tab aplicada, sin crash | OK |
| A13 | anilist view library | `view {"view":"library","tab":"ANIME"}` | vuelve | traza `…/ANIME/library/library/...` | OK |
| A14 | anilist disable/enable | `plugins disable/enable b3l0w/anilist` | persiste + 0 huérfanos | 334 entradas OK; carátulas 414→349 (las de discover no se persistieron); `pgrep -c 'b3l0w anilist'`=0 | FALLA |
| A15 | anilist panel abre/dibuja/cierra | `panel-toggle b3l0w/anilist:{panel,float}` | pintado | `prepareFrame 792x736 logical`, diff región 15.73 %, `panelOpen=true→false`, 0 warnings | OK |

## Conteo

34 casos · 25 OK · 9 FALLA · 0 CPU budget excedido · 0 plugin deshabilitado por timeouts.
`grep -c 'exceeded its CPU budget' noctalia.log*` → 0/0 (tras cada batería y al final).
`grep 'disabled after repeated timeouts'` → 1 línea, 04:31:12 `b3l0w/wallpaper:panel`
(previa a esta corrida, otro plugin, panel y no service).

## Fallos (repro)

1. **C4/C17 — `logs` no deja diagnóstico.** `noctalia msg plugin b3l0w/containers:start all logs '{"id":"no-such"}'`
   → rc0, ni toast ni log; el error sólo existe en `b3l0w_containers_logs` (`service.luau:217-231`,
   `loadLogs` no llama `notifyError` ni `noctalia.log`). Con id real no hay forma de verificar el
   contenido publicado (ninguna acción publica traza con largo de logs).
2. **C12/A9 — `action` desconocida se descarta en silencio.** `frobnicate {...}` en ambos services:
   `handle()` compara contra una cadena de `elseif` y sale sin error. Un typo del panel es invisible.
3. **C13 — payload roto idem:** `noctalia msg plugin ... view '{"tab":'` → rc0 sin diagnóstico.
4. **C20 — `chip()` tira su label.** `panel.luau:94-105` (containers) arma `ui.box({paddingH,paddingV}, {ui.label})`:
   `ui.box` no acepta `padding*` ni hijos → `'box' cannot have children, 1 dropped`. Cada chip se
   dibuja como rectángulo vacío. Repro: abrir `b3l0w/containers:panel`; 2 warnings por render.
5. **A6/A8 — error de AniList no visible fuera del panel.** `discover {"kind":"inventado"}` y
   `mutate {"mediaId":"abc"}`: el CLI devuelve `{"error":...}` + exit 1, el service sólo guarda
   `S.error` (banner del panel). Sin `noctalia.log` ni toast, así que el log de la shell no lo muestra.
6. **A14 — carátulas de discover no persisten.** Tras `discover`, `covers.json` quedó en 334 y en
   memoria había 414: `publishCovers` del discover (`service.luau:484-491`) no llama `saveCoversCache`.
   Tras disable/enable el mapa baja a 349 (sólo lo que repersistió el sync de la biblioteca).
7. **A12 (flake, 1 de 2 corridas):** `view` con `tab` explícita mostró la tab anterior en la traza
   pese a `onOpen` sembrar `SCREEN_KEY`; no reproducible (2ª corrida correcta). Anotado por si reaparece.

## Cobertura no ejecutada por diseño

- `mutate` con `mediaId` real, `start/stop/restart/remove/rmi/volume-rm/network-rm` con ids reales y
  `run` con imagen real: escriben estado del usuario. Quedan como casos de test manual/opt-in.
- `view`/`discover` de anilist requieren red (AniList API); medidos, pero no deterministas.
