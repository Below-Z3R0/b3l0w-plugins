--!strict
-- Dominio de audio: parseo puro de lo que devuelven `wpctl` y `pactl`.
--
-- Nada acá lanza procesos ni toca `noctalia.*`: son funciones sobre texto/JSON,
-- así que el service las corre dentro del presupuesto de 25 ms y los tests las
-- ejercitan con la salida real del sistema.
--
-- Backend: `wpctl` (WirePlumber) para ids y `set-default`; `pactl` para el
-- detalle (volumen por canal, mute, perfiles de tarjeta, streams). El id que
-- publica `pactl` en `properties["object.id"]` es el mismo id global de
-- PipeWire que acepta `wpctl`, y `properties["device.id"]` es el índice de la
-- tarjeta dueña del nodo.

local M = {}

local CODEC_BY_SUFFIX: { [string]: string } = {
	sbc = "SBC",
	sbc_xq = "SBC-XQ",
	aac = "AAC",
	ldac = "LDAC",
	aptx = "aptX",
	aptx_hd = "aptX HD",
	aptx_ll = "aptX LL",
	aptx_ll_duplex = "aptX LL Duplex",
	faststream = "FastStream",
	lc3 = "LC3",
	lc3_plus = "LC3plus",
	opus = "Opus",
	opus_05_1 = "Opus",
	opus_05_2 = "Opus",
	cvsd = "CVSD",
	msbc = "mSBC",
}

-- Códecs que valen la pena marcar como "alta calidad" en la fila.
local HIRES = {
	LDAC = true,
	["aptX HD"] = true,
	["aptX LL"] = true,
	["aptX LL Duplex"] = true,
	["SBC-XQ"] = true,
	LC3plus = true,
}

function M.trim(value: any): string
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Las secciones se marcan con una línea `##nombre`.
--
-- El nombre acepta guiones bajos: los headers de bluetooth llevan la MAC
-- (`##btinfo_31_92_D9_51_AF_84`) y con `%w` (que en Luau NO incluye el
-- guion bajo) esos headers no se reconocían: la salida del `info` se
-- mezclaba con la lista de equipos y la lista de bluetooth CRECÍA en cada
-- refresco (3 → 6 → 9 → 12…).
function M.split_sections(text: any): { [string]: string }
	local out: { [string]: string } = {}
	local name: string? = nil
	local buf: { string } = {}
	for line in string.gmatch(tostring(text or "") .. "\n", "([^\r\n]*)\n") do
		local header = string.match(line, "^##([%w_%-]+)$")
		if header ~= nil then
			if name ~= nil then
				out[name] = table.concat(buf, "\n")
			end
			name = header
			buf = {}
		elseif name ~= nil then
			table.insert(buf, line)
		end
	end
	if name ~= nil then
		out[name] = table.concat(buf, "\n")
	end
	return out
end

-- ── volumen ──────────────────────────────────────────────────────────

-- `pactl` da un objeto por canal con `value_percent` como "115%". El volumen
-- audible es el del canal más alto, no el primero: un balance a la izquierda
-- haría leer 30% cuando el parlante derecho está al 100%.
function M.volume_percent(volume: any): number
	local best: number? = nil
	if type(volume) == "table" then
		for _, channel in pairs(volume) do
			if type(channel) == "table" then
				local raw = tostring(channel.value_percent or "")
				local percent = tonumber(string.match(raw, "(%d+%.?%d*)"))
				if percent ~= nil and (best == nil or percent > best) then
					best = percent
				end
			end
		end
	end
	return math.floor((best or 0) + 0.5)
end

-- ── wpctl status ─────────────────────────────────────────────────────

