--!strict
-- Widget de barra: icono + contador de animes/manga en curso.
-- `show_label` (default false acá) decide si muestra el número al lado.

local prefs = require("./lib/prefs.luau")

local LIBRARY_KEY = "b3l0w_anilist_library"
local STATUS_KEY = "b3l0w_anilist_status"
local PLUGIN = "b3l0w/anilist"

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
	return "book-2"
end

local function paint(): ()
	local status = statusTable()
	barWidget.setGlyph(glyphName())
	if not prefs.show_label() then
		barWidget.setText("")
		barWidget.setTooltip("AniList")
		return
	end
	local count = tonumber(status.current) or 0
	barWidget.setText(count > 0 and tostring(count) or "")
	local parts: { string } = {}
	if (tonumber(status.anime) or 0) > 0 then
		table.insert(parts, tostring(status.anime) .. " anime")
	end
	if (tonumber(status.manga) or 0) > 0 then
		table.insert(parts, tostring(status.manga) .. " manga")
	end
	if status.busy == true then
		table.insert(parts, "sincronizando…")
	end
	barWidget.setTooltip("AniList · " .. table.concat(parts, " · "))
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

noctalia.state.watch(LIBRARY_KEY, paint)
paint()
