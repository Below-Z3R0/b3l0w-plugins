--!strict
-- Panel de b3l0w/ytmusic: Home, Charts, Search, Queue/Now playing.
--
-- Todo lo que se ve viene del service por `noctalia.state`; el panel NUNCA
-- lanza procesos. Las portadas son rutas locales que bajó el CLI (`--thumbs`),
-- porque ui.image no acepta URLs.

local anim = require("./lib/anim.luau")
local layout = require("./lib/layout.luau")
local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")
local sidebar = require("./lib/sidebar.luau")
local playerbar = require("./lib/playerbar.luau")
local columns = require("./lib/columns.luau")
-- Una celda de ancho fijo. El `width` de un label lo descarta el host, así
-- que la columna va dentro de un flex con `width` (el host lo traduce a
-- minWidth = maxWidth): con labels sueltos cada fila arrancaba en una x
-- distinta.
local function celda(texto: any, ancho: number, props: any): any
	return ui.column(columns.colProps(ancho), { ui.label(columns.celdaProps(texto, props)) })
end


local T = noctalia.tr

local HOME_KEY = "b3l0w_ytmusic_home"
local CHARTS_KEY = "b3l0w_ytmusic_charts"
local SEARCH_KEY = "b3l0w_ytmusic_search"
local QUEUE_KEY = "b3l0w_ytmusic_queue"
local PLAYER_KEY = "b3l0w_ytmusic_player"
local STATUS_KEY = "b3l0w_ytmusic_status"
local REQUEST_KEY = "b3l0w_ytmusic_request"
local SCREEN_KEY = "b3l0w_ytmusic_screen"

local FEED_KEY: { [string]: string } = { home = HOME_KEY, charts = CHARTS_KEY, search = SEARCH_KEY }

local function cfg(key: string, fallback: any): any
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

-- El modo del panel lo declara el entry al abrir: "full" usa el layout del
-- cliente real (sidebar + playerbar), "float" el compacto con el ancho del
-- panel flotante, "compact" el de siempre.
--
-- No se resuelve por un módulo compartido: `require` cachea el módulo, así
-- que con dos entries el último en cargarse pisa el modo del otro.
-- UNA sola declaración de MODO.Había dos (una antes de `panelMode` y otra
-- después): la segunda creaba un新的 local que shadowaba al primero, así que
-- `MODO = ...` asignaba a una variable que nadie leía y los tres modos
-- devolvían "compact" con su ancho.
local MODO = "compact"

-- El modo lo declara el ENTRY al abrir (`panel_compact.luau`, `float_panel.luau`
-- o `full.luau`), no el setting: el setting `panel_mode` elige qué entry
-- abre el widget, pero si el usuario abre otro entry desde el launcher, el
-- código calculaba los anchos sobre el panel equivocado.
local function panelMode(): string
	return MODO
end

local function panelModeFull(): boolean
	return MODO == "full"
end

-- El panel flotante es más ancho: la superficie la fija el manifest, así que
-- el contenido tiene que acompañar o quedan 400 px muertos a la derecha.
local PANEL_W_BY_MODE: { [string]: number } = { compact = 720, float = 1120 }
local PANEL_H_BY_MODE: { [string]: number } = { compact = 660, float = 820 }

local function panelWidth(): number
	return PANEL_W_BY_MODE[panelMode()] or 720
end

local function panelHeight(): number
	return PANEL_H_BY_MODE[panelMode()] or 660
end

local THUMB = 42
local ROW_H_BY_DENSITY: { [string]: number } = { compact = 54, cozy = 62, comfortable = 70 }

local function rowHeight(): number
	return ROW_H_BY_DENSITY[prefs.density()] or 62
end

-- Alto exacto de la lista: el panel tiene alto fijo, así que la lista entra
-- justa y la última fila no queda amputada. La rueda no llega a los paneles:
-- la navegación es por botones y por Prior/Next.
-- El cromo (cabecera + playerbar + pie) se calcula POR PARTES: cambia con
-- el modo (el full tiene sidebar) y con la vista. Si la estimación se queda
-- corta, la última fila queda tapada contra el pie.
local function chromeH(): number
	return layout.chrome({
		64, -- cabecera: título + barra de búsqueda
		74, -- playerbar
		40, -- pie de paginación
	})