-- Sólo interesa el bloque "Audio": el "Video" repite los encabezados Sinks y
-- Sources y mezclaría la cámara con el parlante.
function M.parse_wpctl(text: any): any
	local out = { sinks = {}, sources = {}, devices = {}, defaultSink = nil, defaultSource = nil }
	local section: string? = nil
	local inAudio = false

	for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
		local heading = M.trim(line)
		if heading == "Audio" then
			inAudio = true
		elseif heading == "Video" and inAudio then
			break
		elseif line:find("Sinks:", 1, true) then
			section = "sink"
		elseif line:find("Sources:", 1, true) then
			section = "source"
		elseif line:find("Devices:", 1, true) then
			section = "device"
		elseif line:find("Streams:", 1, true) or line:find("Filters:", 1, true) then
			section = nil
		elseif section ~= nil then
			local idText, rest = string.match(line, "(%d+)%.%s+(.+)$")
			if idText ~= nil and rest ~= nil then
				local id = tonumber(idText) or -1
				local active = line:find("*", 1, true) ~= nil
				local name = M.trim(string.match(rest, "^(.-)%s*%[") or rest)
				-- El sufijo de wpctl es `[vol: 1.15 MUTED]`. Se lee en dos pasos:
				-- un grupo opcional con captura dentro de `%[` no matchea en Lua.
				-- wpctl imprime el volumen como fracción (`[vol: 1.15 MUTED]` es
				-- 115%). Se normaliza a porcentaje acá para que el respaldo sin pactl
				-- no muestre 1% donde hay 115%.
				local rawVolume = tonumber(string.match(rest, "%[vol:%s*([%d%.]+)"))
				local entry = {
					id = id,
					name = name,
					active = active,
					volume = if rawVolume ~= nil then math.floor(rawVolume * 100 + 0.5) else nil,
					muted = string.find(rest, "MUTED", 1, true) ~= nil,
				}
				if section == "sink" then
					table.insert(out.sinks, entry)
					if active and out.defaultSink == nil then
						out.defaultSink = id
					end
				elseif section == "source" then
					table.insert(out.sources, entry)
					if active and out.defaultSource == nil then
						out.defaultSource = id
					end
				elseif section == "device" then
					table.insert(out.devices, entry)
				end
			end
		end
	end

	return out
end

-- ── pactl ────────────────────────────────────────────────────────────

-- `list` es el array de `pactl -f json list sinks|sources`; `defaultName` viene
-- de `pactl get-default-sink` (o del marcador `*` de `wpctl status` como
-- respaldo). Los monitores de sink se descartan de las entradas: son la salida
-- reflejada, no un micrófono.
function M.parse_pactl(list: any, kind: string, defaultName: string?, defaultId: number?): { any }
	local rows = {}
	for _, raw in ipairs(type(list) == "table" and list or {}) do
		if type(raw) == "table" then
			local props = type(raw.properties) == "table" and raw.properties or {}
			local name = tostring(raw.name or "")
			local api = tostring(props["device.api"] or "")
			local className = tostring(props["device.class"] or "")
			local monitor = className == "monitor"
				or string.match(name, "%.monitor$") ~= nil

			if kind ~= "source" or not monitor then
				local index = tonumber(raw.index) or -1
				local pwId = tonumber(props["object.id"]) or index
				local active = false
				if defaultName ~= nil and defaultName ~= "" then
					active = name == defaultName
				elseif defaultId ~= nil then
					active = pwId == defaultId or index == defaultId
				end

				-- Volumen por canal, balance, latencia y sample rate: los
				-- cuatro salen del mismo JSON, así que se leen de una vez.
				local channels = M.parse_channels(raw.volume, raw.channel_map)
				local latency = M.parse_latency(raw.latency)
				local rate = M.parse_rate(raw.sample_specification)
				local encoding = M.parse_encoding(raw.sample_specification)

				-- Sin `ports` ni `base_volume`: no se dibujan y construir sus tablas
				-- es la mitad del costo de parseo (medido: 19-31 ms por vuelta).
				table.insert(rows, {
					id = pwId,
					index = index,
					name = name,
					description = tostring(raw.description or name),
					volume = M.volume_percent(raw.volume),
					muted = raw.mute == true,
					state = tostring(raw.state or ""),
					icon = tostring(props["device.icon_name"] or ""),
					api = api,
					bluetooth = api == "bluez5" or string.sub(name, 1, 6) == "bluez_",
					address = tostring(props["api.bluez5.address"] or ""),
					cardId = tonumber(props["device.id"]),
					profileName = tostring(props["device.profile.name"] or ""),
					formFactor = tostring(props["device.form_factor"] or ""),
					activePort = tostring(raw.active_port or ""),
					monitor = monitor,
					active = active,
					channels = channels,
					balance = M.parse_balance(raw.balance, channels),
					latency = latency,
					rate = rate,
					encoding = encoding,
					-- El códec real en uso: la propiedad `api.bluez5.codec` la
					-- publica el nodo bluez5 (SBC, SBC-XQ, LDAC, aptX, mSBC…).
					-- Es más real que el nombre del perfil, que en HFP agrupa
					-- CVSD y mSBC bajo el mismo perfil.
					nodeCodec = tostring(props["api.bluez5.codec"] or ""),
					channelMap = tostring(raw.channel_map or ""),
				})
			end
		end
	end
	return rows
