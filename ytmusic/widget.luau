--!strict
-- Widget de barra: icono de YouTube Music + (opcional) el título que suena.
-- Click abre el panel que corresponda a `panel_mode`; el medio pausa y el
-- derecho pasa de tema (el manifest libera los dos botones con "none").

local prefs = require("./lib/prefs.luau")

local PLAYER_KEY = "b3l0w_ytmusic_player"
local PLUGIN = "b3l0w/ytmusic"
local REQUEST_KEY = "b3l0w_ytmusic_request"

local SNAP = { player = nil :: any }
local counter = 0

local function playerTable(): { [string]: any }
	local cached = SNAP.player
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(PLAYER_KEY)
	return type(value) == "table" and value or {}
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "brand-youtube"
end

-- El widget no puede lanzar procesos: publica un request y el service hace el
-- trabajo. El nonce lleva contador o dos clicks en el mismo ms se descartan.
local function send(action: string): ()
	counter += 1
	noctalia.state.set(REQUEST_KEY, {
		action = action,
		nonce = tostring(math.floor(os.clock() * 1000)) .. ":w" .. tostring(counter),
	})
end

local function paint(): ()
	local player = playerTable()
	barWidget.setGlyph(glyphName())
	local title = tostring(player.title or "")
	local playing = player.playing == true
	local paused = player.paused == true

	if not prefs.show_label() then
		barWidget.setText("")
	elseif title ~= "" then
		local texto = title
		if #texto > 28 then
			texto = string.sub(texto, 1, 27) .. "…"
		end
		barWidget.setText((if paused then "⏸ " else "") .. texto)
	else
		barWidget.setText("")
	end

	local parts: { string } = { "YouTube Music" }
	if title ~= "" then
		local artist = tostring(player.artist or "")
		table.insert(parts, if artist ~= "" then title .. " — " .. artist else title)
	end
	if paused then
		table.insert(parts, "en pausa")
	elseif not playing then
		table.insert(parts, "parado")
	end
	barWidget.setTooltip(table.concat(parts, " · "))
end

function onClick(): ()
	noctalia.togglePanel(prefs.panel_id(PLUGIN))
end

function onMiddleClick(): ()
	send("pause")
end

function onRightClick(): ()
	send("next")
end

noctalia.state.watch(PLAYER_KEY, function(value: any)
	SNAP.player = value
	paint()
end)

paint()
