--!nonstrict
-- Service de b3l0w/audio: dueño de todos los procesos y del estado compartido.
--
-- LECTURA: una sola vuelta de shell publica todo (`##status` de wpctl para el
-- árbol, `##sinks`, `##sources`, `##cards`, `##inputs` de pactl en JSON,
-- `##pinned` de pw-metadata y `##btconnected` de bluetoothctl).
--
-- ESCRITURA: todo va por `pactl` y POR NOMBRE. En esta build `wpctl` numera con
-- `object.id` y `pactl` con `object.serial`: son números distintos para el mismo
-- sink (pactl 55 / node 32 / serial 11297) y `wpctl set-default 55` responde
-- "Node '55' not found". Un nombre (`alsa_output.pci-...`) sobrevive a que el
-- nodo se recree, cosa que pasa en cada cambio de perfil.
--
-- CÓDECS: en esta build `wpctl set-route` no existe de hecho ("Property
-- 'card.profile.device' not found", rc=3). Un códec A2DP ES un perfil de
-- tarjeta con nombre `a2dp-sink-<codec>`, así que se lee de
-- `pactl -f json list cards` (active_profile = códec actual, profiles.available
-- = lo que el remoto soporta) y se escribe con `pactl set-card-profile`.
--
-- Presupuesto: 25 ms de CPU por callback. El parseo va en dos etapas (una vuelta
-- completa medía 19-31 ms) y la batería en una tercera, sólo si hay bluetooth.

local audio = require("./lib/audio.luau")
local proc = require("./lib/proc.luau")
local store = require("./lib/store.luau")

local STATE_KEY = "b3l0w_audio_state"
local REQUEST_KEY = "b3l0w_audio_request"

local SNAPSHOT_FILE = "snapshot.json"
local SNAPSHOT_VERSION = 1

local DEFAULT_REFRESH_SECONDS = 5
local DEBOUNCE_MS = 350
local MIN_VOLUME = 0
local MAX_VOLUME = 150
local DEFAULT_STEP = 5
local MAX_ERROR_CHARS = 180

local S = {
	phase = "idle",
	err = nil,
	sinks = {},
	sources = {},
	cards = {},
	streams = {},
	defaultSinkName = nil,
	defaultSourceName = nil,
	pinned = nil,
	btConnected = false,
	btDevices = {},
	battery = {},
	nodeCodecs = {},
	-- Perfil de audio activo: "music" | "telephony" | "hires" | nil.
	audioProfile = nil,
	-- Sample rate pedido por el perfil (Hz) y el real (del backend).
	rateRequested = nil,
	rateActual = 0,
	-- Módulos de filtro de WirePlumber (wpctl settings) y filtros vivos.
	modules = {},
	filters = {},
	-- El texto crudo de `wpctl status`: de ahí salen los filtros vivos.
	statusText = nil,
	-- Dispositivos Bluetooth conocidos (bluetoothctl devices + info).
	btList = {},
	busy = false,
	queue = {},
	lastNonce = "",
	lastAction = nil,
	feedback = nil,
	feedbackError = false,
	cardsText = nil,
	signature = "",
	at = 0,
	lastRefreshAt = 0,
	pendingRefreshAt = nil,
	subscribed = false,
	seq = 0,
	-- Estados de mute previos a un mute-all, para poder restaurarlos.
	muteBackup = nil,
}

local function now()
	return os.time()
end

local function now_ms()
	return math.floor(os.clock() * 1000)
end

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function cfg(key)
	return noctalia.getConfig(key)
end

local function trim(value)
	return audio.trim(value)
end

local function has(binary)
	return noctalia.commandExists(binary)
end

local function setting_number(key, fallback, low, high)
	local value = tonumber(cfg(key))
	if value == nil then
		return fallback
	end
	if value < low then
		return low
	end
	if value > high then
		return high
	end
	return value
end

-- ── publicación ──────────────────────────────────────────────────────

local function all_muted()
	local any = false
	for _, row in ipairs(S.sinks) do
		if row.muted then
			any = true
		else
			return false
		end
	end
	return any
end

local function publish()
	noctalia.state.set(STATE_KEY, {
		phase = S.phase,
		err = S.err,
		at = S.at,
		busy = S.busy,
		sinks = S.sinks,
		sources = S.sources,
		cards = S.cards,
		streams = S.streams,
		streamCount = #S.streams,
		defaultSinkName = S.defaultSinkName,
		defaultSourceName = S.defaultSourceName,
		pinned = S.pinned,
		btConnected = S.btConnected,
		btDevices = S.btDevices,
		allMuted = all_muted(),
		lastAction = S.lastAction,
		feedback = S.feedback,
		feedbackError = S.feedbackError,
		audioProfile = S.audioProfile,
		rateRequested = S.rateRequested,
		rateActual = S.rateActual,
		modules = S.modules,
		filters = S.filters,
		btList = S.btList,
	})
end

local function report(message, isError)
	S.feedback = message
	S.feedbackError = isError == true
	if isError then
		noctalia.log("[b3l0w-audio] " .. tostring(message))
	end
end

local function notify_switch(what, name)
	if cfg("notify_on_switch") == false then
		return
	end
	noctalia.notify(tr("plugin.title"), tr("service.switched", { what = what, name = tostring(name or "") }))
end

-- ── parseo ───────────────────────────────────────────────────────────

local function decode(text, fallback)
	if type(text) ~= "string" or trim(text) == "" then
		return fallback
	end
	local value = noctalia.json.decode(text)
	if type(value) ~= "table" then
		return fallback
	end
	return value
end

local function default_names(section)
	local lines = {}
	for line in string.gmatch(tostring(section or ""), "[^\r\n]+") do
		local value = trim(line)
		if value ~= "" then
			table.insert(lines, value)
		end
	end
	return lines[1], lines[2]
end

local function cards_by_id(cards)
	local map = {}
	for _, card in ipairs(cards) do
		map[card.id] = card
	end
	return map
end

-- Sin `pactl` no hay JSON: se arma lo mínimo (nombre, volumen, mute) desde el
-- texto de `wpctl status`, que ya trae el volumen y la marca de mute.
local function rows_from_wpctl(status, kind)
	local rows = {}
	local source = if kind == "sink" then status.sinks else status.sources
	for _, entry in ipairs(source) do
		table.insert(rows, {
			id = entry.id,
			index = entry.id,
			name = entry.name,
			description = entry.name,
			volume = entry.volume or 0,
			muted = entry.muted == true,
			api = "",
			bluetooth = false,
			address = "",
			cardId = nil,
			cardName = "",
			cardDescription = "",
			formFactor = "",
			activePort = "",
			active = if kind == "sink" then status.defaultSink == entry.id else status.defaultSource == entry.id,
			profiles = {},
			codecs = {},
			codec = nil,
			battery = nil,
			kind = kind,
		})
	end
	return rows
end

local function decorate(rows, cards, kind)
	local byId = cards_by_id(cards)
	for _, row in ipairs(rows) do
		row.kind = kind
		local card = byId[row.cardId]
		row.cardName = card ~= nil and card.name or ""
		row.cardDescription = card ~= nil and card.description or ""
		-- Perfil de la tarjeta (no es lo mismo que códec): todos los perfiles que
		-- `pactl list cards` publica, con el activo marcado.
		row.profiles = card ~= nil and card.profiles or {}
		row.activeProfile = card ~= nil and card.activeProfile or ""
		row.codecs = {}
		if card ~= nil and card.bluetooth then
			row.bluetooth = true
			if row.address == "" then
				row.address = card.address
			end
			-- Sólo los códecs que el remoto soporta: `available == false` es "este
			-- auricular no lo tiene" y elegirlo devuelve "No such entity".
			row.codecs = audio.codec_profiles(card)
			-- El códec REAL en uso, en este orden de fiable a aproximado:
			--   1. `api.bluez5.codec` del nodo (lo más real: SBC, SBC-XQ, LDAC…);
			--   2. el mapa de pw-dump (mismo dato, otro camino);
			--   3. el nombre del perfil activo (agrupa CVSD y mSBC, peor pero
			--      siempre está).
			local real = row.nodeCodec
			if real == "" then
				real = S.nodeCodecs[row.name] or ""
			end
			if real ~= "" then
				row.codec = audio.codec_label(real) or string.upper(real)
				row.codecRaw = real
			else
				row.codec = audio.codec_label(card.activeProfile)
				row.codecRaw = card.activeProfile
			end
		end
		if row.address ~= "" and S.battery[row.address] ~= nil then
			row.battery = S.battery[row.address]
		end
	end
end

local function find_default(rows, name, id)
	if type(name) == "string" and name ~= "" then
		for _, row in ipairs(rows) do
			if row.name == name then
				return row
			end
		end
	end
	if id ~= nil then
		for _, row in ipairs(rows) do
			if row.id == id then
				return row
			end
		end
	end
	return nil
end

-- El parseo va en dos etapas: la primera decodifica y arma filas, la segunda
-- (con presupuesto nuevo) parsea tarjetas, publica y dispara la batería.
local function parse_base(sections)
	local status = audio.parse_wpctl(sections.status or "")
	local sinkName, sourceName = default_names(sections.defaults)

	local sinkJson = decode(sections.sinks, nil)
	local sourceJson = decode(sections.sources, nil)
	local inputJson = decode(sections.inputs, {})

	local sinks = {}
	local sources = {}
	if sinkJson ~= nil and sourceJson ~= nil then
		sinks = audio.parse_pactl(sinkJson, "sink", sinkName, status.defaultSink)
		sources = audio.parse_pactl(sourceJson, "source", sourceName, status.defaultSource)
	else
		sinks = rows_from_wpctl(status, "sink")
		sources = rows_from_wpctl(status, "source")
	end

	return {
		sinkName = sinkName,
		sourceName = sourceName,
		defaultSinkId = status.defaultSink,
		defaultSourceId = status.defaultSource,
		sinks = sinks,
		sources = sources,
		streams = audio.parse_sink_inputs(inputJson),
		cardsText = sections.cards,
		statusText = sections.status,
		pinned = audio.parse_pinned(sections.pinned or ""),
		btConnected = audio.parse_bt_connected(sections.btconnected or ""),
	}
end

local function commit(base)
	local cards = S.cards
	if base.cardsText ~= S.cardsText then
		cards = audio.parse_cards(decode(base.cardsText, {}))
		S.cardsText = base.cardsText
	end

	local sinks = base.sinks
	local sources = base.sources
	decorate(sinks, cards, "sink")
	decorate(sources, cards, "source")

	local defaultSink = find_default(sinks, base.sinkName, base.defaultSinkId)
	local defaultSource = find_default(sources, base.sourceName, base.defaultSourceId)
	if defaultSink == nil and #sinks > 0 then
		defaultSink = sinks[1]
	end
	if defaultSource == nil and #sources > 0 then
		defaultSource = sources[1]
	end
	for _, row in ipairs(sinks) do
		row.active = defaultSink ~= nil and row.id == defaultSink.id
	end
	for _, row in ipairs(sources) do
		row.active = defaultSource ~= nil and row.id == defaultSource.id
	end

	S.sinks = sinks
	S.sources = sources
	S.cards = cards
	S.streams = base.streams
	S.defaultSinkName = defaultSink ~= nil and defaultSink.name or nil
	S.defaultSourceName = defaultSource ~= nil and defaultSource.name or nil
	S.pinned = base.pinned
	S.btConnected = base.btConnected
	S.statusText = base.statusText
	S.phase = "ready"
	S.err = nil
	S.at = now()

	-- El sample rate REAL del default de salida: sale del backend, nunca del
	-- perfil pedido. Un sink ALSA no cambia de rate en caliente y el backend
	-- puede rechazar el pedido: lo que se muestra es lo que hay.
	S.rateActual = 0
	for _, row in ipairs(sinks) do
		if row.active then
			S.rateActual = tonumber(row.rate) or 0
		end
	end

	-- Traza de una línea, sólo cuando cambia: es la forma de verificar que el
	-- service publicó dispositivos reales sin abrir el panel.
	local bluetooth = 0
	local codecDevices = 0
	local names = {}
	for _, row in ipairs(sinks) do
		if row.bluetooth then
			bluetooth = bluetooth + 1
			table.insert(names, tostring(row.name) .. ":" .. tostring(row.codec or "?"))
		end
		if #row.codecs > 0 then
			codecDevices = codecDevices + 1
		end
	end
	S.btDevices = names

	local signature = "out=" .. tostring(#sinks) .. " in=" .. tostring(#sources)
		.. " streams=" .. tostring(#S.streams) .. " cards=" .. tostring(#cards)
		.. " bt=" .. tostring(bluetooth) .. "/" .. tostring(S.btConnected)
		.. " codecs=" .. tostring(codecDevices) .. " pin=" .. tostring(S.pinned)
	if signature ~= S.signature then
		S.signature = signature
		noctalia.log("[b3l0w-audio] " .. signature .. (#names > 0 and (" [" .. table.concat(names, " ") .. "]") or ""))
	end
end

-- ── lectura del sistema ──────────────────────────────────────────────

-- `pactl -f json` NO termina con salto de línea: sin el `echo` final el marcador
-- siguiente queda pegado al `]` de la última línea y la sección se traga el
-- resto de la salida (síntoma real: sinks gigante, sources vacío).
local function collect_command()
	return "echo '##status'; wpctl status 2>/dev/null; echo; "
		.. "echo '##defaults'; pactl get-default-sink 2>/dev/null; pactl get-default-source 2>/dev/null; echo; "
		.. "echo '##sinks'; pactl -f json list sinks 2>/dev/null; echo; "
		.. "echo '##sources'; pactl -f json list sources 2>/dev/null; echo; "
		.. "echo '##cards'; pactl -f json list cards 2>/dev/null; echo; "
		.. "echo '##inputs'; pactl -f json list sink-inputs 2>/dev/null; echo; "
		.. "echo '##pinned'; pw-metadata -n default 0 default.configured.audio.sink 2>/dev/null | grep -F \"value:\" | head -n1; echo; "
		.. "echo '##btconnected'; bluetoothctl devices Connected 2>/dev/null; echo"
end

-- Segunda vuelta: los datos que no hacen falta en cada refresco.
--
-- `wpctl settings` lista los módulos de filtro de WirePlumber (DSP, mono,
-- autoswitch a HSP…) con su valor: eso es lo que se puede habilitar y
-- deshabilitar. `wpctl status` trae la sección "Filters:" con los nodos de
-- filtro vivos. `bluetoothctl devices` da el listado de equipos y `info` el
-- detalle de cada uno (conectado, pareado, batería).
local function detail_command()
	local parts = {}
	table.insert(parts, "echo '##settings'; wpctl settings 2>/dev/null; echo")
	table.insert(parts, "echo '##btdevices'; bluetoothctl devices 2>/dev/null; echo")

	for _, device in ipairs(S.btList) do
		local mac = tostring(device.mac or "")
		if mac ~= "" then
			local key = string.gsub(mac, ":", "_")
			table.insert(
				parts,
				"echo '##btinfo_" .. key .. "'; bluetoothctl info " .. mac .. " 2>/dev/null; echo"
			)
		end
	end

	return table.concat(parts, "; ")
end

-- `bluez_midi.server` (media.class=Midi/Bridge) está siempre presente: contar
-- objetos con api.bluez5 da falso positivo. La señal real es una tarjeta de
-- audio bluez o un dispositivo conectado en bluetoothctl.
local function bluetooth_present()
	for _, card in ipairs(S.cards) do
		if card.bluetooth then
			return true
		end
	end
	return S.btConnected == true
end

-- Batería: `upower` sólo lista la del portátil; la del auricular está en
-- org.bluez.Battery1 y se lee con busctl por MAC. Una llamada por dispositivo.
local function extra_command(sinks)
	local parts = {}
	local seen = {}
	for _, row in ipairs(sinks) do
		if row.bluetooth and row.address ~= "" and not seen[row.address] then
			seen[row.address] = true
			local path = "/org/bluez/hci0/dev_" .. string.gsub(string.upper(row.address), ":", "_")
			table.insert(
				parts,
				"echo '##battery_" .. string.gsub(row.address, ":", "_") .. "'; "
					.. "busctl --system get-property org.bluez " .. path
					.. " org.bluez.Battery1 Percentage 2>/dev/null; echo"
			)
		end
	end

	if #parts == 0 then
		return nil
	end

	-- Códec real del nodo (distingue CVSD de mSBC dentro del mismo perfil HFP).
	table.insert(parts, "echo '##pwdump'; pw-dump 2>/dev/null | grep -E '\"(api\\.bluez5\\.codec|node\\.name)\"'; echo")
	return table.concat(parts, "; ")
end

local function apply_extra(sections)
	local battery = {}
	for key, block in pairs(sections) do
		local mac = string.match(key, "^battery_(%w+)$")
		if mac ~= nil then
			local percent = audio.parse_busctl_battery(block)
			if percent ~= nil then
				battery[string.gsub(mac, "_", ":")] = percent
			end
		end
	end
	S.battery = battery

	local codecs = {}
	for name, codec in pairs(audio.parse_pw_dump_codecs(sections.pwdump or "")) do
		codecs[name] = codec
	end
	S.nodeCodecs = codecs
end

-- Los detalles de la segunda vuelta: módulos de filtro de WirePlumber,
-- filtros vivos y equipos Bluetooth con su detalle.
local function apply_detail(sections)
	S.modules = audio.parse_wp_settings(sections.settings or "")

	-- Los filtros vivos salen del status (que ya se leyó en la vuelta
	-- principal), así que se toman del bloque guardado.
	if S.statusText ~= nil then
		S.filters = audio.parse_wp_filters(S.statusText)
	end

	local devices = audio.parse_bt_devices(sections.btdevices or "")
	for _, device in ipairs(devices) do
		local key = string.gsub(tostring(device.mac or ""), ":", "_")
		local info = audio.parse_bt_info(sections["btinfo_" .. key] or "")
		device.connected = info.connected
		device.paired = info.paired
		device.trusted = info.trusted
		device.icon = info.icon
		if info.name ~= "" then
			device.name = info.name
		elseif info.alias ~= "" then
			device.name = info.alias
		end
		-- La batería del auricular la publica BlueZ por D-Bus, no
		-- `bluetoothctl info`: se cruza con lo que ya leyó busctl.
		if S.battery[tostring(device.mac or "")] ~= nil then
			device.battery = S.battery[tostring(device.mac or "")]
		elseif info.battery ~= nil then
			device.battery = info.battery
		end
	end
	S.btList = devices
end

-- ── refresco ─────────────────────────────────────────────────────────

local function refresh(cb)
	S.seq = S.seq + 1
	local token = S.seq
	S.busy = true
	publish()

	-- `proc.run("true", ...)` es el único cambio de turno disponible: lanza un
	-- shell trivial y el callback llega con presupuesto de CPU nuevo.
	local function defer(fn)
		proc.run("true", function()
			if token ~= S.seq then
				if cb then
					cb()
				end
				return
			end
			fn()
		end)
	end

	local function fail(message)
		S.phase = "error"
		S.err = message
		S.busy = false
		publish()
		if cb then
			cb()
		end
	end

	proc.run(collect_command(), function(result)
		if token ~= S.seq then
			if cb then
				cb()
			end
			return
		end

		local sections = audio.split_sections(tostring(result.stdout or ""))
		if sections.status == nil or trim(sections.status) == "" then
			fail(tr("service.error.no_backend"))
			return
		end

		local ok, base = pcall(parse_base, sections)
		if not ok then
			noctalia.log("[b3l0w-audio] parse fallo: " .. tostring(base):sub(1, MAX_ERROR_CHARS))
			fail(tostring(base):sub(1, MAX_ERROR_CHARS))
			return
		end

		defer(function()
			local committed, failure = pcall(commit, base)
			if not committed then
				noctalia.log("[b3l0w-audio] commit fallo: " .. tostring(failure):sub(1, MAX_ERROR_CHARS))
				fail(tostring(failure):sub(1, MAX_ERROR_CHARS))
				return
			end

			S.lastRefreshAt = now()

			-- Los detalles (settings de WirePlumber, filtros, equipos BT) van en
			-- una vuelta aparte: son tres procesos más y el refresco normal no
			-- los necesita. Se pide igual en cada vuelta para que la vista de
			-- filtros y la de bluetooth no queden viejas.
			local extra = if bluetooth_present() then extra_command(S.sinks) else nil
			local detail = detail_command()

			-- El resultado del round de detalle SIEMPRE pasa por
			-- `apply_detail`: si no, la vista de filtros y la de bluetooth
			-- se quedan vacías (y con un bluetooth conectado tampoco).
			local function finishDetail(result3)
				if token ~= S.seq then
					if cb then
						cb()
					end
					return
				end
				if result3 ~= nil then
					local detailOk, detailFailure = pcall(apply_detail, audio.split_sections(tostring(result3.stdout or "")))
					if not detailOk then
						noctalia.log("[b3l0w-audio] detail fallo: " .. tostring(detailFailure))
					end
				end
				S.busy = false
				publish()
				if cb then
					cb()
				end
			end

			if extra == nil then
				proc.run(detail, finishDetail)
				return
			end

			proc.run(extra, function(result2)
				if token ~= S.seq then
					if cb then
						cb()
					end
					return
				end
				local extraOk, extraFailure = pcall(apply_extra, audio.split_sections(tostring(result2.stdout or "")))
				if not extraOk then
					noctalia.log("[b3l0w-audio] extra fallo: " .. tostring(extraFailure))
				end
				-- Re-decorar sin volver a leer: la batería y el códec llegaron después.
				decorate(S.sinks, S.cards, "sink")
				decorate(S.sources, S.cards, "source")
				proc.run(detail, finishDetail)
			end)
		end)
	end)
end

-- ── acciones ─────────────────────────────────────────────────────────

local function enqueue(work)
	table.insert(S.queue, work)
end

local function finish()
	S.busy = false
	publish()
	local nextWork = table.remove(S.queue, 1)
	if nextWork ~= nil then
		nextWork()
	end
end

local function run_action(work)
	if S.busy then
		enqueue(function()
			run_action(work)
		end)
		return
	end
	S.busy = true
	publish()
	work(finish)
end

local function rows_of(kind)
	return if kind == "source" then S.sources else S.sinks
end

local function device_of(kind, name)
	for _, row in ipairs(rows_of(kind)) do
		if row.name == name then
			return row
		end
	end
	return nil
end

-- Todas las escrituras: pactl por nombre. Devuelve ok y el detalle para que el
-- panel muestre "no soportado" en vez de un éxito inventado.
local function write(command, cb)
	proc.exit_code(command, function(code, stdout, stderr)
		local detail = trim(stderr)
		if detail == "" then
			detail = trim(stdout)
		end
		if code ~= 0 then
			report(tr("service.error.command", { detail = detail:sub(1, MAX_ERROR_CHARS) }), true)
		end
		cb(code == 0, detail)
	end)
end

local function set_default(kind, name, cb)
	local flag = if kind == "source" then "source" else "sink"
	write("pactl set-default-" .. flag .. " " .. proc.quote(name), function(ok)
		cb(ok)
	end)
end

local function set_volume(kind, name, value, cb)
	local percent = math.max(MIN_VOLUME, math.min(MAX_VOLUME, math.floor(tonumber(value) or 0)))
	local flag = if kind == "source" then "source" else "sink"
	write("pactl set-" .. flag .. "-volume " .. proc.quote(name) .. " " .. tostring(percent) .. "%", function()
		refresh(cb)
	end)
end

local function set_mute(kind, name, muted, cb)
	local flag = if kind == "source" then "source" else "sink"
	write("pactl set-" .. flag .. "-mute " .. proc.quote(name) .. " " .. (muted and "1" or "0"), function()
		refresh(cb)
	end)
end

-- Mute-all con restauración: se guarda el mute de cada dispositivo y "activar
-- todo" devuelve exactamente lo que estaba, no un unmute indiscriminado.
local function mute_all(muted, cb)
	local parts = {}
	if muted then
		S.muteBackup = {}
		for _, row in ipairs(S.sinks) do
			S.muteBackup[row.name] = row.muted
			table.insert(parts, "pactl set-sink-mute " .. proc.quote(row.name) .. " 1")
		end
		for _, row in ipairs(S.sources) do
			S.muteBackup[row.name] = row.muted
			table.insert(parts, "pactl set-source-mute " .. proc.quote(row.name) .. " 1")
		end
	elseif S.muteBackup ~= nil then
		for _, row in ipairs(S.sinks) do
			local was = S.muteBackup[row.name]
			table.insert(parts, "pactl set-sink-mute " .. proc.quote(row.name) .. (was == true and " 1" or " 0"))
		end
		for _, row in ipairs(S.sources) do
			local was = S.muteBackup[row.name]
			table.insert(parts, "pactl set-source-mute " .. proc.quote(row.name) .. (was == true and " 1" or " 0"))
		end
		S.muteBackup = nil
	else
		for _, row in ipairs(S.sinks) do
			table.insert(parts, "pactl set-sink-mute " .. proc.quote(row.name) .. " 0")
		end
	end

	if #parts == 0 then
		cb()
		return
	end
	write(table.concat(parts, "; "), function()
		notify_switch(tr("service.all_devices"), tr(muted and "service.muted" or "service.unmuted"))
		refresh(cb)
	end)
end

-- Perfil de tarjeta y códec bluetooth son el MISMO comando: un códec A2DP es un
-- perfil `a2dp-sink-<codec>`.
--
-- Si el remoto no soporta el perfil, pactl devuelve "No such entity": eso se
-- muestra como "no soportado" en vez de asumir éxito. Si el perfil quedó
-- aplicado pero el nodo renació, se re-afirma el default por nombre.
--
-- REINICIO SEGURO: cambiar el perfil de la tarjeta RECREA el nodo, y en el
-- camino se queda un momento sin audio. Para que el usuario nunca se quede
-- mudo, si la tarjeta que se toca es la del default actual, el default se
-- mueve antes a otro sink disponible (el fallback) y se vuelve a poner al
-- final. Si no hay fallback, se avisa antes de tocar nada.
local function apply_profile_card(card, profile, label, cb)
	if not has("pactl") then
		report(tr("service.error.needs_pactl"), true)
		cb(false)
		return
	end

	local previousDefault = S.defaultSinkName
	local defaultIsThisCard = false
	for _, row in ipairs(S.sinks) do
		if row.name == previousDefault and row.cardId == card.id then
			defaultIsThisCard = true
		end
	end

	-- El fallback: cualquier otro sink que pueda tomar el audio mientras el
	-- nodo se recrea.
	local fallback = nil
	if defaultIsThisCard then
		for _, row in ipairs(S.sinks) do
			if row.name ~= previousDefault then
				fallback = row
			end
		end
		if fallback == nil then
			report(tr("service.error.no_fallback"), true)
			cb(false)
			return
		end
	end

	local function applyNow()
		write("pactl set-card-profile " .. proc.quote(card.name) .. " " .. proc.quote(profile), function(ok, detail)
			if not ok then
				if string.find(string.lower(detail), "no such entity", 1, true) ~= nil then
					report(tr("service.error.unsupported", { codec = label }), true)
				else
					report(tr("service.error.command", { detail = detail:sub(1, MAX_ERROR_CHARS) }), true)
				end
				cb(false)
				return
			end

			refresh(function()
				local active = nil
				for _, entry in ipairs(S.cards) do
					if entry.name == card.name then
						active = entry.activeProfile
					end
				end
				if active ~= profile then
					report(tr("service.error.unsupported", { codec = label }), true)
					cb(false)
					return
				end

				-- Re-afirmar el default si el nodo renació con otra identidad.
				if previousDefault ~= nil and S.defaultSinkName ~= previousDefault then
					set_default("sink", previousDefault, function()
						notify_switch(tr("service.profile"), label)
						refresh(cb)
					end)
					return
				end
				notify_switch(tr("service.profile"), label)
				cb(true)
			end)
		end)
	end

	if fallback ~= nil then
		-- Primero el fallback: el audio sigue saliendo mientras el nodo del
		-- dispositivo viejo se va.
		set_default("sink", fallback.name, function()
			applyNow()
		end)
		return
	end

	applyNow()
end

local function set_stream_volume(streamId, value, cb)
	local percent = math.max(MIN_VOLUME, math.min(MAX_VOLUME, math.floor(tonumber(value) or 0)))
	write("pactl set-sink-input-volume " .. tostring(streamId) .. " " .. tostring(percent) .. "%", function()
		refresh(cb)
	end)
end

-- El perfil configurado por el usuario (`default_profile`). Es el que se
-- aplica al cambiar de salida: fija el rol del stream y el sample rate.
local function configured_profile(): string
	local value = tostring(cfg("default_profile") or "music")
	if value == "telephony" or value == "hires" or value == "music" then
		return value
	end
	return "music"
end

-- ── volumen por canal y balance ──────────────────────────────────────

-- `pactl set-sink-volume SINK V1 V2…` aplica un volumen POR CANAL, en el
-- orden del channel map del sink (front-left, front-right…). Por eso el
-- valor se manda como lista y no como un número suelto.
--
-- El balance se traduce a dos volúmenes: con balance 0.5 el canal derecho
-- queda al 100% y el izquierdo al 50% del máximo. Es la misma cuenta que
-- hace PulseAudio, y el resultado se ve en `pactl list sinks` (balance).
local function set_channel_volume(kind, name, channelIndex, value, cb)
	local row = device_of(kind, name)
	if row == nil then
		report(tr("service.error.unknown_device"), true)
		cb()
		return
	end

	local channels = row.channels or {}
	if #channels == 0 then
		report(tr("service.error.no_channels"), true)
		cb()
		return
	end

	local target = math.floor(tonumber(channelIndex) or 0)
	if target < 1 or target > #channels then
		report(tr("service.error.unknown_channel"), true)
		cb()
		return
	end

	local percent = math.max(MIN_VOLUME, math.min(MAX_VOLUME, math.floor(tonumber(value) or 0)))
	local parts = {}
	for index, channel in ipairs(channels) do
		local amount = if index == target then percent else (tonumber(channel.percent) or 0)
		table.insert(parts, tostring(amount) .. "%")
	end

	local flag = if kind == "source" then "source" else "sink"
	write("pactl set-" .. flag .. "-volume " .. proc.quote(name) .. " " .. table.concat(parts, " "), function()
		refresh(cb)
	end)
end

-- El balance va de -1 (izquierda) a 1 (derecha). Se aplica sobre el volumen
-- MÁXIMO de los canales, así el balance no baja el nivel general.
local function set_balance(kind, name, value, cb)
	local row = device_of(kind, name)
	if row == nil then
		report(tr("service.error.unknown_device"), true)
		cb()
		return
	end

	local channels = row.channels or {}
	if #channels < 2 then
		report(tr("service.error.no_channels"), true)
		cb()
		return
	end

	local balance = tonumber(value) or 0
	balance = math.max(-1, math.min(1, balance))

	local maximo = 0
	for _, channel in ipairs(channels) do
		maximo = math.max(maximo, tonumber(channel.percent) or 0)
	end
	if maximo <= 0 then
		maximo = 100
	end

	local left = maximo
	local right = maximo
	if balance > 0 then
		left = math.floor(maximo * (1 - balance) + 0.5)
	elseif balance < 0 then
		right = math.floor(maximo * (1 + balance) + 0.5)
	end

	-- El primer canal es el izquierdo en un sink estéreo: se usa el channel
	-- map del dispositivo para no asumir el orden.
	local parts = {}
	for index, _ in ipairs(channels) do
		local name = string.lower(tostring(channels[index].name or ""))
		local amount = maximo
		if string.find(name, "left", 1, true) ~= nil then
			amount = left
		elseif string.find(name, "right", 1, true) ~= nil then
			amount = right
		end
		table.insert(parts, tostring(amount) .. "%")
	end

	local flag = if kind == "source" then "source" else "sink"
	write("pactl set-" .. flag .. "-volume " .. proc.quote(name) .. " " .. table.concat(parts, " "), function()
		notify_switch(tr("service.balance"), tostring(math.floor(balance * 100) / 100))
		refresh(cb)
	end)
end

-- ── perfiles de audio ────────────────────────────────────────────────

-- Los perfiles son el par (rol de stream, sample rate):
--
--   music    → role "Music",    rate 48000, códec de música (SBC/LDAC/aptX)
--   telephony→ role "Phone",    rate 16000, códec de voz (mSBC/CVSD)
--   hires    → role "Music",    rate 96000, códec hi-res (LDAC/aptX HD)
--
-- El rate se aplica con `pactl set-sink-formats` (que es el verbo estándar
-- de PulseAudio para el sample rate del sink). El backend puede rechazarlo
-- (un sink ALSA no cambia de rate en caliente): en ese caso se informa y se
-- deja el valor real que publica el backend.
local PROFILES = {
	music = { role = "Music", rate = 48000, label = "service.profile_music" },
	telephony = { role = "Phone", rate = 16000, label = "service.profile_telephony" },
	hires = { role = "Music", rate = 96000, label = "service.profile_hires" },
}

-- El códec que corresponde al perfil, según lo que el dispositivo ofrezca.
-- Se busca el mejor disponible: hi-res → LDAC/aptX HD → música → voz.
local function codec_for_profile(card, profileName): string?
	local codecs = audio.codec_profiles(card)
	local function find(patterns)
		for _, entry in ipairs(codecs) do
			local raw = string.lower(tostring(entry.name or ""))
			for _, pattern in ipairs(patterns) do
				if string.find(raw, pattern, 1, true) ~= nil then
					return entry.name
				end
			end
		end
		return nil
	end

	if profileName == "telephony" then
		return find({ "msbc" }) or find({ "headset-head-unit" })
	elseif profileName == "hires" then
		return find({ "ldac" }) or find({ "aptx_hd" }) or find({ "sbc_xq" }) or find({ "aptx" })
	else
		return find({ "sbc_xq" }) or find({ "a2dp-sink" })
	end
end

-- El perfil cambia el rol de stream del source y el sample rate del sink.
-- El rol se escribe con `wpctl settings node.stream.default-media-role`, que
-- es el verbo de WirePlumber para el rol por defecto de los streams.
local function apply_profile(profileName, cb)
	local profile = PROFILES[profileName]
	if profile == nil then
		report(tr("service.error.unknown_profile"), true)
		cb()
		return
	end

	S.audioProfile = profileName
	S.rateRequested = profile.rate

	-- 1. El rol del stream. `wpctl settings` es el camino real: el daemon
	--    guarda el rol por defecto de los streams nuevos.
	write("wpctl settings node.stream.default-media-role " .. profile.role, function(ok, detail)
		if not ok then
			noctalia.log("[b3l0w-audio] rol: " .. tostring(detail):sub(1, MAX_ERROR_CHARS))
		end

		-- 2. El sample rate del sink actual. Se pide por el índice de
		--    pactl: `set-sink-formats` sólo acepta índice, no nombre.
		local sink = nil
		for _, row in ipairs(S.sinks) do
			if row.active then
				sink = row
			end
		end

		if sink == nil then
			report(tr("service.profile_applied", {
				profile = tr(profile.label),
				rate = tostring(profile.rate),
			}), false)
			refresh(cb)
			return
		end

		-- `set-sink-formats` espera un ENCODING, no un sample format. Los
		-- válidos son pcm, ac3-iec61937, eac3-iec61937, mpeg, dts-iec61937,
		-- aac-adts. `sink.encoding` es "s32le"/"s16le" (el formato de muestra)
		-- y PipeWire lo rechaza: `invalid format string s32le, ...`. Probado
		-- contra el sink real: con `pcm` el cambio se acepta.
		-- `format.rate` acepta una lista de rates: se pide sólo el del perfil
		-- para que el sink negocie ése.
		local formats = 'pcm, format.rate = "[' .. tostring(profile.rate) .. ']"'
		write("pactl set-sink-formats " .. tostring(sink.index) .. " '" .. formats .. "'", function(rateOk, rateDetail)
			if not rateOk then
				-- El backend puede no soportar el cambio en caliente: se
				-- informa con el rate REAL que quedó, no con el pedido.
				noctalia.log("[b3l0w-audio] rate: " .. tostring(rateDetail):sub(1, MAX_ERROR_CHARS))
			end
			refresh(function()
				-- El commit ya dejó `rateActual` con el valor REAL del backend
				-- (el que quedó después del pedido, no el pedido).
				local actual = S.rateActual
				report(tr("service.profile_applied", {
					profile = tr(profile.label),
					rate = tostring(actual > 0 and actual or profile.rate),
				}), false)
				refresh(cb)
			end)
		end)
	end)
end

-- El códec del perfil, sobre el dispositivo elegido.
local function apply_profile_codec(profileName, cardName, cb)
	local card = nil
	for _, entry in ipairs(S.cards) do
		if entry.name == cardName then
			card = entry
		end
	end
	if card == nil then
		report(tr("service.error.unknown_device"), true)
		cb()
		return
	end

	local profile = PROFILES[profileName]
	local wanted = codec_for_profile(card, profileName)
	if wanted == nil then
		report(tr("service.error.unsupported", { codec = tr(profile.label) }), true)
		cb()
		return
	end

	apply_profile(profileName, function()
		local target = nil
		for _, entry in ipairs(S.cards) do
			if entry.name == cardName then
				target = entry
			end
		end
		if target == nil then
			cb()
			return
		end
		local label = audio.codec_label(wanted) or wanted
		apply_profile_card(target, wanted, label, cb)
	end)
end

-- ── filtros de WirePlumber ───────────────────────────────────────────

-- `wpctl settings <id> <valor>` habilita y deshabilita los módulos de
-- filtro de WirePlumber (no-dsp, mono, autoswitch a HSP…). Es el verbo
-- real del daemon: los settings son Boolean y se escriben por id.
local function set_module(moduleId, value, cb)
	local id = tostring(moduleId or "")
	if id == "" then
		report(tr("service.error.unknown_module"), true)
		cb()
		return
	end

	local wanted = if value == true or value == "true" then "true" else "false"
	write("wpctl settings " .. proc.quote(id) .. " " .. wanted, function(ok, detail)
		if not ok then
			report(tr("service.error.module_failed", { detail = tostring(detail):sub(1, MAX_ERROR_CHARS) }), true)
			cb()
			return
		end
		report(tr("service.module_set", { id = id, value = wanted }), false)
		refresh(cb)
	end)
end

-- ── bluetooth ────────────────────────────────────────────────────────

local function bt_action(mac, verb, cb)
	local address = tostring(mac or "")
	if address == "" then
		report(tr("service.error.unknown_device"), true)
		cb()
		return
	end
	write("bluetoothctl " .. verb .. " " .. proc.quote(address), function(ok, detail)
		if not ok then
			report(tr("service.error.bt_failed", { detail = tostring(detail):sub(1, MAX_ERROR_CHARS) }), true)
			cb()
			return
		end
		report(tr("service.bt_done", { verb = verb }), false)
		refresh(cb)
	end)
end

local function move_stream(streamId, sinkName, cb)
	write("pactl move-sink-input " .. tostring(streamId) .. " " .. proc.quote(sinkName), function()
		refresh(cb)
	end)
end

-- Mover TODOS los streams puede cambiar la salida por defecto (WirePlumber
-- sigue al stream), así que después se re-afirma el default que había.
local function move_streams(sink, cb)
	local parts = {}
	for _, stream in ipairs(S.streams) do
		if stream.sink ~= sink.index then
			table.insert(parts, "pactl move-sink-input " .. tostring(stream.id) .. " " .. proc.quote(sink.name))
		end
	end
	if #parts == 0 then
		report(tr("service.nothing_to_move"), false)
		cb()
		return
	end
	local previousDefault = S.defaultSinkName
	write(table.concat(parts, "; "), function()
		local after = function()
			refresh(function()
				notify_switch(tr("service.streams"), tr("service.moved", { count = tostring(#parts) }))
				cb()
			end)
		end
		if previousDefault ~= nil and previousDefault ~= sink.name then
			set_default("sink", previousDefault, after)
			return
		end
		after()
	end)
end

local function cycle(kind, cb)
	local rows = rows_of(kind)
	if #rows < 2 then
		report(tr("service.only_one"), false)
		cb()
		return
	end
	local current = 1
	for index, row in ipairs(rows) do
		if row.active then
			current = index
		end
	end
	local nextRow = rows[(current % #rows) + 1]
	set_default(kind, nextRow.name, function()
		notify_switch(tr(if kind == "source" then "service.input" else "service.output"), nextRow.description)
		refresh(cb)
	end)
end

local function bump_volume(delta, cb)
	local step = setting_number("volume_step", DEFAULT_STEP, 1, 25)
	-- El signo va DELANTE: `5%+` lo rechaza pactl ("Invalid volume
	-- specification"), `+5%` es la forma válida. Con el signo atrás la rueda
	-- del widget no subía ni bajaba el volumen.
	local sign = if delta > 0 then "+" else "-"
	write("pactl set-sink-volume @DEFAULT_SINK@ " .. sign .. tostring(step) .. "%", function()
		refresh(cb)
	end)
end

-- Pin del default: WirePlumber lo respeta y no roba la salida al conectar un
-- bluetooth. Vive en pw-metadata, no en el plugin, así sobrevive al reinicio.
local function pin_default(name, cb)
	local safe = string.gsub(tostring(name), '["\\]', "")
	local command = "pw-metadata -n default 0 default.configured.audio.sink '{\"name\":\"" .. safe .. "\"}'"
	write(command, function()
		report(tr("service.pinned", { name = tostring(name) }), false)
		refresh(cb)
	end)
end

local function unpin_default(cb)
	write("pw-metadata -n default -d 0 default.configured.audio.sink", function()
		report(tr("service.unpinned"), false)
		refresh(cb)
	end)
end

-- ── despacho ─────────────────────────────────────────────────────────

-- Despacho por tabla con claves literales: el contrato entre panel y service
-- queda en un solo bloque y el auditor compara cada `action =` del panel contra
-- estas claves.
local ACTIONS = {
	["refresh"] = function(_req, done)
		refresh(done)
	end,

	["set_default"] = function(req, done)
		local kind = req.kind == "source" and "source" or "sink"
		local row = device_of(kind, tostring(req.name or ""))
		if row == nil then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		set_default(kind, row.name, function()
			notify_switch(tr(if kind == "source" then "service.input" else "service.output"), row.description)
			-- El perfil configurado se aplica al cambiar de salida: fija el rol
			-- del stream y el sample rate del sink nuevo. Sólo si es DISTINTO
			-- del activo, para no pedir un rate que ya está puesto.
			if kind == "sink" and S.audioProfile ~= configured_profile() then
				apply_profile(configured_profile(), function()
					refresh(done)
				end)
				return
			end
			refresh(done)
		end)
	end,

	["set_volume"] = function(req, done)
		local kind = req.kind == "source" and "source" or "sink"
		local row = device_of(kind, tostring(req.name or ""))
		if row == nil then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		set_volume(kind, row.name, req.value, done)
	end,

	["toggle_mute"] = function(req, done)
		local kind = req.kind == "source" and "source" or "sink"
		local row = device_of(kind, tostring(req.name or ""))
		if row == nil then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		set_mute(kind, row.name, not row.muted, done)
	end,

	["mute_all"] = function(req, done)
		local muted = if req.muted ~= nil then req.muted == true else not all_muted()
		mute_all(muted, done)
	end,

	["set_codec"] = function(req, done)
		local profile = tostring(req.profile or "")
		local card = nil
		for _, entry in ipairs(S.cards) do
			if entry.name == tostring(req.card or "") then
				card = entry
			end
		end
		if card == nil or profile == "" then
			report(tr("service.error.unknown_codec"), true)
			done()
			return
		end
		apply_profile_card(card, profile, audio.codec_label(profile) or profile, done)
	end,

	["set_profile"] = function(req, done)
		local profile = tostring(req.profile or "")
		local card = nil
		for _, entry in ipairs(S.cards) do
			if entry.name == tostring(req.card or "") then
				card = entry
			end
		end
		if card == nil or profile == "" then
			report(tr("service.error.unknown_profile"), true)
			done()
			return
		end
		local label = profile
		for _, entry in ipairs(card.profiles) do
			if entry.name == profile then
				label = entry.description
			end
		end
		apply_profile_card(card, profile, label, done)
	end,

	-- ── perfiles de audio (música / telephonía / Hi-Res) ──────────────

	["apply_profile"] = function(req, done)
		apply_profile(tostring(req.profile or ""), done)
	end,

	-- El perfil PLUS el códec que le corresponde en el dispositivo.
	["apply_profile_codec"] = function(req, done)
		apply_profile_codec(tostring(req.profile or ""), tostring(req.card or ""), done)
	end,

	-- ── volumen por canal y balance ───────────────────────────────────

	["set_channel_volume"] = function(req, done)
		local kind = req.kind == "source" and "source" or "sink"
		local row = device_of(kind, tostring(req.name or ""))
		if row == nil then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		set_channel_volume(kind, row.name, req.channel, req.value, done)
	end,

	["set_balance"] = function(req, done)
		local kind = req.kind == "source" and "source" or "sink"
		local row = device_of(kind, tostring(req.name or ""))
		if row == nil then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		set_balance(kind, row.name, req.value, done)
	end,

	-- ── filtros de WirePlumber ────────────────────────────────────────

	["set_module"] = function(req, done)
		set_module(req.id, req.value, done)
	end,

	-- ── bluetooth ─────────────────────────────────────────────────────

	["bt_connect"] = function(req, done)
		bt_action(req.mac, "connect", done)
	end,

	["bt_disconnect"] = function(req, done)
		bt_action(req.mac, "disconnect", done)
	end,

	["set_stream_volume"] = function(req, done)
		local streamId = tonumber(req.stream)
		if streamId == nil then
			report(tr("service.error.unknown_stream"), true)
			done()
			return
		end
		set_stream_volume(streamId, req.value, done)
	end,

	["move_stream"] = function(req, done)
		local streamId = tonumber(req.stream)
		local sink = device_of("sink", tostring(req.sink or ""))
		if streamId == nil or sink == nil then
			report(tr("service.error.unknown_stream"), true)
			done()
			return
		end
		move_stream(streamId, sink.name, function()
			notify_switch(tr("service.streams"), sink.description)
			done()
		end)
	end,

	["move_streams"] = function(req, done)
		local sink = device_of("sink", tostring(req.sink or ""))
		if sink == nil then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		move_streams(sink, done)
	end,

	["pin_default"] = function(req, done)
		local name = tostring(req.name or "")
		if name == "" then
			report(tr("service.error.unknown_device"), true)
			done()
			return
		end
		pin_default(name, done)
	end,

	["unpin_default"] = function(_req, done)
		unpin_default(done)
	end,

	["cycle_output"] = function(_req, done)
		cycle("sink", done)
	end,

	["cycle_input"] = function(_req, done)
		cycle("source", done)
	end,

	["volume_up"] = function(_req, done)
		bump_volume(1, done)
	end,

	["volume_down"] = function(_req, done)
		bump_volume(-1, done)
	end,

	["open_settings"] = function(_req, done)
		noctalia.openSettings()
		done()
	end,
}

local function handle(req)
	if type(req) ~= "table" then
		return
	end

	local nonce = tostring(req.nonce or "")
	if nonce ~= "" then
		if nonce == S.lastNonce then
			return
		end
		S.lastNonce = nonce
	end

	local action = tostring(req.action or "")
	local handler = ACTIONS[action]
	if handler == nil then
		noctalia.log("[b3l0w-audio] accion desconocida: " .. action)
		noctalia.notifyError(tr("plugin.title"), tr("panel.unknown_action", { action = action }))
		return
	end

	S.lastAction = action
	report(nil, false)
	run_action(function(done)
		handler(req, done)
	end)
end

noctalia.state.watch(REQUEST_KEY, handle)

-- ── eventos ──────────────────────────────────────────────────────────

-- `pactl subscribe` avisa de cada cambio real (tecla de volumen, otro cliente,
-- un dispositivo que aparece). Se debounce porque un solo cambio de sink emite
-- varias líneas seguidas y cada una sería una vuelta de shell.
local function on_event(line)
	local event = audio.parse_event(line)
	if event == nil then
		return
	end
	if event.facility == "sink" or event.facility == "source" or event.facility == "sink-input"
		or event.facility == "card" or event.facility == "server" then
		S.pendingRefreshAt = now_ms() + DEBOUNCE_MS
	end
end

local function subscribe()
	if not has("pactl") then
		return
	end
	local ok = noctalia.runStream("pactl subscribe 2>/dev/null", on_event)
	S.subscribed = ok == true
	noctalia.log("[b3l0w-audio] pactl subscribe: " .. tostring(S.subscribed))
end

-- ── persistencia ─────────────────────────────────────────────────────

local function save_snapshot()
	store.save(SNAPSHOT_FILE, {
		version = SNAPSHOT_VERSION,
		sinks = S.sinks,
		sources = S.sources,
		defaultSinkName = S.defaultSinkName,
		defaultSourceName = S.defaultSourceName,
		at = S.at,
	})
end

local function load_snapshot()
	local data = store.load(SNAPSHOT_FILE)
	if type(data) ~= "table" or data.version ~= SNAPSHOT_VERSION then
		return
	end
	if type(data.sinks) == "table" then
		S.sinks = data.sinks
	end
	if type(data.sources) == "table" then
		S.sources = data.sources
	end
	S.defaultSinkName = data.defaultSinkName
	S.defaultSourceName = data.defaultSourceName
	S.at = tonumber(data.at) or 0
end

-- ── ciclo de vida ────────────────────────────────────────────────────

function update()
	if S.busy then
		return
	end

	local seconds = setting_number("refresh_seconds", DEFAULT_REFRESH_SECONDS, 2, 120)

	if S.pendingRefreshAt ~= nil and now_ms() >= S.pendingRefreshAt then
		S.pendingRefreshAt = nil
		refresh(function()
			save_snapshot()
		end)
		return
	end

	if now() - S.lastRefreshAt >= seconds then
		refresh(function()
			save_snapshot()
		end)
	end
end

function onEnable()
	if not has("pactl") then
		S.phase = "error"
		S.err = tr("service.error.needs_pactl")
		publish()
		return
	end
	S.phase = "loading"
	publish()
	subscribe()
	refresh(function()
		save_snapshot()
	end)
end

function onConfigChanged()
	publish()
end

function onIpc(event, payload)
	local req = nil
	if type(payload) == "table" then
		req = payload
	elseif type(payload) == "string" and payload ~= "" then
		local decoded = noctalia.json.decode(payload)
		if type(decoded) == "table" then
			req = decoded
		end
	end
	if req == nil then
		req = {}
	end
	req.action = req.action or event
	handle(req)
end

load_snapshot()
publish()
noctalia.setUpdateInterval(1000)