end

-- Streams por aplicación (`pactl list short sink-inputs` en versión JSON): el
-- nombre de app y el volumen son lo que hace usable el panel, y `sink` es el
-- índice del sink donde está sonando ahora.
function M.parse_sink_inputs(list: any): { any }
	local rows = {}
	for _, raw in ipairs(type(list) == "table" and list or {}) do
		if type(raw) == "table" then
			local props = type(raw.properties) == "table" and raw.properties or {}
			local app = tostring(props["application.name"] or props["media.name"] or props["application.process.binary"] or "?")
			table.insert(rows, {
				id = tonumber(raw.index) or -1,
				sink = tonumber(raw.sink) or -1,
				app = app,
				media = tostring(props["media.name"] or ""),
				icon = tostring(props["application.icon_name"] or props["application.process.binary"] or ""),
				volume = M.volume_percent(raw.volume),
				muted = raw.mute == true,
				-- La latencia REAL del stream: buffer + sink, en microsegundos.
				latency = M.parse_stream_latency(raw),
				rate = M.parse_rate(raw.sample_specification),
				channels = M.parse_channels(raw.volume, raw.channel_map),
			})
		end
	end
	return rows
end

-- ── códecs ───────────────────────────────────────────────────────────

-- `a2dp-sink-sbc_xq` → "SBC-XQ"; `headset-head-unit` no lleva sufijo de códec,
-- así que se mapea por nombre completo (es el modo HFP, CVSD por defecto).
function M.codec_label(profile: any): string?
	local p = tostring(profile or "")
	if p == "" then
		return nil
	end
	-- `a2dp-sink` sin sufijo es el perfil SBC por defecto de bluez; sin esto el
	-- códec más común de todos quedaría sin etiqueta.
	if p == "a2dp-sink" or p == "a2dp-source" then
		return "SBC"
	end
	if p == "headset-head-unit" or p == "headset-head-unit-cvsd" then
		return "CVSD"
	end
	if p == "headset-head-unit-msbc" then
		return "mSBC"
	end
	local suffix = string.match(p, "([%w_]+)$")
	if suffix ~= nil then
		return CODEC_BY_SUFFIX[suffix]
	end
	return nil
end

function M.is_hires(profile: any): boolean
	local label = M.codec_label(profile)
	return label ~= nil and HIRES[label] == true
end

-- Perfiles HFP: no son música, son el modo manos libres (micrófono).
function M.is_telephony(profile: any): boolean
	return string.sub(tostring(profile or ""), 1, 8) == "headset-"
end

