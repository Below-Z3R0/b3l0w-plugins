--!nonstrict
-- Widget de barra: estado de Tailscale y Sunshine con el contador de pares
-- online. Nunca corre un comando: lee lo que publica el service.
--
--   click izq: abrir/cerrar el panel (compacto o flotante según panel_mode)
--   click der: poll inmediato (status + log + puertos)

local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")

local STATE_KEY = "b3l0w_net_state"
local STATUS_KEY = "b3l0w_net_status"
local REQUEST_KEY = "b3l0w_net_request"
local PLUGIN = "b3l0w/net"

local requests = 0

local SNAP = { state = nil, status = nil }

local function stateTable(): table
	local cached = SNAP.state
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATE_KEY)
	return if type(value) == "table" then value else {}
end

local function statusTable(): table
	local cached = SNAP.status
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATUS_KEY)
	return if type(value) == "table" then value else {}
end

local function send(payload)
	-- Contador monotónico propio: leer el nonce anterior con tonumber() no
	-- funciona porque el nonce es "segundos:contador" y tonumber() de eso
	-- devuelve nil → el contador quedaba en 0 y dos requests seguidos
	-- tenían el mismo nonce (el service descartaba el segundo).
	--
	-- `os.clock()` tampoco sirve como reloj: es tiempo de CPU, se congela
	-- cuando el proceso no consume CPU.
	requests += 1
	payload.nonce = tostring(requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "wifi"
end

local function subTable(source: table, key: string): table
	local value = source[key]
	return if type(value) == "table" then value else {}
end

local function tsLabel(ts: table): string
	if ts.err ~= nil then
		return tostring(ts.err)
	end
	local counts = subTable(ts, "counts")
	return noctalia.tr("widget.ts_value", {
		backend = tostring(ts.backend or "—"),
		online = tostring(tonumber(counts.online) or 0),
		total = tostring(tonumber(counts.total) or 0),
	})
end

local function sunLabel(sun: table): string
	local ports = subTable(sun, "ports")
	return noctalia.tr("widget.sun_value", {
		state = tostring(sun.state or "—"),
		ports = tostring(tonumber(ports.count) or 0),
		http = (if tostring(sun.http or "") ~= "" then tostring(sun.http) else "—"),
	})
end

local lastSignature = ""

local function paint()
	local state = stateTable()
	local status = statusTable()
	local ts = subTable(state, "ts")
	local sun = subTable(state, "sun")
	local counts = subTable(ts, "counts")
	local online = tonumber(counts.online) or 0
	local total = tonumber(counts.total) or 0
	local relayed = tonumber(counts.relayed) or 0
	local tsOnline = ts.running == true or ts.backend == "Running"
	local failed = sun.failed == true

	-- Traza sólo cuando cambia la firma: es la forma de verificar que el widget
	-- corre con datos sin mirar la barra.
	local signature = tostring(ts.backend) .. "/" .. tostring(online) .. "/" .. tostring(total)
		.. "/relayed=" .. tostring(relayed) .. "/sun=" .. tostring(sun.state)
	if signature ~= lastSignature then
		lastSignature = signature
		noctalia.log("[b3l0w-net-widget] " .. signature)
	end

	if not tsOnline then
		barWidget.setGlyph("wifi-off")
		barWidget.setGlyphColor("error")
	elseif failed then
		barWidget.setGlyph("alert-triangle")
		barWidget.setGlyphColor(theme.danger())
	elseif relayed > 0 then
		barWidget.setGlyph("world")
		barWidget.setGlyphColor(theme.warn())
	elseif sun.state == "active" then
		barWidget.setGlyph(glyphName())
		barWidget.setGlyphColor(theme.ok())
	else
		barWidget.setGlyph(glyphName())
		barWidget.setGlyphColor("on_surface_variant")
	end

	local text = ""
	if prefs.show_label() then
		if not tsOnline then
			text = noctalia.tr("widget.offline")
		else
			text = tostring(online)
		end
	end
	barWidget.setText(text)
	barWidget.setVisible(noctalia.getConfig("hide_when_offline") ~= true or tsOnline)

	local rows = {
		{ key = noctalia.tr("widget.tooltip.ts"), value = tsLabel(ts) },
		{ key = noctalia.tr("widget.tooltip.sun"), value = sunLabel(sun) },
	}
	if relayed > 0 then
		table.insert(rows, {
			key = noctalia.tr("widget.tooltip.relay"),
			value = noctalia.trp("count.relayed", relayed),
		})
	end
	-- La conexión del NODO LOCAL: si esta máquina también va por DERP, el
	--Icono del widget no lo delata y la latencia parece del peer.
	local self_node = subTable(ts, "self")
	if self_node.direct == false and tostring(self_node.relay or "") ~= "" then
		table.insert(rows, {
			key = noctalia.tr("widget.tooltip.local_relay"),
			value = tostring(self_node.relay),
		})
	end
	-- Avisos de salud del nodo local (reloj, DNS, permisos).
	local health = subTable(self_node, "health")
	if #health > 0 then
		local parts = {}
		for _, entry in ipairs(health) do
			table.insert(parts, tostring(entry))
		end
		table.insert(rows, {
			key = noctalia.tr("widget.tooltip.health"),
			value = table.concat(parts, ", "),
		})
	end
	-- Sunshine: si no hay ninguna conexión establecida, no hay cliente.
	if sun.state == "active" and (tonumber(sun.established) or 0) == 0 then
		table.insert(rows, {
			key = noctalia.tr("widget.tooltip.sun_no_client"),
			value = noctalia.tr("widget.tooltip.sun_no_client_v"),
		})
	end
	if status.busy == true then
		table.insert(rows, { key = "", value = noctalia.tr("widget.tooltip.busy") })
	end
	table.insert(rows, { key = "", value = noctalia.tr("widget.tooltip.hint") })
	barWidget.setTooltip(rows)
end

function onClick()
	noctalia.togglePanel(prefs.panel_id(PLUGIN))
end

function onRightClick()
	send({ action = "refresh" })
end

noctalia.state.watch(STATE_KEY, function(value)
	SNAP.state = value
	paint()
end)

noctalia.state.watch(STATUS_KEY, function(value)
	SNAP.status = value
	paint()
end)

-- Red de seguridad para cambios de ajustes; el watch es el camino real.
function update()
	paint()
end

noctalia.setUpdateInterval(60000)

SNAP.state = noctalia.state.get(STATE_KEY)
SNAP.status = noctalia.state.get(STATUS_KEY)
paint()
