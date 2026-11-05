--!strict
-- Panel de b3l0w/anilist.
--
-- La carátula se resuelve SIEMPRE desde el mapa de carátulas
-- (`covers[mediaId]`), nunca desde la fila: así una lista recién traída —que no
-- trae rutas— no puede convertir todas las portadas en rectángulos de color.

local anim = require("./lib/anim.luau")
local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")
local columns = require("./lib/columns.luau")
local layout = require("./lib/layout.luau")
-- Una celda de ancho fijo. El `width` de un label lo descarta el host, así
-- que la columna va dentro de un flex con `width` (el host lo traduce a
-- minWidth = maxWidth): con labels sueltos cada fila arrancaba en una x
-- distinta.
local function celda(texto: any, ancho: number, props: any): any
	return ui.column(columns.colProps(ancho), { ui.label(columns.celdaProps(texto, props)) })
end


local T = noctalia.tr

-- El MODO lo declara el ENTRY al abrir (`panel_compact.luau` / `float.luau`),
-- no el setting `panel_mode`: el setting elige qué entry abre el WIDGET, pero
-- si el usuario abre el otro entry desde el launcher, el ancho se calculaba
-- sobre el panel equivocado (700 en vez de 1180).
local M: any = {}

-- El MODO lo declara el ENTRY al abrir (`panel_compact.luau` / `float.luau`),
-- no el setting `panel_mode`: el setting elige qué entry abre el WIDGET, pero
-- si el usuario abre el otro entry desde el launcher, el ancho se calculaba
-- sobre el panel equivocado (700 en vez de 1180).
local MODO = "compact"

-- `render` se declara antes de su primer uso: las closures de la UI lo
-- llaman y un `local function` declarado más abajo es nil en ese momento.
local render: () -> ()

local LIBRARY_KEY = "b3l0w_anilist_library"
local STATS_KEY = "b3l0w_anilist_stats"
local COVERS_KEY = "b3l0w_anilist_covers"
local STATUS_KEY = "b3l0w_anilist_status"
local REQUEST_KEY = "b3l0w_anilist_request"
local DISCOVER_KEY = "b3l0w_anilist_discover"
local SCREEN_KEY = "b3l0w_anilist_screen"
local DETAIL_KEY = "b3l0w_anilist_detail"
local SCHEDULE_KEY = "b3l0w_anilist_schedule"
local FILTER_KEY = "b3l0w_anilist_filters"

local function cfg(clave: string, porDefecto: any): any
	local valor = noctalia.getConfig(clave)
	if valor == nil then
		return porDefecto
	end
	return valor
end

local function cfgBool(clave: string, porDefecto: boolean): boolean
	local valor = cfg(clave, porDefecto)
	if type(valor) == "boolean" then
		return valor
	end
	return porDefecto
end

local COVER_W = 46
local COVER_H_BY_SIZE = { small = 56, medium = 64, large = 76 }

local function coverH(): number
	local modo = tostring(cfg("cover_size", "medium"))
	return COVER_H_BY_SIZE[modo] or 64
end

-- El ancho del surface. Lo declara el manifest (740 el compacto, 1180 el
-- flotante) y el host es su dueño: el panel pide el ancho que tiene.
local PANEL_W_BY_MODE = { compact = 740, float = 1180 }

local function panelWidth(): number
	return PANEL_W_BY_MODE[MODO] or PANEL_W_BY_MODE.compact
end

-- Ancho útil del contenido: el surface menos el padding horizontal.
local function PANEL_INNER(): number
	return panelWidth() - 12
end

-- La rejilla: el compacto (740 px) muestra una sola columna; el flotante
-- (1180 px) va en dos. Con una fila de 1156 px quedaban ~900 px muertos
-- entre el título y los botones de progreso, y la lista mostraba la mitad
-- de los títulos por página.
local COLS_BY_MODE = { compact = 1, float = 2 }
local COL_GAP = 8

local function gridCols(): number
	return COLS_BY_MODE[MODO] or 1
end

-- Ancho EXPLÍCITO de la fila. Sin esto el `ui.row` se mide por contenido: el
-- título largo empuja y la tarjeta se sale del panel.
-- En la rejilla es el ancho de UNA celda, no el del panel entero.
local function ROW_W(): number
	local available = PANEL_INNER() - 12
	local cols = gridCols()
	if cols <= 1 then
		return available
	end
	return math.floor((available - COL_GAP * (cols - 1)) / cols)
end

-- Ancho de una línea completa de la rejilla (las celdas + los huecos).
local function GRID_W(): number
	return PANEL_INNER() - 12
end

local ROW_H_BY_DENSITY = { compact = 60, cozy = 68, comfortable = 76 }

local function rowHeight(): number
	local base = ROW_H_BY_DENSITY[prefs.density()] or 68
	-- La fila nunca puede ser más baja que la carátula + padding.
	return math.max(base, coverH() + 16)
end
-- Ancho disponible para el título: fila − padding − portada − gaps − 2 botones.
local function TITLE_W(): number
	return ROW_W() - 16 - COVER_W - 28 - 28 - 40
end
-- Filas por página. Sin rueda en los paneles, la navegación tiene que ser por
-- botones: 12 filas entran en el alto del panel y el resto es paginado.
-- Alto útil de la lista dentro del panel. Las filas de la página entran justas:
-- si sobra contenido, el panel recorta y no hay forma de llegar (la rueda no
-- se entrega a los paneles).
-- El alto de la lista se deriva del panel real: con 512 fijos y el panel de 720
-- quedaban ~130 px muertos, y al pasar a 9 filas la última se salía del surface.
local PANEL_H_BY_MODE = { compact = 720, float = 820 }

local function panelHeight(): number
	return PANEL_H_BY_MODE[MODO] or PANEL_H_BY_MODE.compact
end

-- header + pestañas + pie de página + paddings del contenedor raíz
local CHROME_H = 168

local function listHeight(): number
	return math.max(240, panelHeight() - CHROME_H)
end

local function pageSize(): number
	-- n filas de alto h con gap 6 tienen que entrar en el alto disponible.
	-- En el flotante la rejilla es de varias columnas: cada "fila" de la
	-- rejilla son `gridCols()` tarjetas, así que una página trae cols× más.
	return math.max(3, math.floor((listHeight() + 6) / (rowHeight() + 6)))
end

-- Cuántas tarjetas entran en una página (una por celda de la rejilla).
local function pageCount(): number
	return pageSize() * gridCols()
end

-- Agrupa las tarjetas en bandas horizontales de la rejilla. El scroll
-- recibe las bandas, no las tarjetas sueltas: en el flotante (1180 px) una
-- fila estirada a 1156 px dejaba ~900 px muertos entre el título y los
-- botones, y la página mostraba la mitad de los títulos.
local function gridBands(cells: { any }): { any }
	local cols = gridCols()
	if cols <= 1 then
		return cells
	end
	local bands: { any } = {}
	local band: { any } = {}
	local index = 0
	for _, cell in ipairs(cells) do
		table.insert(band, cell)
		if #band == cols then
			index += 1
			table.insert(bands, ui.row({
				key = "band-" .. tostring(index),
				gap = COL_GAP,
				width = GRID_W(),
				align = "start",
			}, band))
			band = {}
		end
	end
	if #band > 0 then
		index += 1
		table.insert(bands, ui.row({
			key = "band-" .. tostring(index),
			gap = COL_GAP,
			width = GRID_W(),
			align = "start",
		}, band))
	end
	return bands
end

-- Alto exacto para las filas que se dibujan: si el scroll queda más alto que
-- n*pitch-gap, la última fila entra a medias y se ve amputada.
local function exactListHeight(): number
	return pageSize() * (rowHeight() + 6) - 6
end

