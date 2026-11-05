--!strict
-- Barra de reproducción del panel de YouTube Music.
--
-- Réplica de `views/components/playerbar.luau` del plugin original
-- (aabidk20/yt-music): pista a la izquierda, scrubber y controles al
-- centro, volumen y acción de pantalla completa a la derecha.
--
-- La barra es un HERMANO del scroll de contenido, nunca un hijo: dentro del
-- scroll quedaría fuera de la vista (la rueda del mouse no llega a los
-- paneles).

local theme = require("./theme.luau")

local M = {}

M.HEIGHT = 96

local function fmtTime(seconds: any): string
	local total = math.max(0, math.floor(tonumber(seconds) or 0))
	local minutes = math.floor(total / 60)
	local rest = total % 60
	return tostring(minutes) .. ":" .. string.format("%02d", rest)
end

local function fmtCount(value: any): string
	local n = tonumber(value) or 0
	if n >= 1000000 then
		return string.format("%.1f M", n / 1000000)
	end
	if n >= 1000 then
		return string.format("%.1f K", n / 1000)
	end
	return tostring(n)
end

local function iconButton(glyph: string, tooltip: string, active: boolean, onClick: () -> ()): any
	return ui.button({
		glyph = glyph,
		variant = if active then "primary" else "ghost",
		controlSize = "sm",
		tooltip = tooltip,
		onClick = onClick,
	})
end

-- `player` es la tabla de PLAYER_KEY; `onAction` manda la acción al service.
function M.build(player: any, onAction: (string, any) -> ()): any
	-- El service publica PLAYER_KEY con esta forma (ver `status --json` del
	-- backend): pid, videoId, title, artist, position, duration, playing,
	-- paused, starting, ended.
	local isPlaying = player.playing == true
	local isPaused = player.paused == true
	local isLoading = player.starting == true
	local title = tostring(player.title or "")
	local hasTrack = title ~= ""
	local artist = tostring(player.artist or "")
	local duration = tonumber(player.duration) or 0
	local position = math.min(tonumber(player.position) or 0, duration)
	local volume = tonumber(player.volume) or 70
	local shuffleOn = player.shuffle == true
	local repeatMode = tostring(player.repeat_mode or "off")

	if title == "" then
		title = "Nothing playing"
	end
	if artist == "" then
		artist = if hasTrack then "Unknown artist" else "Pick something to play"
	end

	-- ── izquierda: portada + título/artista ──────────────────────────
	local thumb = ui.glyph({
		name = "music",
		size = 24,
		color = if isPlaying then theme.accent() else theme.dim(),
	})
	local thumbPath = player.thumb_path
	if (type(thumbPath) ~= "string" or thumbPath == "") and type(player.thumb) == "string" then
		thumbPath = player.thumb
	end
	if type(thumbPath) == "string" and thumbPath ~= "" then
		thumb = ui.image({
			path = thumbPath,
			width = 56,
			height = 56,
			radius = 8,
			fit = "cover",
		})
	end

	local stats: { string } = {}
	if tonumber(player.views) and tonumber(player.views) > 0 then
		table.insert(stats, fmtCount(player.views) .. " views")
	end
	if tonumber(player.likes) and tonumber(player.likes) > 0 then
		table.insert(stats, fmtCount(player.likes) .. " likes")
	end

	local left = ui.row({
		key = "pb-now",
		gap = 10,
		align = "center",
		width = 280,
		minWidth = 220,
	}, {
		thumb,
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0 }, {
			ui.label({
				text = title,
				fontSize = 14,
				fontWeight = "bold",
				color = theme.text(),
				maxLines = 1,
				maxWidth = 200,
			}),
			ui.label({
				text = artist,
				fontSize = 12,
				color = if isPlaying then theme.accent() else theme.muted(),
				maxLines = 1,
				maxWidth = 200,
			}),
			-- La línea de stats se dibuja siempre (aunque vacía) para que la
			-- altura de la columna sea estable y el título no salte.
			ui.label({
				text = if #stats == 0 then "\u{00A0}" else table.concat(stats, " • "),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
				maxWidth = 200,
			}),
		}),
	})

	-- ── centro: scrubber + controles ──────────────────────────────────
	local playGlyph = if isLoading then "loader" else (if isPlaying and not isPaused then "player-pause" else "player-play")
	local repeatGlyph = if repeatMode == "one" then "repeat-once" else "repeat"

	local center = ui.column({
		key = "pb-center-col",
		align = "center",
		gap = 4,
		flexGrow = 1,
		minWidth = 0,
		justify = "center",
	}, {
		ui.row({ key = "pb-scrub", align = "center", gap = 10, width = "fill" }, {
			ui.label({
				key = "pb-pos-label",
				text = fmtTime(position),
				fontSize = 10,
				color = theme.dim(),
			}),
			ui.slider({
				key = "pb-seek",
				min = 0,
				max = math.max(1, duration),
				step = 1,
				value = math.floor(position),
				flexGrow = 1,
				controlSize = "sm",
				onChange = function(value: any)
					local seconds = tonumber(value)
					if seconds ~= nil then
						onAction("seek", { seconds = seconds })
					end
				end,
			}),
			ui.label({
				key = "pb-dur-label",
				text = fmtTime(duration),
				fontSize = 10,
				color = theme.dim(),
			}),
		}),
		ui.row({ key = "pb-controls", align = "center", justify = "center", gap = 4 }, {
			iconButton("arrows-shuffle", "Shuffle", shuffleOn, function()
				onAction("shuffle", {})
			end),
			iconButton("player-skip-back", "Previous", false, function()
				onAction("prev", {})
			end),
			ui.button({
				key = "pb-play",
				glyph = playGlyph,
				variant = "primary",
				controlSize = "md",
				onClick = function()
					-- El service expone `pause` y `stop`: con la pista en
					-- marcha se pausa; si está pausada o stopped, `stop`
					-- la reinicia desde el principio.
					onAction(if isPlaying then "pause" else "stop", {})
				end,
			}),
			iconButton("player-skip-forward", "Next", false, function()
				onAction("next", {})
			end),
			iconButton(repeatGlyph, "Repeat", repeatMode ~= "off", function()
				onAction("repeat", {})
			end),
		}),
	})

	-- ── derecha: like + pantalla completa + volumen ───────────────────
	local right = ui.row({
		key = "pb-right",
		gap = 8,
		align = "center",
		justify = "space_between",
		width = 220,
		minWidth = 180,
	}, {
		iconButton("heart", "Like", player.liked == true, function()
			onAction("toggle_like", { id = player.id })
		end),
		iconButton("maximize", "Full screen", false, function()
			onAction("expand", {})
		end),
		ui.slider({
			key = "pb-volume",
			min = 0,
			max = 100,
			step = 1,
			value = math.floor(volume),
			width = 90,
			controlSize = "sm",
			onChange = function(value: any)
				local v = tonumber(value)
				if v ~= nil then
					onAction("set_volume", { volume = v })
				end
			end,
		}),
	})

	return ui.row({
		key = "player-bar",
		gap = 12,
		align = "center",
		height = M.HEIGHT,
		paddingH = 16,
		paddingV = 8,
		fill = theme.surface(),
	}, {
		left,
		center,
		right,
	})
end

return M
