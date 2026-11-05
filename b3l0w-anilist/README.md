# b3l0w-anilist

Plugin propio de Noctalia para AniList: biblioteca de anime/manga, progreso y
descubrimiento del catálogo. Reemplaza a `cleboost/anilist`.

## Por qué existe

El plugin original tenía un bug estructural: `coverPath` era un campo de cada
entrada de la lista, y el refresco (que reconstruye las filas desde cero)
publicaba el modelo sin rutas. Resultado: **todas las carátulas se convertían en
placeholders durante varios segundos** cada vez que se abría el panel.

Acá las carátulas viven en su **propia clave de estado** (`b3l0w_anilist_covers`)
que sólo escribe el sincronizador de imágenes. Un refresco de lista no puede
tocarlas.

## Arquitectura

```
panel.luau    biblioteca, descubrimiento, preview. No hace red ni proceso.
service.luau  dueño del CLI y del estado. Refresco por TTL, no al abrir.
widget.luau   icono + contador de "en curso".
lib/          capa compartida (anim, cli, prefs, store) copiada de
              b3l0w/internal/plugins/luau-shared
```

Backend en Go: `b3l0w anilist sync|discover|library|covers|mutate|status`
(`b3l0w/internal/plugins/anilist`). Todo lo caro vive ahí: paginación GraphQL,
merge por `mediaId`, backoff en 429/5xx, descarga de carátulas con 6 workers y
GC de huérfanas.

## Claves de estado

| Clave | Contenido |
|---|---|
| `b3l0w_anilist_library` | viewer + anime[] + manga[] + fetchedAt |
| `b3l0w_anilist_covers` | `{ [mediaId] = "/ruta.jpg" }` — **separada a propósito** |
| `b3l0w_anilist_discover` | kind, page, hasNext, total, items[] |
| `b3l0w_anilist_status` | busy, phase, error, conteos |
| `b3l0w_anilist_request` | panel/widget → service |
| `b3l0w_anilist_screen` | service → panel (abrir vista por IPC) |

## Ajustes

`access_token`, `refresh_minutes`, `show_label`, `panel_mode` (compact|float),
`glyph`, `animations`, `density` (compact|cozy|comfortable). Los siete se leen;
`panel_mode` decide si el widget abre el panel attached (740×720) o el flotante
(1180×820), porque el tamaño del panel no se puede cambiar en runtime.

## Verificación

```bash
noctalia msg plugin b3l0w/anilist:start all sync '{}'
noctalia msg plugin b3l0w/anilist:start all discover '{"kind":"trending","page":1}'
noctalia msg plugin b3l0w/anilist:start all view '{"view":"discover","page":3}'
grep 'b3l0w-anilist]' ~/.cache/noctalia/noctalia.log | tail -1
```

La traza del panel informa `entradas/carátulas/pestaña/vista/página/filtradas/catálogo/título`.

## Requisitos

- `b3l0w` con la extensión `b3l0w-anilist`
- Red (API de AniList)

## Instalación

```bash
git clone https://github.com/Below-Z3R0/b3l0w-anilist ~/.local/share/noctalia/plugins/b3l0w-anilist
```

Después habilitá el plugin desde **Ajustes → Plugins** de Noctalia, o
reiniciá Noctalia para que lo descubra:

```bash
kill $(pgrep -x noctalia); nohup noctalia >/dev/null 2>&1 &
```

## Licencia

MIT — ver [LICENSE](LICENSE).
