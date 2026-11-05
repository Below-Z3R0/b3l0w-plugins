# Auditoría — `shangshui0302/github-kanban` (Noctalia v5)

**Alcance**: plugin de terceros instalado en
`~/.local/state/noctalia/plugins/materialized/community/github-kanban`.
Se audita como proyecto propio (cada widget = un proyecto). **No se modificó ningún archivo del plugin.**

| Dato | Valor | Evidencia |
|---|---|---|
| id / versión | `shangshui0302/github-kanban` / `0.2.7` | `plugin.toml:1-3` |
| `plugin_api` | `43` (máximo actual: 43 = roles `*_container`/`outline_variant`) | `plugin.toml:4`, docs `plugin-api` |
| Host | Noctalia `v5.4.1` (41-gf2cebd97e016); plugin **enabled** | `noctalia --version`, `noctalia msg plugins list` |
| Entries | 1 widget + 1 panel + 2 services = 4 | `plugin.toml:714-734`; log: `loaded plugin ... (4 entries)` |
| Dependencias | `gh`, `xdg-open` | `plugin.toml:10` |
| Código | 3.032 líneas `.luau` (panel 1.196, lib/notifications 716, service 615, lib/data 363, lib/github 74, widget 51, notifications 17) | `wc -l` |
| i18n | `en` (332 hojas), `zh-Hans` (328), `zh-Hant` (328). **No hay `es.json`** | `translations/*.json` |
| Sintaxis | `luau-compile --binary`: 7/7 archivos OK | verificado |

**Nombre engañoso**: no hay tablero kanban, ni proyectos, ni columnas, ni drag & drop.
Es un *dashboard* GitHub de 5 pestañas (ver §4 y §5).

---

## 1. Entries y settings

### 1.1 Entries

| Entry | Tipo | Líneas | Rol |
|---|---|---|---|
| `github` | `[[widget]]` | `plugin.toml:714-716` / `widget.luau:1-51` | Glyph + contador de no leídas; click izquierdo abre el panel, click derecho refresca |
| `kanban` | `[[panel]]` | `plugin.toml:718-726` / `panel.luau:1-1196` | Dashboard 860×620, `attached`, `position = "auto"`, `open_near_click = true`, `dismiss_on_outside_click = true` |
| `sync` | `[[service]]` | `plugin.toml:728-730` / `service.luau:1-615` | Dueño del dashboard (perfil, contribuciones, PRs, issues, repos, Actions, following) |
| `notifications` | `[[service]]` | `plugin.toml:732-734` / `notifications.luau:1-17` + `lib/notifications.luau` | Dueño de notificaciones y de las escrituras `mark_read` |

Callbacks que **sí** existen:

* widget: `onClick` (`widget.luau:39`), `onRightClick` (`43`), `onConfigChanged` (`47`). No hay `onScroll`/`onIpc`.
* panel: `onContributionHover` (`panel.luau:1133`), `onOpen` (`1142`), `onClose` (`1158`), `onFrameTick` (`1165`), `update` (`1169`), `onConfigChanged` (`1178`). **No hay `onKey` ni `onIpc`** (el manifest tampoco declara `capture_keys`).
* `sync`: `update` (`service.luau:583`), `onEnable` (`603`), `onConfigChanged` (`604`), `onIpc` (`612`).
* `notifications`: `update`, `onEnable`, `onConfigChanged`, `onIpc` (`notifications.luau:12-17`).

### 1.2 Los 74 settings, por tema

Tipos: **29 bool · 22 select · 16 int · 5 string · 2 string_list**. 42 usan `visible_when`, 22 no tienen
`description_key`, ninguno usa `advanced`. Todos declaran `label_key` (ninguno cae en la trampa de `label`).

**A. Refresco y generales (3)** — `plugin.toml:12-48`

| key | tipo | default | label_key |
|---|---|---|---|
| `refresh_interval_minutes` | select `5/15/30` | `"15"` | `settings.refresh_interval.label` |
| `default_dashboard` | select `overview/notifications/work/following/repositories` | `"overview"` | `settings.general.default_dashboard.label` |
| `bar_display_mode` | select `icon/count/both` | `"both"` | `settings.general.bar_display_mode.label` |

**B. Overview (1)** — `plugin.toml:51-56`: `show_overview` bool `true`.

**C. Notificaciones (7)** — `plugin.toml:59-129`

| key | tipo | default | nota |
|---|---|---|---|
| `show_notifications` | bool | `true` | |
| `notification_sync_mode` | select `legacy/synced` | `"legacy"` | vis. si `show_notifications` |
| `notification_refresh_interval_seconds` | select `60/120/300` | `"120"` | vis. si `synced` |
| `notification_refresh_on_open` | bool | `true` | vis. si `synced` |
| `notification_mark_read_on_open` | bool | `false` | vis. si `synced` |
| `notification_history_days` | int 1–90 step 1 | `30` | |
| `notification_default_filter` | select `all/unread/read` | `"unread"` | |

