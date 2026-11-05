# b3l0w-audit

Plugin de Noctalia que reemplaza al `arch-audit` de la comunidad y le suma tres
fuentes de estado del sistema: actualizaciones de **Noctalia**, de **Umbriel** y
si el **CLI `b3l0w`** quedó viejo respecto de sus fuentes Go.

```
panel.luau    triage de vulnerabilidades + estado de actualizaciones
service.luau  dueño de los procesos y del estado; cola de trabajos
widget.luau   conteo de avisos con color por peor severidad
lib/          capa compartida (anim, cli, prefs, store) + audit (parseo puro)
```

## Paridad con `cero800/arch-audit`

| `arch-audit` | b3l0w-audit |
|---|---|
| `arch-audit --json` + `pacman -Q` por paquete | ✅ igual |
| Lista de avisos con severidad, estado, tipo, CVEs | ✅ igual, con `fixed` y link al tracker |
| Filtro por severidad y "sólo con arreglo" | ✅ igual |
| Conteo y color en el widget por peor severidad | ✅ igual |
| `hide_on_clean`, `show_count`, glyph configurable | ✅ `hide_when_clean`, `show_label`, `glyph` |
| Notificación de avisos nuevos con severidad mínima | ✅ igual (`notify_new`, `notify_min_severity`) |
| `ignore_packages` (un aviso desaparece sólo si todos sus paquetes están ignorados) | ✅ igual |
| Intervalo de chequeo (`check_hours`) | ✅ `check_hours` + `updates_minutes` |
| Banners de binario faltante y error de chequeo | ✅ igual |
| Copiar `sudo pacman -Syu` | ✅ igual |

## Lo que agrega

1. **Noctalia** — filas de `pacman -Qu` cuyo nombre contiene `noctalia`, más la
   versión del paquete (`pacman -Q noctalia-git`) y la que corre el binario
   (`noctalia --version`).
2. **Umbriel** — lo mismo para `umbriel-git` y `xdg-desktop-portal-umbriel-git`.
3. **CLI b3l0w** — compara el mtime del binario con el del `.go` más nuevo bajo
   el repo. Si la fuente es más nueva, el estado es **"Necesita recompilar"**.
4. **Sistema** — el resto de los pendientes, con actualización confirmada por
   ítem. Sin esta sección el panel diría "32 pendientes" sin mostrar ninguno.

### De dónde sale la lista de pendientes

`pacman -Qu` compara contra la base local: si nunca se sincronizó, subreporta
(en esta máquina: 1 paquete contra 32 reales). Por eso el service usa
`checkupdates` cuando existe —el mismo `-Qu` sobre una copia de la base
sincronizada en un directorio temporal, sin root— y cae a `pacman -Qu` cuando
no está. La fuente efectiva viaja en `updates.source` y se muestra en el pie.


## "Actualizar todo" (subconjunto seguro)

Nunca corre `pacman -Syu` por su cuenta. Hace dos cosas y lo dice en un toast:

1. `pacman -Qu` → lista de pendientes. Cada fila tiene su propio botón
   **Actualizar** con confirmación (dos clicks) y copia del comando.
2. `go build ./cmd/b3l0w` para el CLI, compilando a `<bin>.new`, verificando que
   ejecute y recién ahí reemplazando el binario: un build roto no deja al usuario
   sin CLI.

La actualización por paquete usa `pkexec pacman -S --noconfirm --needed <pkg>`.
Arch no soporta actualizaciones parciales, así que el tooltip lo advierte y el
botón de copiar siempre ofrece el upgrade completo.

## Ajustes (`plugin.toml`)

| clave | tipo | default | qué hace |
|---|---|---|---|
| `check_hours` | int 1–168 | 6 | horas entre corridas de `arch-audit` |
| `updates_minutes` | int 2–240 | 15 | minutos entre `pacman -Qu` y la comprobación del CLI |
| `notify_new` | bool | true | toast de avisos nuevos |
| `notify_min_severity` | select | high | severidad mínima para notificar |
| `ignore_packages` | string_list | `[]` | paquetes que no se muestran |
| `show_label` | bool | true | número en la barra |
| `hide_when_clean` | bool | false | ocultar el widget sin novedades |
| `glyph` | glyph | `shield-exclamation` | icono de la barra |
| `panel_mode` | select | compact | `compact` (attached) / `float` (floating) |
| `animations` | bool | true | filas escalonadas al cambiar pestaña |
| `density` | select | cozy | alto de fila: compact / cozy / comfortable |
| `cli_bin` | string | `~/.local/bin/b3l0w` | binario a comparar y recompilar |
| `cli_repo` | string | `~/Documents/Github/b3l0w` | repo Go de donde sale el build |

## Acciones (IPC / panel → service)

| acción | efecto |
|---|---|
| `refresh` | chequeo de vulnerabilidades + actualizaciones |
| `check` | sólo `arch-audit` |
| `updates` | sólo `pacman -Qu` + versiones + staleness del CLI |
| `update_all` | lista pendientes + recompila el CLI si hace falta (toast con el resumen) |
| `update_cli` | sólo `go build` |
| `update_pkg` | `pkexec pacman -S --needed <name>` (validado por regex) |
| `screen` | fuerza la pestaña del panel (`vulns` / `updates`) |
| `open_settings` | abre los ajustes del plugin |

```bash
noctalia msg plugin b3l0w/audit:service refresh '{}'
noctalia msg plugin b3l0w/audit:service update_all '{}'
noctalia msg panel-toggle b3l0w/audit:panel
```

## Claves de estado

- `b3l0w_audit_state` — `phase`, `total`, `packageCount`, `counts`, `items`,
  `severity`, `checkedAtMs`, `newCount`, `ignoredCount`, `binaryMissing`, `err`.
- `b3l0w_audit_updates` — `total`, `rows`, `source`, `noctalia{rows,pending,installed,version,build}`,
  `umbriel{rows,pending,installed,portal}`, `system{rows,pending}`,
  `cli{bin,binMtime,newestMtime,newestPath,stale}`.
- `b3l0w_audit_status` — `busy`, `what`, `phase`, `err`, `updates`, `cliStale`.
- `b3l0w_audit_request` — requests del panel/widget (nonce con contador).
- `b3l0w_audit_screen` — orden de pestaña para abrir el panel desde IPC.

## Notas de implementación

- Sólo `ui.column`, `ui.row` y `ui.scroll` aceptan hijos; las píldoras con texto
  son `ui.row` (un `ui.box` con hijos los dropea en silencio).
- El panel usa alto numérico (640 / 860) y un `ui.scroll` con alto exacto por
  página: dentro de `height = "content"` un scroll con `flexGrow` mide 0.
- Todos los comandos son `runAsync`: el presupuesto por callback es 25 ms.
- El service encola trabajos mientras está ocupado; nunca los descarta.

## Requisitos

- `b3l0w` (estado de actualizaciones)
- `pacman`
- `arch-audit` (opcional, vulnerabilidades)
- `gh` (opcional, para Noctalia y Umbriel)

## Instalación

```bash
git clone https://github.com/Below-Z3R0/b3l0w-audit ~/.local/share/noctalia/plugins/b3l0w-audit
```

Después habilitá el plugin desde **Ajustes → Plugins** de Noctalia, o
reiniciá Noctalia para que lo descubra:

```bash
kill $(pgrep -x noctalia); nohup noctalia >/dev/null 2>&1 &
```

## Licencia

MIT — ver [LICENSE](LICENSE).
