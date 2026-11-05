--!nonstrict
-- Widget de barra: cuenta de vulnerabilidades coloreada por la peor severidad.
-- Nunca corre un comando: lee lo que publica el service.
--
--   click izq: abrir/cerrar el panel (compacto o flotante según panel_mode)
--   click der: chequeo completo ahora

local audit = require("./lib/audit.luau")
local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")

local STATE_KEY = "b3l0w_audit_state"
local UPDATES_KEY = "b3l0w_audit_updates"
local REQUEST_KEY = "b3l0w_audit_request"
local PLUGIN = "b3l0w/audit"

local requests = 0

local SNAP = { state = nil, updates = nil }

local function stateTable()
	local cached = SNAP.state
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATE_KEY)
	return type(value) == "table" and value or {}
end

local function updatesTable()
	local cached = SNAP.updates
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(UPDATES_KEY)
	return type(value) == "table" and value or {}
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

local function glyphName()
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "shield-exclamation"
end

local function isClean(state)
	return state.phase == "clean" and state.binaryMissing ~= true and state.err == nil
end

local function countsLabel(state)
	local counts = state.counts or {}
	local parts = {}
	for _, severity in ipairs(audit.SEVERITIES) do
		local count = tonumber(counts[severity]) or 0
		if count > 0 then
			table.insert(parts, tostring(count) .. " " .. noctalia.tr("severity." .. severity):lower())
		end
	end
	if #parts == 0 then
		return noctalia.tr("widget.counts_none")
	end
	return table.concat(parts, " · ")
end

local function updatesLabel(updates)
	local noctaliaCount = tonumber((updates.noctalia or {}).pending) or 0
	local umbrielCount = tonumber((updates.umbriel or {}).pending) or 0
	local cli = type(updates.cli) == "table" and updates.cli or {}
	local cliText = if cli.stale == true then noctalia.tr("panel.cli.stale") else noctalia.tr("panel.cli.fresh")
	return noctalia.tr("widget.updates_value", {
		noctalia = tostring(noctaliaCount),
		umbriel = tostring(umbrielCount),
		cli = cliText,
	})
end

local lastSignature = ""

local function paint()
	local state = stateTable()
	local updates = updatesTable()
	local total = tonumber(state.total) or 0
	local broken = state.binaryMissing == true or state.err ~= nil
	local cliStale = type(updates.cli) == "table" and updates.cli.stale == true

	-- Traza sólo cuando cambia la firma: es la forma de verificar que el
	-- widget corre con datos sin mirar la barra.
	local signature = tostring(total) .. "/" .. tostring(state.severity) .. "/" .. tostring(state.phase)
		.. "/updates=" .. tostring(tonumber(updates.total) or 0) .. "/cli_stale=" .. tostring(cliStale)
	if signature ~= lastSignature then
		lastSignature = signature
		noctalia.log("[b3l0w-audit-widget] " .. signature)
	end

	barWidget.setGlyph(if broken then "shield-x" elseif isClean(state) then "shield-check" else glyphName())

	if broken then
		barWidget.setGlyphColor("error")
	elseif state.phase == "checking" then
		barWidget.setGlyphColor(theme.warn())
	elseif total > 0 then
		barWidget.setGlyphColor(audit.severity_color(state.severity))
	elseif isClean(state) then
		barWidget.setGlyphColor(theme.ok())
	else
		barWidget.setGlyphColor("on_surface_variant")
	end

	local text = ""
	if prefs.show_label() then
		if total > 0 then
			text = tostring(total)
		elseif broken then
			text = "!"
		end
	end
	barWidget.setText(text)

	local hide = noctalia.getConfig("hide_when_clean") == true
	barWidget.setVisible(not (hide and isClean(state)))

	local rows = {
		{ key = noctalia.tr("widget.tooltip.state"), value = countsLabel(state) },
		{ key = noctalia.tr("widget.tooltip.updates"), value = updatesLabel(updates) },
	}
	if (tonumber(state.newCount) or 0) > 0 then
		table.insert(rows, {
			key = noctalia.tr("widget.tooltip.new"),
			value = noctalia.trp("count.new", state.newCount),
		})
	end
	table.insert(rows, {
		key = noctalia.tr("widget.tooltip.checked"),
		value = if tonumber(state.checkedAtMs) ~= nil
			then audit.age_text(tonumber(state.checkedAtMs), noctalia.tr, noctalia.trp)
			else noctalia.tr("time.never"),
	})
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

noctalia.state.watch(UPDATES_KEY, function(value)
	SNAP.updates = value
	paint()
end)

-- Red de seguridad para cambios de ajustes; el watch es el camino real.
function update()
	paint()
end

noctalia.setUpdateInterval(60000)

SNAP.state = noctalia.state.get(STATE_KEY)
SNAP.updates = noctalia.state.get(UPDATES_KEY)
paint()