**D. Work / Activity (4)** — `plugin.toml:132-174`: `show_activity` bool `true`;
`activity_history_days` int 1–365 `30`; `pr_default_filter` select `all/created/review` `"all"`;
`issue_default_filter` select `all/created/assigned` `"all"`.

**E. Following (17)** — `plugin.toml:177-318`

| key | tipo | default |
|---|---|---|
| `show_following` | bool | `true` |
| `following_card_max_height` | int 140–500 step 20 | `260` |
| `following_user_limit` | int 1–12 | `4` |
| `following_events_per_user` | int 1–30 | `30` |
| `starred_repository_limit` | int 10–100 step 10 | `100` |
| `following_include_prereleases` | bool | `true` |
| `following_hide_bots` | bool | `false` |
| `following_show_stars` / `_pushes` / `_issues` / `_pull_requests` / `_releases` / `_forks` / `_other` | bool ×7 | `true` |
| `following_ignored_users` | string_list | `[]` |
| `following_ignored_repositories` | string_list | `[]` |
| `following_history_days` | int 1–30 | `30` |

**F. Repositorios (1)** — `plugin.toml:321-326`: `show_repositories` bool `true`.

**G. Apariencia general (14)** — `plugin.toml:330-479`: `appearance_density` (select `compact/standard/comfortable`, `"standard"`),
`appearance_font_scale` (80–130 step 5, `100`), `appearance_card_radius` (0–24, `9`), `appearance_card_spacing` (4–20, `8`),
`appearance_card_border` (`none/subtle/accent`, `"subtle"`), `appearance_card_background` (`transparent/tinted/solid`, `"tinted"`),
`appearance_hover_effect` (`none/background/border`, `"background"`), `appearance_secondary_text` (`full/truncate/hidden`, `"truncate"`),
`appearance_time_format` (`relative/local/iso`, `"relative"`), `appearance_avatar_size` (`small/medium/large`, `"medium"`),
`appearance_avatar_shape` (`circle/rounded`, `"circle"`), `appearance_icon_style` (`color/theme/muted`, `"theme"`),
`appearance_show_empty_illustration` (`true`), `appearance_animations` (`true`).

**H. Heatmap (15)** — `plugin.toml:482-608`: `heatmap_cell_size` (8–16, `13`), `heatmap_cell_gap` (1–4, `1`),
`heatmap_cell_radius` (0–4, `2`), `heatmap_levels` (`4/5`, `"5"`), `heatmap_show_months|_weekdays|_total|_legend` (bool `true` ×4),
`heatmap_empty_style` (`background/outline`), `heatmap_color_mode` (`noctalia/github/custom`), `heatmap_custom_level_0..4` (string `""` ×5, visibles sólo en `custom`).

**I. Detalles del dashboard (12)** — `plugin.toml:611-712`: `notification_unread_dot` (`true`), `notification_unread_border` (`true`),
`notification_read_opacity` (40–100 step 5, `100`), `activity_show_status_badges` (`true`), `activity_show_type_icons` (`true`),
`activity_repository_emphasis` (`true`), `following_event_spacing` (2–12, `5`), `following_content_lines` (1–5, `2`),
`repositories_layout` (`list/grid`, `"list"`), `repositories_show_language` (`true`), `repositories_show_stats` (`true`),
`overview_stats_layout` (`columns4/grid/compact`, `"columns4"`).

**Cobertura real de los settings** (grep sobre todo el `.luau`): los 74 se leen en código.
Los 5 `heatmap_custom_level_*` se leen de forma dinámica (`panel.luau:132`, `readConfig("heatmap_custom_level_" .. level)`), por eso no aparecen como literal.
Copiar/pegar en el manifest: `heatmap_custom_level_1..4` reusan `settings.appearance.heatmap_custom_level_0.description`
(`plugin.toml:582, 590, 598, 606`) → los cinco campos muestran la descripción del nivel 0.

---

## 2. Autenticación GitHub

**No hay gestión de token en el plugin.** Toda la autenticación es la sesión de `gh` (keyring / `~/.config/gh/hosts.yml`);
el código nunca lee `GH_TOKEN`, ni un archivo de config, ni guarda credenciales.

* Todas las llamadas son argv directos: `{"gh", "api", endpoint}` — `lib/github.luau:10-12`.
* El service de notificaciones fija host, versión de API y pide headers explícitos:
  `gh api --hostname github.com --include --method GET -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"` — `lib/notifications.luau:302-309`.