-- Estado del panel. Los snapshots se guardan aparte para leer siempre el valor
-- que entrega el watcher (state.get puede venir un frame atrás).
local SNAP = {
	stats = nil :: any,
	library = nil :: any,
	covers = nil :: any,
	status = nil :: any,
	discover = nil :: any,
	detail = nil :: any,
	schedule = nil :: any,
	filters = nil :: any,
}

local S = {
	screen = "library" :: string,
	view = "library" :: string,
	kind = "trending" :: string,
	discPage = 1,
	schedPage = 1,
	tab = "ANIME" :: string,
	previewId = nil :: number?,
	page = 1,
	-- Filtros y orden. El service los publica y los guarda; el panel los
	-- aplica sobre la lista que ya tiene en memoria.
	filterStatus = "" :: string,
	filterGenre = "" :: string,
	sort = "updated" :: string,
	requestCount = 0,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
}

-- Los estados que AniList maneja en la lista del usuario. El orden de acá
-- es el orden del selector.
local STATUS_FILTERS = {
	{ status = "", label = T("panel.filter.all") },
	{ status = "CURRENT", label = T("panel.filter.current") },
	{ status = "PLANNING", label = T("panel.filter.planning") },
	{ status = "COMPLETED", label = T("panel.filter.completed") },
	{ status = "DROPPED", label = T("panel.filter.dropped") },
	{ status = "PAUSED", label = T("panel.filter.paused") },
	{ status = "REPEATING", label = T("panel.filter.repeating") },
}

-- Los órdenes que ofrece el panel. El primero es el que se usa por defecto.
local SORT_OPTIONS = {
	{ value = "updated", label = T("panel.sort.updated") },
	{ value = "title", label = T("panel.sort.title") },
	{ value = "progress", label = T("panel.sort.progress") },
	{ value = "airing", label = T("panel.sort.airing") },
	{ value = "score", label = T("panel.sort.score") },
}


local function nowMs(): number
	return math.floor(os.clock() * 1000)
end

local function send(payload: any): ()
	S.requestCount += 1
	payload.nonce = tostring(nowMs()) .. ":" .. tostring(S.requestCount)
	noctalia.state.set(REQUEST_KEY, payload)
end

-- Los filtros y el orden van al service, que los guarda y los publica: así
-- sobreviven al cierre del panel. El panel los aplica al instante sobre la
-- lista que ya tiene, sin esperar la vuelta.
local function enviarFiltros(): ()
	send({
		action = "filters",
		status = S.filterStatus,
		genre = S.filterGenre,
		sort = S.sort,
	})
end

-- Un solo accesor: los tres snapshots se leen igual y siempre del valor que
-- entregó el watcher (state.get puede venir un frame atrás).
local function snapshot(field: string, key: string): { [string]: any }
	local cached = SNAP[field]
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(key)
	return type(value) == "table" and value or {}
end

local function libraryTable(): { [string]: any }
	return snapshot("library", LIBRARY_KEY)
end

local function coversTable(): { [string]: any }
	return snapshot("covers", COVERS_KEY)
end

local function statusTable(): { [string]: any }
	return snapshot("status", STATUS_KEY)
end

local function currentList(): { any }
	local lib = libraryTable()
	local list = if S.tab == "MANGA" then lib.manga else lib.anime
	return type(list) == "table" and list or {}
end

-- El estado de los filtros y la lista de géneros los publica el service.
local function filtersTable(): { [string]: any }
	return snapshot("filters", FILTER_KEY)
end

local function detailTable(): { [string]: any }
	return snapshot("detail", DETAIL_KEY)
end

local function scheduleTable(): { [string]: any }
	return snapshot("schedule", SCHEDULE_KEY)
end

local function scheduleItems(): { any }
	local data = scheduleTable()
	return type(data.items) == "table" and data.items or {}
end

local SORT_KEYS = {
	updated = function(e) return tonumber(e.updatedAt) or 0 end,
	title = function(e) return string.lower(tostring(e.title or "")) end,
	score = function(e) return tonumber(e.score) or 0 end,
	progress = function(e) return tonumber(e.progress) or 0 end,
	airing = function(e) return tonumber(e.airingAt) or math.huge end,
}

-- El orden por progreso y por airing tienen un matiz: dos entradas con el
-- mismo valor se ordenan por título, así la lista no baila entre renders.
local function filtered(): { any }
	local ocultarPlaneados = cfgBool("hide_planning", false)
	local wanted = S.filterStatus
	local genero = S.filterGenre
	local out = {}
	for _, entry in ipairs(currentList()) do
		local incluir = (wanted == "" or entry.status == wanted)
			and not (ocultarPlaneados and entry.status == "PLANNING")
		if incluir and genero ~= "" then
			local coincide = false
			local genres = entry.genres
			if type(genres) == "table" then
				for _, g in ipairs(genres) do
					if tostring(g) == genero then
						coincide = true
						break
					end
				end
			end
			incluir = coincide
		end
		if incluir then
			table.insert(out, entry)
		end
	end
	local clave = S.sort
	local orden = SORT_KEYS[clave] or SORT_KEYS.updated
	local descendente = clave ~= "title" and clave ~= "airing"
	table.sort(out, function(a, b)
		local va, vb = orden(a), orden(b)
		if va == vb then
			return tostring(a.title or "") < tostring(b.title or "")
		end
		return if descendente then va > vb else va < vb
	end)
	return out
end

-- Accesores del catálogo. Van ANTES de las piezas de UI: `tabs()` los usa y
-- un local declarado más abajo es nil en el momento de crear la closure.
local function discoverTable(): { [string]: any }
	return snapshot("discover", DISCOVER_KEY)
end

local function discoverItems(): { any }
	local data = discoverTable()
	local items = data.items
	return type(items) == "table" and items or {}
end

-- ── piezas de UI ─────────────────────────────────────────────────────

local function coverFor(entry: any): any
	local covers = coversTable()
	local path = covers[tostring(entry.mediaId)]
	if type(path) == "string" and path ~= "" then
		return ui.image({
			path = path,
			width = COVER_W,
			height = coverH(),
			radius = 6,
			fit = "cover",
			onClick = function()
				S.previewId = tonumber(entry.mediaId)
				S.screen = "preview"
			pedirDetalle(S.previewId)
				pedirDetalle(S.previewId)
				render()
			end,
		})
	end
	-- Placeholder con el color dominante que informa AniList: se ve intencional,
	-- no como un hueco negro.
	local color = entry.coverColor
	return ui.box({
		width = COVER_W,
		height = coverH(),
		radius = 6,
		fill = if type(color) == "string" and color ~= "" then color else theme.chip(),
	})
end

local function progressText(entry: any): string
	local progress = tonumber(entry.progress) or 0
	local total = tonumber(entry.total) or 0
	if total > 0 then
		return tostring(progress) .. " / " .. tostring(total)
	end
	return tostring(progress)
end

-- La cuenta regresiva de un airing: "en 3d 4h" o "en 2h 15m".
local function countdown(at: number): string
	local diff = at - os.time()
	if diff <= 0 then
		return ""
	end
	local days = math.floor(diff / 86400)
	local hours = math.floor((diff % 86400) / 3600)
	if days > 0 then
		return tostring(days) .. "d " .. tostring(hours) .. "h"
	end
	local minutes = math.floor((diff % 3600) / 60)
	return tostring(hours) .. "h " .. tostring(minutes) .. "m"
end

local function airingText(entry: any): string
	if not cfgBool("show_airing", true) then
		return ""
	end
	local at = tonumber(entry.airingAt)
	local episode = tonumber(entry.airingEpisode)
	if at == nil or at == 0 then
		return ""
	end
	local when = countdown(at)
	if when == "" then
		return ""
	end
	return "ep " .. tostring(episode or 0) .. " en " .. when
end

local function step(entry: any, delta: number): ()
	local progress = math.max(0, (tonumber(entry.progress) or 0) + delta)
	local status = ""
	local total = tonumber(entry.total) or 0
	if total > 0 and progress >= total then
		status = "COMPLETED"
	end
	send({ action = "mutate", mediaId = entry.mediaId, progress = progress, status = status })
