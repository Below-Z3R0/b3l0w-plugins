# b3l0w Audio

Plugin de audio para Noctalia: reemplaza al `blackbartblues/audio-switcher` del
catálogo con paridad de dispositivos y agrega **selección de códec por
dispositivo Bluetooth**, **perfiles de tarjeta**, **streams por aplicación**,
**batería del auricular** y **pin del default**.

- `id`: `b3l0w/audio` · `plugin_api`: 43
- Backend: `pactl` (lectura y escritura) con `wpctl` sólo para el árbol de
  dispositivos. Requiere `pactl`, `wpctl`, `bluetoothctl`, `pw-metadata`,
  `pw-dump` y `busctl`.

## Qué hace

| Vista | Contenido |
|---|---|
| **Salidas** | cada sink con slider de volumen (0–1.5 = 0–150%), mute, "usar como default", pin del default, mover todos los streams acá, selector de **perfil** de su tarjeta y, si es Bluetooth, selector de **códec** |
| **Entradas** | cada source (los monitores de sink se filtran: no son micrófonos) con volumen, mute, default y perfil |
| **Streams** | cada `sink-input` con aplicación, volumen propio y selector de salida (mueve con `pactl move-sink-input`) |

Widget de barra: ícono según el estado (`volume-x` si todo está muteado,
`headphones` si el default es Bluetooth, `volume-2` si no), porcentaje del sink
por defecto y tooltip con salida, entrada, códec y batería. Click izquierdo abre
el panel (compacto o flotante según `panel_mode`), click derecho pasa a la
siguiente salida, la rueda sube/baja el volumen.

## Decisiones de backend (verificadas en esta máquina)

Estas reglas no son teóricas: cada una costó una prueba fallida.

1. **Se escribe con `pactl` y por nombre, nunca con `wpctl` por id.** En esta
   build `wpctl` numera con `object.id` y `pactl` con `object.serial`: el mismo
   sink es `pactl 55` / `node 32` / `serial 11297`, y `wpctl set-default 55`
   responde `Node '55' not found`. Un nombre sobrevive a que el nodo se recree.
2. **No se cachean índices.** Un cambio de perfil recrea los nodos
   (`sink 55 → 11297 → 12243`). El estado se refresca por `pactl -f json` y por
   el evento de `pactl subscribe`.
3. **Un códec A2DP es un perfil de tarjeta.** `wpctl set-route` no existe en
   esta build (`Property 'card.profile.device' not found`, rc=3). Los códecs se
   leen de `pactl -f json list cards` (`active_profile` = códec actual,
   `profiles[x].available` = lo que el remoto soporta, sólo se ofrecen los
   disponibles) y se escriben con
   `pactl set-card-profile <card> a2dp-sink-<codec>`. Si el remoto no lo
   soporta, `pactl` devuelve `Failure: No such entity` y el panel muestra
   `<códec>: el dispositivo no lo soporta` — nunca un éxito inventado.
4. **Detectar "sin Bluetooth" no es "existe un objeto bluez5".** El nodo
   `bluez_midi.server` (BLE MIDI) está siempre y da falso positivo: se usa que
   exista una tarjeta con `device.api == bluez5` **o** que
   `bluetoothctl devices Connected` no esté vacío.
5. **La batería no sale de `upower`.** `upower` sólo lista la del portátil; la
   del auricular se lee de `org.bluez.Battery1`:
   `busctl --system get-property org.bluez /org/bluez/hci0/dev_XX_XX... org.bluez.Battery1 Percentage` → `y 80`.
6. **El rango de volumen real llega a 150%** (`1.15` en wpctl), así que el
   slider va de 0 a 1.5 y el service clampea en 0–150%.
7. **Mover todos los streams puede cambiar la salida por defecto** (WirePlumber
   sigue al stream): después de mover se re-afirma el default anterior por
   nombre.
8. **Pin del default** para que WirePlumber no robe la salida al conectar un
   Bluetooth: `pw-metadata -n default 0 default.configured.audio.sink '{"name":"<sink>"}'`,
   y se suelta con `pw-metadata -n default -d 0 ...`.
9. **No se ofrece** suspender dispositivo (`pactl suspend-sink` es no-op acá) ni
   cambiar de puerto (devuelve rc=0 incluso con el puerto no disponible y en
   esta tarjeta hace desaparecer el micrófono).

`lib/proc.luau` es el puente a procesos. `lib/cli.luau` de la familia b3l0w es
el puente al binario Go (`b3l0w <extensión> ...`) y lo reescribe
`luau-shared/sync.sh`: este plugin no lo usa, por eso el suyo se llama `proc`.

## Ajustes