* El dashboard **no** fija `--hostname` (`lib/github.luau:10-12`): usa el host activo de `gh`. En una instalación con
  `GH_HOST`/GHE, dashboard y notificaciones pueden hablar con hosts distintos → identidad y contadores inconsistentes (§8.7).

**Validación de identidad (doble)**

1. Lectura: `gh api user` → `Data.profile` (`lib/data.luau:12-28`) → `verifiedProfile` exige `login` que matchee
   `^[%w%-]+$` (`service.luau:355-361`).
2. Cierre de ronda: al terminar todas las secciones se vuelve a pedir `gh api user` (`service.luau:391`) y, si el login
   cambió, se llama `setAccount` y se marca `auth_error` sin publicar la ronda (`service.luau:370-384`).
   En notificaciones: `gh api --hostname github.com user --jq .login` (`lib/notifications.luau:328-334`), y **antes de cada
   escritura** se revalida cuenta y versión del hilo (`lib/notifications.luau:562-568`).

**Scopes**: no se piden, no se verifican y no se inspeccionan (`X-OAuth-Scopes` nunca se lee; nadie llama `gh auth status`).
Consecuencia: un token sin scope `notifications` no falla al arrancar, falla a mitad de refresco con 403/404 y el plugin lo
clasifica por *substring*: `auth|token|401` (`service.luau:318-322`) y `401|403|auth|scope|token` + `rate limit|429` en
notificaciones (`lib/notifications.luau:314-319`). El PATCH de lectura requiere scope de escritura de notificaciones.

**Riesgo asumido**: como todo pasa por `gh`, si el usuario cambia de cuenta mientras hay requests en vuelo, el guard es
*después* (`generation`/`refreshSerial`, `service.luau:13-15, 129-131`), no por request.

---

## 3. Llamadas a la API

### 3.1 Endpoints exactos

| # | Verbo / endpoint | Dónde | `--jq` | Paginación |
|---|---|---|---|---|
| 1 | `GET user` | `github.luau:30` | no | — |
| 2 | `POST graphql` query `viewer{...contributionsCollection...}` | `github.luau:28, 31` | no | — |
| 3 | `GET user/following?per_page=12` | `github.luau:32` | no | no |
| 4 | `GET search/issues?q=is:pr+author:@me&sort=updated&order=desc&per_page=20` | `github.luau:24, 34` | `SEARCH_JQ` (`45`) | no |
| 5 | `... q=is:pr+is:open+review-requested:@me` | `github.luau:35` | idem | no |
| 6 | `... q=is:issue+author:@me` | `github.luau:36` | idem | no |
| 7 | `... q=is:issue+assignee:@me` | `github.luau:37` | idem | no |
| 8 | `GET user/repos?sort=updated&direction=desc&per_page=20` | `github.luau:38` | `REPO_JQ` (`46`) | no |
| 9 | `GET users/{login}/events/public?per_page=N` (N≤30) | `github.luau:50-53` | `EVENT_JQ` (`48`) | no |
| 10 | `GET repos/{full}/actions/runs?per_page=5` | `github.luau:59-61` | `RUNS_JQ` (`47`) | no |
| 11 | `POST graphql` `viewer.starredRepositories(first:$count, after:$after)` + `releases(first:1)` | `github.luau:63-72` | no | **cursor, 2 páginas (≤100)** |
| 12 | `GET notifications?all=..&per_page=50&page=N[&since=]` | `lib/notifications.luau:371-383` | `projection` (`6-7`) | **completa** |
| 13 | `GET notifications/threads/{id}` (pre-check) | `lib/notifications.luau:570` | no | — |
| 14 | `PATCH notifications/threads/{id}` | `lib/notifications.luau:591` | no | — |
| 15 | `GET user --jq .login` (identidad) | `lib/notifications.luau:329` | inline | — |
| — | `GET repos/{full}/events?per_page=30` | `github.luau:55-57` | no | **sin llamador** (§8.3) |

Total por refresco del dashboard: 1 perfil + 1 GraphQL contribuciones + 4 búsquedas + 1 repos + 1 following
+ hasta 12 eventos de usuario + hasta 2 páginas GraphQL de releases + hasta 5 `actions/runs`
(`service.luau:461` usa `GitHub.ACTION_REPO_LIMIT = 5`, `github.luau:7`). ≈ 25-28 procesos `gh` por refresco.

### 3.2 Paginación

* **Sólo notificaciones pagina de verdad**: bucle `page(n+1)` mientras `Link: rel="next"` o `#raw == 50`
  (`lib/notifications.luau:409, 416`), dos pasadas por refresco: `all=true&since=<cutoff>` y `all=false`
  (`lib/notifications.luau:505-508`). Dedupe por `id` y gana la versión con `updatedAt` mayor (`444-478`).
