# b3l0w Net

Plugin de Noctalia para mirar Tailscale y Sunshine en un solo panel. **No para,
no deshabilita y no reinicia ningún servicio.**

- **Pestaña Tailscale** — backend, self (hostname, MagicDNS, IPv4/IPv6), pares con
  IP, estado, sistema operativo, camino (directo o relay DERP) y último visto.
  `netcheck` bajo demanda y `ping -c 3` por par.
- **Pestaña Sunshine** — unit `app-dev.lizardbyte.app.Sunshine.service`, puertos
  TCP escuchando, chequeo HTTP del panel web, encoder en uso leído del log,
  última sesión y avisos de configuración.
- **Widget de barra** — icono según estado (Tailscale online/offline, Sunshine
  active/failed, relay en ámbar) con el contador de pares online.

## Regla dura: sólo lectura

El plugin no tiene botones para parar, deshabilitar ni reiniciar servicios.

| Lo que pediría parar algo | Cómo se resuelve acá |
|---|---|
| Reiniciar Sunshine para tomar un cambio de config | No existe. Se muestra `capture` / `output_name` con el aviso, y el usuario edita `sunshine.conf` a mano. |
| `systemctl restart` para salir de un crash-loop | `reset-failed` + `start`, y sólo con el unit en `failed` (ahí no hay sesión que cortar). Pide confirmación en dos pasos y el texto dice el comando exacto. |
| Tocar el daemon de Tailscale | No existe ningún camino que escriba sobre `tailscaled`. `netcheck` y `ping` son consultas. |

## Instalación

```bash
ln -s ~/Documents/Github/b3l0w-net ~/.local/share/noctalia/plugins/b3l0w-net
noctalia msg plugins list            # b3l0w/net [local] 1.0.0 disabled
noctalia msg plugins enable b3l0w/net
```

Agregá el widget `b3l0w/net` a la barra desde Ajustes → Barra.

## Ajustes (`plugin.toml`)

| Clave | Tipo | Default | Para qué |
|---|---|---|---|
| `refresh_seconds` | int 5–300 | 20 | Cada cuánto se leen `tailscale status`, el unit y el log. |
| `show_label` | bool | true | Muestra el contador de pares online al lado del icono. |
| `hide_when_offline` | bool | false | Oculta el widget mientras el backend no está en `Running`. |
| `glyph` | glyph | `wifi` | Icono cuando todo está en orden. |
| `panel_mode` | select | `compact` | `compact` abre `b3l0w/net:panel` (560×720 pegado); `float` abre `b3l0w/net:float` (1180×880 flotante). |
| `animations` | bool | true | Entrada escalonada de las tarjetas. |
| `density` | select | `cozy` | Alto de las filas de par y cuántas entran por página. |

## Acciones (panel → service)

El panel no lanza procesos: publica `b3l0w_net_request` con `{ action, nonce }` y
el service ejecuta. Todas las acciones son de lectura salvo `reset_failed`.

| Acción | Qué corre | Efecto sobre servicios |
|---|---|---|
| `refresh` | `tailscale status --json`, `tailscale ip -4`, probe de Sunshine | ninguno |
| `netcheck` | `timeout 25 tailscale netcheck` | ninguno (sólo mide) |
| `ping` | `timeout 10 tailscale ping -c 3 <ip>` | ninguno |
| `open_web` | `xdg-open https://<ip-local>:47990` | ninguno |
| `reset_failed` | `systemctl --user reset-failed … && systemctl --user start …` | sólo si el unit está en `failed`; nunca stop/disable/restart |
| `screen` | publica la pestaña pedida (IPC, para pruebas) | ninguno |
| `open_settings` | `noctalia.openSettings()` | ninguno |

Desde una terminal:

```bash
noctalia msg plugin b3l0w/net:service all screen '{"tab":"sunshine"}'
noctalia msg plugin b3l0w/net:service all netcheck '{}'
noctalia msg plugin b3l0w/net:service all ping '{"ip":"100.101.43.56"}'
noctalia msg panel-toggle b3l0w/net:panel
```

## Claves de estado

| Clave | Contenido |
|---|---|
| `b3l0w_net_state` | `{ at, phase, local_ip, ts, sun }` (lo que dibuja el panel) |
| `b3l0w_net_status` | `{ busy, what, tsOk, backend, peersOnline, peersTotal, relayed, sunState, sunOk }` (barra) |
| `b3l0w_net_netcheck` | reporte de `netcheck`: `udp`, `ipv4`, `ipv6`, `mapping`, `portmap`, `nearest`, `derps` |
| `b3l0w_net_ping` | último ping: `{ ip, state, direct, relay, via, latency, detail }` |
| `b3l0w_net_request` | pedido del panel al service |
| `b3l0w_net_screen` | orden de una sola vez para abrir una pestaña |

El último snapshot se persiste en el directorio de datos del plugin
(`snapshot.json`) para que el panel abra con datos en vez de esqueletos.

## Qué lee de Sunshine

| Dato | Fuente |
|---|---|
| Estado del unit | `systemctl --user is-active` + `show -p SubState -p NRestarts` |
| Puertos | `ss -tln` filtrado a `47984`, `47989`, `47990`, `48010` |
| Panel web | `curl -sk -o /dev/null -w %{http_code} https://127.0.0.1:47990` (401 y 307 son sanos) |
| Encoder | `Found H.264 encoder:` / `Found HEVC encoder:` del log; avisa si aparece `nvenc` o `vulkan` |
| Última sesión | último `CLIENT CONNECTED` y si después hubo `Undo Cmd` o `CLIENT DISCONNECTED` |
| Config | `capture` y `output_name` de `sunshine.conf`, contra `umbriel outputs` |

`umbriel outputs` es la fuente de salidas; si no devuelve nada, el chequeo de
`output_name` se omite en vez de inventar un aviso.

## Relay DERP

Un par se marca en ámbar cuando está **online** sin `CurAddr` y con `Relay`
poblado: eso es lo que significa "va por relay". Con el par dormido no se marca
(no hay conexión que explicar), pero la fila igual muestra `DERP <región>`, así
la causa de la latencia queda a la vista cuando vuelve.

## Verificación

```bash
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .
grep -E "\[b3l0w-net\]" ~/.cache/noctalia/noctalia.log | tail
```

El service loguea una línea por poll
(`poll ts=Running peers=1/1 relayed=0 sun=active ports=4 http=401 enc=vaapi`) y
el panel loguea una firma por render. Son la evidencia de datos reales sin mirar
la pantalla.

## Limitaciones conocidas

- Sin rueda del mouse en los paneles: los pares se paginan con ‹ › o
  `Prior`/`Next`, y las pestañas con `Left`/`Right`.
- El panel no sabe qué superficie lo abrió: dibuja según `panel_mode`, que es lo
  mismo que usa el widget para elegir `:panel` o `:float`. Si se abre el panel
  equivocado desde la CLI, el contenido mantiene el ancho del modo configurado.
- Sunshine no expone su encoder actual por API: se lee del log, así que refleja
  el último encoder inicializado con éxito.
