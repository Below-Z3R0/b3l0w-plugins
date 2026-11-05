--!nonstrict
-- Widget de barra: ícono del estado real del audio.
--
--   silencio total      → volume-x
--   auricular bluetooth → headphones
--   resto               → volume-2
--
--   click izq: abrir/cerrar el panel (compacto o flotante según panel_mode)
--   click der: siguiente salida
--   rueda:     volumen del sink por defecto (setting volume_step)
--
-- Nunca lanza un comando: lee lo que publica el service y le manda requests.

local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")

local STATE_KEY = "b3l0w_audio_state"
local REQUEST_KEY = "b3l0w_audio_request"
local PLUGIN = "b3l0w/audio"

local SNAP = { state = nil }
local requests = 0
local lastSignature = ""

local function stateTable()
	local cached = SNAP.state
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATE_KEY)
	return type(value) == "table" and value or {}
end

local function send(payload)
	requests = requests + 1
	payload.nonce = tostring(math.floor(os.clock() * 1000)) .. ":" .. tostring(requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

local function defaultRow(state, kind)
	local rows = if kind == "source" then (state.sources or {}) else (state.sinks or {})
	local name = if kind == "source" then state.defaultSourceName else state.defaultSinkName
	for _, row in ipairs(rows) do
		if row.active == true then
			return row
		end
	end
	for _, row in ipairs(rows) do
		if name ~= nil and row.name == name then
			return row
		end
	end
	return nil
end

local function percent(value)
	return tostring(math.floor((tonumber(value) or 0) + 0.5)) .. "%"
end

local function paint()
	local state = stateTable()
	local out = defaultRow(state, "sink")
	local input = defaultRow(state, "source")
	local muted = state.allMuted == true or (out ~= nil and out.muted == true)
	local volume = out ~= nil and tonumber(out.volume) or 0

	local glyph = "volume-2"
	if muted then
		glyph = "volume-x"
	elseif out ~= nil and out.bluetooth == true then
		glyph = "headphones"
	end

	local signature = glyph .. "/" .. tostring(volume) .. "/" .. tostring(state.phase)
		.. "/def=" .. tostring(state.defaultSinkName)
	if signature ~= lastSignature then
		lastSignature = signature
		noctalia.log("[b3l0w-audio-widget] " .. signature)
	end

	barWidget.setGlyph(glyph)
	-- El estado que quedó de la corrida anterior puede traer phase="error"
	-- de un fallo viejo. Al arrancar, el widget pinta antes de que el
	-- service publique y la barra muestra el ícono de error aunque todo
	-- esté bien. Un estado con `at` viejo no es un error actual.
	local stale = tonumber(state.at) ~= nil and (os.time() - tonumber(state.at)) > 90
	if state.phase == "error" and not stale then
		barWidget.setGlyphColor("error")
	elseif muted then
		barWidget.setGlyphColor(theme.warn())
	elseif state.phase == "loading" then
		barWidget.setGlyphColor("secondary")
	else
		barWidget.setGlyphColor("primary")
	end

	local showPercentage = noctalia.getConfig("show_percentage")
	local text = ""
	if prefs.show_label() and showPercentage ~= false and not barWidget.isVertical() then
		text = percent(volume)
	end
	barWidget.setText(text)

	local rows = {
		{
			key = noctalia.tr("widget.output"),
			value = (out ~= nil and tostring(out.description or out.name) or noctalia.tr("panel.no_output"))
				.. " (" .. percent(volume) .. ")",
		},
		{
			key = noctalia.tr("widget.input"),
			value = input ~= nil
					and (tostring(input.description or input.name) .. " (" .. percent(input.volume) .. ")")
				or noctalia.tr("panel.no_input"),
		},
	}
	if out ~= nil and type(out.codec) == "string" and out.codec ~= "" then
		table.insert(rows, { key = noctalia.tr("widget.codec"), value = string.upper(out.codec) })
	end
	if out ~= nil and tonumber(out.battery) ~= nil then
		table.insert(rows, { key = noctalia.tr("widget.battery"), value = percent(out.battery) })
	end
	table.insert(rows, { key = "", value = noctalia.tr("widget.hint") })
	barWidget.setTooltip(rows)
end

function onClick()
	noctalia.togglePanel(prefs.panel_id(PLUGIN))
end

function onRightClick()
	send({ action = "cycle_output" })
end

-- `steps` es positivo al subir la rueda. El paso real lo aplica el service con
-- el setting `volume_step`, acá sólo se manda la dirección.
function onScroll(_axis, steps, _startsGesture)
	if tonumber(steps) == nil or tonumber(steps) == 0 then
		return
	end
	send({ action = if (tonumber(steps) or 0) > 0 then "volume_up" else "volume_down" })
end

noctalia.state.watch(STATE_KEY, function(value)
	SNAP.state = value
	paint()
end)

function update()
	paint()
end

function onConfigChanged()
	paint()
end

noctalia.setUpdateInterval(60000)

SNAP.state = noctalia.state.get(STATE_KEY)
paint()