* **Releases**: 2 páginas como máximo, 50 + hasta 50 según `starred_repository_limit`
  (`service.luau:528-546`).
* **Todo el resto es una sola página con tope duro**: 20 ítems (búsquedas/repos), 12 (following), 30 (eventos), 5 (runs).
  No hay `--paginate` en ningún lado y no hay "cargar más" en la UI.

### 3.3 Rate limit / condicionales

* Notificaciones: parsea headers de la respuesta con `--include` (`lib/notifications.luau:32-46`) y aplica
  `x-poll-interval`, `retry-after`, `x-ratelimit-remaining == 0 → x-ratelimit-reset` (`361-370`).
  Condicionales `If-Modified-Since` + `If-None-Match` por endpoint cacheado; `304` reusa la página (`377-390`).
* Backoff exponencial ante fallo: `nextAllowed = now + 60·2^(failures-1)`, `failures` tope 4 (`lib/notifications.luau:321-327`).
* Timeout de lectura/escritura: 120 s (`lib/notifications.luau:8`), con `cancel()` que reconcilia por lectura, nunca reintenta la escritura (`543-553`).
* **El dashboard no tiene nada de esto**: ni condicionales, ni backoff, ni lectura de `X-RateLimit-*`; un 403 secundario
  sólo deja `status = "partial"` y espera el próximo intervalo (`service.luau:343-349`).
  Sólo hay un watchdog de 120 s para la ronda completa (`service.luau:301, 583-600`).

---

## 4. Modelo de datos (y por qué no hay kanban)

**No existe modelo de proyecto/columna/tarjeta.** No hay GraphQL Projects v2, ni `ProjectV2Item`, ni estados de columna,
ni transiciones, ni drag & drop en ningún archivo: cero apariciones de `ProjectV2`/`projectItems`, de manejadores de
arrastre (`onPointerDown`, `onDrop`, `onPointerMove`) y de `onKey`; lo único que matchea `column` es `ui.column` de layout
(grep sobre los 7 `.luau`). Las "columnas" del nombre son pestañas de dashboard.

Lo que sí hay son 6 formas de ítem, todas planas y ya normalizadas en `lib/data.luau`:

| Forma | Campos | Evidencia |
|---|---|---|
| `profile` | `login, name, bio, avatarUrl, avatarPath, url, followers, following, publicRepos` | `data.luau:12-28` |
| `contributions` | `login, total, rows[7] (glifos ░▒▓█), details[7] (date|count por tab), today, todayDate, currentStreak, bestStreak, fetchedAt` | `data.luau:30-68` |
| `issue` / `pr` | `number, title, url, repository, kind ("pull_request"|"issue"), state ("open"|"closed"), updatedAt, user, source` | `data.luau:160-180` |
| `notification` | `id, title, reason, type, repository, url, updatedAt, unread, lastReadAt` | `data.luau:182-202` |
| `event` | `id, type, action, titleKey, name, repo, subtitle, subtitleKey, subtitleArgs, actor, actorType, actorAvatarUrl, repository, url, createdAt, source, sourceName` (+`actorAvatarPath` inyectado) | `data.luau:311-335` |
| `repository` | `name, fullName, description, url, updatedAt, language, stars, forks, ownerLogin, ownerAvatarUrl, source` | `data.luau:70-84` |
| `run` (Actions) | `id, name, status, conclusion, branch, event, url, repository, createdAt, updatedAt, source` | `data.luau:343-361` |

**Estados y transiciones reales**

* PR/issue: sólo `state` (`open|closed`) como filtro de lectura (`panel.luau:966-981`); no se escribe nada.
* Acción de run: `conclusion or status` (`data.luau:350`), sólo visual.
* Notificación: `unread → read` es **la única mutación** del plugin. Optimista y versionada:
  `overrides[id] = { updatedAt, pending }` (`lib/notifications.luau:599-610`), PATCH con pre-check de versión
  (`562-596`), rollback si falla (`532-536`), `expiresAt = now + 600 s` (`529`) para no quedar pegado si GitHub no confirma.
  También revierte a *unread* si el hilo vuelve a actualizarse (`575-588`).

---

## 5. Funcionalidad visible, pantalla por pantalla

Header fijo: glyph `brand-github`, título, "frescura" (`formatTime("%H:%M")` o "stale"), botón refrescar, botón cerrar
(`panel.luau:1071-1084`). Debajo, una fila de pestañas generada desde `TABS` (`1014-1020`) filtrando por
`show_overview|notifications|activity|following|repositories` (`1022-1028`). Si la pestaña activa se deshabilita, cae a la primera visible (`1047-1049`).