function M.parse_cards(list: any): { any }
	local cards = {}
	for _, raw in ipairs(type(list) == "table" and list or {}) do
		if type(raw) == "table" then
			local props = type(raw.properties) == "table" and raw.properties or {}
			local profiles = {}
			for name, def in pairs(type(raw.profiles) == "table" and raw.profiles or {}) do
				local entry = type(def) == "table" and def or {}
				local profileName = tostring(name)
				table.insert(profiles, {
					name = profileName,
					description = tostring(entry.description or profileName),
					available = entry.available ~= false,
					sinks = tonumber(entry.sinks) or 0,
					sources = tonumber(entry.sources) or 0,
					codec = M.codec_label(profileName),
					hires = M.is_hires(profileName),
					telephony = M.is_telephony(profileName),
					active = profileName == tostring(raw.active_profile or ""),
				})
			end
			-- Orden estable: los perfiles de códec primero, después por nombre. El
			-- `selectedIndex` del select se calcula sobre esta misma lista, así que
			-- un orden que cambia entre refrescos mueve la opción elegida.
			table.sort(profiles, function(a: any, b: any): boolean
				local aCodec = a.codec ~= nil and not a.telephony
				local bCodec = b.codec ~= nil and not b.telephony
				if aCodec ~= bCodec then
					return aCodec
				end
				if a.available ~= b.available then
					return a.available
				end
				return a.name < b.name
			end)

			table.insert(cards, {
				id = tonumber(raw.index) or -1,
				name = tostring(raw.name or ""),
				driver = tostring(raw.driver or ""),
				description = tostring(props["device.description"] or props["device.alias"] or raw.name or ""),
				api = tostring(props["device.api"] or ""),
				address = tostring(props["api.bluez5.address"] or ""),
				bluetooth = tostring(props["device.api"] or "") == "bluez5",
				activeProfile = tostring(raw.active_profile or ""),
				profiles = profiles,
			})
		end
	end
	return cards
end

-- Perfiles de una tarjeta que valen como "códec" para el selector: los A2DP y
-- HFP de una tarjeta bluez. En una tarjeta ALSA no hay códec, así que no se
-- ofrece selector.
-- Sólo los códecs `available == true`: en una tarjeta bluez ese flag es lo que
-- el auricular realmente soporta, y elegir uno no disponible devuelve
-- "Failure: No such entity" (rc 1) en vez de aplicar.
function M.codec_profiles(card: any): { any }
	local out = {}
	for _, profile in ipairs(type(card) == "table" and card.profiles or {}) do
		if profile.codec ~= nil and profile.available ~= false then
			table.insert(out, profile)
		end
	end
	return out
end

-- Respaldo cuando `wpctl inspect` no existe: `pw-dump` filtrado a las dos
-- propiedades que importan. En la salida de pw-dump las props van ordenadas, así
-- que `api.bluez5.codec` aparece ANTES del `node.name` de su mismo objeto: se
-- acumula el códec y se asigna al nombre que llega después.
function M.parse_pw_dump_codecs(text: any): { [string]: string }
	local out: { [string]: string } = {}
	local pending: string? = nil
	for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
		local codec = string.match(line, '"api%.bluez5%.codec"%s*:%s*"([^"]*)"')
		if codec ~= nil then
			pending = codec
		end
		local name = string.match(line, '"node%.name"%s*:%s*"([^"]*)"')
		if name ~= nil then
			if pending ~= nil then
				out[name] = pending
				pending = nil
			end
		end
	end
	return out
end

-- ── eventos ──────────────────────────────────────────────────────────

-- `pactl subscribe` emite una línea por cambio:
--   Event 'change' on sink #55
--   Event 'new' on sink-input #10612
function M.parse_event(line: any): any
	local facility, idText = string.match(tostring(line or ""), "on%s+([%w%-]+)%s+#(%d+)")
	if facility == nil then
		return nil
	end
	return { facility = facility, id = tonumber(idText) or -1 }
end

-- ── pin del default ──────────────────────────────────────────────────

-- `pw-metadata -n default 0 default.configured.audio.sink` imprime
--   update: id:0 key:'default.configured.audio.sink' value:'{ "name": "sink" }'
-- y sin valor sólo la cabecera `Found "default" metadata N`.
function M.parse_pinned(text: any): string?
	local value = string.match(tostring(text or ""), "value:'(.-)'") or tostring(text or "")
	return string.match(value, '"name"%s*:%s*"([^"]+)"')
end

-- `bluetoothctl devices Connected` lista una línea por equipo conectado:
--   Device 31:92:D9:51:AF:84 Cubitt Headphones
-- Salir vacío es la señal de "no hay ningún bluetooth conectado".
function M.parse_bt_connected(text: any): boolean
	return string.match(tostring(text or ""), "^Device%s+%x%x:") ~= nil
