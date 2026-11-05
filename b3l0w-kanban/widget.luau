--!strict
-- Widget de barra: cuántas tarjetas tiene el tablero y cuántas notificaciones
-- sin leer. Click = abre el panel (compacto o flotante según `panel_mode`).

local prefs = require("./lib/prefs.luau")

local STATUS_KEY = "b3l0w_kanban_status"
local PLUGIN = "b3l0w/kanban"
local T = noctalia.tr

local SNAP = { status = nil :: any }

local function statusTable(): { [string]: any }
	local cached = SNAP.status
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATUS_KEY)
	return if type(value) == "table" then value else {}
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "brand-github"
end

local function displayMode(): string
	local value = noctalia.getConfig("bar_display_mode")
	if value == "icon" or value == "count" then
		return value
	end
	return "both"
end

local function paint(): ()
	local status = statusTable()
	local cards = tonumber(status.cards) or 0
	local unread = tonumber(status.unread) or 0
	barWidget.setGlyph(glyphName())

	-- `show_label` manda: apagado = sólo icono. `bar_display_mode` elige qué
	-- número mostrar cuando hay texto.
	local mode = displayMode()
	local text = ""
	if prefs.show_label() and mode ~= "icon" then
		text = tostring(if unread > 0 and mode == "count" then unread else cards)
	end
	barWidget.setText(text)

	if status.auth == "auth_error" then
		barWidget.setGlyphColor("error")
	elseif unread > 0 then
		barWidget.setGlyphColor("primary")
	else
		barWidget.setGlyphColor("on_surface")
	end

	local partes: { string } = {
		T("widget.bar_summary", {
			cards = tostring(cards),
			unread = tostring(unread),
		}),
	}
	if tostring(status.repo or "") ~= "" then
		table.insert(partes, tostring(status.repo))
	end
	barWidget.setTooltip(T("widget.bar_tooltip", { summary = table.concat(partes, " · ") }))
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