**1) Overview** (`panel.luau:776-792`)
* Card de perfil clicable → abre `profile.url`: avatar (auto-descargado), nombre, `@login`, bio, y 4 métricas
  (followers/following/repos/contribuciones) en `columns4|grid|compact` (`683-717`, `672-681`).
* Sección "Contributions": heatmap anual construido por **7 filas de glifos** que se parsean a niveles
  (`228-233`) y se arman columna por columna en ticks (`308-357`), con etiquetas de mes/semana, total del año o
  detalle del día on-hover (`726-774`). Colores `noctalia|github|custom` (`119-134`).
* 4 métricas: hoy, racha actual, mejor racha, total año (`785-790`).
* Placeholder "Preparing contribution calendar…" mientras se arma (`727-731`).

**2) Notificaciones** (`panel.luau:802-876`)
* Dos tiras de filtros: estado de lectura (`all/unread/read`) y motivo agrupado (`all/attention/assigned/updates`,
  mapeo en `794-798`).
* En modo `synced`: botón "Marcar como leídas" del listado filtrado, indicador de refresco y de "marcando…" (`839-851`).
* Lista de tarjetas: punto de no-leída, avatar/glyph, título, subtítulo, meta (motivo traducido), `external-link`;
  borde y opacidad distintos para leídas (`83-97`, `406-495`). En `synced`, cada tarjeta agrega un botón de check
  como blanco de click separado del link (`481-494`).
* Paginado de 50 con ‹ › (`800, 831-873`). `notificationPage` se resetea al abrir y al cambiar filtro.

**3) Work** (`panel.luau:878-985`)
* Tres sub-pestañas: Pull requests / Issues / Actions.
* PRs e Issues: filtro de alcance (`all|created|review` y `all|created|assigned`) y filtro de estado (`all|open|closed`);
  el merge de `my_prs`+`review_prs` (y `authored_issues`+`issues`) deduplica por URL y anota `createdByMe`/`reviewRequested`/
  `assignedToMe` (`879-910`).
* Tarjetas con énfasis de repositorio, iconos de tipo y badges de estado opcionales (`439-445`, `478`).
* Acciones: lista plana de runs con `status/conclusion` como meta.

**4) Following** (`panel.luau:987-1012`, `558-662`)
* Filtro `all/users/repositories`; dos fuentes unidas por `id` (`998-1010`): eventos públicos de personas seguidas y
  releases de repos con estrella.
* Agrupación por actor o repositorio, orden por `createdAt` desc, tarjetas con avatar, nombre, contador y filas de evento
  (`640-662`). Cada tarjeta respeta `following_card_max_height` calculando filas visibles y un botón "Show N more"
  (`601-623`) — el estado de expansión se pierde al cerrar el panel (`1145`).

**5) Repositorios** (`panel.luau:540-556`): lista o grilla de 2 columnas, con lenguaje, estrellas, forks y fecha.

**Interacción**: todo es click izquierdo. Click en tarjeta → `xdg-open <url>` (con error visible si falta el binario,
`362-369`). Hover repinta y resalta (`452-456`, `573-577`). **No hay**: drag & drop, menú contextual, vista de detalle
interna de issue/PR (siempre abre el navegador), scroll horizontal, atajos de teclado, selección múltiple.
`ui.scroll` es vertical en las 3 listas (`506, 555, 661`).

---

## 6. State e IPC

### 6.1 Claves de `noctalia.state`

| Clave | Productor | Consumidor |
|---|---|---|
| `profile`, `contributions`, `repositories`, `actions`, `my_prs`, `review_prs`, `authored_issues`, `issues` | `service.luau:89-92` (`publish`) | panel `WATCHES` (`1109-1115`) |
| `following`, `following_users` | `service.luau:470, 494` | **nadie** (ni panel ni widget) |
| `following_events`, `following_repo_events` | `service.luau:487-493, 524-525` | panel (`1113`) |
| `following_repos` | `service.luau:530` (publicado vía `publishReleaseFeed`, `521-525`) | nadie |
| `status`, `stale`, `error`, `errors`, `last_update`, `login`, `dashboard` | `service.luau:289-350, 575-579` | widget `status` (`widget.luau:24`), panel `status/stale/error/last_update` |
| `notifications`, `notifications_count`, `notifications_pending`, `notifications_last_update`, `notifications_error`, `notifications_status` | `lib/notifications.luau:156-164, 202-225, 319, 432, 500, 531` | widget (`widget.luau:29-37`), panel (`1111-1112`) |
| `refresh_request` | widget (`widget.luau:44`), panel (`panel.luau:1078`) | `service.luau:615` (`state.watch`) |
| `notification_action` | panel (`panel.luau:375-378`) | entry `notifications.luau:9` (`state.watch`) |

El panel cachea el valor del watcher en `state` (no relee `get()` dentro del callback) — patrón correcto (`1116-1131`).

