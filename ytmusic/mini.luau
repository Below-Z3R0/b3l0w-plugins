--!strict
-- Mini player de YouTube Music.
--
-- Panel flotante chiquito (380 × 460) con la portada, el título, el scrubber
-- y los controles, como el `mini.luau` del plugin original.
--
-- A diferencia del panel grande, éste no pide datos: sólo lee PLAYER_KEY y
-- publica requests al service. El botón de expandir abre el panel full.

local theme = require("./lib/theme.luau")
local prefs = require("./lib/prefs.luau")

local PLAYER_KEY = "b3l0w_ytmusic_player"
local REQUEST_KEY = "b3l0w_ytmusic_request"
local PLUGIN = "b3l0w/ytmusic"

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

-- El widget no puede lanzar procesos: publica un request y el service hace el
-- trabajo. El nonce lleva contador porque dos clicks en el mismo ms se
-- descartan.
local function send(action: string, extra: any?): ()
	counter += 1
	local payload: any = {
		action = action,
		nonce = tostring(math.floor(os.clock() * 1000)) .. ":m" .. tostring(counter),
	}
	if type(extra) == "table" then
		for key, value in pairs(extra) do
			payload[key] = value
		end
	end
	noctalia.state.set(REQUEST_KEY, payload)
end

local function fmtTime(seconds: any): string
	local total = math.max(0, math.floor(tonumber(seconds) or 0))
	return tostring(math.floor(total / 60)) .. ":" .. string.format("%02d", total % 60)
end

local function build(): any
	local player = playerTable()
	local isPlaying = player.playing == true and player.paused ~= true
	local isLoading = player.starting == true
	local title = tostring(player.title or "")
	local artist = tostring(player.artist or "")
	local duration = tonumber(player.duration) or 0
	local position = math.min(tonumber(player.position) or 0, duration)
	local hasTrack = title ~= ""

	if title == "" then
		title = "Nothing playing"
		artist = "Pick something to play"
	end

	-- La portada: `ui.image` sólo acepta rutas locales, así que el service
	-- baja la carátula y publica la ruta en `thumb`.
	local cover: any = ui.glyph({
		name = "brand-youtube",
		size = 64,
		color = theme.dim(),
	})
	local thumbPath = player.thumb_path
	if (type(thumbPath) ~= "string" or thumbPath == "") and type(player.thumb) == "string" then
		thumbPath = player.thumb
	end
	if type(thumbPath) == "string" and thumbPath ~= "" then
		cover = ui.image({ path = thumbPath, width = 200, height = 200, radius = 12, fit = "cover" })
	end

	return ui.column({
		key = "mini-root",
		gap = 12,
		padding = 14,
		align = "center",
		width = 380,
		height = 460,
	}, {
		ui.row({ key = "mini-head", align = "center", gap = 8, width = "fill" }, {
			ui.glyph({ name = "brand-youtube", size = 18, color = theme.accent() }),
			ui.label({
				text = "YouTube Music",
				fontSize = 12,
				fontWeight = "bold",
				color = theme.text(),
				flexGrow = 1,
			}),
			ui.button({
				key = "btn-expand-full",
				glyph = "maximize",
				controlSize = "sm",
				variant = "ghost",
				tooltip = "Full screen",
				onClick = function()
					noctalia.state.set(REQUEST_KEY, {
						action = "expand",
						nonce = tostring(math.floor(os.clock() * 1000)) .. ":x",
					})
				end,
			}),
		}),
		cover,
		ui.column({ key = "mini-title-wrap", align = "center", gap = 4, width = "fill" }, {
			ui.label({
				text = title,
				fontSize = 15,
				fontWeight = "bold",
				color = theme.text(),
				maxLines = 1,
				maxWidth = 340,
			}),
			ui.label({
				text = artist,
				fontSize = 12,
				color = if isPlaying then theme.accent() else theme.muted(),
				maxLines = 1,
				maxWidth = 340,
			}),
		}),
		ui.column({ key = "mini-scrub-col", gap = 4, width = "fill" }, {
			ui.slider({
				key = "mini-seek-slider",
				min = 0,
				max = math.max(1, duration),
				step = 1,
				value = math.floor(position),
				controlSize = "sm",
				enabled = hasTrack and duration > 0,
				onChange = function(value: any)
					local seconds = tonumber(value)
					if seconds ~= nil then
						send("seek", { seconds = seconds })
					end
				end,
			}),
			ui.row({ key = "mini-times", align = "center", justify = "space_between", width = "fill" }, {
				ui.label({ text = fmtTime(position), fontSize = 10, color = theme.dim() }),
				ui.label({ text = fmtTime(duration), fontSize = 10, color = theme.dim() }),
			}),
		}),
		ui.row({ key = "mini-controls", align = "center", justify = "center", gap = 10 }, {
			ui.button({
				key = "mini-prev",
				glyph = "player-skip-back",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					send("prev")
				end,
			}),
			ui.button({
				key = "mini-play-btn",
				glyph = if isLoading then "loader" else (if isPlaying then "player-pause" else "player-play"),
				variant = "primary",
				controlSize = "lg",
				onClick = function()
					send(if isPlaying then "pause" else "stop")
				end,
			}),
			ui.button({
				key = "mini-next",
				glyph = "player-skip-forward",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					send("next")
				end,
			}),
		}),
	})
end

-- El host llama a `render()` para pintar: tiene que ser un GLOBAL del entry,
-- no una local (igual que `onOpen`).
function render(): ()
	panel.render(build())
end

function onOpen(_context: any): ()
	render()
end

function onClose(): ()
	SNAP.player = nil
end

function onKey(_chord: string, _pressed: boolean): ()
	return
end

function onFrameTick(_delta: any): ()
	return
end

noctalia.state.watch(PLAYER_KEY, function(value: any)
	SNAP.player = value
	render()
end)

render()
