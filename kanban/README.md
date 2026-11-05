# b3l0w Kanban

Tablero kanban de GitHub para [Noctalia](https://docs.noctalia.dev) sobre la CLI
`gh`. Reemplazo desde cero del plugin de la comunidad `shangshui0302/github-kanban`:
mismas 74 settings, mismas pestañas de dashboard, más el tablero que le da sentido
al nombre.

- **Columnas por estado** — proyecto v2 (campo `Status`) o estado del issue (open/closed).
- **Tarjetas** con labels coloreados, asignados, antigüedad y **aviso de estancamiento**.
- **Mover sin drag** — un `ui.select` por tarjeta con las columnas del tablero.
- **Crear issue** desde el panel (`gh issue create`).
- **Buscador y filtros** — texto, asignado (todos/míos/sin asignar), label, sólo estancadas.
- **Contadores por columna** y total visible/total real.
- **Selector de repositorio** y de proyecto clickeable, en una pantalla propia.
- **Dashboard heredado** — Overview con mapa de calor de contribuciones, Notificaciones,
  Actividad (PRs/issues/Actions), Following (eventos + releases) y Repositorios.
- **Panel compacto o flotante**, animaciones, densidad, icono y texto de barra configurables.
- **Botón de ajustes** en la cabecera (`noctalia.openSettings()`).

## Arquitectura

```
service.luau      único dueño de los procesos: corre gh con runAsync y publica estado
panel.luau        dibuja desde noctalia.state; publica pedidos en <plugin>_request
widget.luau       barra: contador de tarjetas / sin leer, abre el panel según panel_mode
lib/cli.luau      runAsync + JSON con exit code; jsonBin/textBin para binarios del PATH
lib/github.luau   argv de gh (proyectos, issues, notificaciones, búsquedas, graphql)
lib/store.luau    persistencia en pluginDataDir (view.json, board.json)
lib/prefs.luau    show_label, panel_mode, animations, density
lib/anim.luau     easing y stagger para onFrameTick
```

Nada de `gh` corre en el panel: el presupuesto del host es **25 ms de CPU por
callback** y una llamada de red lo revienta. El service publica primero y trabaja
después; el panel repinta cuando llega el estado.

### Claves de estado

| Clave | Contenido |
|---|---|
| `b3l0w_kanban_status` | `busy`, `phase`, `error`, `auth`, `at`, `source`, `repo`, `project`, `columns`, `cards`, `unread`, `login` |
| `b3l0w_kanban_board` | columnas con `id`, `name`, `state`, `cards[]`; más `total`, `source`, `projectId`, `fieldId`, `options`, `note` |
| `b3l0w_kanban_meta` | `viewer`, `repos[]`, `projects[]`, `projectsError` |
| `b3l0w_kanban_feed` | `notifications[]`, `prs[]`, `issues[]`, `runs[]`, `events[]`, `releases[]`, `calendar`, `unread` |
| `b3l0w_kanban_request` | pedidos del panel al service (`action` + `nonce`) |
| `b3l0w_kanban_screen` | órdenes del service al panel (`tab`, `url`) |

### Acciones (`b3l0w_kanban_request`)

`refresh`, `discover`, `set_repo`, `set_source`, `set_project`, `move`, `create`,
`open`, `mark_read`, `mark_all_read`, `view`.

```bash
noctalia msg plugin b3l0w/kanban:start all refresh '{}'
noctalia msg plugin b3l0w/kanban:start all set_repo '{"repo":"Below-Z3R0/community-templates"}'
noctalia msg plugin b3l0w/kanban:start all set_source '{"source":"issues"}'
noctalia msg plugin b3l0w/kanban:start all move '{"id":"12","target":"Closed"}'
noctalia msg plugin b3l0w/kanban:start all view '{"tab":"overview"}'
noctalia msg panel-open b3l0w/kanban:panel
```

## Ajustes (92)

Los 74 del plugin original conservan nombre y default, así que una configuración
migrada sigue valiendo. Los 18 nuevos (`show_board`, `board_*`,
`create_default_labels`, `open_links`, `show_label`, `panel_mode`, `glyph`,
`animations`, `density`) son el tablero y el estándar b3l0w.

| key | tipo | default | etiqueta |
|---|---|---|---|
| `refresh_interval_minutes` | select | `15` | Refresh interval |
| `default_dashboard` | select | `board` | General · Default dashboard |
| `bar_display_mode` | select | `both` | General · Bar display |
| `show_overview` | bool | `true` | Overview · Show dashboard |
| `show_notifications` | bool | `true` | Notifications · Show dashboard |
| `notification_sync_mode` | select | `legacy` | Notifications · Sync mode |
| `notification_refresh_interval_seconds` | select | `120` | Notifications · Refresh interval |
| `notification_refresh_on_open` | bool | `true` | Notifications · Refresh when panel opens |
| `notification_mark_read_on_open` | bool | `false` | Notifications · Mark read when opening a notification |
| `notification_history_days` | int | `30` | Notifications · History range (days) |
| `notification_default_filter` | select | `unread` | Notifications · Default status filter |
| `show_activity` | bool | `true` | Activity · Show dashboard |
| `activity_history_days` | int | `30` | Activity · History range (days) |
| `pr_default_filter` | select | `all` | Activity · Default pull request filter |
| `issue_default_filter` | select | `all` | Activity · Default issue filter |
| `show_following` | bool | `true` | Following · Show dashboard |
| `following_card_max_height` | int | `260` | Following · Card maximum height |
| `following_user_limit` | int | `4` | Following · People to fetch |
| `following_events_per_user` | int | `30` | Following · Events per person |
| `starred_repository_limit` | int | `100` | Following · Starred repositories to scan |
| `following_include_prereleases` | bool | `true` | Following · Include prereleases |
| `following_hide_bots` | bool | `false` | Following · Hide bots |
| `following_show_stars` | bool | `true` | Following · Show stars |
| `following_show_pushes` | bool | `true` | Following · Show pushes |
| `following_show_issues` | bool | `true` | Following · Show issues and comments |
| `following_show_pull_requests` | bool | `true` | Following · Show pull requests and reviews |
| `following_show_releases` | bool | `true` | Following · Show releases |
| `following_show_forks` | bool | `true` | Following · Show forks |
| `following_show_other` | bool | `true` | Following · Show other events |
| `following_ignored_users` | string_list | `[]` | Following · Ignored users |
| `following_ignored_repositories` | string_list | `[]` | Following · Ignored repositories |
| `following_history_days` | int | `30` | Following · History range (days) |
| `show_repositories` | bool | `true` | Repositories · Show dashboard |
| `appearance_density` | select | `standard` | Appearance · Content density |
| `appearance_font_scale` | int | `100` | Appearance · Font scale |
| `appearance_card_radius` | int | `9` | Appearance · Card corner radius |
| `appearance_card_spacing` | int | `8` | Appearance · Card spacing |
| `appearance_card_border` | select | `subtle` | Appearance · Card border |
| `appearance_card_background` | select | `tinted` | Appearance · Card background |
| `appearance_hover_effect` | select | `background` | Appearance · Hover effect |
| `appearance_secondary_text` | select | `truncate` | Appearance · Secondary text |
| `appearance_time_format` | select | `relative` | Appearance · Time format |
| `appearance_avatar_size` | select | `medium` | Appearance · Avatar size |
| `appearance_avatar_shape` | select | `circle` | Appearance · Avatar shape |
| `appearance_icon_style` | select | `theme` | Appearance · Icon style |
| `appearance_show_empty_illustration` | bool | `true` | Appearance · Empty-state illustration |
| `appearance_animations` | bool | `true` | Appearance · Animations |
| `heatmap_cell_size` | int | `13` | Appearance · Heatmap · Cell size |
| `heatmap_cell_gap` | int | `1` | Appearance · Heatmap · Cell gap |
| `heatmap_cell_radius` | int | `2` | Appearance · Heatmap · Cell corner radius |
| `heatmap_levels` | select | `5` | Appearance · Heatmap · Activity levels |
| `heatmap_show_months` | bool | `true` | Appearance · Heatmap · Show month labels |
| `heatmap_show_weekdays` | bool | `true` | Appearance · Heatmap · Show weekday labels |
| `heatmap_show_total` | bool | `true` | Appearance · Heatmap · Show contribution total |
| `heatmap_show_legend` | bool | `true` | Appearance · Heatmap · Show intensity legend |
| `heatmap_empty_style` | select | `background` | Appearance · Heatmap · Empty cell style |
| `heatmap_color_mode` | select | `noctalia` | Appearance · Heatmap · Color mode |
| `heatmap_custom_level_0` | string | `` | Appearance · Heatmap · Custom level 0 |
| `heatmap_custom_level_1` | string | `` | Appearance · Heatmap · Custom level 1 |
| `heatmap_custom_level_2` | string | `` | Appearance · Heatmap · Custom level 2 |
| `heatmap_custom_level_3` | string | `` | Appearance · Heatmap · Custom level 3 |
| `heatmap_custom_level_4` | string | `` | Appearance · Heatmap · Custom level 4 |
| `notification_unread_dot` | bool | `true` | Appearance · Notifications · Unread status dot |
| `notification_unread_border` | bool | `true` | Appearance · Notifications · Unread card border |
| `notification_read_opacity` | int | `100` | Appearance · Notifications · Read card opacity |
| `activity_show_status_badges` | bool | `true` | Appearance · Activity · Status badges |
| `activity_show_type_icons` | bool | `true` | Appearance · Activity · Type icons |
| `activity_repository_emphasis` | bool | `true` | Appearance · Activity · Emphasize repository names |
| `following_event_spacing` | int | `5` | Appearance · Following · Event spacing |
| `following_content_lines` | int | `2` | Appearance · Following · Content lines |
| `repositories_layout` | select | `list` | Appearance · Repositories · Repository layout |
| `repositories_show_language` | bool | `true` | Appearance · Repositories · Show repository language |
| `repositories_show_stats` | bool | `true` | Appearance · Repositories · Show repository statistics |
| `overview_stats_layout` | select | `columns4` | Appearance · Overview · Statistics layout |
| `show_board` | bool | `true` | Board · Show tab |
| `board_source` | select | `issues` | Board · Column source |
| `board_repo` | string | `` | Board · Repository |
| `board_project_owner` | string | `` | Board · Project owner |
| `board_project_number` | int | `0` | Board · Project number |
| `board_status_field` | string | `Status` | Board · Status field |
| `board_cards_per_column` | int | `25` | Board · Cards per column |
| `board_show_labels` | bool | `true` | Board · Card labels |
| `board_show_assignees` | bool | `true` | Board · Card assignees |
| `board_show_counts` | bool | `true` | Board · Column counts |
| `board_stale_days` | int | `7` | Board · Stale after (days) |
| `create_default_labels` | string | `` | Board · Default labels |
| `open_links` | bool | `true` | General · Open in browser |
| `show_label` | bool | `false` | General · Text in the bar |
| `panel_mode` | select | `compact` | General · Panel style |
| `glyph` | glyph | `brand-github` | General · Bar icon |
| `animations` | bool | `true` | General · Animations |
| `density` | select | `cozy` | General · Density |

`appearance_density` / `appearance_animations` gobiernan el **dashboard**;
`density` / `animations` gobiernan el **tablero y sus listas**. Se separaron a
propósito: el tablero necesita tarjetas más altas que una fila de feed.

## Instalación

```bash
ln -s ~/Documents/Github/b3l0w-kanban ~/.local/share/noctalia/plugins/b3l0w-kanban
noctalia msg plugins enable b3l0w/kanban
noctalia msg plugins list | grep kanban
```

## Verificación

```bash
luau-compile --binary service.luau
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .
noctalia msg plugin b3l0w/kanban:start all refresh '{}'
grep -E 'b3l0w-kanban|\[ERR\]' ~/.cache/noctalia/noctalia.log | tail
```

El panel loguea `[b3l0w-kanban] <cols> cols/<n> cards/<tab>/<screen>` cada vez que
cambia la firma del estado: es la prueba de que el árbol `ui.*` se armó con datos
y no quedó en blanco.

## Límites conocidos

- **Proyectos v2 requieren scope**: `gh auth refresh -s read:project` (más `project`
  para mover tarjetas). Sin eso el selector muestra el error de `gh` y el tablero
  por proyectos queda vacío; el modo `issues` funciona igual.
- **Modo `issues`**: las columnas son `open`/`closed` — es lo único que la API de
  issues expone como estado. Mover una tarjeta cierra o reabre el issue.
- **Sin avatares descargados**: el plugin no baja imágenes, usa glifos. Mantiene al
  service fuera del disco y de la red más allá de `gh`.
- **Sin drag & drop**: la API sí tiene `drag_source`/`drop_zone`, pero el pedido fue
  mover con botones; el select por tarjeta funciona con teclado y mouse.
- **Atajos**: `g` y las flechas cambian de pestaña, `Prior`/`Next` paginan.
  `capture_keys` no incluye `Return` (se comería el Enter del buscador) ni `c`
  (el host lo entregaba al abrir el panel y abría el formulario de creación).