### 6.2 IPC

| Canal | Evento | Efecto |
|---|---|---|
| `noctalia msg plugin <id>:sync all refresh` | `onIpc("refresh")` | `refreshAll()`: publica `notification_action={type="refresh"}` y refresca el dashboard (`service.luau:608-614`) |
| `noctalia msg plugin <id>:notifications all refresh` | `onIpc("refresh")` | `notifications.refresh()` (`notifications.luau:15-17`) |
| panel | — | **no implementa `onIpc`**: cualquier evento se ignora |
| widget | — | no implementa `onIpc`; sólo `onClick`/`onRightClick` |

Acciones emitidas por el panel (todas atendidas): `refresh`, `mark_read` (con `id`+`updatedAt`), `mark_visible_read`
(con `items[]`) → `lib/notifications.luau:611-633`. `refresh` se enruta a `self.refresh()` antes de chequear `synced` (`613`).

Los nonces son sólo `noctalia.nowMs()` (`panel.luau:376`, `service.luau:609`): dos acciones en el mismo milisegundo
comparten nonce (hoy no rompe porque nadie deduplica por nonce, pero es la trampa clásica del patrón).

---

## 7. Trabajo caro en Luau delegable a un CLI en Go

Presupuesto del host: **25 ms de CPU por callback**, 3 timeouts seguidos deshabilitan el plugin. Todo esto corre dentro de
callbacks de `gh` o de `update()`:

| Trabajo | Dónde | Costo |
|---|---|---|
| Parseo del calendario de contribuciones (53 semanas × 7 días → 7 strings + 7 strings de detalle + streaks) | `lib/data.luau:30-68` | ~371 iteraciones + concatenaciones O(n²) (`rows[row] ..=`) en el callback del GraphQL; el payload **no tiene proyección `--jq`** (`github.luau:28-31`) |
| Merge/dedupe/sort de notificaciones (todas + no leídas, hasta miles) | `lib/notifications.luau:444-478` | construye `sortKeys` (`updatedAt .. "\0" .. id`), `table.sort` nativo y reindexa; hecho a mano con `coroutine.yield` por slice de 2 ms (`647`) |
| Merge de eventos por usuario (hasta 12 usuarios × 30 eventos) y de releases (hasta 100 repos) | `service.luau:482-496, 497-546` | todo en callbacks anidados |
| Filtro + agrupación + sort del feed Following en **cada render** | `panel.luau:640-662` | O(n log n) por repaint |
| Serialización del cache del dashboard entero | `service.luau:223-227` | `json.encode(dashboard)` completo en un solo llamado |
| Serialización/deserialización del cache de notificaciones en chunks de 50 | `lib/notifications.luau:233-265, 268-296` | ya troceado por ticks, pero es trabajo que un binario hace en µs |
| Descarga de avatares (1 por usuario/repo, secuencial por callback) | `service.luau:128-221` | ya delegado a `noctalia.download`, pero orquestado en Luau |

**Qué conviene mover a un CLI Go** (un subcomando por caso, JSON chico ya proyectado, cache con ETag en disco):

1. `kanban snapshot --since <días> --json` → una sola ronda: `gh api` con paginación completa, `If-None-Match`,
   merge/dedupe/sort, y devuelve sólo los campos que la UI dibuja. Reemplaza los ~25 procesos `gh` y el merge en Luau.
2. `kanban heatmap --json` → `{ rows[7], details[7], today, currentStreak, bestStreak, total }` ya calculado
   (hoy `data.luau:34-67` lo hace en el callback).
3. `kanban notifications --since <días> [--unread-only] --json` → páginas 1..N, merge por versión, `unread` canónico,
   `X-Poll-Interval`/`ETag` cacheados en `$XDG_CACHE_HOME/b3l0w-kanban/`.
4. `kanban mark-read <id...>` → PATCH con pre-check de versión y salida `{ok, id, updatedAt}` (deja el Luau como pura UI).

Con eso el plugin quedaría: `runAsync(btn, cb)` → `state.set` → render, sin `coroutine` ni `json.decode` de payloads grandes.

---

## 8. Bugs, límites y código muerto

### Bugs / comportamiento incorrecto

1. **Heatmap eternamente "preparando" si falla `/graphql`.** `gridReady` sólo es `true` si `contributions.rows` es tabla
   (`panel.luau:251`); sin datos, `heatmap()` devuelve el placeholder (`727-731`) y **nunca** muestra el error.
   Un 401/403 o una cuenta sin contribuciones deja la sección en "Preparing contribution calendar…" para siempre.