end

local function listHeight(): number
	return math.max(180, panelHeight() - chromeH())
end

local function pageSize(): number
	return math.max(3, math.floor((listHeight() + 6) / (rowHeight() + 6)))
end

local function exactListHeight(): number
	return pageSize() * (rowHeight() + 6) - 6
end

local function rowW(): number
	return panelWidth() - 12
end

local function titleWidth(): number
	return rowW() - 16 - THUMB - 60
end

-- ── snapshots ────────────────────────────────────────────────────────
-- Se guarda lo que entrega el watcher: `state.get` puede venir un frame atrás.

local SNAP = {
	home = nil :: any,
	charts = nil :: any,
	search = nil :: any,
	queue = nil :: any,
	player = nil :: any,
	status = nil :: any,
}

local S = {
	screen = "home" :: string,
	-- "compact" = el panel de siempre; "full" = el layout del original con
	-- sidebar a la izquierda y playerbar abajo.
	mode = "compact" :: string,
	kind = "home" :: string,
	pages = {} :: { [string]: number },
	query = "" :: string,
	requestCount = 0,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
	seekDraft = nil :: number?,
}

-- Las vistas del sidebar. El `screen` es la clave que usa el service; las
-- vistas de biblioteca y ajustes son locales (el service no tiene todavía
-- esos comandos) y se muestran con su propio estado vacío.
local TABS = {
	{ id = "home", label = T("panel.tab.home") },
	{ id = "charts", label = T("panel.tab.charts") },
	{ id = "search", label = T("panel.tab.search") },
	{ id = "queue", label = T("panel.tab.queue") },
	{ id = "discover", label = T("panel.tab.discover") },
	{ id = "offline", label = T("panel.tab.offline") },
	{ id = "library", label = T("panel.tab.library") },
	{ id = "settings", label = T("panel.tab.settings") },
}

local function nowMs(): number
	return math.floor(os.clock() * 1000)
end

local function send(payload: any): ()
	S.requestCount += 1
	payload.nonce = tostring(nowMs()) .. ":" .. tostring(S.requestCount)
	noctalia.state.set(REQUEST_KEY, payload)
end

local function snapshot(field: string, key: string): { [string]: any }
	local cached = SNAP[field]
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(key)
	return type(value) == "table" and value or {}
end

local function feedTable(kind: string): { [string]: any }
	local data = snapshot(kind, FEED_KEY[kind])
	if type(data.items) ~= "table" then
		data.items = {}
	end
	return data
end

local function feedItems(kind: string): { any }
	return feedTable(kind).items
end

local function queueTable(): { [string]: any }
	local data = snapshot("queue", QUEUE_KEY)
	if type(data.items) ~= "table" then
		data.items = {}
	end
	return data
end

local function playerTable(): { [string]: any }
	return snapshot("player", PLAYER_KEY)
end

local function statusTable(): { [string]: any }
	return snapshot("status", STATUS_KEY)
end

-- ── helpers de presentación ──────────────────────────────────────────

local function clock(seconds: number): string
	if seconds <= 0 then
		return "0:00"
	end
	local total = math.floor(seconds)
	local hours = math.floor(total / 3600)
	local minutes = math.floor((total % 3600) / 60)
	if hours > 0 then
		return tostring(hours) .. ":" .. string.format("%02d", minutes) .. ":" .. string.format("%02d", total % 60)
	end
	return tostring(minutes) .. ":" .. string.format("%02d", total % 60)
end

local function subtitleOf(item: any): string
	local parts: { string } = {}
	local artist = tostring(item.artist or "")
	if artist ~= "" then
		table.insert(parts, artist)
	end
	local album = tostring(item.album or "")
	if album ~= "" then
		table.insert(parts, album)
	end
	local duration = tostring(item.duration or "")
	if duration ~= "" then
		table.insert(parts, duration)
	end
	return table.concat(parts, " · ")
end

local function thumbnail(item: any, size: number): any
	local path = item.thumb
	if type(path) == "string" and path ~= "" then
		return ui.image({ path = path, width = size, height = size, radius = 6, fit = "cover" })
	end
	-- Placeholder sin fill negro: se ve intencional, no como un hueco.
	return ui.box({ width = size, height = size, radius = 6, fill = theme.chip() })
