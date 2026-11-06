-- Specs del dominio puro (lib/audio.luau) contra la salida REAL de esta máquina.
--
-- Los fixtures `wpctl_status.txt`, `sinks.json`, `sources.json`, `cards.json`,
-- `sink-inputs.json`, `pwdump_none.txt` y `upower.txt` se capturaron con
-- `wpctl`/`pactl`/`upower`/`pw-dump` tal cual en CachyOS con PipeWire 1.6.10.
-- Los `synthetic_*` NO son capturas: son la forma documentada de una tarjeta
-- bluez, porque en esta máquina no hay ningún dispositivo bluetooth conectado.
-- El spec los separa a propósito.
--
--   python3 tests/build_fixtures.py && luau tests/audio_spec.luau

local audio = require("../lib/audio")
local data = require("./fixtures/data")

local passed, failed = 0, 0

local function check(label, ok, detail)
	if ok then
		passed += 1
		print("ok   " .. label)
	else
		failed += 1
		print("FAIL " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
	end
end

-- ── wpctl status real ────────────────────────────────────────────────

local status = audio.parse_wpctl(data.status)
check("wpctl: un sink", #status.sinks == 1, #status.sinks)
check("wpctl: sink activo es el default", status.defaultSink == 55, status.defaultSink)
check(
	"wpctl: nombre del sink",
	status.sinks[1] ~= nil and status.sinks[1].name == "Built-in Audio Analog Stereo",
	status.sinks[1] and status.sinks[1].name
)
check("wpctl: sink muteado leído del texto", status.sinks[1] ~= nil and status.sinks[1].muted == true)
check("wpctl: source default", status.defaultSource == 56, status.defaultSource)
check("wpctl: un device (tarjeta)", #status.devices == 1 and status.devices[1].id == 44, #status.devices)

-- ── pactl real ───────────────────────────────────────────────────────

local sinks = audio.parse_pactl(data.sinks, "sink", "alsa_output.pci-0000_00_1f.3.analog-stereo")
check("pactl sinks: una fila", #sinks == 1, #sinks)
local sink = sinks[1] or {}
check("pactl sinks: pw id == object.id", sink.id == 55, sink.id)
check("pactl sinks: volumen 115%", sink.volume == 115, sink.volume)
check("pactl sinks: mute", sink.muted == true)
check("pactl sinks: activo por nombre default", sink.active == true)
check("pactl sinks: tarjeta dueña", sink.cardId == 44, sink.cardId)
check("pactl sinks: api alsa", sink.api == "alsa", sink.api)

local sources = audio.parse_pactl(data.sources, "source", "alsa_input.pci-0000_00_1f.3.analog-stereo")
check("pactl sources: monitor filtrado, queda 1", #sources == 1, #sources)
check(
	"pactl sources: es el micrófono interno",
	sources[1] ~= nil and string.find(sources[1].name, "^alsa_input") ~= nil,
	sources[1] and sources[1].name
)

local cards = audio.parse_cards(data.cards)
check("cards: una tarjeta", #cards == 1, #cards)
check("cards: no es bluetooth", cards[1] ~= nil and cards[1].bluetooth == false)
check("cards: perfil activo", cards[1] ~= nil and cards[1].activeProfile ~= "", cards[1] and cards[1].activeProfile)
-- El orden del select se deriva de esta lista: si cambia entre dos parseos del
-- mismo JSON, el índice elegido salta de opción en cada refresco.
local function order(card)
	local names = {}
	for _, profile in ipairs(card.profiles) do
		table.insert(names, profile.name)
	end
	return table.concat(names, ",")
end
local first = order(cards[1])
local second = order(audio.parse_cards(data.cards)[1])
check("cards: orden de perfiles estable entre parseos", first == second, first)
check("cards: disponibles antes que no disponibles", cards[1].profiles[1].available == true)
check("cards: ALSA no ofrece selector de códec", #audio.codec_profiles(cards[1]) == 0)

local inputs = audio.parse_sink_inputs(data.inputs)
check("sink-inputs: 3 streams", #inputs == 3, #inputs)
check("sink-inputs: todos en el sink 55", inputs[1] ~= nil and inputs[1].sink == 55, inputs[1] and inputs[1].sink)

-- ── códecs (sintético) ───────────────────────────────────────────────

local bluez = audio.parse_cards(data.bluez_card)[1]
check("bluez: detectada como bluetooth", bluez ~= nil and bluez.bluetooth == true)
check("bluez: MAC", bluez ~= nil and bluez.address == "31:92:D9:51:AF:84", bluez and bluez.address)
local codecs = audio.codec_profiles(bluez)
-- 8 perfiles con códec, pero LDAC viene `available:false` (el remoto no lo
-- soporta) y no se ofrece: elegirlo devolvería "No such entity".
check("bluez: 7 códecs ofrecidos (LDAC no disponible filtrado)", #codecs == 7, #codecs)
check("bluez: SBC primero", codecs[1] ~= nil and codecs[1].codec == "SBC", codecs[1] and codecs[1].name)
check("bluez: el perfil activo es sbc_xq", bluez.activeProfile == "a2dp-sink-sbc_xq", bluez.activeProfile)

local labels = {}
for _, profile in ipairs(codecs) do
	labels[profile.name] = profile.codec
end
check("bluez: LDAC no se ofrece si el remoto no lo soporta", labels["a2dp-sink-ldac"] == nil)
check("bluez: aptX HD etiquetado", labels["a2dp-sink-aptx_hd"] == "aptX HD", labels["a2dp-sink-aptx_hd"])
check("bluez: HFP sin sufijo es CVSD", labels["headset-head-unit"] == "CVSD", labels["headset-head-unit"])
check("bluez: HFP mSBC etiquetado", labels["headset-head-unit-msbc"] == "mSBC", labels["headset-head-unit-msbc"])
check("bluez: LDAC marcado hi-res", audio.is_hires("a2dp-sink-ldac") == true)
check("bluez: SBC no es hi-res", audio.is_hires("a2dp-sink") == false)

local dumped = audio.parse_pw_dump_codecs(data.pw_dump)
check(
	"pw-dump: códec del sink",
	dumped["bluez_output.31_92_D9_51_AF_84.1"] == "sbc_xq",
	dumped["bluez_output.31_92_D9_51_AF_84.1"]
)
check(
	"pw-dump: códec del source HFP",
	dumped["bluez_input.31_92_D9_51_AF_84.0"] == "msbc",
	dumped["bluez_input.31_92_D9_51_AF_84.0"]
)
check("pw-dump real (sin bluez) no inventa códecs", next(audio.parse_pw_dump_codecs(data.pwdump_none)) == nil)

-- ── batería por busctl ───────────────────────────────────────────────
-- `upower` sólo lista la batería del portátil (verificado en esta máquina): la
-- del auricular vive en org.bluez.Battery1.

check("busctl: 'y 80' -> 80", audio.parse_busctl_battery("y 80\n") == 80, audio.parse_busctl_battery("y 80\n"))
check("busctl: vacío -> nil", audio.parse_busctl_battery("") == nil)
check("busctl: error de busctl -> nil", audio.parse_busctl_battery("Failed to get property: Unknown object") == nil)

-- ── pin del default y bluetooth conectado ────────────────────────────

check(
	"pw-metadata: valor fijado",
	audio.parse_pinned("update: id:0 key:'default.configured.audio.sink' value:'{ \"name\": \"alsa_output.x\" }' type:'(null)'")
		== "alsa_output.x",
	audio.parse_pinned("update: value:'{ \"name\": \"alsa_output.x\" }'")
)
check("pw-metadata: sin valor -> nil", audio.parse_pinned('Found "default" metadata 40') == nil)
check("bluetoothctl: equipo conectado", audio.parse_bt_connected("Device 31:92:D9:51:AF:84 Cubitt Headphones\n") == true)
check("bluetoothctl: vacío = sin bluetooth", audio.parse_bt_connected("") == false)
check(
	"bluetoothctl: la cabecera del controller no cuenta",
	audio.parse_bt_connected("Controller 00:1A:7D:DA:71:13 parallel-cachyos [default]\n") == false
)

-- ── volumen por canal, balance y latencia ────────────────────────────
-- El orden de los canales sale del `channel_map` del sink, NO del mapa de
-- volumen: `pactl set-sink-volume` toma los volúmenes en ese orden.

local canales = sink.channels or {}
check("sink: dos canales", #canales == 2, #canales)
check("sink: el primero es front-left", canales[1] ~= nil and canales[1].name == "front-left",
	canales[1] and canales[1].name)
check("sink: el segundo es front-right", canales[2] ~= nil and canales[2].name == "front-right",
	canales[2] and canales[2].name)
check("sink: el volumen del canal viene del mapa", canales[1] ~= nil and canales[1].percent == 115,
	canales[1] and canales[1].percent)
check("sink: balance leído del JSON", sink.balance == 0.0, sink.balance)
check("sink: latencia en microsegundos", type(sink.latency) == "table" and sink.latency.actual == 0)
check("sink: sample rate real (48000)", sink.rate == 48000, sink.rate)
check("sink: encoding real del sink", sink.encoding == "s32le", sink.encoding)

-- El balance se calcula cuando el backend no lo trae.
local sinBalance = audio.parse_balance(nil, {
	{ name = "front-left", percent = 50 },
	{ name = "front-right", percent = 100 },
})
check("balance: calculado desde los canales", sinBalance == 0.5, sinBalance)
check("balance: el JSON gana sobre el cálculo", audio.parse_balance(0.25, {}) == 0.25)

-- La latencia del stream: buffer + sink, en microsegundos.
check("stream: latencia sumada", audio.parse_stream_latency({
	buffer_latency_usec = 1000.0,
	sink_latency_usec = 2000.0,
}) == 3000)
check("stream: sin latencia -> 0", audio.parse_stream_latency({}) == 0)
check("stream: nil -> 0", audio.parse_stream_latency(nil) == 0)

-- El sample rate y el encoding salen del "Sample Specification" real.
check("rate: 48000Hz", audio.parse_rate("s32le 2ch 48000Hz") == 48000)
check("rate: 96000Hz", audio.parse_rate("s16le 2ch 96000Hz") == 96000)
check("rate: sin dato -> 0", audio.parse_rate("") == 0)
check("encoding: s32le", audio.parse_encoding("s32le 2ch 48000Hz") == "s32le")
check("encoding: float32ne", audio.parse_encoding("float32ne 2ch 48000Hz") == "float32ne")

-- ── módulos de filtro de WirePlumber ─────────────────────────────────

local settings = audio.parse_wp_settings([[
- Id: node.features.audio.no-dsp
  Name: No DSP
  Desc: Disable all DSP processing
  Type: Boolean
  Default: false
  Value: true

- Id: linking.role-based.duck-level
  Name: Ducking level
  Desc: The volume level to apply when ducking
  Type: Float
  Default: 0.3	[Min: 0.0, Max: 1.0]
  Value: 0.3
]])
check("settings: dos módulos", #settings == 2, #settings)
check("settings: el id", settings[1] ~= nil and settings[1].id == "node.features.audio.no-dsp",
	settings[1] and settings[1].id)
check("settings: el nombre", settings[1] ~= nil and settings[1].name == "No DSP",
	settings[1] and settings[1].name)
check("settings: el tipo", settings[1] ~= nil and settings[1].type == "Boolean",
	settings[1] and settings[1].type)
check("settings: el valor", settings[1] ~= nil and settings[1].value == "true",
	settings[1] and settings[1].value)
check("settings: el Float también se lee", settings[2] ~= nil and settings[2].type == "Float",
	settings[2] and settings[2].type)
check("settings: texto vacío -> nada", #audio.parse_wp_settings("") == 0)

-- Los filtros VIVOS salen de la sección "Filters:" de `wpctl status`.
local filtros = audio.parse_wp_filters([[
Audio
 ├─ Devices:
 │      44. Built-in Audio                      [alsa]
 │
 ├─ Sinks:
 │  *   57. Built-in Audio Analog Stereo        [vol: 1.00]
 │
 ├─ Filters:
 │      62. filter-chain                        [vol: 1.00]
 │      63. easyeffects                         [vol: 1.00]
 │
 └─ Streams:
        65. Noctalia Spectrum
]])
check("filtros: dos nodos", #filtros == 2, #filtros)
check("filtros: el id", filtros[1] ~= nil and filtros[1].id == 62, filtros[1] and filtros[1].id)
check("filtros: el nombre sin el volumen", filtros[1] ~= nil and filtros[1].name == "filter-chain",
	filtros[1] and filtros[1].name)
check("filtros: sin sección Filters -> nada", #audio.parse_wp_filters("Audio\n ├─ Sinks:\n") == 0)

-- ── bluetooth ────────────────────────────────────────────────────────

local equipos = audio.parse_bt_devices("Device 31:92:D9:51:AF:84 Cubitt Headphones\nDevice 27:CB:CF:69:29:1E HP H23C Earbuds\n")
check("bt: dos equipos", #equipos == 2, #equipos)
check("bt: la MAC", equipos[1] ~= nil and equipos[1].mac == "31:92:D9:51:AF:84",
	equipos[1] and equipos[1].mac)
check("bt: el nombre", equipos[1] ~= nil and equipos[1].name == "Cubitt Headphones",
	equipos[1] and equipos[1].name)
check("bt: sin línea final -> el último también", #audio.parse_bt_devices("Device AA:BB:CC:DD:EE:FF Auricular") == 1)
-- La cabecera de `bluetoothctl info` tiene la misma forma pero sin nombre
-- real: si se cuela en la lista, el conteo de equipos queda mal.
check("bt: la cabecera (public) no es un equipo",
	#audio.parse_bt_devices("Device 31:92:D9:51:AF:84 (public)\n") == 0,
	#audio.parse_bt_devices("Device 31:92:D9:51:AF:84 (public)\n"))

-- ── secciones con guion bajo ─────────────────────────────────────────
-- Los headers de bluetooth llevan la MAC (`##btinfo_31_92_D9_51_AF_84`) y
-- `%w` en Luau NO incluye el guion bajo: sin este arreglo la lista de
-- bluetooth CRECÍA en cada refresco (3 → 6 → 9 → 12…).
local secciones = audio.split_sections("##btdevices\nDevice AA:BB:CC:DD:EE:FF Uno\n##btinfo_AA_BB_CC_DD_EE_FF\nDevice AA:BB:CC:DD:EE:FF (public)\n")
check("secciones: el header con guion bajo se parte", secciones.btinfo_AA_BB_CC_DD_EE_FF ~= nil,
	"btinfo_AA_BB_CC_DD_EE_FF")
check("secciones: la lista de equipos queda aparte",
	secciones.btdevices ~= nil and string.find(secciones.btdevices, "Uno", 1, true) ~= nil)
check("secciones: el info no se mezcla con la lista",
	secciones.btdevices ~= nil and string.find(secciones.btdevices, "public", 1, true) == nil)

local info = audio.parse_bt_info([[Device 31:92:D9:51:AF:84 (public)
	Name: Cubitt Headphones
	Alias: Cubitt Headphones
	Icon: audio-headset
	Paired: yes
	Bonded: yes
	Trusted: yes
	Blocked: no
	Connected: no
]])
check("bt info: el nombre", info.name == "Cubitt Headphones", info.name)
check("bt info: el ícono", info.icon == "audio-headset", info.icon)
check("bt info: pareado", info.paired == true)
check("bt info: no conectado", info.connected == false)
check("bt info: texto vacío -> todo falso", audio.parse_bt_info("").paired == false)

-- ── eventos ──────────────────────────────────────────────────────────
local event = audio.parse_event("Event 'change' on sink #55")
check("evento: facility e id", event ~= nil and event.facility == "sink" and event.id == 55)
check("evento: sink-input", (audio.parse_event("Event 'new' on sink-input #10612") or {}).facility == "sink-input")
check("evento: basura devuelve nil", audio.parse_event("Connection failure: Connection refused") == nil)

print(("\n%d ok, %d fallos"):format(passed, failed))
if failed > 0 then
	error("specs fallaron")
end
