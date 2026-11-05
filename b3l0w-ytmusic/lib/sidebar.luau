--!strict
-- Menú lateral del panel de YouTube Music.
--
-- Replica el sidebar del plugin original (aabidk20/yt-music):
--   For you · Search · Queue · Offline · Library · Settings
-- más el bloque "YOUR LIBRARY" con los tipos de biblioteca.
--
-- El sidebar NO scrollea (`ui.scroll` es sólo vertical): se recorta con
-- `maxHeight` en vez de crecer.
--
-- Cada ítem es un `ui.row` con `onClick` (no un `ui.button`): así puede
-- tener icono + texto alineados y el hover del host, como el original.

local theme = require("./theme.luau")

local M = {}

-- Ancho fijo del sidebar: el contenido de la derecha se lleva el resto.
M.WIDTH = 190

-- Las vistas del sidebar y el icono de cada una.
M.ITEMS = {
	{ id = "home", label = "For you", glyph = "home" },
	{ id = "discover", label = "Search", glyph = "search" },
	{ id = "queue", label = "Queue", glyph = "music" },
	{ id = "offline", label = "Offline", glyph = "download" },
	{ id = "library", label = "Library", glyph = "library" },
	{ id = "settings", label = "Settings", glyph = "settings" },
}

-- Los tipos de biblioteca que muestra el original bajo "YOUR LIBRARY".
M.LIBRARY = {
	{ id = "playlists", label = "Playlists" },
	{ id = "songs", label = "Songs" },
	{ id = "albums", label = "Albums" },
	{ id = "artists", label = "Artists" },
	{ id = "profiles", label = "Profiles" },
	{ id = "podcasts", label = "Podcasts" },
}

local function item(key: string, glyph: string, label: string, active: boolean, onSelect: (string) -> ()): any
	return ui.row({
		key = key,
		gap = 10,
		align = "center",
		padding = 8,
		width = M.WIDTH,
		minWidth = M.WIDTH,
		radius = 8,
		fill = if active then theme.chip() else theme.surface(),
		onClick = function()
			onSelect(key)
		end,
	}, {
		ui.glyph({
			name = glyph,
			size = 17,
			color = if active then theme.accent() else theme.muted(),
		}),
		ui.label({
			text = label,
			fontSize = 13,
			fontWeight = if active then "bold" else "medium",
			color = if active then theme.accent() else theme.text(),
			maxLines = 1,
			flexGrow = 1,
		}),
	})
end

-- `onSelect` recibe el id de la vista o de la biblioteca.
function M.build(active: string, onSelect: (string) -> ()): any
	local items: { any } = {}

	for _, entry in M.ITEMS do
		table.insert(items, item("sb-" .. entry.id, entry.glyph, entry.label, active == entry.id, onSelect))
	end

	table.insert(items, ui.separator({ key = "sb-sep", color = theme.border(), spacing = 8 }))
	table.insert(items, ui.row({ key = "sb-lib-title-row", paddingH = 8 }, {
		ui.label({
			text = "YOUR LIBRARY",
			fontSize = 10,
			fontWeight = "semibold",
			color = theme.dim(),
		}),
	}))

	for _, entry in M.LIBRARY do
		table.insert(items, item("sb-lib-" .. entry.id, "folder", entry.label, active == entry.id, onSelect))
	end

	return ui.column({
		key = "sidebar",
		width = M.WIDTH,
		minWidth = M.WIDTH,
		gap = 2,
		padding = 8,
		align = "stretch",
	}, items)
end

return M