end

-- `busctl --system get-property org.bluez <path> org.bluez.Battery1 Percentage`
-- responde `y 80`. Falla con rc!=0 cuando el equipo no expone Battery1.
function M.parse_busctl_battery(text: any): number?
	return tonumber(string.match(tostring(text or ""), "^y%s+(%d+)%s*$"))
end

-- ── canales, balance y latencia ─────────────────────────────────────

-- El volumen por canal de `pactl -f json list sinks` viene como un mapa
-- channel -> {value, value_percent}. El ORDEN del mapa no es el orden de los
-- canales: `pactl set-sink-volume` toma los volúmenes en el orden del
-- channel map del sink, así que la lista sale del `channel_map` y no del mapa.
function M.parse_channels(volume: any, channelMap: any): { any }
	local percentes: { [string]: number } = {}
	if type(volume) == "table" then
		for name, data in pairs(volume) do
			percentes[tostring(name)] = M.volume_percent({ data })
		end
	end

	local out: { any } = {}
	local visto: { [string]: boolean } = {}
	for name in string.gmatch(tostring(channelMap or ""), "[^,]+") do
		local channel = M.trim(name)
		if channel ~= "" and percentes[channel] ~= nil then
			table.insert(out, { name = channel, percent = percentes[channel] })
			visto[channel] = true
		end
	end
	-- Los canales que no estén en el map (surround, etc.) van al final.
	for name, percent in pairs(percentes) do
		if not visto[name] then
			table.insert(out, { name = name, percent = percent })
		end
	end
	return out
end

-- El balance de PulseAudio va de -1 (izquierda) a 1 (derecha). `pactl` lo
-- publica YA calculado en el JSON (`balance`), así que se lee de ahí; el
-- cálculo local es sólo el respaldo para cuando el backend no lo trae.
function M.parse_balance(raw: any, channels: any): number
	local value = tonumber(raw)
	if value ~= nil then
		return value
	end
	if type(channels) ~= "table" then
		return 0
	end
	local left = 0
	local right = 0
	for _, channel in ipairs(channels) do
		local name = string.lower(tostring(channel.name or ""))
		local percent = tonumber(channel.percent) or 0
		if string.find(name, "left", 1, true) ~= nil then
			left = percent
		elseif string.find(name, "right", 1, true) ~= nil then
			right = percent
		end
	end
	local maximo = math.max(left, right)
	if maximo <= 0 then
		return 0
	end
	return math.floor(((right - left) / maximo) * 100 + 0.5) / 100
end

-- `pactl -f json list sinks` publica la latencia en microsegundos:
--   "latency": { "actual": 0.0, "configured": 0.0 }
function M.parse_latency(raw: any): any
	local out = { actual = 0, configured = 0 }
	if type(raw) == "table" then
		out.actual = math.floor(tonumber(raw.actual) or 0)
		out.configured = math.floor(tonumber(raw.configured) or 0)
	end
	return out
end

-- Los streams (sink-inputs) traen la latencia partida:
--   "buffer_latency_usec": 0.0, "sink_latency_usec": 0.0
function M.parse_stream_latency(raw: any): number
	if type(raw) ~= "table" then
		return 0
	end
	local buffer = tonumber(raw.buffer_latency_usec) or 0
	local sink = tonumber(raw.sink_latency_usec) or 0
	return math.floor(buffer + sink)
end

-- "s32le 2ch 48000Hz" -> 48000. Es el sample rate REAL del sink.
function M.parse_rate(sampleSpec: any): number
	return tonumber(string.match(tostring(sampleSpec or ""), "(%d+)%s*[Hh]z")) or 0
end

-- "s32le 2ch 48000Hz" -> "s32le". El encoding REAL que ya usa el sink:
-- `pactl set-sink-formats` rechaza un encoding que el dispositivo no
-- soporta, así que se reusa el suyo en vez de inventar uno.
function M.parse_encoding(sampleSpec: any): string
	local encoding = string.match(tostring(sampleSpec or ""), "^%s*([%a%d]+)")
	if encoding == nil or encoding == "" then
		return "s16le"
	end
	return encoding