end

local function row(entry: any, index: number): any
	local alpha = 1
	if S.anim.t < 1 then
		alpha = 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.04)
	end
	local airing = airingText(entry)
	local subtitle = progressText(entry)
	if airing ~= "" then
		subtitle = subtitle .. "  ·  " .. airing
	end
	return ui.row({
		key = "row-" .. tostring(entry.mediaId),
		width = ROW_W(),
		height = rowHeight(),
		gap = 10,
		padding = 8,
		align = "center",
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		coverFor(entry),
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({
				text = tostring(entry.title or ""),
				fontSize = 14,
				fontWeight = "semibold",
				maxLines = 1,
				maxWidth = TITLE_W(),
			}),
			ui.label({ text = layout.ellipsis(subtitle, 46), fontSize = 12, color = theme.muted(), maxLines = 1, maxWidth = TITLE_W() }),
		}),
		ui.button({ glyph = "minus", controlSize = "sm", variant = "ghost", tooltip = "−1", onClick = function() step(entry, -1) end }),
		ui.button({ glyph = "plus", controlSize = "sm", variant = "ghost", tooltip = "+1", onClick = function() step(entry, 1) end }),
	})
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "book-2"
end

local function header(): any
	local lib = libraryTable()
	local status = statusTable()
	local viewer = type(lib.viewer) == "table" and lib.viewer.name or ""
	local busy = status.busy == true
	return ui.row({ gap = 8, padding = 8, align = "center" }, {
		ui.glyph({ name = glyphName(), size = 18 }),
		ui.label({ text = "AniList", fontSize = 16, fontWeight = "semibold" }),
		ui.label({ text = viewer, fontSize = 12, color = theme.muted(), maxWidth = 160, maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({
			text = if busy then T("panel.syncing") else T("panel.current_count", { count = tostring(status.current or 0) }),
			fontSize = 12,
			color = if busy then theme.warn() else theme.muted(),
		}),
		ui.button({ glyph = "refresh", controlSize = "sm", variant = "ghost", tooltip = T("panel.sync"), onClick = function() send({ action = "sync" }) end }),
		ui.button({ glyph = "settings", controlSize = "sm", variant = "ghost", tooltip = T("panel.settings"), onClick = function() noctalia.openSettings() end }),
	})
end

local KINDS = {
	{ label = T("panel.kind.trending"), value = "trending" },
	{ label = T("panel.kind.popular"), value = "popular" },
	{ label = T("panel.kind.top"), value = "top" },
	{ label = T("panel.kind.new"), value = "new" },
	{ label = T("panel.kind.seasonal"), value = "seasonal" },
}

local function kindIndex(): number
	for index, kind in ipairs(KINDS) do
		if kind.value == S.kind then
			return index - 1
		end
	end
	return 0
end

local function statusIndex(): number
	for index, filtro in ipairs(STATUS_FILTERS) do
		if filtro.status == S.filterStatus then
			return index - 1
		end
	end
	return 0
end

local function sortIndex(): number
	for index, option in ipairs(SORT_OPTIONS) do
		if option.value == S.sort then
			return index - 1
		end
	end
	return 0
end

-- El orden puede venir del estado compartido con un valor que este panel no
-- ofrece (otro plugin, una versión anterior, un archivo escrito a mano). Si
-- no se normaliza, el selector muestra "Recently updated" pero S.sort sigue
-- siendo el otro valor, y el estado publicado no corresponde con la
-- pantalla. Se deja el valor real y se avisa.
local function normalizarOrden(): ()
	for _, option in ipairs(SORT_OPTIONS) do
		if option.value == S.sort then
			return
		end
	end
	noctalia.log("[b3l0w-anilist] orden desconocido: " .. tostring(S.sort) .. " → updated")
	S.sort = "updated"
end

-- La lista de géneros la publica el service (sale de la biblioteca, no de una
-- lista fija de AniList): así el selector ofrece sólo lo que el usuario tiene.
local function genreOptions(): { string }
	local options: { string } = { T("panel.genre.all") }
	local data = filtersTable()
	local genres = data.genres
	if type(genres) == "table" then
		for _, genero in ipairs(genres) do
			table.insert(options, tostring(genero))
		end
	end
	return options
end

-- El índice del género elegido dentro de la lista de opciones (la primera es
-- "Todos"). Si el género ya no está en la biblioteca, el selector vuelve a
-- "Todos" en vez de quedar apuntando a algo inexistente.
local function genreIndex(): number
	local options = genreOptions()
	for index, option in ipairs(options) do
		if index > 1 and option == S.filterGenre then
			return index - 1
		end
	end
	return 0
end

-- La barra de filtros: estado, género y orden. Cada cambio va al service,
-- que los guarda y los publica; el panel los aplica sobre la lista.
local function filterBar(): any
	local statusOptions: { string } = {}
	for _, filtro in ipairs(STATUS_FILTERS) do
		table.insert(statusOptions, filtro.label)
	end
	local genreList = genreOptions()
	return ui.row({ gap = 8, paddingH = 8, align = "center" }, {
		ui.label({ text = T("panel.filter.label"), fontSize = 11, color = theme.dim(), maxLines = 1 }),
		ui.select({
			options = statusOptions,
			selectedIndex = statusIndex(),
			controlSize = "sm",
			width = 132,
			onChange = function(index: any)
				local filtro = STATUS_FILTERS[(tonumber(index) or 0) + 1]
				if filtro == nil then
					return
				end
				S.filterStatus = filtro.status
				S.page = 1
				S.anim.t = 0
				enviarFiltros()
				render()
			end,
		}),
		ui.select({
			options = genreList,
			selectedIndex = genreIndex(),
			controlSize = "sm",
			width = 148,
			onChange = function(index: any)
				local elegido = genreList[(tonumber(index) or 0) + 1]
				S.filterGenre = if elegido == nil then "" else elegido
				S.page = 1
				S.anim.t = 0
				enviarFiltros()
				render()
			end,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.label({ text = T("panel.sort.label"), fontSize = 11, color = theme.dim(), maxLines = 1 }),
		ui.select({
			options = (function(): { string }
				local opciones: { string } = {}
				for _, option in ipairs(SORT_OPTIONS) do
					table.insert(opciones, option.label)
				end
				return opciones
			end)(),
			selectedIndex = sortIndex(),
			controlSize = "sm",
			width = 138,
			onChange = function(index: any)
				local option = SORT_OPTIONS[(tonumber(index) or 0) + 1]
				if option == nil then
					return
				end
				S.sort = option.value
				S.page = 1
				S.anim.t = 0
				enviarFiltros()
				render()
			end,
		}),
	})
end

local function tabs(): any
	local function tabButton(label: string, value: string, target: string)
		local active = S.tab == value
		return ui.button({
			text = label,
			controlSize = "sm",
			variant = if active then "secondary" else "ghost",
			selected = active,
			onClick = function()
				if S.tab == value and S.view == target then
					return
				end
				S.tab = value
				S.view = target
				S.page = 1
				S.anim.t = 0
				render()
			end,
		})
	end
	local right: any
	if S.view == "discover" then
		local kinds: { string } = {}
		for _, kind in ipairs(KINDS) do
			table.insert(kinds, kind.label)
		end
		right = ui.select({
			options = kinds,
			selectedIndex = kindIndex(),
			controlSize = "sm",
			width = 176,
			onChange = function(index: any)
				S.kind = KINDS[(tonumber(index) or 0) + 1].value
				S.page = 1
				S.anim.t = 0
				send({ action = "discover", kind = S.kind, page = 1 })
			end,
		})
	end
	return ui.row({ gap = 8, paddingH = 8, align = "center" }, {
		tabButton(T("panel.tab.anime"), "ANIME", "library"),
		tabButton(T("panel.tab.manga"), "MANGA", "library"),
		ui.button({
			text = T("panel.tab.discover"),
			controlSize = "sm",
			variant = if S.view == "discover" then "secondary" else "ghost",
			selected = S.view == "discover",
			onClick = function()
				if S.view == "discover" then
					return
				end
				S.view = "discover"
				S.page = 1
				S.anim.t = 0
				if #discoverItems() == 0 then
					send({ action = "discover", kind = S.kind, page = S.discPage })
				end
				render()
			end,
		}),
		ui.button({
			text = T("panel.tab.schedule"),
			controlSize = "sm",
			variant = if S.view == "schedule" then "secondary" else "ghost",
			selected = S.view == "schedule",
			onClick = function()
				if S.view == "schedule" then
					return
				end
				S.view = "schedule"
				S.page = 1
				S.schedPage = 1
				S.anim.t = 0
				-- La agenda cambia cada hora: se pide siempre al abrirla para
				-- que no muestre los capítulos de hace dos días.
				send({ action = "schedule" })
				render()
			end,
		}),
		ui.spacer({ flexGrow = 1 }),
		right,
	})
end

-- ── descubrimiento ───────────────────────────────────────────────────

local function discoverRow(item: any, index: number): any
	local alpha = 1
	if S.anim.t < 1 then
		alpha = 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.05)
	end
	local covers = coversTable()
	local path = covers[tostring(item.id)]
	local visual: any
	if type(path) == "string" and path ~= "" then
		visual = ui.image({
			path = path,
			width = COVER_W,
			height = coverH(),
			radius = 6,
			fit = "cover",
			onClick = function()
				S.previewId = tonumber(item.id)
				S.screen = "preview"
				pedirDetalle(S.previewId)
				render()
			end,
		})
	else
		visual = ui.box({ width = COVER_W, height = coverH(), radius = 6, fill = tostring(item.coverColor or theme.chip()) })
	end
	local meta: { string } = {}
	if (tonumber(item.score) or 0) > 0 then
		table.insert(meta, "★ " .. tostring(item.score))
	end
	if (tonumber(item.episodes) or 0) > 0 then
		table.insert(meta, tostring(item.episodes) .. " ep")
	end
	if type(item.season) == "string" and item.season ~= "" then
		table.insert(meta, tostring(item.season) .. " " .. tostring(item.seasonYear or ""))
	end
	local genres = type(item.genres) == "table" and table.concat(item.genres, " · ", 1, math.min(3, #item.genres)) or ""
	return ui.row({
		key = "disc-" .. tostring(item.id),
		width = ROW_W(),
		height = rowHeight(),
		gap = 10,
		padding = 8,
		align = "center",
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
		onClick = function()
			S.previewId = tonumber(item.id)
			S.screen = "preview"
			pedirDetalle(S.previewId)
			render()
		end,
	}, {
		visual,
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({
				text = tostring(item.title or ""),
				fontSize = 14,
				fontWeight = "semibold",
				maxLines = 1,
				maxWidth = TITLE_W(),
			}),
			ui.label({
				text = table.concat(meta, "  ·  "),
				fontSize = 12,
				color = theme.muted(),
				maxLines = 1,
				maxWidth = TITLE_W(),
			}),
			ui.label({ text = genres, fontSize = 11, color = theme.dim(), maxLines = 1, maxWidth = TITLE_W() }),
		}),
	})
end

local function discoverView(): any
	local items = discoverItems()
	local data = discoverTable()
	local perPage = pageSize()
	local pages = math.max(1, math.ceil((tonumber(data.total) or 0) / math.max(1, perPage)))
	if not data.hasNext and pages > S.page then
		pages = S.page
	end
	local children: { any } = { header(), tabs() }
	if #items == 0 then
		table.insert(children, ui.column({ padding = 24, align = "center" }, {
			ui.label({
				text = if statusTable().busy == true then T("panel.loading_catalog") else T("panel.pick_kind"),
				fontSize = 13,
				color = theme.muted(),
			}),
		}))
		table.insert(children, ui.row({ gap = 8, padding = 4, align = "center", justify = "center" }, {
			ui.button({
				text = T("panel.load_trending"),
				variant = "primary",
				controlSize = "sm",
				onClick = function() send({ action = "discover", kind = S.kind, page = 1 }) end,
			}),
		}))
		return ui.column({ gap = 6 }, children)
	end
	local list: { any } = {}
	for index, item in ipairs(items) do
		table.insert(list, discoverRow(item, index))
	end
	table.insert(children, ui.scroll(layout.merge({
		key = "discover-scroll",
		gap = 6,
		paddingH = 2,

		align = "center",
	}, layout.scrollExtra(exactListHeight())), gridBands(list)))
	table.insert(children, ui.row({ gap = 8, padding = 4, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.discPage > 1,
			onClick = function()
				S.discPage = math.max(1, S.discPage - 1)
				S.anim.t = 0
				send({ action = "discover", kind = S.kind, page = S.discPage })
			end,
		}),
		ui.label({
			text = T("panel.page_discover", { page = tostring(S.discPage), count = tostring(#items) }),
			fontSize = 12,
			color = theme.muted(),
			maxWidth = 320,
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = data.hasNext == true,
			onClick = function()
				S.discPage = S.discPage + 1
				S.anim.t = 0
				send({ action = "discover", kind = S.kind, page = S.discPage })
			end,
		}),
	}))
	return ui.column({ gap = 6 }, children)
end

-- ── agenda de emisión ────────────────────────────────────────────────

-- Una fila de la agenda: la carátula, el título, el capítulo y cuánto falta.
local function scheduleRow(item: any, index: number): any
	local alpha = 1
	if S.anim.t < 1 then
		alpha = 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.05)
	end
	local mediaId = tonumber(item.mediaId) or 0
	local visual: any
	local covers = coversTable()
	local path = covers[tostring(mediaId)]
	if type(path) == "string" and path ~= "" then
		visual = ui.image({
			path = path,
			width = COVER_W,
			height = coverH(),
			radius = 6,
			fit = "cover",
			onClick = function()
				S.previewId = mediaId
				S.screen = "preview"
				pedirDetalle(mediaId)
				render()
			end,
		})
	else
		visual = ui.box({
			width = COVER_W,
			height = coverH(),
			radius = 6,
			fill = if type(item.coverColor) == "string" and item.coverColor ~= "" then item.coverColor else theme.chip(),
		})
	end
	local at = tonumber(item.airingAt) or 0
	local when = countdown(at)
	local episode = tonumber(item.episode) or 0
	local subtitulo = T("panel.schedule.episode", { episode = tostring(episode) })
	if when ~= "" then
		subtitulo = subtitulo .. "  ·  " .. when
	end
	return ui.row({
		key = "sched-" .. tostring(mediaId) .. "-" .. tostring(episode),
		width = ROW_W(),
		height = rowHeight(),
		gap = 10,
		padding = 8,
		align = "center",
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
		onClick = function()
			S.previewId = mediaId
			S.screen = "preview"
			pedirDetalle(mediaId)
			render()
		end,
	}, {
		visual,
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({
				text = tostring(item.title or ""),
				fontSize = 14,
				fontWeight = "semibold",
				maxLines = 1,
				maxWidth = TITLE_W(),
			}),
			ui.label({ text = subtitulo, fontSize = 12, color = theme.muted(), maxLines = 1, maxWidth = TITLE_W() }),
		}),
	})
end

-- La agenda: los capítulos que se emiten de las series que el usuario sigue.
--
-- La consulta la pide el service, así que el panel avisa cuando entra a la
-- vista y espera. Antes la agenda sólo se pedía con el clic en la pestaña:
-- abrir el panel en Emisión (por IPC o al reabrir) la dejaba vacía para
-- siempre y decía "no hay capítulos próximos" aunque los hubiera.
local function scheduleView(): any
	local data = scheduleTable()
	local items = scheduleItems()
	local children: { any } = { header(), tabs() }
	if #items == 0 then
		local cargando = data.loading == true
		-- `err` y no `error`: `error` es el nombre de una global de Luau y
		-- el auditor lo marcaría como global implícito al sombrearlo.
		local err = data.error
		local texto = T("panel.schedule.empty")
		if cargando then
			texto = T("panel.schedule.loading")
		elseif type(err) == "string" and err ~= "" then
			texto = err
		end
		table.insert(children, ui.column({ padding = 24, align = "center" }, {
			ui.label({
				text = texto,
				fontSize = 13,
				color = if type(err) == "string" and err ~= "" then theme.danger() else theme.muted(),
				textAlign = "center",
				maxWidth = PANEL_INNER() - 48,
				maxLines = 3,
			}),
		}))
		-- El error se muestra con el botón de reintento: si la consulta
		-- falló, el usuario tiene que poder volver a pedirla.
		if type(err) == "string" and err ~= "" then
			table.insert(children, ui.row({ gap = 8, padding = 4, align = "center", justify = "center" }, {
				ui.button({
					text = T("panel.retry"),
					variant = "primary",
					controlSize = "sm",
					onClick = function() send({ action = "schedule" }) end,
				}),
			}))
		end
		return ui.column({ gap = 6 }, children)
	end
	local perPage = pageCount()
	local pages = math.max(1, math.ceil(#items / perPage))
	-- Página local: mutar S.schedPage durante el render compite con el reset
	-- al cambiar de vista y deja el pie apuntando a una página inexistente.
	local page = math.max(1, math.min(S.schedPage, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#items, first + perPage - 1)
	local cells: { any } = {}
	for index = first, last do
		table.insert(cells, scheduleRow(items[index], index - first + 1))
	end
	table.insert(children, ui.scroll(layout.merge({
		key = "schedule-scroll",
		gap = 6,
		paddingH = 2,
		align = "center",
	}, layout.scrollExtra(exactListHeight())), gridBands(cells)))
	table.insert(children, ui.row({ gap = 8, padding = 4, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = page > 1,
			onClick = function()
				S.schedPage = math.max(1, page - 1)
				S.anim.t = 0
				render()
			end,
		}),
		ui.label({
			text = T("panel.page_of", { page = tostring(page), pages = tostring(pages), total = tostring(#items) }),
			fontSize = 12,
			color = theme.muted(),
			maxWidth = 320,
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = page < pages,
			onClick = function()
				S.schedPage = math.min(pages, page + 1)
				S.anim.t = 0
				render()
			end,
		}),
	}))
	return ui.column({ gap = 6 }, children)
end

-- La tarjeta del panel y la del descubridor abren esta ficha. Busca primero en
-- la biblioteca (tiene estado y progreso) y cae al catálogo de discover.
local function previewItem(): (any, string?)
	local id = tonumber(S.previewId)
	if id == nil then
		return nil, nil
	end
	for _, entry in ipairs(libraryTable().anime or {}) do
		if tonumber(entry.mediaId) == id then
			return entry, "library"
		end
	end
	for _, entry in ipairs(libraryTable().manga or {}) do
		if tonumber(entry.mediaId) == id then
			return entry, "library"
		end
	end
	for _, item in ipairs(discoverItems()) do
		if tonumber(item.id) == id then
			return item, "discover"
		end
	end
	return nil, nil
end

-- La ficha que trae la API (sinopsis, géneros, próximo capítulo). El service
-- la pide al abrir el detalle y la publica; acá sólo se lee.
local function detailFor(id: number): any
	local data = detailTable()
	if tonumber(data.id) ~= id then
		return nil
	end
	return data
end

-- Pide la ficha de una serie al service. Se llama al abrir el detalle: la
-- biblioteca no trae sinopsis y son 300 entradas.
local function pedirDetalle(mediaId: number): ()
	send({ action = "detail", mediaId = mediaId })
end

local function previewCover(item: any): any
	local id = tostring(item.mediaId or item.id or "")
	local covers = coversTable()
	local path = covers[id]
	if type(path) == "string" and path ~= "" then
		return ui.image({ path = path, width = 196, height = 280, radius = 10, fit = "cover" })
	end
	local color = item.coverColor
	return ui.box({
		width = 196,
		height = 280,
		radius = 10,
		fill = if type(color) == "string" and color ~= "" then color else theme.chip(),
	})
end

-- Las píldoras de género. Se envuelven en un row porque `ui.box` es una hoja:
-- no acepta hijos (el host los dropea en silencio y el chip queda vacío).
local function genreChips(genres: any): any
	local lista: { any } = {}
	for _, genero in ipairs(type(genres) == "table" and genres or {}) do
		table.insert(lista, ui.row({
			fill = theme.chip(),
			radius = 6,
			paddingH = 6,
			paddingV = 2,
			align = "center",
		}, { ui.label({ text = tostring(genero), fontSize = 11, color = theme.muted() }) }))
	end
	if #lista == 0 then
		return ui.row({ gap = 6, align = "center" }, {})
	end
	return ui.row({ gap = 6, align = "center" }, lista)
end

local function previewView(): any
	local item, origen = previewItem()
	local function volver()
		S.screen = "library"
		S.previewId = nil
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	end
	if item == nil then
		return ui.column({ gap = 10, padding = 12, align = "start" }, {
			ui.label({ text = T("panel.preview.missing"), fontSize = 13, color = theme.muted() }),
			ui.button({ text = T("panel.back"), controlSize = "sm", onClick = volver }),
		})
	end

	local enBiblioteca = origen == "library"
	local id = tonumber(item.mediaId or item.id) or 0
	local ficha = detailFor(id)
	-- La ficha de la API es la fuente de la sinopsis, los géneros y el
	-- próximo capítulo: la biblioteca no los trae.
	local total = tonumber(item.total or item.episodes) or 0
	local score = tonumber(item.score) or 0
	local meta: { string } = {}
	if type(item.format) == "string" and item.format ~= "" then
		table.insert(meta, string.gsub(item.format, "_", " "))
	end
	if total > 0 then
		table.insert(meta, tostring(total) .. " " .. T("panel.preview.episodes"))
	end
	if type(item.season) == "string" and item.season ~= "" then
		table.insert(meta, item.season .. " " .. tostring(item.seasonYear or ""))
	end
	if score > 0 then
		table.insert(meta, "★ " .. string.format("%.1f", score / 10))
	end

	local generos = genreChips(if ficha ~= nil then ficha.genres else item.genres)
	local descripcion = ""
	if ficha ~= nil then
		descripcion = tostring(ficha.description or "")
	else
		descripcion = tostring(item.summary or "")
	end
	descripcion = string.gsub(descripcion, "<[^>]*>", "")
	descripcion = string.gsub(descripcion, "&quot;", '"')
	descripcion = string.sub(descripcion, 1, 900)
	-- de CPU del host. Se recorta.
	-- recarga el layout en cada frame y el render se pasa del presupuesto
	-- La sinopsis de AniList puede medir miles de caracteres: pintarla entera
	descripcion = string.gsub(descripcion, "&#039;", "'")
	descripcion = string.gsub(descripcion, "&amp;", "&")

	-- Episodios vistos / total: el progreso de la biblioteca si el título
	-- está en la lista; si no, el que trae la ficha de la API.
	local vistos = tonumber(item.progress) or 0
	if ficha ~= nil and tonumber(ficha.progress) ~= nil and ficha.progress ~= nil then
		vistos = tonumber(ficha.progress) or vistos
	end
	local totalFinal = total
	if ficha ~= nil and (tonumber(ficha.episodes) or 0) > 0 then
		totalFinal = tonumber(ficha.episodes) or totalFinal
	elseif ficha ~= nil and (tonumber(ficha.chapters) or 0) > 0 then
		totalFinal = tonumber(ficha.chapters) or totalFinal
	end

	-- El próximo capítulo: la ficha de la API si ya llegó; si no, el que
	-- venía en la biblioteca.
	local proximo = ""
	local airingAt = 0
	local airingEp = 0
	if ficha ~= nil and type(ficha.nextAiring) == "table" then
		airingAt = tonumber(ficha.nextAiring.airingAt) or 0
		airingEp = tonumber(ficha.nextAiring.episode) or 0
	else
		airingAt = tonumber(item.airingAt) or 0
		airingEp = tonumber(item.airingEpisode) or 0
	end
	if airingAt > 0 then
		local when = countdown(airingAt)
		if when ~= "" then
			proximo = T("panel.detail.next_airing", { episode = tostring(airingEp), when = when })
		end
	end

	local acciones: { any } = {}
	if enBiblioteca then
		table.insert(acciones, ui.row({
			fill = theme.chip(),
			radius = 6,
			paddingH = 8,
			paddingV = 4,
			align = "center",
		}, {
			ui.label({
				text = tostring(item.status or "") .. "  ·  " .. progressText(item),
				fontSize = 11,
				color = theme.info(),
			}),
		}))
		table.insert(acciones, ui.button({
			text = "+1",
			controlSize = "sm",
			variant = "primary",
			onClick = function()
				step(item, 1)
			end,
		}))
		table.insert(acciones, ui.button({
			text = "−1",
			controlSize = "sm",
			onClick = function()
				step(item, -1)
			end,
		}))
	else
		table.insert(acciones, ui.button({
			text = T("panel.add_planning"),
			controlSize = "sm",
			variant = "primary",
			onClick = function()
				send({ action = "mutate", mediaId = item.id, progress = 0, status = "PLANNING" })
			end,
		}))
	end
	table.insert(acciones, ui.button({ text = T("panel.back"), controlSize = "sm", variant = "ghost", onClick = volver }))

	-- Los próximos capítulos de esta serie: los que trae `airingSchedule`.
	local agenda: { any } = {}
	if ficha ~= nil and type(ficha.schedule) == "table" then
		for _, capitulo in ipairs(ficha.schedule) do
			local at = tonumber(capitulo.airingAt) or 0
			local ep = tonumber(capitulo.episode) or 0
			local when = countdown(at)
			if when ~= "" then
				table.insert(agenda, ui.row({ gap = 8, align = "center" }, {
					ui.label({ text = T("panel.detail.episode", { episode = tostring(ep) }), fontSize = 11, color = theme.text(), maxLines = 1 }),
					ui.label({ text = when, fontSize = 11, color = theme.muted(), maxLines = 1 }),
				}))
			end
		end
	end

	local cuerpo: { any } = {}
	table.insert(cuerpo, ui.label({ text = tostring(item.title or ""), fontSize = 18, fontWeight = "semibold", maxLines = 2, maxWidth = PANEL_INNER() - 240 }))
	table.insert(cuerpo, ui.label({ text = table.concat(meta, "  ·  "), fontSize = 12, color = theme.muted(), maxLines = 1, maxWidth = PANEL_INNER() - 240 }))
	-- Episodios vistos sobre el total: el dato que uno busca en la ficha.
	if totalFinal > 0 then
		table.insert(cuerpo, ui.row({ gap = 8, align = "center" }, {
			ui.label({
				text = T("panel.detail.progress", {
					seen = tostring(vistos),
					total = tostring(totalFinal),
				}),
				fontSize = 12,
				color = theme.text(),
				maxLines = 1,
			}),
			ui.progress({ progress = math.min(1, vistos / totalFinal), height = 6, radius = 3, fill = theme.info() }),
		}))
	end
	table.insert(cuerpo, generos)
	if proximo ~= "" then
		table.insert(cuerpo, ui.label({ text = proximo, fontSize = 12, color = theme.warn(), maxLines = 1 }))
	end
	if #agenda > 0 then
		table.insert(cuerpo, ui.label({ text = T("panel.detail.upcoming"), fontSize = 11, fontWeight = "semibold", color = theme.muted() }))
		local listaAgenda: { any } = {}
		for _, linea in ipairs(agenda) do
			table.insert(listaAgenda, linea)
		end
		table.insert(cuerpo, ui.column({ gap = 4, align = "start" }, listaAgenda))
	end
	table.insert(cuerpo, ui.row({ gap = 8, align = "center" }, acciones))
	if descripcion ~= "" then
		table.insert(cuerpo, ui.scroll(layout.merge({ key = "preview-scroll", align = "stretch", paddingH = 2 }, layout.scrollExtra(240)), {
			ui.label({ text = descripcion, fontSize = 12, color = theme.text(), maxWidth = PANEL_INNER() - 250 }),
		}))
	elseif ficha == nil then
		table.insert(cuerpo, ui.label({ text = T("panel.detail.loading"), fontSize = 12, color = theme.muted() }))
	end

	return ui.row({ gap = 16, padding = 12, align = "start", width = PANEL_INNER() }, {
		previewCover(item),
		ui.column({ gap = 8, flexGrow = 1, minWidth = 0, align = "start" }, cuerpo),
	})
end

-- ── estadísticas ─────────────────────────────────────────────────────

local function statsTable(): { [string]: any }
	return snapshot("stats", STATS_KEY)
end

local function statsAnime(): { [string]: any }
	local data = statsTable()
	return type(data.anime) == "table" and data.anime or {}
end

local function miles(n: number): string
	local texto = tostring(math.floor(n + 0.5))
	local salida = ""
	while #texto > 3 do
		salida = "." .. string.sub(texto, -3) .. salida
		texto = string.sub(texto, 1, -4)
	end
	return texto .. salida
end

-- Franja al pie de la biblioteca: el dato que uno mira de reojo (días vistos y
-- nota media) sin abrir otra pantalla.
local function statsFooter(): any
	local anime = statsAnime()
	local dias = tonumber(anime.daysWatched) or 0
	if dias == 0 and (tonumber(anime.episodesWatched) or 0) == 0 then
		return ui.box({ height = 0 })
	end
	local generos: { string } = {}
	for _, g in ipairs(type(anime.genres) == "table" and anime.genres or {}) do
		if #generos < 2 then
			table.insert(generos, tostring(g.genre))
		end
	end
	return ui.row({ gap = 10, padding = 4, align = "center" }, {
		ui.glyph({ name = "chart-bar", size = 13 }),
		ui.label({ text = string.format("%.1f", dias) .. " " .. T("panel.stats.days"), fontSize = 11, color = theme.muted() }),
		ui.label({ text = miles(tonumber(anime.episodesWatched) or 0) .. " " .. T("panel.stats.eps"), fontSize = 11, color = theme.muted() }),
		ui.label({ text = "★ " .. string.format("%.1f", (tonumber(anime.meanScore) or 0) / 10), fontSize = 11, color = theme.warn() }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({ text = table.concat(generos, " · "), fontSize = 11, color = theme.dim(), maxWidth = 220, maxLines = 1 }),
		ui.button({
			text = T("panel.stats.more"),
			controlSize = "sm",
			variant = "ghost",
			onClick = function()
				S.screen = "stats"
				S.anim.t = if prefs.animations() then 0 else 1
				send({ action = "stats" })
				render()
			end,
		}),
	})
end

local function barra(etiqueta: string, valor: number, total: number, color: string?): any
	local pct = if total > 0 then valor / total else 0
	return ui.row({ gap = 8, align = "center", width = PANEL_INNER() - 24 }, {
		celda(etiqueta, 110, { fontSize = 11, color = theme.text(), maxLines = 1 }),
		ui.progress({ progress = math.min(1, pct), height = 8, radius = 4, fill = color }),
		celda(tostring(valor), 42, { fontSize = 11, color = theme.dim() }),
	})
end

local function statsView(): any
	local anime = statsAnime()
	local total = tonumber(anime.count) or 0
	local function volver()
		S.screen = "library"
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	end
	if total == 0 then
		return ui.column({ gap = 10, padding = 12, align = "start" }, {
			ui.label({ text = T("panel.stats.loading"), fontSize = 13, color = theme.muted() }),
			ui.button({ text = T("panel.back"), controlSize = "sm", onClick = volver }),
		})
	end
	local generos: { any } = {}
	local maxGenero = 0
	for _, g in ipairs(type(anime.genres) == "table" and anime.genres or {}) do
		maxGenero = math.max(maxGenero, tonumber(g.count) or 0)
	end
	for _, g in ipairs(type(anime.genres) == "table" and anime.genres or {}) do
		table.insert(generos, barra(tostring(g.genre), tonumber(g.count) or 0, maxGenero, "#6f9fd8"))
	end
	local notas: { any } = {}
	local maxNota = 0
	for _, s in ipairs(type(anime.scores) == "table" and anime.scores or {}) do
		maxNota = math.max(maxNota, tonumber(s.count) or 0)
	end
	for _, s in ipairs(type(anime.scores) == "table" and anime.scores or {}) do
		table.insert(notas, barra(tostring(s.score), tonumber(s.count) or 0, maxNota, theme.warn()))
	end
	return ui.column({ gap = 10, padding = 12, align = "start", width = PANEL_INNER() }, {
		ui.row({ gap = 10, align = "center" }, {
			ui.button({ glyph = "arrow-left", controlSize = "sm", variant = "ghost", onClick = volver }),
			ui.label({ text = T("panel.stats.title"), fontSize = 16, fontWeight = "semibold" }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({ text = tostring(statsTable().user or ""), fontSize = 12, color = theme.muted() }),
		}),
		ui.row({ gap = 22, align = "center" }, {
			ui.label({ text = miles(tonumber(anime.episodesWatched) or 0), fontSize = 22, fontWeight = "semibold" }),
			ui.label({ text = T("panel.stats.eps"), fontSize = 11, color = theme.dim() }),
			ui.label({ text = string.format("%.1f", tonumber(anime.daysWatched) or 0), fontSize = 22, fontWeight = "semibold" }),
			ui.label({ text = T("panel.stats.days"), fontSize = 11, color = theme.dim() }),
			ui.label({ text = string.format("%.1f", (tonumber(anime.meanScore) or 0) / 10), fontSize = 22, fontWeight = "semibold" }),
			ui.label({ text = T("panel.stats.mean"), fontSize = 11, color = theme.dim() }),
			ui.label({ text = miles(total), fontSize = 22, fontWeight = "semibold" }),
			ui.label({ text = T("panel.stats.titles"), fontSize = 11, color = theme.dim() }),
		}),
		ui.label({ text = T("panel.stats.genres"), fontSize = 12, fontWeight = "semibold", color = theme.muted() }),
		ui.column({ gap = 6, align = "start" }, generos),
		ui.label({ text = T("panel.stats.scores"), fontSize = 12, fontWeight = "semibold", color = theme.muted() }),
		ui.column({ gap = 6, align = "start" }, notas),
	})
end

local function loginView(): any
	return ui.column({ gap = 10, padding = 20, align = "center" }, {
		ui.glyph({ name = glyphName(), size = 34 }),
		ui.label({ text = T("panel.login.title"), fontSize = 16, fontWeight = "semibold" }),
		ui.label({
			text = T("panel.login.help"),
			fontSize = 12,
			color = theme.muted(),
			maxWidth = 420,
			maxLines = 3,
			textAlign = "center",
		}),
		ui.row({ gap = 8 }, {
			ui.button({ text = T("panel.settings"), variant = "primary", onClick = function() noctalia.openSettings() end }),
			ui.button({ text = T("panel.retry"), onClick = function() send({ action = "sync" }) end }),
		}),
	})
end

local function libraryView(): any
	local rows = filtered()
	local status = statusTable()
	local children: { any } = { header(), tabs(), filterBar() }
	if status.error ~= nil and status.error ~= "" then
		table.insert(children, ui.label({
			text = tostring(status.error),
			fontSize = 12,
			color = theme.danger(),
			maxWidth = PANEL_INNER(),
			maxLines = 2,
		}))
	end
	if #rows == 0 then
		table.insert(children, ui.column({ padding = 24, align = "center" }, {
			ui.label({
				text = if status.busy == true then T("panel.syncing") else T("panel.empty_filter"),
				fontSize = 13,
				color = theme.muted(),
			}),
		}))
		return ui.column({ gap = 6 }, children)
	end
	local perPage = pageCount()
	local pages = math.max(1, math.ceil(#rows / perPage))
	-- Acotar SIN mutar S.page: mutarlo durante el render compite con el
	-- reset de página al cambiar de vista y deja la paginación apuntando a
	-- una página inexistente (la lista se vacía sin aviso).
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#rows, first + perPage - 1)
	local cells: { any } = {}
	for index = first, last do
		table.insert(cells, row(rows[index], index - first + 1))
	end
	table.insert(children, ui.scroll(layout.merge({
		key = "library-scroll",
		gap = 6,
		paddingH = 2,

		align = "center",
	}, layout.scrollExtra(exactListHeight())), gridBands(cells)))
	-- Pie de página: la rueda del mouse no llega a los paneles, así que el
	-- avance tiene que estar en botones (y en las teclas Prior/Next).
	table.insert(children, ui.row({ gap = 8, padding = 4, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page > 1,
			onClick = function()
				S.page = math.max(1, S.page - 1)
				S.anim.t = 0
				render()
			end,
		}),
		ui.label({
			text = T("panel.page_of", { page = tostring(S.page), pages = tostring(pages), total = tostring(#rows) }),
			fontSize = 12,
			color = theme.muted(),
			maxWidth = 320,
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page < pages,
			onClick = function()
				S.page = math.min(pages, S.page + 1)
				S.anim.t = 0
				render()
			end,
		}),
	}))
	return ui.column({ gap = 6 }, children)
end

-- ── render ───────────────────────────────────────────────────────────

-- Traza de geometría: permite verificar sin ver la pantalla que la lista y el
-- mapa de carátulas llegaron al panel. Se emite sólo cuando cambia el conteo.
local lastTrace = ""

render = function(): ()
	local lib = libraryTable()
	local covers = coversTable()
	local totalCovers = 0
	for _ in pairs(covers) do
		totalCovers += 1
	end
	local items = discoverItems()
	local primero = type(items[1]) == "table" and tostring(items[1].title or "") or ""
	local trace = tostring(#currentList()) .. "/" .. tostring(totalCovers) .. "/" .. S.tab
		.. "/" .. S.screen .. "/" .. S.view .. "/p" .. tostring(S.page) .. "/q" .. tostring(S.discPage) .. "/f" .. tostring(#filtered())
		.. "/d" .. tostring(#items) .. "/pv" .. tostring(S.previewId or 0) .. "/sc" .. tostring(#scheduleItems())
		.. "/st" .. S.filterStatus .. "/gn" .. S.filterGenre .. "/" .. S.sort
		.. "/" .. string.sub(primero, 1, 14)
	if trace ~= lastTrace then
		lastTrace = trace
		noctalia.log("[b3l0w-anilist] entradas/caratulas/pestana/vista = " .. trace)
	end
	local body: any
	if type(lib.viewer) ~= "table" or lib.viewer.id == nil then
		body = loginView()
	elseif S.screen == "stats" then
		body = statsView()
	elseif S.screen == "preview" then
		body = previewView()
	elseif S.view == "discover" then
		body = discoverView()
	elseif S.view == "schedule" then
		body = scheduleView()
	else
		body = libraryView()
	end
	panel.render(ui.column({ gap = 4, padding = 6, align = "stretch", width = layout.width(PANEL_INNER()), height = panelHeight() }, { body }))
end

-- ── animación ────────────────────────────────────────────────────────

function M.frameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	local ms = tonumber(delta) or 16
	S.anim.t = math.min(1, S.anim.t + ms / (S.anim.ms or 220))
	render()
end

-- ── ciclo de vida ────────────────────────────────────────────────────

function M.open(context: any, mode: string?): ()
	-- El entry dice qué panel es: el host no lo pasa por el contexto.
	if mode == "compact" or mode == "float" then
		MODO = mode
	end
	-- Fuerza una traza por apertura: si no, sólo se loguea cuando cambia el
	-- conteo y no se puede verificar que las carátulas siguen ahí.
	lastTrace = ""
	SNAP.library = noctalia.state.get(LIBRARY_KEY)
	SNAP.stats = noctalia.state.get(STATS_KEY)
	SNAP.covers = noctalia.state.get(COVERS_KEY)
	SNAP.status = noctalia.state.get(STATUS_KEY)
	SNAP.discover = noctalia.state.get(DISCOVER_KEY)
	SNAP.detail = noctalia.state.get(DETAIL_KEY)
	SNAP.schedule = noctalia.state.get(SCHEDULE_KEY)
	SNAP.filters = noctalia.state.get(FILTER_KEY)
	-- Los filtros y el orden los publica el service (los guarda entre
	-- sesiones): se siembran acá porque el watcher sólo avisa de cambios
	-- POSTERIORES al registro y el panel se instancia al abrirse.
	local filtros = SNAP.filters
	if type(filtros) == "table" then
		local estado = filtros.status
		local genero = filtros.genre
		local orden = filtros.sort
		if type(estado) == "string" then
			S.filterStatus = estado
		end
		if type(genero) == "string" then
			S.filterGenre = genero
		end
		if type(orden) == "string" and orden ~= "" then
			S.sort = orden
		end
	end
	normalizarOrden()
	-- El script del panel se instancia recién al abrirlo: un `view` pedido con
	-- el panel cerrado nunca llega por el watcher (no hay cambio posterior), así
	-- que el estado de la pantalla se siembra acá.
	local pantalla = noctalia.state.get(SCREEN_KEY)
	if type(pantalla) == "table" then
		if type(pantalla.view) == "string" then
			S.view = pantalla.view
		end
		if pantalla.tab == "ANIME" or pantalla.tab == "MANGA" then
			S.tab = pantalla.tab
		end
		if type(pantalla.page) == "number" then
			S.page = pantalla.page
			S.discPage = pantalla.page
		end
		if type(pantalla.screen) == "string" and pantalla.screen ~= "" then
			S.screen = pantalla.screen
		end
		if tonumber(pantalla.preview) ~= nil then
			S.previewId = tonumber(pantalla.preview)
			S.screen = "preview"
		end
	end
	-- La página del catálogo manda sobre la de la pantalla: el service publica
	-- la que realmente trajo. Si va antes, la siembra de arriba la pisa con la
	-- página vieja y el pie miente.
	if type(SNAP.discover) == "table" and type(SNAP.discover.page) == "number" then
		S.discPage = SNAP.discover.page
	end
	S.anim.t = 0
	-- Sin refresco automático: el service ya refresca por TTL. Recargar en cada
	-- apertura era justo lo que vaciaba las carátulas en el plugin original.
	panel.setNeedsFrameTick(true)
	-- Si la vista arranca en Descubrir y no hay catálogo, hay que pedirlo: el
	-- service no lo trae solo y el panel quedaría en "elegí una categoría".
	if S.view == "discover" and #discoverItems() == 0 then
		send({ action = "discover", kind = S.kind, page = S.discPage })
	end
	-- La agenda es una consulta aparte: el service no la trae sola. Sin este
	-- pedido, abrir el panel en la pestaña Emisión la deja vacía para
	-- siempre (dice "no hay capítulos próximos" aunque los haya).
	if S.view == "schedule" and #scheduleItems() == 0 then
		send({ action = "schedule" })
	end
	render()
end

function M.close(): ()
	S.previewId = nil
	S.screen = "library"
end

function M.key(chord: string, pressed: boolean): ()
	if not pressed then
		return
	end
	if chord == "g" then
		S.tab = if S.tab == "ANIME" then "MANGA" else "ANIME"
		S.anim.t = 0
		render()
	elseif chord == "Prior" or chord == "Next" then
		local pages = math.max(1, math.ceil(#filtered() / pageSize()))
		if chord == "Next" then
			S.page = math.min(pages, S.page + 1)
		else
			S.page = math.max(1, S.page - 1)
		end
		S.anim.t = 0
		render()
	elseif chord == "Home" then
		S.screen = "library"
		S.previewId = nil
		S.anim.t = 0
		render()
	end
end

noctalia.state.watch(STATS_KEY, function(value: any)
	SNAP.stats = value
	if S.screen == "stats" or S.screen == "library" then
		render()
	end
end)

noctalia.state.watch(LIBRARY_KEY, function(value: any)
	SNAP.library = value
	render()
end)

-- Clave aparte: las carátulas llegan o cambian sin tocar la lista.
noctalia.state.watch(COVERS_KEY, function(value: any)
	SNAP.covers = value
	render()
end)

noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = value
	render()
end)

noctalia.state.watch(DISCOVER_KEY, function(value: any)
	SNAP.discover = value
	if type(value) == "table" and type(value.page) == "number" then
		S.discPage = value.page
	end
	S.anim.t = if prefs.animations() then 0 else 1
	render()
end)

-- La ficha de la serie: llega después de pedirla y repinta el detalle.
noctalia.state.watch(DETAIL_KEY, function(value: any)
	SNAP.detail = value
	render()
end)

-- La agenda de emisión.
noctalia.state.watch(SCHEDULE_KEY, function(value: any)
	SNAP.schedule = value
	render()
end)

-- Los filtros y el orden los publica el service: son la fuente de verdad
-- (el service los guarda y los aplica al abrir de nuevo).
noctalia.state.watch(FILTER_KEY, function(value: any)
	SNAP.filters = value
	if type(value) == "table" then
		local estado = value.status
		local genero = value.genre
		local orden = value.sort
		if type(estado) == "string" then
			S.filterStatus = estado
		end
		if type(genero) == "string" then
			S.filterGenre = genero
		end
		if type(orden) == "string" and orden ~= "" then
			S.sort = orden
		end
	end
	normalizarOrden()
	S.page = 1
	render()
end)

-- Abrir una vista concreta por IPC: permite testear pestañas y páginas sin
-- clickear (misma técnica que en el plugin de wallpapers).
noctalia.state.watch(SCREEN_KEY, function(value: any)
	local req = if type(value) == "table" then value else {}
	if type(req.view) == "string" then
		S.view = req.view
	end
	if type(req.tab) == "string" and (req.tab == "ANIME" or req.tab == "MANGA") then
		S.tab = req.tab
	end
	if type(req.page) == "number" then
		S.page = req.page
		S.discPage = req.page
	end
	-- Una ficha pedida por IPC (preview) tiene que ganar: si no, el deep-link
	-- cae siempre en la biblioteca y la vista pedida no aparece.
	if tonumber(req.preview) ~= nil then
		S.previewId = tonumber(req.preview)
		S.screen = "preview"
		pedirDetalle(S.previewId)
	else
		if type(req.screen) == "string" and req.screen ~= "" then
			S.screen = req.screen
		else
			S.screen = "library"
		end
		S.previewId = nil
	end
	-- La agenda se pide al entrar a la vista: es una consulta aparte y el
	-- service no la trae sola (sin esto la pestaña sale vacía).
	if S.view == "schedule" and #scheduleItems() == 0 then
		send({ action = "schedule" })
	end
	S.anim.t = if prefs.animations() then 0 else 1
	render()
end)
return M