end

local function isPlayingItem(item: any): boolean
	local player = playerTable()
	return tostring(player.videoId or "") ~= "" and tostring(player.videoId) == tostring(item.videoId)
end

local function glyphName(): string
	local value = cfg("glyph", "brand-youtube")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "brand-youtube"
end

-- ── render (forward declaration: los callbacks lo usan) ──────────────

local render: () -> ()

-- ── piezas de UI ─────────────────────────────────────────────────────

local function header(): any
	local player = playerTable()
	local status = statusTable()
	local nowTitle = tostring(player.title or "")
	return ui.row({ gap = 8, padding = 6, align = "center" }, {
		ui.glyph({ name = glyphName(), size = 18 }),
		ui.label({ text = "YouTube Music", fontSize = 16, fontWeight = "semibold" }),
		ui.label({
			text = if status.busy == true then T("panel.loading") else nowTitle,
			fontSize = 12,
			color = if status.busy == true then theme.warn() else theme.muted(),
			maxLines = 1,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			glyph = "refresh",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.refresh"),
			onClick = function()
				send({ action = if S.screen == "queue" then "queue" else S.screen, query = S.query })
			end,
		}),
		ui.button({
			glyph = "settings",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
	})
end

-- Cambiar de vista desde el sidebar: pide los datos si la vista está vacía y
-- redibuja. Las vistas que el service todavía no implementa (biblioteca,
-- ajustes) se muestran con su estado vacío local.
local function selectView(id: string): ()
	S.screen = id
	S.page = 1
	S.anim.t = if prefs.animations() then 0 else 1
	local known = false
	for _, tab in ipairs(TABS) do
		if tab.id == id then
			known = true
			break
		end
	end
	if known and id ~= "queue" and id ~= "settings" and id ~= "library"
		and id ~= "offline" and #feedItems(id) == 0 then
		send({ action = if id == "discover" then "search" else id, query = S.query })
	end
	render()
end

local function tabs(): any
	local children: { any } = {}
	for _, tab in ipairs(TABS) do
		local active = S.screen == tab.id
		table.insert(children, ui.button({
			key = "tab-" .. tab.id,
			text = tab.label,
			controlSize = "sm",
			variant = if active then "secondary" else "ghost",
			selected = active,
			onClick = function()
				if S.screen == tab.id then
					return
				end
				selectView(tab.id)
			end,
		}))
	end
	table.insert(children, ui.spacer({ flexGrow = 1 }))
	return ui.row({ gap = 6, padding = 6, align = "center" }, children)
end

local function feedRow(item: any, index: number): any
	-- La opacidad NUNCA llega a 0: `anim.stagger` vale 0 cuando la
	-- animación arranca (t = 0) y la fila quedaba invisible. Con el piso en
	-- 0.85 la animación da un fade sutil y la fila siempre se ve.
	local alpha = 1
	if S.anim.t < 1 then
		alpha = 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.04)
	end
	local rank = tonumber(item.rank) or 0
	local children: { any } = {}
	if rank > 0 then
		table.insert(children, celda(tostring(rank), 26, { fontSize = 12,
			color = theme.dim(),
			textAlign = "end" }))
	end
	table.insert(children, thumbnail(item, THUMB))
	table.insert(children, ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
		ui.label({
			text = tostring(item.title or ""),
			fontSize = 14,
			fontWeight = if isPlayingItem(item) then "bold" else "semibold",
			color = if isPlayingItem(item) then theme.info() else nil,
			maxLines = 1,
		}),
		ui.label({
			text = subtitleOf(item),
			fontSize = 12,
			color = theme.muted(),
			maxLines = 1,
		}),
	}))
	table.insert(children, ui.button({
		glyph = "player-play",
		controlSize = "sm",
		variant = "ghost",
		tooltip = T("panel.play"),
		onClick = function()
			send({ action = "play_item", item = item })
		end,
	}))
	return ui.row({
		key = "feed-" .. tostring(item.videoId or index),
		width = rowW(),
		height = rowHeight(),
		gap = 10,
		padding = 6,
		align = "center",
		fill = if isPlayingItem(item) then theme.chip() else theme.surface(),
		radius = 10,
		opacity = alpha,
		onClick = function()
			send({ action = "play_item", item = item })
		end,
	}, children)