end

-- ── WirePlumber: settings y filtros ─────────────────────────────────

-- `wpctl settings` lista los settings del daemon con su tipo y su valor:
--   - Id: node.features.audio.no-dsp
--     Name: No DSP
--     Desc: Disable all DSP processing
--     Type: Boolean
--     Default: false
--     Value: false
function M.parse_wp_settings(text: any): { any }
	local out: { any } = {}
	local current: any = nil
	for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
		local id = string.match(line, "^%s*%-%s+Id:%s+(%S+)")
		if id ~= nil then
			current = { id = id, name = "", desc = "", type = "", value = "", default = "" }
			table.insert(out, current)
		elseif current ~= nil then
			local key, value = string.match(line, "^%s+([%a]+):%s*(.*)$")
			if key ~= nil then
				local texto = M.trim(value)
				if key == "Name" then
					current.name = texto
				elseif key == "Desc" then
					current.desc = texto
				elseif key == "Type" then
					current.type = texto
				elseif key == "Value" then
					current.value = texto
				elseif key == "Default" then
					current.default = texto
				end
			end
		end
	end
	return out
end

-- La sección "Filters:" de `wpctl status` lista los nodos de filtro vivos:
--   │      62. filter-chain            [vol: 1.00]
function M.parse_wp_filters(text: any): { any }
	local out: { any } = {}
	local inFilters = false
	for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
		if string.find(line, "Filters:", 1, true) ~= nil then
			inFilters = true
		elseif inFilters then
			if string.find(line, "Streams:", 1, true) ~= nil then
				break
			end
			local limpia = string.gsub(line, "^[%s│├└─]*", "")
			local id, name = string.match(limpia, "^(%d+)%.%s+(.+)$")
			if id ~= nil then
				local label = M.trim(string.match(name, "^(.-)%s*%[") or name)
				table.insert(out, { id = tonumber(id) or -1, name = label })
			end
		end
	end
	return out
end

-- ── bluetooth ───────────────────────────────────────────────────────

-- `bluetoothctl devices` lista los equipos conocidos:
--   Device 31:92:D9:51:AF:84 Cubitt Headphones
--
-- La cabecera de `bluetoothctl info` (`Device 31:92:... (public)`) tiene la
-- misma forma pero sin nombre real: se descarta lo que viene entre
-- paréntesis. El nombre puede llevar espacios ("HP H23C Earbuds"), así que
-- sólo se corta en el paréntesis.
function M.parse_bt_devices(text: any): { any }
	local out: { any } = {}
	for mac, name in string.gmatch(tostring(text or "") .. "\n", "Device%s+([%x:]+)%s+(.-)\n") do
		local limpio = string.match(name, "^(.-)%s*%(") or M.trim(name)
		local valor = M.trim(limpio)
		if valor ~= "" then
			table.insert(out, { mac = tostring(mac), name = valor })
		end
	end
	return out
end

-- `bluetoothctl info <mac>`:
--   Name: Cubitt Headphones
--   Icon: audio-headset
--   Paired: yes
--   Connected: no
function M.parse_bt_info(text: any): any
	local out: any = {
		name = "",
		alias = "",
		icon = "",
		connected = false,
		paired = false,
		trusted = false,
		battery = nil,
	}
	for line in string.gmatch(tostring(text or ""), "[^\r\n]+") do
		local key, value = string.match(line, "^%s+([%a]+):%s*(.*)$")
		if key ~= nil then
			local texto = M.trim(value)
			if key == "Name" then
				out.name = texto
			elseif key == "Alias" then
				out.alias = texto
			elseif key == "Icon" then
				out.icon = texto
			elseif key == "Connected" then
				out.connected = texto == "yes"
			elseif key == "Paired" then
				out.paired = texto == "yes"
			elseif key == "Trusted" then
				out.trusted = texto == "yes"
			elseif key == "BatteryPercentage" then
				out.battery = tonumber(texto)
			end
		end
	end
	return out
end

return M