2. **Paridad i18n rota.** `zh-Hans` y `zh-Hant` tienen 328 hojas vs 332 de `en`: faltan
   `settings.notifications.history_days.description`, `status.notification_refresh_failed`,
   `status.notification_refresh_timeout`, `status.notification_write_timeout` → en chino la UI muestra la clave cruda
   (`noctalia.tr` devuelve la clave). Verificado con el auditor (check 2).
3. **Código muerto**: `GitHub.apiWithFields` (`lib/github.luau:14-21`) y `GitHub.repoEvents` (`lib/github.luau:55-57`)
   no tienen ningún llamador (grep en los 7 `.luau`). `repoEvents` además quedó sin proyección `--jq`.
4. **Clamp de ancho hardcodeado**: `maxCell = floor((760 - 52·GAP)/53)` (`panel.luau:124`) asume 760 px aunque el panel
   mide 860 (`plugin.toml:721`). Desperdicia ~100 px y se rompe en cuanto cambie el ancho (§9.2).
5. **`--hostname` inconsistente** entre services (`lib/github.luau:10-12` vs `lib/notifications.luau:303`): con GHE o
   `GH_HOST` seteados, el dashboard y las notificaciones pueden hablar de cuentas distintas.
6. **Actions se cae entera si falla un repo**: `requestSeries` publica sólo si `failed == false`
   (`service.luau:434-457`), así que un 403 en 1 de los 5 repos borra la lista completa de runs.
7. **"Marcar visibles como leídas" no es lo visible**: usa `items` completo del filtro (todas las páginas)
   (`panel.luau:840-848`) mientras el botón dice "visible" → puede encolar cientos de PATCH.
8. **Cambiar cualquier setting resetea la pestaña** a `default_dashboard` (`panel.luau:1179`), perdiendo el contexto del usuario.
9. **Fuente no escala en el título de sección**: `fontSize = 15` fijo (`panel.luau:782`) y `11` (`729`) ignoran
   `appearance_font_scale` (que sí pasa por `font()` en el resto).
10. **`setGlyph("")` para "sólo contador"** (`widget.luau:7`) no está documentado: la doc sólo define `setText("")`
    como forma de ocultar texto; no hay `clearGlyph()`. En la práctica el modo `count` probablemente conserva el icono
    (no verificado en runtime; requiere mirar la barra).
11. **Nonce sin contador** (`panel.luau:376`, `service.luau:609`): dos acciones en el mismo ms comparten nonce.
12. **`errors` por ítem no se muestran**: las claves son `actions.3`, `following_events.2` (`service.luau:449`); la UI
    sólo muestra el banner genérico `status.request_error` (`panel.luau:1064-1069`).
13. **Tick a 16 ms** mientras hay trabajo pendiente (`lib/notifications.luau:8, 74`): ~60 callbacks/s de `update()`,
    cada uno con su presupuesto, en paralelo al render del panel. No es un bug hoy, es el punto donde se cae primero si
    crece el volumen.
14. **Descripciones duplicadas** en los 5 settings de color custom (`plugin.toml:582-606`).

### Límites de plataforma (no son bugs)

* Panel de tamaño fijo: no hay API de resize en runtime (reconocido por el propio README `:133`).
* Sin `ui.grid`, sin scroll horizontal, sin drag, sin overlays con `onPointerMove` (se comen el click).
* Todo lo que se escribe en GitHub es un PATCH de notificación; el resto es read-only por diseño.

### Código muerto / ruido

* `GitHub.apiWithFields`, `GitHub.repoEvents` (§8.3).
* `following`, `following_users`, `following_repos` se publican al state y nadie los consume (§6.1).
* `hot` paths con `local function publish(key, value)` sombreando el `publish` de módulo dentro de `refresh()`
  (`service.luau:89-92` vs `314-315`): funciona (`publishNow` se captura antes) pero es una trampa de lectura.

---

## 9. Qué falta para (a) ocultar el label del icono y (b) panel flotante grande

### 9.1 Ocultar el label del icono

**Ya está soportado, sin tocar código**: `bar_display_mode = "icon"` (`plugin.toml:39-48`) hace
`setGlyph("brand-github")` + `setText("")` (`widget.luau:7-9`), y la doc del host dice literalmente que
`barWidget.setText("")` **oculta el label**. Hoy se cambia en Settings → Plugins.

Lo que **falta** si el objetivo es más fino:

1. **Alcance**: es un `[[setting]]` de nivel plugin, compartido por todas las instancias del widget. Para
   "esta instancia sin label, la otra con contador" hace falta mover la clave a `[[widget.setting]]`
   (hoy `plugin.toml:714-716` no declara ninguno) y leerla igual con `getConfig`.
