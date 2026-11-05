--!strict
-- Widget de barra: cuántos contenedores corren y si hay alguno unhealthy.

local prefs = require("./lib/prefs.luau")

local STATUS_KEY = "b3l0w_containers_status"
local PLUGIN = "b3l0w/containers"

local SNAP = { status = nil :: any }

local function statusTable(): { [string]: any }
	local cached = SNAP.status
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATUS_KEY)
	return type(value) == "table" and value or {}
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "brand-docker"
end

local function paint(): ()
	local status = statusTable()
	barWidget.setGlyph(glyphName())
	if not prefs.show_label() then
		barWidget.setText("")
	else
		barWidget.setText(tostring(tonumber(status.running) or 0))
	end
	local partes: { string } = {
		tostring(tonumber(status.running) or 0) .. " corriendo",
		tostring(tonumber(status.stopped) or 0) .. " parados",
	}
	local unhealthy = tonumber(status.unhealthy) or 0
	if unhealthy > 0 then
		table.insert(partes, tostring(unhealthy) .. " unhealthy")
		barWidget.setGlyphColor("error")
	else
		barWidget.setGlyphColor("on_surface")
	end
	barWidget.setTooltip("Docker · " .. table.concat(partes, " · "))
end

function onClick(): ()
	noctalia.togglePanel(prefs.panel_id(PLUGIN))
end

function onRightClick(): ()
	noctalia.openSettings()
end

noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = value
	paint()
end)

paint()