end

local function emptyState(kind: string): any
	local status = statusTable()
	local data = feedTable(kind)
	local message = T("panel.empty")
	if data.loading == true or status.busy == true then
		message = T("panel.loading")
	elseif type(data.error) == "string" and data.error ~= "" then
		message = data.error
	end
	return ui.column({ padding = 24, align = "center", gap = 8 }, {
		ui.glyph({ name = "music", size = 26, color = theme.dim() }),
		ui.label({ text = message, fontSize = 13, color = theme.muted(), maxLines = 3, textAlign = "center" }),
		ui.button({
			text = T("panel.retry"),
			controlSize = "sm",
			variant = "secondary",
			onClick = function()
				send({ action = kind })
			end,
		}),
	})
end

local function feedView(kind: string): any
	local items = feedItems(kind)
	local data = feedTable(kind)
	local children: { any } = {}

	if #items == 0 then
		table.insert(children, emptyState(kind))
		return ui.column({ gap = 6, height = listHeight(), align = "stretch" }, children)
	end

	local perPage = pageSize()
	local pages = math.max(1, math.ceil(#items / perPage))
	local page = math.min(math.max(1, S.pages[kind] or 1), pages)
	S.pages[kind] = page
	local first = (page - 1) * perPage + 1
	local last = math.min(#items, first + perPage - 1)

	local rows: { any } = {}
	for index = first, last do
		table.insert(rows, feedRow(items[index], index - first + 1))
	end
	table.insert(children, ui.scroll(layout.merge({
			width = layout.row(rowW()),
		key = kind .. "-scroll",
		gap = 6,
		paddingH = 2,
		
		align = "center",
	}, layout.scrollExtra(exactListHeight())), rows))

	-- El pie va FUERA del scroll: la rueda no llega a los paneles, así que un
	-- botón adentro del scroll es inalcanzable.
	local hasMore = tostring(data.continuation or "") ~= ""
	table.insert(children, ui.row({ gap = 8, paddingH = 6, paddingV = 2, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = page > 1,
			onClick = function()
				S.pages[kind] = page - 1
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
		ui.label({
			text = T("panel.page", { page = tostring(page), pages = tostring(pages), total = tostring(#items) }),
			fontSize = 12,
			color = theme.muted(),
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = page < pages,
			onClick = function()
				S.pages[kind] = page + 1
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
		ui.button({
			glyph = "download",
			text = T("panel.more"),
			controlSize = "sm",
			variant = "secondary",
			enabled = hasMore and data.loading ~= true,
			onClick = function()
				send({ action = "more", kind = kind, continuation = tostring(data.continuation or ""), query = S.query })
			end,
		}),
	}))
	return ui.column({ gap = 6, align = "stretch" }, children)
end

local function searchView(): any
	local data = feedTable("search")
	return ui.column({ gap = 6, align = "stretch" }, {
		ui.row({ gap = 8, paddingH = 6, align = "center" }, {
			ui.input({
				key = "search-input",
				value = S.query,
				placeholder = T("panel.search_placeholder"),
				controlSize = "sm",
				flexGrow = 1,
				submitOnEnter = true,
				onChange = function(value: any)
					S.query = tostring(value or "")
				end,
				onSubmit = function(value: any)
					S.query = tostring(value or S.query)
					S.pages.search = 1
					S.anim.t = if prefs.animations() then 0 else 1
					send({ action = "search", query = S.query })
				end,
			}),
			ui.button({
				glyph = "search",
				controlSize = "sm",
				variant = "primary",
				tooltip = T("panel.search_action"),
				onClick = function()
					S.pages.search = 1
					send({ action = "search", query = S.query })
				end,
			}),
		}),
		ui.label({
			text = if tostring(data.title or "") ~= "" then T("panel.results", { query = tostring(data.title), count = tostring(#feedItems("search")) }) else "",
			fontSize = 12,
			color = theme.muted(),
			maxLines = 1,
		}),
		feedView("search"),
	})
end

local function controls(): any
	local player = playerTable()
	local playing = player.playing == true
	local paused = player.paused == true
	local position = tonumber(player.position) or 0
	local duration = tonumber(player.duration) or 0
	local title = tostring(player.title or "")
	if title == "" then
		title = T("panel.nothing_playing")
	end
	local artist = tostring(player.artist or "")
	local label = if artist ~= "" then title .. " — " .. artist else title


	return ui.column({ gap = 4, padding = 6, fill = theme.surface(), radius = 10, align = "stretch", width = panelWidth() - 12 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = label, fontSize = 13, fontWeight = "semibold", maxLines = 1 }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({ text = clock(position) .. " / " .. clock(duration), fontSize = 11, color = theme.muted() }),
		}),
		ui.row({ gap = 6, align = "center" }, {
			ui.slider({
				key = "seek",
				min = 0,
				max = math.max(1, duration),
				step = 1,
				value = position,
				controlSize = "sm",
				flexGrow = 1,
				enabled = duration > 0,
				onChange = function(value: any)
					S.seekDraft = tonumber(value) or 0
				end,
				onDragEnd = function(value: any)
					local seconds = tonumber(value) or S.seekDraft or 0
					S.seekDraft = nil
					send({ action = "seek", seconds = seconds })
				end,
			}),
			ui.button({
				glyph = "player-track-prev",
				controlSize = "sm",
				variant = "ghost",
				enabled = playing,
				onClick = function()
					send({ action = "prev" })
				end,
			}),
			ui.button({
				glyph = if paused then "player-play" else "player-pause",
				controlSize = "md",
				variant = "primary",
				enabled = playing,
				tooltip = if paused then T("panel.play") else T("panel.pause"),
				onClick = function()
					send({ action = "pause" })
				end,
			}),
			ui.button({
				glyph = "player-track-next",
				controlSize = "sm",
				variant = "ghost",
				enabled = playing,
				onClick = function()
					send({ action = "next" })
				end,
			}),
			ui.button({
				glyph = "arrows-shuffle",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.shuffle"),
				onClick = function()
					send({ action = "shuffle" })
				end,
			}),
			ui.button({
				glyph = "player-stop",
				controlSize = "sm",
				variant = "ghost",
				enabled = playing,
				tooltip = T("panel.stop"),
				onClick = function()
					send({ action = "stop" })
				end,
			}),
		}),
	})
end

-- ── vistas sin datos del backend ─────────────────────────────────────
-- El backend todavía no expone `library`, `offline` ni `settings`: se
-- muestra el estado vacío real en vez de una lista rota. Cuando el Go las
-- implemente, alcanza con leer la clave de estado y reusar `feedView`.

local function emptyView(icon: string, title: string, hint: string): any
	return ui.column({
		gap = 10,
		align = "center",
		justify = "center",
		padding = 28,
		width = "fill",
	}, {
		ui.glyph({ name = icon, size = 34, color = theme.dim() }),
		ui.label({ text = layout.ellipsis(title, 40), fontSize = 15, fontWeight = "bold", color = theme.text() }),
		ui.label({
			text = layout.ellipsis(hint, 50),
			fontSize = 12,
			color = theme.muted(),
			wrap = true,
		}),
	})
end

local function libraryView(): any
	-- Los tipos de biblioteca, como en el cliente real. Cada uno abre su
	-- lista cuando el backend la sirva.
	local children: { any } = {}
	local data = feedTable("library")
	local items = data.items or {}

	if #items == 0 then
		table.insert(children, emptyView(
			"library",
			T("panel.library.title"),
			T("panel.library.hint")
		))
		return ui.column({ gap = 6, align = "stretch" }, children)
	end

	for index, item in ipairs(items) do
		table.insert(children, ui.row({
			key = "lib-item-" .. tostring(index),
			gap = 10,
			align = "center",
			padding = 8,
			radius = 8,
			width = "fill",
			onClick = function()
				send({ action = "play_item", item = item })
			end,
		}, {
			ui.glyph({ name = "music", size = 18, color = theme.accent() }),
			ui.label({
				text = tostring(item.title or item.name or ""),
				fontSize = 13,
				color = theme.text(),
				maxLines = 1,
				flexGrow = 1,
			}),
		}))
	end
	return ui.column({ gap = 4, align = "stretch" }, children)
end

local function settingsView(): any
	local rows: { any } = {}
	local function setting(label: string, value: string): any
		return ui.row({
			gap = 12,
			align = "center",
			paddingH = 10,
			paddingV = 6,
			width = "fill",
		}, {
			ui.label({ text = label, fontSize = 13, color = theme.text(), flexGrow = 1 }),
			ui.label({ text = value, fontSize = 12, color = theme.muted() }),
		})
	end

	table.insert(rows, setting(T("panel.setting.quality"), T("panel.setting.quality.value")))
	table.insert(rows, setting(T("panel.setting.region"), T("panel.setting.region.value")))
	table.insert(rows, setting(T("panel.setting.covers"), if prefs.covers() then T("panel.setting.covers.on") else T("panel.setting.covers.off")))
	table.insert(rows, setting(T("panel.setting.animations"), tostring(prefs.animations())))
	table.insert(rows, setting(T("panel.setting.mode"), if panelModeFull() then "Full" else "Compact"))

	return ui.column({ gap = 2, padding = 8, align = "stretch" }, rows)
end

local function discoverView(): any
	-- La búsqueda real vive en la vista Search; Discover muestra las
	-- categorías para elegir el punto de partida.
	local chips: { any } = {}
	local categories = {
		{ id = "charts", label = T("panel.tab.charts") },
		{ id = "trending", label = "Trending" },
		{ id = "mood", label = "Mood" },
		{ id = "genres", label = "Genres" },
		{ id = "new", label = "New releases" },
	}
	for _, category in ipairs(categories) do
		table.insert(chips, ui.button({
			key = "cat-" .. category.id,
			text = category.label,
			controlSize = "sm",
			variant = "secondary",
			onClick = function()
				selectView(category.id)
			end,
		}))
	end
	return ui.column({ gap = 10, padding = 12, align = "stretch" }, {
		ui.label({
			text = T("panel.discover.hint"),
			fontSize = 12,
			color = theme.muted(),
		}),
		ui.row({ gap = 8, wrap = true }, chips),
	})
end

local function queueView(): any
	local queue = queueTable()
	local items = queue.items
	local cursor = tonumber(queue.cursor) or 0
	local children: { any } = {}
	if #items == 0 then
		table.insert(children, emptyState("home"))
		return ui.column({ gap = 6, height = listHeight(), align = "stretch" }, children)
	end
	local rows: { any } = {}
	for index, item in ipairs(items) do
		if index <= pageSize() * math.max(1, S.pages.queue or 1) then
			local current = index - 1 == cursor
			local alpha = 1
			if S.anim.t < 1 then
				alpha = 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.03)
			end
			table.insert(rows, ui.row({
				key = "queue-" .. tostring(item.videoId) .. "-" .. tostring(index),
				width = rowW(),
				height = rowHeight(),
				gap = 10,
				padding = 6,
				align = "center",
				fill = if current then theme.chip() else theme.surface(),
				radius = 10,
				opacity = alpha,
				onClick = function()
					send({ action = "play_item", item = item })
				end,
			}, {
				celda(if current then "▶" else tostring(index), 26, { fontSize = 12,
					color = if current then theme.info() else theme.dim(),
					textAlign = "end" }),
				thumbnail(item, THUMB),
				ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
					ui.label({
						text = layout.ellipsis(item.title, 60),
						fontSize = 14,
						fontWeight = if current then "bold" else "semibold",
						maxLines = 1,
					}),
					ui.label({ text = subtitleOf(item), fontSize = 12, color = theme.muted(), maxLines = 1 }),
				}),
			}))
		end
	end
	table.insert(children, ui.scroll(layout.merge({
			width = layout.row(rowW()),
		key = "queue-scroll",
		gap = 6,
		paddingH = 2,
		
		align = "center",
	}, layout.scrollExtra(exactListHeight())), rows))
	local pages = math.max(1, math.ceil(#items / pageSize()))
	local page = math.min(math.max(1, S.pages.queue or 1), pages)
	S.pages.queue = page
	table.insert(children, ui.row({ gap = 8, paddingH = 6, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = page > 1,
			onClick = function()
				S.pages.queue = page - 1
				render()
			end,
		}),
		ui.label({
			text = T("panel.queue_page", { page = tostring(page), pages = tostring(pages), total = tostring(#items) }),
			fontSize = 12,
			color = theme.muted(),
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = page < pages,
			onClick = function()
				S.pages.queue = page + 1
				render()
			end,
		}),
	}))
	return ui.column({ gap = 6, align = "stretch" }, children)
end

-- ── render ───────────────────────────────────────────────────────────

local lastTrace = ""

render = function(): ()
	local kind = if S.screen == "queue" then "queue" else S.screen
	local items = if kind == "queue" then queueTable().items else feedItems(kind)
	local player = playerTable()
	local first = if type(items) == "table" and type(items[1]) == "table" then tostring(items[1].title or "") else ""
	local trace = string.format(
		"%s|%d|%s|playing=%s|%d/%d|p%d|modo=%s|w=%s",
		tostring(kind),
		#(items or {}),
		string.sub(first, 1, 26),
		tostring(player.playing == true),
		tonumber(player.position) or 0,
		tonumber(player.duration) or 0,
		tonumber(S.pages[kind] or 1) or 1,
		-- El modo y el ancho: la forma de VERIFICAR que el entry pasó el modo
		-- correcto. El float usaba el entry compacto, así que un panel de
		-- 1160 px se renderizaba con la lógica del de 740.
		MODO,
		-- El layout "full" usa flexGrow (sidebar + columna): su ancho lo
		-- pone el manifest (pantalla completa), no el del modo.
		if MODO == "full" then "screen" else tostring(panelWidth())
	)
	if trace ~= lastTrace then
		lastTrace = trace
		noctalia.log("[b3l0w-ytmusic] pantalla=" .. trace)
	end

	local body: any
	if S.screen == "queue" then
		body = queueView()
	elseif S.screen == "search" then
		body = searchView()
	elseif S.screen == "library" or S.screen == "playlists" or S.screen == "songs"
		or S.screen == "albums" or S.screen == "artists" or S.screen == "profiles"
		or S.screen == "podcasts" then
		body = libraryView()
	elseif S.screen == "settings" then
		body = settingsView()
	elseif S.screen == "discover" or S.screen == "offline" then
		body = discoverView()
	else
		body = feedView(S.screen)
	end

	-- Estructura del panel completo, como el original:
	--   fila principal (sidebar + columna derecha) + playerbar abajo.
	-- La playerbar es HERMANA del scroll, nunca hija: dentro del scroll
	-- quedaría fuera de la vista.
	local full = panelModeFull()

	if full then
		local sidebarNode = sidebar.build(S.screen, function(id: string)
			selectView(id)
		end)
		panel.render(ui.column({
			-- En modo full el manifest declara `width = "fill"`: la raíz NO lleva
			-- ancho fijo, o el panel mide 740 px y el contenido queda en un rincón.
			width = if full then nil else layout.width(740),
			align = "stretch",
			key = "ytmusic-root",
			gap = 0,
			padding = 0,
			flexGrow = 1,
		}, {
			ui.row({ key = "main-row", align = "stretch", flexGrow = 1, gap = 12, padding = 12 }, {
				sidebarNode,
				ui.column({ key = "right-col", flexGrow = 1, minWidth = 0, gap = 8, align = "stretch" }, {
					header(),
					ui.scroll({
						-- En full el scroll toma el ancho que le deja la columna
						-- (flexGrow); con un width fijo el contenido queda angosto.
			width = if full then nil else layout.width(rowW()), key = "content-scroll", flexGrow = 1, gap = 8 }, { body }),
				}),
			}),
			playerbar.build(player, function(action: string, extra: any)
				local payload: any = { action = action }
				if type(extra) == "table" then
					for key, value in pairs(extra) do
						payload[key] = value
					end
				end
				send(payload)
			end),
		}))
		return
	end

	panel.render(ui.column({ gap = 4, padding = 6, width = panelWidth(), align = "stretch" }, {
		header(),
		tabs(),
		body,
		controls(),
	}))
end

-- ── animación ────────────────────────────────────────────────────────

function onFrameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	local ms = tonumber(delta) or 16
	S.anim.t = math.min(1, S.anim.t + ms / (S.anim.ms or 220))
	render()
end

-- ── ciclo de vida ────────────────────────────────────────────────────

local function open(_context: any, modo: string): ()
	-- "compact" = 740 px, "float" = 1160 px (el mismo layout, más ancho),
	-- "full" = el layout del cliente real con sidebar y playerbar.
	MODO = if modo == "full" then "full" elseif modo == "float" then "float" else "compact"
	lastTrace = ""
	SNAP.home = noctalia.state.get(HOME_KEY)
	SNAP.charts = noctalia.state.get(CHARTS_KEY)
	SNAP.search = noctalia.state.get(SEARCH_KEY)
	SNAP.queue = noctalia.state.get(QUEUE_KEY)
	SNAP.player = noctalia.state.get(PLAYER_KEY)
	SNAP.status = noctalia.state.get(STATUS_KEY)

	-- Una orden de pantalla pedida por IPC con el panel cerrado no llega por el
	-- watcher (el entry se instancia recién al abrir): se siembra acá.
	local order = noctalia.state.get(SCREEN_KEY)
	if type(order) == "table" and type(order.screen) == "string" and order.screen ~= "" then
		S.screen = order.screen
	end
	S.anim.t = if prefs.animations() then 0 else 1
	panel.setNeedsFrameTick(true)

	if S.screen ~= "queue" and #feedItems(S.screen) == 0 then
		send({ action = S.screen })
	end
	render()
end

local function close(): ()
	S.seekDraft = nil
end

local function onKeyHandler(chord: string, pressed: boolean): ()
	if not pressed then
		return
	end
	if chord == "g" then
		S.screen = if S.screen == "queue" then "home" else "queue"
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Prior" or chord == "Next" then
		local kind = if S.screen == "queue" then "queue" else S.screen
		local items = if kind == "queue" then queueTable().items else feedItems(kind)
		local pages = math.max(1, math.ceil(#(items or {}) / pageSize()))
		local page = tonumber(S.pages[kind]) or 1
		if chord == "Next" then
			S.pages[kind] = math.min(pages, page + 1)
		else
			S.pages[kind] = math.max(1, page - 1)
		end
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Home" then
		S.screen = "home"
		S.pages.home = 1
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	end
end

noctalia.state.watch(HOME_KEY, function(value: any)
	SNAP.home = value
	if S.screen == "home" then
		render()
	end
end)

noctalia.state.watch(CHARTS_KEY, function(value: any)
	SNAP.charts = value
	if S.screen == "charts" then
		render()
	end
end)

noctalia.state.watch(SEARCH_KEY, function(value: any)
	SNAP.search = value
	if S.screen == "search" then
		if type(value) == "table" and type(value.title) == "string" and value.title ~= "" then
			S.query = value.title
		end
		render()
	end
end)

noctalia.state.watch(QUEUE_KEY, function(value: any)
	SNAP.queue = value
	if S.screen == "queue" then
		render()
	end
end)

noctalia.state.watch(PLAYER_KEY, function(value: any)
	SNAP.player = value
	render()
end)

noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = value
	render()
end)

noctalia.state.watch(SCREEN_KEY, function(value: any)
	local order = if type(value) == "table" then value else {}
	local screen = tostring(order.screen or "")
	if screen ~= "" then
		S.screen = screen
	end
	S.anim.t = if prefs.animations() then 0 else 1
	render()
end)

-- El entry devuelve un valor no-nil: `full.luau` lo carga con `require` para
-- reutilizar toda la lógica del panel. (El sandbox exige exactamente un
-- valor no-nil.)
return {
	open = open,
	close = close,
	key = onKeyHandler,
	-- `onFrameTick` es global y `require` no lo exporta: el entry lo llama
	-- a través de esta referencia. Sin esto la animación nunca avanzaba
	-- (S.anim.t quedaba en 0) y las filas se quedaban con la opacidad del
	-- primer frame: INVISIBLES.
	frameTick = onFrameTick,
}