2. **Modo "sólo contador" (sin icono)**: no hay forma documentada de limpiar el glyph. `setGlyph("")`
   (`widget.luau:7`) no está en la tabla de la doc (`setGlyph(name)` muestra un glyph; `setImage` oculta el glyph).
   Opciones honestas: (a) verificar en runtime si `""` limpia, (b) cambiar a `barWidget.render(ui.row{...})` y dibujar
   sólo el label con `ui.label`, que es la vía soportada (`entries` doc: `render` reemplaza la fila glyph/texto).
3. **Tooltip**: en modo `icon` el tooltip sigue mostrando "N unread notifications" (`widget.luau:20`). Si "ocultar label"
   incluye el tooltip, hay que condicionar `setTooltip` al modo o llamar `clearTooltip()`.

### 9.2 Panel flotante grande

**Lo que ya se puede hacer sin tocar el plugin**: el `placement` del manifest es sólo un *default*; el host inyecta
`kanban_placement`, `kanban_position`, `kanban_open_near_click` como settings del entry, así que el usuario puede pasar
`attached → floating` desde Settings → Plugins. El **tamaño no**: sigue 860×620 (`plugin.toml:721-722`).

Para un panel flotante grande, en orden:

1. `plugin.toml:718-726`: `placement = "floating"` (+ `position = "center"`), y tamaño:
   * números explícitos (`width = 1400`, `height = 900`; el host los clampea al output), o
   * `width = "fill"` / `height = "fill"` — **`"fill"` exige `placement = "floating"`**, si no el manifest rechaza el plugin.
2. `height = "content"` + `max_height` (api ≥ 42, ya se declara 43) **no sirve tal cual**: los tres `ui.scroll` del panel
   usan `flexGrow = 1` sin alto (`panel.luau:506, 555, 661`) y dentro de un padre sin alto definido miden 0
   (pitfall conocido del host). Habría que darles `height` numérico derivado del alto de ventana.
3. Constantes que hay que deshardcodear para que el layout aproveche el ancho:
   * `panel.luau:124` (760 px del heatmap),
   * `panel.luau:709` (columna de texto del perfil, 205 px),
   * `panel.luau:301, 760` (gutter de 28 px de los días de semana),
   * `panel.luau:800` (`NOTIFICATION_PAGE_SIZE = 50`) y el cálculo de filas de `followingGroupCard` (`601-607`).
4. No hay API de resize en runtime: cualquier "grande/mediano" tiene que ser manifest + reinicio del plugin, o
   dos entries de panel distintos con tamaños distintos.

---

## 10. Animaciones

**Hay `onFrameTick`, pero no hay animación.**

* `panel.luau:1165-1167`: `function onFrameTick(_deltaMs) if panelOpen then prepareGrid() end` — el tick **sólo** sirve
  para construir el heatmap por partes (una fila/columna por frame, `308-357`). El delta se ignora (`_deltaMs`).
* Se enciende con `panel.setNeedsFrameTick(true)` al abrir si falta el calendario (`1151-1154`), al cambiar
  contribuciones (`1124-1127`) y al cambiar config (`1185-1188`); se apaga al terminar el grid (`354-355`) y en `onClose` (`1162`).
  Ojo: apagarlo es una puerta de una sola dirección en este host — acá no molesta porque el grid termina una vez.
* `panel.setWantsSecondTicks(true)` se usa para el throttle de renders de datos (400 ms, `1092-1107`, `1147`).
* **Cero** `ease`, `tween`, `transition`, `animate`, `duration`: no existen en la API y el plugin no los emula.
* El setting `appearance_animations` **no anima nada**: sólo decide si el hover repinta
  (`panel.luau:453, 525, 574`). Nombre engañoso: es "highlight on hover".

Si se quisiera un fade/slide real: `onFrameTick` + interpolar un `opacity`/`padding`, con `render()` sólo cuando cambie
un entero de layout (patrón documentado), y **nunca** apagar/encender el tick por animación.

---

## Anexo — verificación ejecutada

```
luau-compile --binary  → 7/7 OK (panel, service, widget, notifications, lib/data, lib/github, lib/notifications)
audit_plugin.py        → check 1 OK; check 2 FAIL (4 claves zh); check 3 falsos positivos por plurales _one/_other;
                         check 4 sin salida (no detecta `function GitHub.x`); checks 7/8/9 falsos positivos
                         (declaraciones multi-variable y locales de closure)
grep de llamadores     → apiWithFields / repoEvents sin uso
en.json vs zh-*.json   → 332 vs 328 hojas
noctalia msg plugins list → github-kanban 0.2.7 [community] enabled
~/.cache/noctalia/noctalia.log → plugin cargado (4 entries), panel abierto 2 veces, sin warnings de ui-tree
                                 atribuibles a este plugin ni timeouts de CPU
```

No se ejecutó ninguna escritura contra GitHub ni se modificó el plugin.