| Clave | Tipo | Default | Qué hace |
|---|---|---|---|
| `show_label` | bool | `true` | oculta la etiqueta del widget en la barra |
| `show_percentage` | bool | `true` | muestra el porcentaje del sink por defecto |
| `panel_mode` | select | `compact` | `compact` (attached) o `float` (flotante, dos paneles en el manifest) |
| `animations` | bool | `true` | fade escalonado de las filas al cambiar de vista |
| `density` | select | `cozy` | alto de fila y cuántos dispositivos entran por página |
| `refresh_seconds` | int | `5` | respaldo de refresco si el stream de eventos muere |
| `volume_step` | int | `5` | cuánto mueve la rueda sobre el widget |
| `notify_on_switch` | bool | `true` | notifica cambios de salida, entrada o códec |
| `show_battery` | bool | `true` | muestra la batería del dispositivo Bluetooth |

## Acciones (IPC y panel)

El service despacha por tabla (`ACTIONS`) y también por IPC:

```bash
noctalia msg plugin b3l0w/audio:service all refresh '{}'
noctalia msg plugin b3l0w/audio:service all set_default '{"kind":"sink","name":"alsa_output.pci-0000_00_1f.3.analog-stereo"}'
noctalia msg plugin b3l0w/audio:service all set_volume '{"kind":"sink","name":"<sink>","value":40}'
noctalia msg plugin b3l0w/audio:service all toggle_mute '{"kind":"sink","name":"<sink>"}'
noctalia msg plugin b3l0w/audio:service all mute_all '{"muted":true}'
noctalia msg plugin b3l0w/audio:service all set_profile '{"card":"alsa_card.pci-0000_00_1f.3","profile":"output:analog-stereo"}'
noctalia msg plugin b3l0w/audio:service all set_codec '{"card":"bluez_card.31_92_D9_51_AF_84","profile":"a2dp-sink-ldac"}'
noctalia msg plugin b3l0w/audio:service all move_stream '{"stream":10602,"sink":"<sink>"}'
noctalia msg plugin b3l0w/audio:service all move_streams '{"sink":"<sink>"}'
noctalia msg plugin b3l0w/audio:service all pin_default '{"name":"<sink>"}'
noctalia msg plugin b3l0w/audio:service all unpin_default '{}'
noctalia msg plugin b3l0w/audio:service all cycle_output '{}'
noctalia msg plugin b3l0w/audio:service all cycle_input '{}'
```

`mute_all` guarda el estado de mute de cada dispositivo y lo restaura al
desmutear: no es un unmute indiscriminado.

## Estructura

```
plugin.toml            manifest (settings, service, widget, dos paneles)
service.luau           procesos + estado publicado (parseo en dos etapas)
panel.luau             UI declarativa ui.* (salidas / entradas / streams)
widget.luau            barra
lib/audio.luau         dominio puro: parseo de wpctl/pactl/pw-metadata/busctl
lib/proc.luau          puente a procesos (quote/run/exit_code)
lib/{anim,prefs,store}.luau   capa compartida b3l0w
translations/{en,es}.json     mismo set de claves (82)
tests/                 specs del dominio contra la salida real de la máquina
AUDIT.md               inventario del plugin original (qué features tenía)
```

## Tests

Los specs corren el dominio puro contra la salida **real** capturada en esta
máquina (`tests/fixtures/*.json`, `wpctl_status.txt`) más dos fixtures
sintéticos y marcados como tales (tarjeta bluez y pw-dump), porque acá no hay
ningún dispositivo Bluetooth conectado.

```bash
python3 tests/build_fixtures.py    # empaqueta los fixtures en un literal Luau
luau tests/audio_spec.luau         # 48 assertions
luau-compile --binary service.luau # y panel/widget/lib
python3 ~/.hermes/profiles/parallel/skills/noctalia-plugin-development/scripts/audit_plugin.py .
```

## Fuera de alcance (deliberado)

El original además agrupa salidas (combine-sink), renombra/oculta dispositivos
con alias e íconos propios, y asigna "slots" a los Bluetooth. No están acá: el
alcance pedido fue paridad de selección (dispositivos, default, volumen, mute,
refresco) más códecs, perfiles, streams, batería y pin. El detalle de lo que
hacía el original está en `AUDIT.md`.

## Requisitos

- `pactl` (pipewire-pulse)
- `wpctl` (WirePlumber)
- `bluetoothctl` (BlueZ, solo para el panel de Bluetooth)

## Instalación

```bash
git clone https://github.com/Below-Z3R0/b3l0w-audio ~/.local/share/noctalia/plugins/b3l0w-audio
```

Después habilitá el plugin desde **Ajustes → Plugins** de Noctalia, o
reiniciá Noctalia para que lo descubra:

```bash
kill $(pgrep -x noctalia); nohup noctalia >/dev/null 2>&1 &
```

## Licencia

MIT — ver [LICENSE](LICENSE).
