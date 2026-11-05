--!strict
--!nolint FunctionUnused

local engine = require("./lib/engine.luau")
local panel_size = require("./lib/panel_size.luau")
-- Panel entry. The host resolves onOpen, onClose and onKey as globals of this
-- script, which is why the file is not module-shaped and returns nothing.
--
-- Keys reach onKey only for chords declared in plugin.toml:
--   capture_keys = ["Left", "Right", "Return", "g"]
--
-- The panel owns no processes and reads no files: every action is published on
-- `wes_request` and the service carries it out.

local STATUS_KEY = "wes_status"
local CATALOG_KEY = "wes_catalog"
local STORE_KEY = "wes_store"
local NAV_KEY = "wes_nav"
local REQUEST_KEY = "wes_request"

-- Panel width from plugin.toml. The carousel paging math below depends on it.
-- Ancho del panel declarado en plugin.toml (el host lo fija, no se cambia en runtime).
-- El ancho del panel lo decide el HOST (el manifiesto declara un ancho fijo
-- y el API no tiene `setWidth`), pero cada entry sabe el suyo: lo pasa al
-- abrir. Estos valores se recalculan en `setPanelWidth`, así que el layout
-- se adapta al ancho real del panel en vez de suponer 1500.
local PANEL_PAD_H = 16

-- Ancho máximo de una tarjeta del carrusel. Antes se usaba un `MAX_FOCUS_W`
-- que NO ESTABA DEFINIDO: el slider del ancho recibía `max = nil` y el host
-- lo ignoraba. El tope real es el ancho del panel menos el cromo, dividido
-- por las celdas: una tarjeta más ancha que eso no entraría.

local TILE_GAP = 4
local TILE_DEFAULT = 200
local TILE_MIN = 120
local TILE_MAX = 340

-- Geometría del carrusel
--
-- La cantidad de wallpapers visibles es configurable (3 o 5): `slots` en la
-- sección de layout del carrusel. Con 5 se ve la tira completa (el wallpaper
-- enfocado al centro y dos a cada lado, como un coverflow); con 3 sólo el
-- enfocado y uno a cada lado.
--
-- El radio sale del conteo: slots impares -> radio = (slots - 1) / 2.
local CAROUSEL_SLOTS_MIN = 3
local CAROUSEL_SLOTS_MAX = 5
-- Ancho útil del panel: PANEL_W menos el padding horizontal.
-- El host recorta 12 px del ancho pedido (la barra de progreso midió 1456
-- de 1468), así que el ancho útil real es PANEL_W - 2*PAD - 12.
local PANEL_CROP = 12

-- ── Ancho del panel ──────────────────────────────────────────────────────
-- El host es dueño del tamaño y NO se puede cambiar en runtime: el API de
-- `panel` es `render`, `close`, `openContextMenu`, `setWantsSecondTicks` y
-- `setNeedsFrameTick` (no hay `setWidth`), y el manifiesto sólo acepta un
-- ancho entero o "fill" — no existe `width = "content"`.
--
-- Por eso el plugin declara una ESCALERA de entries con anchos fijos y abre
-- la que corresponde. Cambiar de ancho implica cerrar y reabrir el panel.
-- La escalera y la geometría viven en `lib/panel_size.luau`: las necesitan
-- también el service (para publicar qué entrada abrir) y el widget. Acá sólo
-- se guarda el ancho de ESTA entrada.
local PANEL_MIN_W = panel_size.MIN_W
local PANEL_MAX_W = panel_size.MAX_W
local PANEL_STEP = panel_size.STEP
local PANEL_TIERS = panel_size.tiers()

local PANEL_W = 1500
local PANEL_INNER = PANEL_W - 2 * PANEL_PAD_H - PANEL_CROP
local PANEL_CONTENT = PANEL_W - 2 * PANEL_PAD_H

-- Qué entry del manifiesto está ejecutando este panel. Lo pasa el entry.
local CURRENT_ENTRY = "panel"
local tierFor = panel_size.tierFor
local panelEntryFor = panel_size.entryFor

-- Fija el ancho real del panel y recalcula lo que depende de él.
local function setPanelWidth(ancho: number, entry: string?)
	if type(ancho) == "number" and ancho >= 320 then
		local nuevo = math.floor(ancho)
		if nuevo ~= math.floor(PANEL_W) then
			PANEL_W = nuevo
			PANEL_CONTENT = PANEL_W - 2 * PANEL_PAD_H
			PANEL_INNER = PANEL_CONTENT - PANEL_CROP
		end
	end
	if type(entry) == "string" then
		CURRENT_ENTRY = entry
	end
end

-- Snapshots de lo que publica el service. Vive fuera de S porque tileW() se
-- define antes de la tabla de estado y ahí S todavía sería un global nil.
local SNAP: { store: any, catalog: any, status: any } = { store = nil, catalog = nil, status = nil }
local TITLE_MAX = 22
-- Padding horizontal del scroll de la grilla (por lado).
local GRID_PAD_H = 8
-- Alto máximo del área de grilla; el panel es content, así que hay que fijarlo.
-- Alto máximo del panel (max_height del manifiesto). El scroll de la grilla
-- toma lo que queda después del chrome.
local GRID_MAX_H = 920
-- Alto del panel cuando se muestran Opciones / valores por defecto.
-- El panel tiene max_height=920: el scroll usa todo lo que hay debajo del
-- encabezado. Con 700 se desaprovechaban 120 px que ahora son dos filas más.
local OPTIONS_MAX_H = 820
-- Cuántas tarjetas se dibujan por tanda en el grid.
local GRID_WINDOW = 120
local COLUMNS_MIN = 2
local COLUMNS_MAX = 8
local MINUTES_MIN = 1
local MINUTES_MAX = 120
local MINUTES_DEFAULT = 15

type Item = {
	id: string,
	title: string?,
	type: string?,
	thumb: string?,
	preview: string?,
	load: { busy_pct: number?, freq_mhz: number? }?,
}

type EngineField = {
	key: string,
	kind: string, -- "enum" | "number" | "bool"
	label: string,
	values: { string }?,
	option_labels: { string }?,
	lo: number?,
	hi: number?,
}

type State = {
	open: boolean,
	screen: string, -- "browse" | "options" | "gpu"
	offset: number,
	selecting: boolean,
	selected: { string },
	minutes: number,
	order: string,
	optionsId: string?,
	draft: { [string]: any },
	columns: number?,
	probeTotal: number,
}

local S: State = {
	open = false,
	screen = "browse",
	offset = 0,
	hoverId = nil :: string?,
	anim = 1,
	slide = 1,
	focus = 0,
	focusFrom = 0,
	focusTo = 0,
	focusT = 1,
	lastSizes = nil :: string?,
	lastFirm = nil :: string?,
	warm = false,
	slideDir = 1,
	sections = { playback = true, image = true, advanced = true, input = true, settings = true },
	search = "",
	-- Salida elegida en "Aplicar en": "*" = todas. Viaja con cada apply.
	output = "*",
	-- El usuario escribió en el buscador y todavía no envió la búsqueda.
	searchDirty = false,
	onlyFav = false,
	pendingView = nil :: string?,
	-- Un render posterior consume este flag y lo apaga (ver grid()).
	revealPending = false,
	-- Valores elegidos en Opciones que el store todavía no confirmó.
	pendingLayout = nil :: { [string]: any }?,
	pendingFlags = nil :: { [string]: boolean }?,
	-- Primera fila visible de Opciones (paginado con PgUp/PgDn).
	optPage = 1,
	optRows = 0,
	pendingSource = nil :: string?,
	wh = {
		purity = "sfw",
		categories = "all",
		sorting = "toplist",
		order = "desc",
		atleast = "",
		ratios = "any",
		page = 1,
		query = "",
	},
	selecting = false,
	selected = {},
	minutes = MINUTES_DEFAULT,
	order = "sequential",
	optionsId = nil,
	draft = {},
	columns = nil,
	probeTotal = 0,
}

-- The 13 engine fields of lib/engine.luau, in the order the form shows them.
-- An enum's first entry is the empty string: it means "no flag emitted" and
-- becomes nil in the draft.
local ENGINE_FIELDS: { EngineField } = {
	{ key = "fps", kind = "number", label = "engine.fps", lo = 5, hi = 144 },
	{ key = "volume", kind = "number", label = "engine.volume", lo = 0, hi = 100 },
	{
		key = "scaling",
		kind = "enum",
		label = "engine.scaling",
		values = { "", "default", "fill", "fit", "stretch" },
		option_labels = {
			"engine.unset",
			"engine.scaling_default",
			"engine.scaling_fill",
			"engine.scaling_fit",
			"engine.scaling_stretch",
		},
	},
	{
		key = "clamp",
		kind = "enum",
		label = "engine.clamp",
		values = { "", "clamp", "border", "repeat" },
		option_labels = { "engine.unset", "engine.clamp_clamp", "engine.clamp_border", "engine.clamp_repeat" },
	},
	{
		key = "layer",
		kind = "enum",
		label = "engine.layer",
		values = { "", "background", "below", "default", "top", "overlay" },
		option_labels = {
			"engine.unset",
			"engine.layer_background",
			"engine.layer_below",
			"engine.layer_default",
			"engine.layer_top",
			"engine.layer_overlay",
		},
	},
	{ key = "silent", kind = "bool", label = "engine.silent" },
	{ key = "disable_mouse", kind = "bool", label = "engine.disable_mouse" },
	{ key = "disable_parallax", kind = "bool", label = "engine.disable_parallax" },
	{ key = "disable_particles", kind = "bool", label = "engine.disable_particles" },
	{ key = "no_audio_processing", kind = "bool", label = "engine.no_audio_processing" },
	{ key = "no_fullscreen_pause", kind = "bool", label = "engine.no_fullscreen_pause" },
	{ key = "fullscreen_pause_only_active", kind = "bool", label = "engine.fullscreen_pause_only_active" },
	{ key = "noautomute", kind = "bool", label = "engine.noautomute" },
}

-- El panel mantiene su propia tabla porque necesita etiquetas por valor; esta
-- guardia evita que se desincronice de lib/engine.luau y que una opción se
-- descarte en silencio al aplicar.
for _, field in ipairs(ENGINE_FIELDS) do
	for _, value in ipairs(field.values or {}) do
		if value ~= "" and not engine.is_valid(field.key, value) then
			noctalia.log("[panel] engine rechaza " .. field.key .. "=" .. value .. ": opción muerta en la UI")
		end
	end
end

local render: () -> ()

-- ── helpers ──────────────────────────────────────────────────────────────────

local function tr(key: string, subst: { [string]: string }?): string
	if subst then
		return noctalia.tr(key, subst)
	end
	return noctalia.tr(key)
end

local function append(list: { any }, node: any?): ()
	if node ~= nil then
		list[#list + 1] = node
	end
end

local function copy(source: { [string]: any }): { [string]: any }
	local out: { [string]: any } = {}
	for key, value in pairs(source) do
		out[key] = value
	end
	return out
end

-- Titles come from Workshop authors, so cut on codepoints and never inside a
-- multibyte character.
local function truncate(text: string, max: number): string
	local length = utf8.len(text)
	if not length or length <= max then
		return text
	end
	local cut = utf8.offset(text, max)
	if not cut then
		return text
	end
	return string.sub(text, 1, cut - 1) .. "…"
end

-- El service deduplica por nonce: dos acciones en el mismo milisegundo tienen
-- que seguir siendo distinguibles, por eso el contador además del reloj.
local requestCount = 0

-- Traza del lado del panel: qué pidió la UI. Se aparea con el `[dbg] ipc` del
-- service, que dice qué recibió y qué hizo.
local function dbgPanel(event: string, data: any?): ()
	-- Sin storeTable(): se define más abajo y acá sería nil (mismo motivo que en
	-- tileW). El snapshot del watcher o el estado crudo alcanzan.
	local store: any = SNAP.store
	if type(store) ~= "table" then
		store = noctalia.state.get(STORE_KEY)
	end
	if type(store) ~= "table" or store.debug ~= true then
		return
	end
	local partes = { "[dbg:panel] " .. event }
	if type(data) == "table" then
		for key, value in pairs(data) do
			partes[#partes + 1] = tostring(key) .. "=" .. tostring(value)
		end
	end
	noctalia.log(table.concat(partes, " "))
end

local function send(payload: { [string]: any }): ()
	dbgPanel("send", { action = payload.action, id = payload.id })
	requestCount += 1
	payload.nonce = tostring(noctalia.nowMs()) .. ":" .. requestCount
	noctalia.state.set(REQUEST_KEY, payload)
end

local function statusTable(): { [string]: any }
	local value = if type(SNAP.status) == "table" then SNAP.status else noctalia.state.get(STATUS_KEY)
	return type(value) == "table" and value or {}
end

-- El valor que entrega el watcher es el nuevo; `noctalia.state.get` puede
-- devolver todavía el anterior (el panel leía un estado atrasado y por eso el
-- cambio de modo o de fuente no se veía hasta reabrir).
local function storeTable(): { [string]: any }
	local cached = SNAP.store
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STORE_KEY)
	return type(value) == "table" and value or {}
end

-- Valor escalar del store. `tableAt` devuelve {} cuando el campo no es tabla,
-- así que leer `source`, `local_sort` o `sync_colors` con él daba siempre nil:
-- la fuente activa caía al default y el selector parecía no cambiar nada.
local function storeValue(key: string): any
	local store = storeTable()
	if type(store) ~= "table" then
		return nil
	end
	return store[key]
end

-- Tolerante a `source` nil: el panel se construye antes de que el service
-- publique el primer store, y un `source[key]` sobre nil mataba el render entero
-- sin dejar rastro (el panel simplemente no aparecía).
local function tableAt(source: any, key: string): { [string]: any }
	if type(source) ~= "table" then
		return {}
	end
	local value = source[key]
	return type(value) == "table" and value or {}
end


-- Fuente activa: la publica el service en el store (engine | images | videos).
local function activeSource(): string
	local value = storeValue("source")
	if S.pendingSource and S.pendingSource ~= value then
		return S.pendingSource
	end
	if value == "images" or value == "videos" or value == "wallhaven" then
		return value
	end
	return "engine"
end

local function isFavorite(id: string): boolean
	local favorites = tableAt(storeTable(), "favorites")
	return favorites[id] == true
end

-- El buscador de texto libre sólo está disponible en el grid (en carrusel no se
-- muestra), así que el filtro local se aplica únicamente en esa vista. Wallhaven
-- es la excepción: ahí la búsqueda va a la API y sirve en las dos vistas.
local function localSearchActive(): boolean
	local mode = tableAt(storeTable(), "view").mode
	if mode ~= "grid" and mode ~= "carousel" then
		mode = noctalia.getConfig("default_view") == "grid" and "grid" or "carousel"
	end
	return mode == "grid"
end

-- El buscador de las fuentes locales filtra acá; en wallhaven la búsqueda va a
-- la API, así que el filtro local sólo aplica cuando no es esa fuente.
-- Filtros + búsqueda de la lista visible. Se memoiza por render: con miles de
-- items, recalcular esto nueve veces por frame (como antes) se nota.
local function catalogItems(): { Item }
	if S.itemsCache and S.itemsCacheStamp == S.renderStamp then
		return S.itemsCache
	end
	local catalog = if type(SNAP.catalog) == "table" then SNAP.catalog else noctalia.state.get(CATALOG_KEY)
	local items: { Item } = {}
	if type(catalog) == "table" and type(catalog.items) == "table" then
		items = catalog.items
	end
	if S.onlyFav then
		local picked: { Item } = {}
		for _, item in ipairs(items) do
			if isFavorite(item.id) then
				picked[#picked + 1] = item
			end
		end
		items = picked
	end
	if activeSource() == "wallhaven" or not localSearchActive() then
		S.itemsCache, S.itemsCacheStamp = items, S.renderStamp
		return items
	end
	local needle = string.lower((S.search or ""):gsub("^%s*(.-)%s*$", "%1"))
	if needle == "" then
		S.itemsCache, S.itemsCacheStamp = items, S.renderStamp
		return items
	end
	local out: { Item } = {}
	for _, item in ipairs(items) do
		local title = string.lower(tostring(item.title or item.id or ""))
		if string.find(title, needle, 1, true) then
			out[#out + 1] = item
		end
	end
	S.itemsCache, S.itemsCacheStamp = out, S.renderStamp
	return out
end

local function itemTitle(item: Item): string
	local title = item.title
	if type(title) == "string" and title ~= "" then
		return title
	end
	return item.id
end

local function findItem(items: { Item }, id: string?): Item?
	if id == nil then
		return nil
	end
	for _, item in ipairs(items) do
		if item.id == id then
			return item
		end
	end
	return nil
end

local function blockEntry(id: string): { [string]: any }?
	local entry = tableAt(storeTable(), "blocklist")[id]
	if type(entry) == "table" then
		return entry
	end
	return nil
end

-- ── view ─────────────────────────────────────────────────────────────────────

-- maxOffset() la usa y se declara más abajo: sin el forward queda como global nil.
local fitCount: () -> number

local function maxOffset(total: number): number
	return math.max(0, total - fitCount())
end

-- Orden del desplegable de fuentes: el índice del select es 0-based.
local SOURCES = { "engine", "images", "videos", "wallhaven" }

local function sourceIndex(): number
	local current = activeSource()
	for index, value in ipairs(SOURCES) do
		if value == current then
			return index - 1
		end
	end
	return 0
end

local function setSource(next_source: string): ()
	S.pendingSource = next_source
	S.offset = 0
	S.anim = 0
	send({ action = "set_source", source = next_source })
	render()
end

local function viewMode(): string
	local mode = tableAt(storeTable(), "view").mode
	-- Lo que el usuario acaba de elegir manda hasta que el store lo confirme:
	-- el round-trip al service tarda y el control se veía sin cambios.
	if S.pendingView and S.pendingView ~= mode then
		return S.pendingView
	end
	if mode == "grid" or mode == "carousel" then
		return mode
	end
	return noctalia.getConfig("default_view") == "grid" and "grid" or "carousel"
end

-- Separación del carrusel, 0..100 (0 = pegadas). La persiste el service en el
-- store, igual que las columnas: el panel no puede escribir settings.
local function viewSpacing(): number
	local stored = tonumber(tableAt(storeTable(), "view").spacing)
	if stored == nil then
		return 15
	end
	return math.max(0, math.min(100, stored))
end

local function viewColumns(): number
	local stored = tonumber(tableAt(storeTable(), "view").columns)
	local configured = tonumber(noctalia.getConfig("grid_columns"))
	local value = math.floor(stored or configured or 4)
	return math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, value))
end

-- ── disposición por modo ─────────────────────────────────────────────────────
-- `w`/`h` en 0 = automático: se derivan del panel o de la proporción 16:9.

-- Lo que dice el store, sin pendientes.
local function storedLayout(mode: string): { [string]: any }
	local conf = tableAt(storeTable(), "view")[mode]
	return type(conf) == "table" and conf or {}
end

-- Lo que el usuario acaba de elegir todavía no volvió del service. Se aplica
-- encima del store para que el control no rebote al valor viejo mientras dura
-- el viaje de ida y vuelta.
local function setPendingLayout(mode: string, key: string, value: any): ()
	S.pendingLayout = S.pendingLayout or {}
	S.pendingLayout[mode .. "." .. key] = value
end

local function setPendingFlag(key: string, value: boolean): ()
	S.pendingFlags = S.pendingFlags or {}
	S.pendingFlags[key] = value
end

-- Limpia lo pendiente cuando el store ya coincide. Si no coincide (service
-- caído, request perdido) el valor local sigue mandando, que es lo que el
-- usuario pidió.
local function confirmPending(): ()
	local keys: { string } = {}
	for clave in pairs(S.pendingLayout or {}) do
		keys[#keys + 1] = clave
	end
	for _, clave in ipairs(keys) do
		local mode_key, key = string.match(clave, "^(%a+)%.(%a+)$")
		if mode_key and storedLayout(mode_key)[key] == S.pendingLayout[clave] then
			S.pendingLayout[clave] = nil
		end
	end
	for key in pairs(S.pendingFlags or {}) do
		if tableAt(storeTable(), "view")[key] == S.pendingFlags[key] then
			S.pendingFlags[key] = nil
		end
	end
end

local function layoutFor(mode: string): { [string]: any }
	local conf = storedLayout(mode)
	local pend = S.pendingLayout
	if pend == nil or next(pend) == nil then
		return conf
	end
	local merged = copy(conf)
	local prefix = mode .. "."
	for clave, value in pairs(pend) do
		if string.sub(clave, 1, #prefix) == prefix then
			merged[string.sub(clave, #prefix + 1)] = value
		end
	end
	return merged
end

local function minimalOn(): boolean
	return layoutFor(viewMode()).layout == "minimal"
end

local function carouselProgressOn(): boolean
	return layoutFor("carousel").progress ~= false
end

-- Flags globales de la vista (`apply_on`, `view_label`): el default es true.
local function viewFlag(key: string): boolean
	local pendiente = (S.pendingFlags or {})[key]
	if pendiente ~= nil then
		return pendiente
	end
	return tableAt(storeTable(), "view")[key] ~= false
end

local function applyOnVisible(): boolean
	return viewFlag("apply_on")
end

local function viewLabelVisible(): boolean
	return viewFlag("view_label")
end

-- Columnas y ancho de la grilla. Tienen que salir de la misma cuenta: si el
-- ancho fijo recalculaba columnas pero el dibujo usaba otras, la fila dejaba
-- huecos a la derecha.
local function gridGeometry(): (number, number)
	local content = PANEL_CONTENT
	-- Techo real: las columnas más sus separaciones tienen que entrar.
	-- El scroll usa paddingH = 8 POR LADO y el panel ya aporta 16: hay que
	-- descontar los dos lados o la fila se sale por la derecha.
	local fixed = tonumber(layoutFor("grid").w) or 0
	if fixed >= 60 then
		-- Con ancho fijo manda el ancho: las columnas se recalculan para que la
		-- fila llene el panel.
		local columnas = math.max(1, math.floor((content - 2 * GRID_PAD_H + TILE_GAP) / (fixed + TILE_GAP)))
		local maximo = math.floor((content - 2 * GRID_PAD_H - (columnas - 1) * TILE_GAP) / columnas)
		return columnas, math.min(fixed, maximo)
	end
	local columns = viewColumns()
	local maximo = math.floor((content - 2 * GRID_PAD_H - (columns - 1) * TILE_GAP) / columns)
	return columns, maximo
end

local function gridCardW(): number
	local _, ancho = gridGeometry()
	return ancho
end

local function gridCardH(w: number): number
	local fixed = tonumber(layoutFor("grid").h) or 0
	if fixed >= 40 then
		return fixed
	end
	return math.floor(w * 9 / 16)
end


-- Cuántas tarjetas entran por fila: es la cantidad de columnas de la grilla.
function fitCount(): number
	return viewColumns()
end

local function currentTitle(items: { Item }): string?
	local status = statusTable()
	local item = findItem(items, type(status.id) == "string" and status.id or nil)
	if item then
		return itemTitle(item)
	end
	return type(status.title) == "string" and status.title or nil
end

-- ── selection ────────────────────────────────────────────────────────────────

local function selectionIndex(id: string): number?
	for index, value in ipairs(S.selected) do
		if value == id then
			return index
		end
	end
	return nil
end

local function isSelected(id: string): boolean
	return selectionIndex(id) ~= nil
end

local function toggleSelection(id: string): ()
	local index = selectionIndex(id)
	if index then
		table.remove(S.selected, index)
	else
		S.selected[#S.selected + 1] = id
	end
end

-- Siembra el estado que viene del store. La selección múltiple arranca
-- SIEMPRE apagada: antes se encendía sola si el store traía `cycle.ids`, y
-- el panel aparecía con "N selected" y en modo selección sin que el usuario
-- lo hubiera pedido. Sólo se restaura la lista cuando hay un ciclo CORRIENDO
-- (ahí hace falta para poder detenerlo).
local function seedFromStore(): ()
	local cycle = tableAt(storeTable(), "cycle")
	local running = cycle.active == true
	if running then
		local ids = cycle.ids
		if type(ids) == "table" then
			local list: { string } = {}
			for _, value in ipairs(ids) do
				if type(value) == "string" then
					list[#list + 1] = value
				end
			end
			S.selected = list
		end
	end
	-- Sin ciclo corriendo no hay selección que restaurar: el panel queda
	-- limpio (la entrada vive entre aperturas y arrastraba la selección).
	if not running then
		S.selected = {}
	end
	local minutes = tonumber(cycle.minutes) or MINUTES_DEFAULT
	S.minutes = math.max(MINUTES_MIN, math.min(MINUTES_MAX, math.floor(minutes)))
	S.order = cycle.order == "random" and "random" or "sequential"
	S.selecting = false
end

-- ── requests ─────────────────────────────────────────────────────────────────

local function refresh(): ()
	S.offset = 0
	send({ action = "refresh" })
end

local function applyWallpaper(item: Item): ()
	-- El selector "Aplicar en" tiene que viajar: sin `output` el service
	-- aplicaba siempre en el output enfocado y el selector no hacía nada.
	local req: { [string]: any } = { action = "apply", id = item.id }
	local destino = S.output
	if type(destino) == "string" and destino ~= "" then
		req.output = destino
	end
	send(req)
	noctalia.notify(tr("panel.title"), tr("panel.apply", { name = itemTitle(item) }))
end

local function activate(item: Item): ()
	if S.selecting then
		toggleSelection(item.id)
		render()
		return
	end
	S.searchDirty = false
	applyWallpaper(item)
end

local function openOptions(id: string?): ()
	S.optionsId = id
	S.draft = {}
	S.screen = "options"
	render()
end

local function setView(mode: string): ()
	S.anim = 0
	S.pendingView = mode
	S.offset = 0
	send({ action = "set_view", mode = mode, spacing = S.spacing or viewSpacing() })
	render()
end

-- ── tiles ────────────────────────────────────────────────────────────────────

local function tileStill(item: Item, width: number, height: number): any
	local still = item.thumb or item.preview
	if type(still) == "string" and still ~= "" then
		return ui.image({ path = still, width = width, height = height, radius = 8, fit = "cover" })
	end
	-- El placeholder (el wallpaper sin miniatura) también va sobre el fondo
	-- del plugin: sin `fill` ni con un tinte apenas perceptible. Antes
	-- usaba `surface_container` opaco y se veía como un rectángulo claro
	-- entre las tarjetas.
	return ui.column({
		width = width,
		height = height,
		radius = 8,
		fill = "#00000000",
		align = "center",
		justify = "center",
		gap = 2,
	}, {
		ui.glyph({ name = "photo", size = 18, color = "on_surface_variant" }),
		ui.label({ text = tr("panel.no_thumb"), fontSize = 9, color = "on_surface_variant", maxLines = 2, textAlign = "center" }),
	})
end

local function tileCaption(item: Item, width: number, applied: boolean): any
	local row: { any } = {}
	local blocked = blockEntry(item.id)
	if isFavorite(item.id) then
		append(row, ui.glyph({ name = "star-filled", size = 12, color = "primary" }))
	end
	if blocked then
		append(row, ui.glyph({ name = "alert-triangle", size = 12, color = "error" }))
	elseif isSelected(item.id) then
		append(row, ui.glyph({ name = "check", size = 13, color = "primary" }))
	elseif applied and item.load == nil then
		-- Applied but never measured: a neutral dot, not a warning.
		append(row, ui.glyph({ name = "circle", size = 11, color = "on_surface_variant" }))
	end
	-- El ancho del texto sigue a la tarjeta: con un máximo fijo (22) el
	-- título se cortaba antes de tiempo con muchas columnas y desperdiciaba
	-- espacio con pocas. El límite de caracteres va aparte, escalado al ancho.
	local max_chars = math.max(8, math.floor((width - 16) / 6.2))
	append(
		row,
		ui.label({
			text = truncate(itemTitle(item), math.min(TITLE_MAX, max_chars)),
			fontSize = 11,
			maxLines = 1,
			width = math.max(20, width - 16),
			textAlign = "start",
			color = applied and "secondary" or "on_surface",
		})
	)
	return ui.row({ gap = 4, align = "center" }, row)
end

-- ── foco del carrusel ────────────────────────────────────────────────────────

-- Se puede apagar desde Ajustes: en equipos modestos ahorra CPU.
local function animationsOn(): boolean
	return noctalia.getConfig("animations") ~= false
end

-- Coverflow: el del centro va a tamaño completo y cada lugar de distancia
-- encoge. La distancia es fraccionaria durante la animación, así que los tiles
-- crecen/decrecen cuadro a cuadro en vez de saltar.
-- Caída de tamaño por distancia. `spacing` 0 = todas iguales (pegadas) y 100 =
-- muy separadas. El valor se mapea a la constante de la curva.
local function focusScale(distance: number): number
	local spacing = S.spacing or viewSpacing()
	-- Piso de 0.08: con la separación al mínimo las tarjetas quedan pegadas pero
	-- el seleccionado se sigue viendo más grande.
	local k = 0.08 + (spacing / 100) * 0.47
	return math.max(0.50, 1 / (1 + k * distance))
end

-- Ancho de las zonas de scroll en los extremos de la tira. Va antes del
-- reparto: el ancho de celda lo descuenta.
local EDGE_W = 26

-- Cuántos wallpapers se ven a la vez en el carrusel.
--
-- El valor sale de la sección de layout del carrusel (`slots`): 3 muestra el
-- enfocado y uno a cada lado; 5 muestra el coverflow completo. Siempre
-- impar: el wallpaper enfocado va en el centro y los demás se reparten a
-- partes iguales a cada lado.
local function carouselSlots(): number
	local stored = tonumber(layoutFor("carousel").slots)
	local value = stored or 5
	-- Impar y dentro del rango: 3 o 5.
	if value % 2 == 0 then
		value = value + 1
	end
	return math.max(CAROUSEL_SLOTS_MIN, math.min(CAROUSEL_SLOTS_MAX, value))
end

-- El radio: cuántos slots hay a cada lado del enfocado.
local function carouselRadius(): number
	return (carouselSlots() - 1) // 2
end

-- Ancho de celda del carrusel: constante para que la tira no cambie de tamaño.
-- Auto = reparte el ancho del panel entre las cinco celdas. El tamaño de
-- tarjeta ya no interviene: hay un control por modo en Disposición.
--
-- El reparto descuenta las dos zonas de flecha (EDGE_W) y los gaps: la tira
-- completa (5 celdas + gaps + zonas) tiene que caber en PANEL_INNER. Antes
-- el reparto ignoraba las zonas y la tira se salía del panel por 52 px: la
-- zona de la flecha izquierda quedaba fuera y su glifo no se veía.
-- ── Geometría del carrusel ───────────────────────────────────────────────
-- La regla, en una línea:
--
--   ancho del panel = slots * celda + gaps + zonas de scroll + padding
--
-- El conteo de wallpapers fija el tamaño base (3 pide un panel más chico que
-- 5) y el ancho de las tarjetas lo alarga o lo achica desde ahí. Si en
-- Opciones se fija un ancho de panel, manda ése y las tarjetas se reparten.
local function carouselGap(): number
	return math.max(0, math.min(100, tonumber(tableAt(storeTable(), "view").spacing) or 0))
end

-- Tope del control de ancho de tarjeta: lo que entra en el panel más ancho.
local function maxCardW(): number
	return panel_size.maxCard(carouselSlots(), carouselGap())
end

-- (ancho del panel, ancho de celda) para el carrusel. La cuenta vive en
-- `lib/panel_size.luau`: el service la necesita igual para publicar qué
-- entrada hay que abrir.
local function carouselGeometry(): (number, number)
	local conf = layoutFor("carousel")
	return panel_size.carousel(
		carouselSlots(),
		carouselGap(),
		tonumber(conf.w) or 0,
		math.floor(tonumber(conf.panel_w) or 0)
	)
end

-- El entry y el ancho que necesita la configuración vigente. La grilla no
-- usa la tira: su ancho sale de su propio control (0 = 1500).
local function desiredPanel(): (string, number)
	if viewMode() == "carousel" then
		local ancho = panel_size.carousel(
			carouselSlots(),
			carouselGap(),
			tonumber(layoutFor("carousel").w) or 0,
			math.floor(tonumber(layoutFor("carousel").panel_w) or 0)
		)
		return panelEntryFor(ancho), ancho
	end
	local ancho = panel_size.grid(math.floor(tonumber(layoutFor("grid").panel_w) or 0))
	return panelEntryFor(ancho), ancho
end

-- El ancho de celda del carrusel: sale de la geometría, no del panel actual.
local function carouselSlotWidth(): number
	local _, celda = carouselGeometry()
	-- Si la entry abierta no es la que pide la configuración (la abrió alguien
	-- que no resolvió la entrada), la tarjeta se achica para no desbordar:
	-- la ventana la fija el host y no se puede cambiar en vivo.
	return math.min(celda, panel_size.maxCellIn(PANEL_W, carouselSlots(), carouselGap()))
end

-- El host repinta el panel entero en cada render, así que durante la animación
-- sólo se renderiza cuando los anchos calculados cambian al menos 1 px.
local function carouselSignature(focus: number): string
	local slot_w = carouselSlotWidth()
	local base = math.floor(focus)
	local out: { string } = {}
	local radius = carouselRadius()
	for slot = 1, carouselSlots() do
		local index = base + 1 - radius + (slot - 1)
		local distance = math.abs((index - 1) - focus)
		out[#out + 1] = tostring(math.floor(slot_w * focusScale(distance)))
	end
	return table.concat(out, ",")
end

local function easeOut(t: number): number
	local clamp = math.max(0, math.min(1, t))
	return 1 - (1 - clamp) ^ 3
end

local function focusedIndex(): number
	return math.max(0, math.min(math.floor(S.focusTo + 0.5), math.max(0, #catalogItems() - 1)))
end

-- ¿El usuario está escribiendo en el buscador? Los atajos de una letra (g, f,
-- p) no deben disparar mientras tanto: escribirlas en el input cambiaba de
-- vista o marcaba favorito.
local function searching(): boolean
	return S.searchDirty == true or (type(S.search) == "string" and S.search ~= "")
end

local function focusTo(index: number): ()
	local items = catalogItems()
	if #items == 0 then
		return
	end
	local target = math.max(0, math.min(math.floor(index + 0.5), #items - 1))
	if target == S.focusTo and S.focusT >= 1 then
		return
	end
	S.focusFrom = S.focus
	S.focusTo = target
	S.focusT = if animationsOn() then 0 else 1
	if S.focusT >= 1 then
		S.focus = target
	else
		panel.setNeedsFrameTick(true)
	end
	S.offset = target
	S.slide = 1
	-- El scroll del grid sigue al foco sólo cuando el foco lo pidió.
	S.revealPending = true
	-- Navegar significa que el usuario ya no está escribiendo.
	S.searchDirty = false
	render()
end


local function tile(item: Item, current: string?, width: number, height: number, alpha: number?, focused: boolean?, index: number?, slot_w: number?, slot_h: number?): any
	-- `tile-<id>`: el scroll del grid lo usa como `revealKey` para seguir el
	-- foco con el teclado.
	local selected = isSelected(item.id)
	local applied = current == item.id
	local border = "outline_variant"
	local borderWidth = 1
	if focused == true then
		border = "primary"
	elseif selected then
		border = "primary"
	elseif applied then
		border = "secondary"
	end

	-- Como el plugin oficial: el borde avisa la pureza sin abrir nada.
	local purity = item.purity
	if purity == "nsfw" then
		border, borderWidth = "error", 3
	elseif purity == "sketchy" then
		border, borderWidth = "tertiary", 2
	end

	local blocked = blockEntry(item.id)
	local tooltip: string? = nil
	if blocked then
		local pct = math.floor(tonumber(blocked.busy_pct) or 0)
		tooltip = tr("panel.gpu_badge", { pct = tostring(pct) })
	end

	if not (purity == "nsfw" or purity == "sketchy") then
		borderWidth = (focused == true and 2) or ((selected or applied) and 2 or 1)
	end

	-- El marco abraza la imagen: padding de 3 px y el borde sobre el bloque, no
	-- sobre la celda. Así se ve como antes aunque el layout tenga slots fijos.
	-- El marco va DENTRO del tamaño pedido: la imagen mide lo que queda
	-- después del padding y del borde. Antes el marco se sumaba por fuera y
	-- la tarjeta medía 8 px más que su celda: en el carrusel el marco del
	-- wallpaper enfocado se salía por abajo y pisaba la barra de progreso; en
	-- el grid la fila se salía del panel.
	local marco = 2 * 3 + 2 * borderWidth
	local img_w = math.max(24, width - marco)
	local img_h = math.max(16, height - marco)
	local frame = ui.column({
		key = item.id .. "/f",
		padding = 3,
		radius = 10,
		align = "center",
		justify = "center",
		border = border,
		borderWidth = borderWidth,
		-- El marco NO lleva fondo: antes usaba `surface_container/0.30`, un
		-- tinte translúcido que se veía como un rectángulo de otro color
		-- alrededor de cada wallpaper, distinto del fondo del panel. Ahora el
		-- marco es transparente y las tarjetas quedan sobre el mismo fondo
		-- que el resto del plugin.
		--
		-- El transparente va como HEX explícito (`#00000000`) y no como clave
		-- ausente: el host no tiene `clearFill`, así que si el `fill` se
		-- omite en un nodo que se reusa (misma key) el color ANTERIOR se
		-- queda pegado. Con el hex siempre presente, el host lo aplica
		-- siempre y el marco queda limpio.
		--
		-- El wallpaper aplicado sí se distingue: lleva un tinte `primary`
		-- translúcido, que marca cuál está en uso.
		fill = applied and "primary/0.12" or "#00000000",
		tooltip = tooltip,
		opacity = alpha or 1,
		onClick = function()
			-- Click en el que está al centro = aplicar; en cualquier otro = centrarlo.
			if focused == true or index == nil then
				activate(item)
			else
				focusTo(index)
			end
		end,
		-- Hover en el extremo = scroll de borde (ver hoverTick). No roba el clic
		-- porque onHover convive con onClick.
		onHover = function(state: any, _key: any)
			S.hoverId = state == "true" and item.id or (S.hoverId == item.id and nil or S.hoverId)
		end,
	}, { tileStill(item, img_w, img_h) })

	if slot_w and slot_h then
		-- Carrusel: sólo la imagen, sin nombre. La celda mide siempre lo mismo y
		-- el marco de adentro crece o encoge con la foto.
		-- La celda mide el slot exacto: el marco va dentro (ver arriba), así
		-- que el wallpaper enfocado no desborda la celda hacia la barra.
		return ui.column({
			key = item.id,
			width = slot_w,
			height = slot_h,
			align = "center",
			justify = "center",
			-- El hover va sobre la celda entera, no sobre el marco de 3 px: era la
			-- razón por la que el "scroll" de borde costaba engancharlo.
			onHover = function(state: any)
				S.hoverId = state == "true" and item.id or (S.hoverId == item.id and nil or S.hoverId)
			end,
		}, { frame })
	end

	-- Grid: alto automático, marco y caption apilados (el caption se oculta en
	-- el layout minimalista).
	local hijos: { any } = { frame }
	if not minimalOn() then
		hijos[#hijos + 1] = tileCaption(item, width, applied)
	end
	-- La celda lleva el ancho explícito: sin esto lo heredaba de la imagen y
	-- el marco (padding + borde) la hacía más ancha de lo pedido, con lo que
	-- la fila se salía del panel.
	return ui.column({ key = item.id, width = width, align = "center", gap = 4 }, hijos)
end

-- ── browse ───────────────────────────────────────────────────────────────────

local function iconButton(glyph: string, tooltip: string, onClick: () -> (), selected: boolean?): any
	return ui.button({
		glyph = glyph,
		variant = "ghost",
		controlSize = "sm",
		tooltip = tooltip,
		selected = selected == true,
		onClick = onClick,
	})
end

local WH_SORTING = { "toplist", "date_added", "relevance", "random", "favorites", "views", "hot" }
-- Mismo orden que WH_SORTING, con su etiqueta legible.
local function WH_SORTING_LABELS(): { string }
	return { "Top", tr("panel.wh_sort_date"), tr("panel.wh_sort_relevance"), tr("panel.wh_sort_random"),
		tr("panel.wh_sort_favorites"), tr("panel.wh_sort_views"), tr("panel.wh_sort_hot") }
end
local function WH_RATIO_LABELS(): { string }
	return { tr("panel.wh_any"), tr("panel.wh_landscape"), tr("panel.wh_portrait"),
		"16:9", "16:10", "21:9", "32:9", "48:9", "9:16", "10:16", "9:18", "1:1", "3:2", "4:3", "5:4" }
end
local WH_RATIOS = { "any", "landscape", "portrait", "16x9", "16x10", "21x9", "32x9", "48x9", "9x16", "10x16", "9x18", "1x1", "3x2", "4x3", "5x4" }

local function indexOf(list: { string }, value: string): number
	for index, entry in ipairs(list) do
		if entry == value then
			return index - 1
		end
	end
	return 0
end

-- Manda SÓLO lo que cambió. Antes viajaba también la página, y el service
-- prioriza `page` sobre "cambió un filtro": cambiar la pureza no reiniciaba la
-- búsqueda y seguías en la página 20 de otra consulta.
local function sendWallhaven(patch: { [string]: any }): ()
	local req: { [string]: any } = { action = "set_wallhaven" }
	for key, value in pairs(patch) do
		S.wh[key] = value
		-- El código de categorías viaja como `categories` (nombre que usa la API).
		req[(key == "categories_code") and "categories" or key] = value
	end
	send(req)
end

-- Filtros del modo Wallhaven. La API sólo acepta una combinación por pedido, así
local function whChip(label: string, active: boolean, on_click: () -> ()): any
	return ui.button({
		text = label,
		variant = if active then "primary" else "outline",
		controlSize = "sm",
		onClick = on_click,
	})
end

-- La API acepta la palabra "all" o el código de tres dígitos (general=100,
-- anime=010, people=001). El store guarda la forma de la API; los chips
-- necesitan el código. Esta función traduce entre las dos.
local function categorias_a_codigo(valor: any): string
	if type(valor) ~= "string" then
		return "111"
	end
	if valor == "all" then
		return "111"
	end
	if valor == "general" then
		return "100"
	end
	if valor == "anime" then
		return "010"
	end
	if valor == "people" then
		return "001"
	end
	if #valor == 3 then
		return valor
	end
	return "111"
end

local function digitAt(code: string, pos: number): string
	if type(code) ~= "string" or #code ~= 3 then
		code = "100"
	end
	return string.sub(code, pos, pos)
end

local function toggleDigit(code: string, pos: number, fallback: string): string
	if type(code) ~= "string" or #code ~= 3 then
		code = fallback
	end
	local digits = { string.sub(code, 1, 1), string.sub(code, 2, 2), string.sub(code, 3, 3) }
	digits[pos] = (digits[pos] == "1") and "0" or "1"
	local out = table.concat(digits)
	if out == "000" then
		out = fallback
	end
	return out
end

-- Barra de Wallhaven en dos filas. Antes eran tres más el contador de items:
-- con el buscador arriba, el chrome se comía casi todo el panel y las tarjetas
-- quedaban en una franja. Las tres filas se juntaron en dos.

-- `wallhavenFilters` se define más abajo; la declaración previa evita que la
-- llamada resuelva a un global nil en runtime.
local wallhavenFilters: () -> any = nil :: any

local function wallhavenBar(): any
	return ui.column({ gap = 6, padding = 8, radius = 9, fill = "surface_container/0.35" }, {
		wallhavenFilters(),
	})
end

-- Fila de chips (pureza + categorías) con la paginación a la derecha.
local function whChipsRow(): any
	local purity = S.wh.purity or "100"
	local categories = S.wh.categories_code or "111"
	local pagina = math.max(1, tonumber(S.wh.page) or 1)
	local total = math.max(1, tonumber(S.wh.lastPage) or 1)
	return ui.row({ gap = 6, align = "center" }, {
		whChip("SFW", digitAt(purity, 1) == "1", function()
			S.wh.purity = toggleDigit(purity, 1, "100")
			sendWallhaven({ purity = S.wh.purity })
			render()
		end),
		whChip("Sketchy", digitAt(purity, 2) == "1", function()
			S.wh.purity = toggleDigit(purity, 2, "100")
			sendWallhaven({ purity = S.wh.purity })
			render()
		end),
		whChip("NSFW", digitAt(purity, 3) == "1", function()
			S.wh.purity = toggleDigit(purity, 3, "100")
			sendWallhaven({ purity = S.wh.purity })
			render()
		end),
		ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" }),
		whChip("General", digitAt(categories, 1) == "1", function()
			S.wh.categories_code = toggleDigit(categories, 1, "111")
			sendWallhaven({ categories = S.wh.categories_code })
			render()
		end),
		whChip("Anime", digitAt(categories, 2) == "1", function()
			S.wh.categories_code = toggleDigit(categories, 2, "111")
			sendWallhaven({ categories = S.wh.categories_code })
			render()
		end),
		whChip("People", digitAt(categories, 3) == "1", function()
			S.wh.categories_code = toggleDigit(categories, 3, "111")
			sendWallhaven({ categories = S.wh.categories_code })
			render()
		end),
		ui.spacer(),
		iconButton("chevron-left", tr("panel.prev"), function()
			if pagina > 1 then
				sendWallhaven({ page = pagina - 1 })
			end
		end),
		(if S.pageEdit then
			ui.input({
				key = "page-jump",
				placeholder = tostring(pagina),
				width = 64,
				controlSize = "sm",
					onSubmit = function(value: any)
					local wanted = tonumber(tostring(value or ""))
					S.pageEdit = false
					if wanted and wanted >= 1 then
						sendWallhaven({ page = math.floor(wanted) })
					end
					render()
				end,
			})
		else
			ui.button({
				key = "page-label",
				text = tostring(pagina) .. "/" .. tostring(total),
				variant = "ghost",
				controlSize = "sm",
				tooltip = tr("panel.page_jump"),
				onClick = function()
					S.pageEdit = true
					render()
				end,
			})),
		iconButton("chevron-right", tr("panel.next"), function()
			sendWallhaven({ page = pagina + 1 })
		end),
	})
end

-- Orden, sentido y proporción: lo que el original pone en su fila inferior.
local function whControlsRow(): any
	return ui.row({ gap = 6, align = "center" }, {
		ui.select({
			options = WH_SORTING_LABELS(),
			selectedIndex = indexOf(WH_SORTING, S.wh.sorting),
			controlSize = "sm",
			width = 118,
			onChange = function(value: any)
				local index = tonumber(value)
				local picked = index and WH_SORTING[index + 1]
				if picked then
					sendWallhaven({ sorting = picked })
					render()
				end
			end,
		}),
		-- El chip de orden no va siempre resaltado: era un toggle que parecía
		-- un filtro activo y亂 competía con el selector de orden de al lado.
		whChip(if S.wh.order == "asc" then tr("panel.wh_asc") else tr("panel.wh_desc"), false, function()
			S.wh.order = (S.wh.order == "asc") and "desc" or "asc"
			sendWallhaven({ order = S.wh.order })
			render()
		end),
		ui.select({
			options = WH_RATIO_LABELS(),
			selectedIndex = indexOf(WH_RATIOS, S.wh.ratios),
			controlSize = "sm",
			width = 104,
			onChange = function(value: any)
				local index = tonumber(value)
				local picked = index and WH_RATIOS[index + 1]
				if picked then
					sendWallhaven({ ratios = picked })
					render()
				end
			end,
		}),
	})
end

local function syncWhFromStore()
	local filters = tableAt(storeTable(), "wallhaven_filters")
	if next(filters) == nil then
		return
	end
	if type(filters.purity) == "string" then
		S.wh.purity = filters.purity
	end
	if type(filters.categories) == "string" then
		-- El store guarda "all" (la palabra de la API) pero los chips trabajan
		-- con el código de tres dígitos. Sin convertir, los tres chips
		-- aparecían apagados aunque la búsqueda fuera de todo.
		S.wh.categories_code = categorias_a_codigo(filters.categories)
	end
	if type(filters.sorting) == "string" then
		S.wh.sorting = filters.sorting
	end
	if type(filters.order) == "string" then
		S.wh.order = filters.order
	end
	if type(filters.ratios) == "string" then
		S.wh.ratios = filters.ratios
	end
	if tonumber(filters.page) then
		S.wh.page = tonumber(filters.page)
	end
	if tonumber(filters.last_page) then
		S.wh.lastPage = tonumber(filters.last_page)
	end
end

function wallhavenFilters(): any
	syncWhFromStore()
	return ui.column({ gap = 6 }, { whChipsRow(), whControlsRow() })
end

-- Nunca los tres apagados: la API devuelve vacío con 000.
-- Lo que manda es el service: los filtros publicados se copian a S.wh antes de
-- dibujar, así los chips nunca muestran algo distinto de lo que se pidió.


-- Selector de salida: "Todas" aplica en cada monitor; el resto, sólo en uno.
local function outputRow(): any
	local SENTINEL = "*"
	local nombres: { string } = { SENTINEL }
	for _, entry in ipairs(noctalia.outputs() or {}) do
		nombres[#nombres + 1] = tostring(entry.name)
	end
	local actual = S.output or SENTINEL
	local index = indexOf(nombres, actual)
	return ui.row({ align = "center", gap = 8 }, {
		ui.label({ text = tr("panel.apply_on"), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
		ui.select({
			options = nombres,
			selectedIndex = math.max(0, index),
			controlSize = "sm",
			width = 170,
			onChange = function(value: any)
				local picked = nombres[(tonumber(value) or 0) + 1]
				if picked then
					S.output = picked
					render()
				end
			end,
		}),
	})
end

-- Buscador de la barra: en Wallhaven busca en el servidor, en la grilla filtra
-- el catálogo local. Sin buscador devuelve un espaciador que empuja el resto.
local function headerSearch(mode: string, source: string): any
	if source == "wallhaven" then
		return ui.input({
			-- `value` sólo siembra el campo: con key estable el host conserva lo
			-- que el usuario escribe y Enter dispara onSubmit.
			key = "search-input",
			value = S.wh.query,
			placeholder = tr("panel.search"),
			controlSize = "sm",
			-- Ancho explícito, no `flexGrow`: el buscador vive en un row
			-- anidado dentro del header agrupado, y ahí el host no conoce el
			-- ancho del contenedor (lo calcula por contenido). Sin ancho
			-- conocido el reparto de `flexGrow` no se aplica y el input cae a
			-- su mínimo de 48 px. El ancho es un mínimo (setMinLayoutWidth),
			-- así que el campo sigue usable.
			width = 320,
			onChange = function(value: any)
				S.wh.query = tostring(value or "")
				-- El usuario está escribiendo: el primer Enter busca y el
				-- siguiente aplica. Sin esto, escribir y pulsar Enter
				-- aplicaba un wallpaper al azar.
				S.searchDirty = true
			end,
			onSubmit = function(value: any)
				sendWallhaven({ query = tostring(value or "") })
			end,
		})
	elseif mode == "grid" then
		return ui.input({
			key = "search-input",
			value = S.search,
			placeholder = tr("panel.search"),
			controlSize = "sm",
			-- Ancho explícito, no `flexGrow`: dentro del row agrupado del
			-- header el host no expande el input y el buscador no se dibujaba
			-- (el modo grid se quedaba sin forma de filtrar).
			width = 320,
			onChange = function(value: any)
				S.search = tostring(value or "")
				S.searchDirty = true
				S.focus, S.focusFrom, S.focusTo, S.focusT = 0, 0, 0, 1
				S.offset = 0
				render()
			end,
			onSubmit = function(value: any)
				S.search = tostring(value or "")
				focusTo(0)
			end,
		})
	end
	-- Sin buscador el header tiene que empujar los controles a la derecha.
	return ui.spacer()
end

-- Selector de fuente del catálogo.
local function headerSource(source: string): any
	return ui.select({
		options = {
			tr("panel.source_engine"),
			tr("panel.source_images"),
			tr("panel.source_videos"),
			tr("panel.source_wallhaven"),
		},
		selectedIndex = sourceIndex(),
		controlSize = "sm",
		width = 168,
		onChange = function(value: any)
			local index = tonumber(value)
			local target = index and SOURCES[index + 1]
			if target and target ~= activeSource() then
				setSource(target)
			end
		end,
	})
end

-- Botón que alterna carrusel/grilla, con etiqueta opcional.
local function headerViewSwitch(mode: string): any
	return ui.button({
		glyph = mode == "carousel" and "layout-grid" or "layout-list",
		text = viewLabelVisible() and tr(mode == "carousel" and "panel.view_carousel" or "panel.view_grid") or nil,
		variant = "ghost",
		controlSize = "sm",
		tooltip = tr("panel.toggle_view"),
		onClick = function()
			setView(mode == "carousel" and "grid" or "carousel")
		end,
	})
end

-- Acciones de la derecha: refrescar, favoritos, selección, diagnóstico,
-- ajustes y stop. El selector de salida va aparte porque lo esconde un ajuste.
local function headerActions(items: { Item }, source: string): { any }
	local acciones: { any } = {
		iconButton("refresh", tr("panel.refresh"), refresh),
		iconButton("star", tr("panel.only_favorites"), function()
			S.onlyFav = not S.onlyFav
			S.focus, S.focusFrom, S.focusTo, S.focusT = 0, 0, 0, 1
			S.offset = 0
			render()
		end, S.onlyFav),
		iconButton("checks", tr("panel.select_multiple_tooltip"), function()
			S.selecting = not S.selecting
			render()
		end, S.selecting),
	}
	if source == "engine" then
		acciones[#acciones + 1] = iconButton("gauge", tr("panel.diagnostics"), function()
			S.screen = "gpu"
			S.probeTotal = 0
			render()
		end)
	end
	acciones[#acciones + 1] = iconButton("settings", tr("panel.settings"), function()
		openOptions(nil)
	end)
	if statusTable().running == true then
		acciones[#acciones + 1] = ui.button({
			glyph = "player-stop",
			text = tr("panel.stop"),
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.stop_tooltip"),
			onClick = function()
				send({ action = "stop" })
			end,
		})
	end
	return acciones
end

local function header(items: { Item }, minimal: boolean?): any
	local mode = viewMode()
	local source = activeSource()
	local minimal = minimal == true
	-- El conteo de items salió del header: la barra de progreso de abajo ya dice
	-- en qué posición está el foco.
	-- El header se agrupa en dos bloques: fuente y navegación a la izquierda,
	-- acciones a la derecha. Con `space_between` y ocho hijos los controles
	-- quedaban repartidos por los 1500 px del panel, con huecos grandes en el
	-- medio que se leían como controles descolgados.
	local izquierda: { any } = {}
	-- El buscador se muestra siempre que la vista lo use (grilla y Wallhaven):
	-- es una función, no decoración. Ocultarlo en minimal dejaba la grilla sin
	-- forma de filtrar. Lo que minimal quita es el selector de salida, que es
	-- chrome.
	if mode == "grid" or source == "wallhaven" then
		izquierda[#izquierda + 1] = headerSearch(mode, source)
	end
	-- Con Wallhaven el Enter dispara la búsqueda, pero el botón deja el gesto a
	-- la vista: no todos descubren el Enter.
	if source == "wallhaven" then
		izquierda[#izquierda + 1] = iconButton("search", tr("panel.search_go"), function()
			sendWallhaven({ query = S.wh.query })
			render()
		end)
	end
	izquierda[#izquierda + 1] = headerSource(source)
	izquierda[#izquierda + 1] = headerViewSwitch(mode)
	-- El selector de salida sirve para cualquier fuente; el ajuste lo esconde.
	-- En minimal se oculta: es un control grande y el layout lo pide escueto.
	if applyOnVisible() and not minimal then
		izquierda[#izquierda + 1] = outputRow()
	end

	local derecha: { any } = {}
	for _, boton in ipairs(headerActions(items, source)) do
		derecha[#derecha + 1] = boton
	end

	return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
		ui.row({ align = "center", gap = 8 }, izquierda),
		ui.row({ align = "center", gap = 6 }, derecha),
	})
end

local function minutesControl(): any
	return ui.row({ align = "center", gap = 6 }, {
		ui.slider({
			min = MINUTES_MIN,
			max = MINUTES_MAX,
			step = 1,
			value = S.minutes,
			width = 200,
			onChange = function(value: any)
				local picked = tonumber(value)
				if picked then
					S.minutes = math.max(MINUTES_MIN, math.min(MINUTES_MAX, math.floor(picked + 0.5)))
				end
			end,
			onDragEnd = function()
				render()
			end,
		}),
		ui.label(
			{ text = tostring(S.minutes) .. " " .. tr("panel.minutes"), fontSize = 11, color = "on_surface_variant", maxWidth = 60 }
		),
	})
end

local function orderControl(): any
	return ui.select({
		options = { tr("panel.order_sequential"), tr("panel.order_random") },
		selectedIndex = S.order == "random" and 1 or 0,
		controlSize = "sm",
		onChange = function(index: any)
			S.order = (math.floor(tonumber(index) or 0) == 1) and "random" or "sequential"
			render()
		end,
	})
end

local function startOrStopCycle(running: boolean): ()
	if running then
		send({ action = "cycle_stop" })
		return
	end
	if #S.selected == 0 then
		noctalia.notifyError(tr("panel.cycle_needs_selection"))
		return
	end
	send({ action = "cycle_start", ids = S.selected, minutes = S.minutes, order = S.order })
end

local function cycleBar(): any
	local cycle = tableAt(statusTable(), "cycle")
	local running = cycle.active == true
	local count = tonumber(cycle.count) or #S.selected
	local summary = running
			and tr("panel.cycle_running", { count = tostring(count), minutes = tostring(S.minutes) })
		or tr("panel.selected_count", { count = tostring(#S.selected) })

	return ui.row({
		align = "center",
		gap = 8,
		padding = 8,
		radius = 9,
		fill = "surface_container/0.45",
		border = running and "primary/0.55" or "outline_variant/0.35",
		borderWidth = 1,
	}, {
		ui.label({ text = summary, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
		ui.label({ text = tr("panel.every"), fontSize = 12, color = "on_surface_variant" }),
		minutesControl(),
		orderControl(),
		ui.button({
			text = running and tr("panel.cycle_stop") or tr("panel.cycle_start"),
			glyph = running and "player-stop" or "player-play",
			variant = running and "ghost" or "primary",
			controlSize = "sm",
			onClick = function()
				startOrStopCycle(running)
			end,
		}),
	})
end

local function emptyState(): any
	local catalog = noctalia.state.get(CATALOG_KEY)
	local message = type(catalog) == "table" and tr("panel.no_wallpapers") or tr("panel.list_failed")
	-- `flexGrow` sin alto propio no centra nada en un panel height="content":
	-- el estado vacío quedaba pegado arriba y con un alto distinto al del grid.
	return ui.column({ align = "center", justify = "center", gap = 10, height = 420 }, {
		ui.glyph({ name = "photo", size = 28, color = "on_surface_variant" }),
		ui.label({ text = message, fontSize = 13, color = "on_surface_variant", maxLines = 2, textAlign = "center" }),
		ui.button({
			glyph = "refresh",
			text = tr("panel.refresh"),
			variant = "outline",
			controlSize = "sm",
			onClick = refresh,
		}),
	})
end

-- Coverflow: el foco va al centro a tamaño completo y los vecinos encogen con
-- la distancia. No hay transforms en la API, pero `width`/`height` son props:
-- escalar el tile es exactamente eso, y al animar la distancia de forma
-- fraccionaria el crecimiento también se anima.


-- La tira ocupa slot_w * (1 + 2*focusScale(1) + 2*focusScale(2)); si el foco
-- pidiera más que eso, las tarjetas se salen del panel y el foco deja de estar
-- centrado. Este es el techo real que puede pedir el usuario.
-- El ancho de celda sale siempre del reparto (que ya descuenta zonas y gaps):
-- una sola fórmula, para que la tira no pueda quedar más ancha que el panel.
local function carouselSlotW(): number
	local auto = carouselSlotWidth()
	local fixed = tonumber(layoutFor("carousel").w) or 0
	if fixed >= 80 then
		return math.min(fixed, auto)
	end
	return auto
end

local function carouselSlotH(w: number): number
	local fixed = tonumber(layoutFor("carousel").h) or 0
	if fixed >= 40 then
		return fixed
	end
	return math.floor(w * 9 / 16)
end

-- Celdas de la tira: siempre el mismo número de slots (el que eligió el
-- usuario). Cuando el catálogo no
-- llega a cubrirlos, el hueco se rellena con un contenedor del tamaño que le
-- tocaría por distancia, para que la tira mida igual en cualquier posición.
-- Devuelve las celdas y la firma de anchos que usa el diagnóstico.
local function carouselCells(
	items: { Item },
	center: number,
	slot_w: number,
	slot_h: number,
	current: string?
): ({ any }, string)
	local tiles: { any } = {}
	local sizes: { string } = {}
	local center_index = math.floor(center) + 1
	local radius = carouselRadius()
	for slot = 1, carouselSlots() do
		local index = center_index - radius + (slot - 1)
		local item = items[index]
		local distance = if item then math.abs((index - 1) - center) else math.abs(slot - (radius + 1))
		local scale = focusScale(distance)
		local width = math.max(48, math.floor(slot_w * scale))
		local height = math.max(24, math.floor(slot_h * scale))
		if item then
			local alpha = 1
			if S.warm then
				-- Frame invisible a tamaño máximo: el host decodifica la imagen de
				-- forma síncrona cuando el nodo CRE (el guard es monótono), así que
				-- se paga una vez acá y después achicar no vuelve a decodificar.
				width, height, alpha = slot_w, slot_h, 0
			end
			sizes[#sizes + 1] = tostring(width)
			tiles[#tiles + 1] = tile(item, current, width, height, alpha, distance < 0.5, index - 1, slot_w, slot_h)
		else
			-- El slot está fuera del catálogo (el foco está en el primer o en
			-- el último wallpaper): en vez de un hueco vacío se repite el
			-- wallpaper del borde, para que la tira se vea completa y el
			-- wallpaper enfocado quede en el centro.
			--
			-- Un `ui.box` con opacity 0 colapsa a tamaño cero en este host: la
			-- tira se encogía y el foco quedaba pegado a la izquierda. El
			-- placeholder mide el slot COMPLETO, como la celda real: con el
			-- ancho escalado los slots vacíos eran más angostos que los
			-- llenos y la tira quedaba asimétrica (el wallpaper enfocado a 47
			-- px del centro) y cambiaba de tamaño al mover el foco.
			local borde = if index < 1 then items[1] else items[#items]
			sizes[#sizes + 1] = tostring(slot_w)
			if borde ~= nil then
				tiles[#tiles + 1] = tile(borde, current, slot_w, slot_h, 0.35, false, index - 1, slot_w, slot_h)
			else
				tiles[#tiles + 1] = ui.column({
					key = "ph-" .. tostring(slot),
					width = slot_w,
					height = slot_h,
				}, {})
			end
		end
	end
	return tiles, table.concat(sizes, ",")
end

local function carousel(items: { Item }, current: string?): any
	local total = #items
	if total == 0 then
		return emptyState()
	end

	-- El foco puede quedar fuera de rango si el catálogo se achica (filtro nuevo,
	-- otra búsqueda): sin esto la celda central no tiene item y la tira se ve
	-- como una fila de cajas negras.
	local center = math.max(0, math.min(math.floor(S.focus + 0.5), total - 1))
	S.focus = center

	-- Siempre el mismo número de celdas (aunque en los bordes sobren): si el
	-- ancho de la tira dependiera de cuántos items entran, pasar del primer
	-- wallpaper al segundo movería todo el layout.
	local slot_w = carouselSlotW()
	local slot_h = math.max(40, carouselSlotH(slot_w))
	local gap = math.max(0, math.min(100, math.floor(tonumber(tableAt(storeTable(), "view").spacing) or 0)))
	-- El gap real (no 0): el store puede no traerlo y por defecto es 15.
	if tonumber(tableAt(storeTable(), "view").spacing) == nil then
		gap = 15
	end
	local minimal = minimalOn()

	local tiles, firm = carouselCells(items, center, slot_w, slot_h, current)

	-- Diagnóstico barato: sólo loguea cuando cambian los anchos calculados.
	if S.focusT >= 1 and S.lastSizes ~= firm then
		S.lastSizes = firm
		noctalia.log("[carousel] slot=" .. tostring(slot_w) .. "x" .. tostring(slot_h) .. " foco=" .. tostring(center) .. " anchos=" .. firm)
	end

	local focused = focusedIndex()
	local span = math.max(1, total - 1)

	-- La fila de celdas necesita `flexGrow = 1`: sin él el host la mide por
	-- contenido y, dentro de la tira (`space_between`), queda pegada a la
	-- derecha en vez de al centro. Con el grow la fila toma el ancho que
	-- sobra entre las dos zonas y `justify = "center"` centra las celdas
	-- DENTRO de ese ancho: con 3 wallpapers quedan agrupados en el centro
	-- del panel, con el fondo del plugin a los lados.
	local fila = ui.row({ align = "center", justify = "center", gap = gap, height = slot_h, flexGrow = 1 }, tiles)
	-- Zonas de scroll por hover, con clave estable.
	--
	-- El glifo se eliminó: las flechas dibujadas en los extremos competían
	-- con las imágenes y el usuario pidió quitar las flechas de izquierda y
	-- derecha. La ZONA sigue estando (sin glifo): es la que dispara el
	-- scroll por hover (`S.hoverDir`), que es como se recorre la tira sin
	-- flechas.
	local function zona(dir: number, ancho: number): any
		return ui.column({
			key = "wh-edge-" .. tostring(dir),
			width = ancho,
			height = slot_h,
			align = "center",
			justify = "center",
			onHover = function(state: any)
				if state == "true" then
					S.hoverDir = dir
				elseif S.hoverDir == dir then
					S.hoverDir = 0
				end
			end,
		}, {})
	end
	-- La tira: las zonas de scroll van en los extremos y las celdas al centro.
	-- Con `justify = "center"` el reparto del host era 0 (las celdas ya
	-- consumían el ancho) y la zona de la izquierda quedaba fuera del
	-- panel: su glifo no se veía. Con `space_between` las zonas se pegan a los
	-- bordes y las celdas se centran en el espacio que sobra.
	--
	-- Con 3 wallpapers la tira es más angosta que el panel: `space_between`
	-- deja las zonas pegadas a los bordes y las celdas en el medio, que es
	-- justo lo que se quiere (la tira al centro del panel, con el fondo del
	-- plugin a los lados).
	local tira = ui.row({ align = "center", justify = "space_between", gap = 0 }, {
		zona(-1, EDGE_W),
		fila,
		zona(1, EDGE_W),
	})
	-- Minimal = sólo la galería. Full agrega los metadatos: el contador
	-- "3/40" y el nombre del wallpaper enfocado. La barra de progreso NO es
	-- metadato: tiene su propio interruptor (`carousel.progress`) y se
	-- respeta en los dos layouts, si no el ajuste dejaría de hacer nada.
	local pie: { any } = {}
	if carouselProgressOn() then
		pie[#pie + 1] = ui.progress({
			progress = total <= 1 and 0 or (focused / span),
			height = 2,
			radius = 1,
			-- Sin `width` el host mide el progress por su contenido y queda
			-- pegado a la izquierda (516 px de 1468). Con el ancho explícito
			-- ocupa toda la tira.
			width = PANEL_INNER,
		})
	else
		pie[#pie + 1] = ui.spacer()
	end
	if not minimal then
		pie[#pie + 1] = ui.label({
			text = tostring(focused + 1) .. "/" .. tostring(total),
			fontSize = 10,
			color = "on_surface_variant",
			maxLines = 1,
		})
	end

	local hijos: { any } = { tira }
	if minimal then
		if carouselProgressOn() then
			hijos[#hijos + 1] = ui.row({ align = "center", gap = 8 }, pie)
		end
		-- El gap separa la barra del borde inferior de las tarjetas: con 0
		-- quedaba en la misma línea y se leía como si estuviera encima de ellas.
		-- (`marginTop` no existe en la API: sólo gap, padding, paddingH/V.)
		return ui.column({ gap = 12 }, hijos)
	end

	-- Full: además del contador, el nombre de lo que está en el medio. El
	-- carrusel no mostraba ningún título: sólo se veía la imagen.
	local item_foco = items[focused + 1]
	hijos[#hijos + 1] = ui.row({ align = "center", gap = 8 }, pie)
	if item_foco ~= nil then
		hijos[#hijos + 1] = ui.label({
			text = truncate(itemTitle(item_foco), TITLE_MAX),
			fontSize = 12,
			color = "on_surface",
			maxLines = 1,
		})
	end
	-- El gap de 12 separa la barra del borde inferior de las tarjetas: con el
	-- gap anterior (8) quedaba pegada y se leía como si estuviera encima.
	return ui.column({ gap = 12 }, hijos)
end

-- El grid reparte el ancho en columnas; el carrusel usa tileW().
-- A grid row sizes its tiles to the column count instead, so 2 to 8 columns all
-- fit the fixed panel width without clipping.
-- Alto que ocupa el chrome sobre la grilla: cabecera, barra de Wallhaven y
-- barra de ciclo. Se resta del alto disponible del panel.
local function grid_chrome_h(): number
	local chrome = 56 -- cabecera
	if activeSource() == "wallhaven" then
		chrome += 92 -- dos filas de filtros + buscador
	end
	if S.selecting or tableAt(statusTable(), "cycle").active == true then
		chrome += 48
	end
	if not minimalOn() then
		chrome += 44 -- barra "reproduciendo ahora"
	end
	return chrome
end

local function grid(items: { Item }, current: string?): any
	-- Con miles de resultados, dibujar todas las tarjetas revienta el render:
	-- se dibuja una ventana y crece cuando el scroll se acerca al final.
	local window = math.min(#items, S.gridWindow or GRID_WINDOW)
	local columns, width = gridGeometry()
	local height = gridCardH(width)
	local minimal = minimalOn()
	local rows: { any } = {}
	local row: { any } = {}
	for index = 1, window do
		local item = items[index]
		row[#row + 1] = tile(item, current, width, height)
		if #row == columns or index == window then
			rows[#rows + 1] = ui.row({ gap = TILE_GAP, align = "start" }, row)
			row = {}
		end
	end
	-- Una caja final del alto de media fila: sin esto la última fila queda
	-- pegada al borde y parece cortada por la mitad.
	rows[#rows + 1] = ui.box({ height = math.floor(height / 2) })

	-- Alto explícito: el panel es height="content" y un scroll con flexGrow
	-- dentro de un padre sin alto definido mide 0 (el panel quedaba en una tira).
	-- El alto disponible sale del `max_height` del manifiesto menos el chrome
	-- (header + barra de Wallhaven + barra de ciclo), no de un 640 fijo: con
	-- 5 columnas sólo se veían 2 filas de 55 wallpapers.
	local row_h = height + (minimal and 10 or 60)
	local disponible = GRID_MAX_H - grid_chrome_h()
	local visible = math.max(1, math.floor(disponible / row_h))
	local height_total = math.min(#rows * row_h, visible * row_h)
	local focus_item = items[focusedIndex() + 1]
	-- El flag se lee ANTES de limpiarlo: antes se ponía en false unas líneas
	-- más arriba y la expresión daba siempre nil, así que el scroll del grid
	-- nunca seguía al foco con el teclado.
	local revelar = S.revealPending
	S.revealPending = false
	return ui.scroll({
		key = "grid-scroll",
		gap = TILE_GAP,
		paddingH = GRID_PAD_H,
		align = "stretch",
		height = height_total,
		-- Con el teclado, el host scrollea hasta la tarjeta enfocada.
		-- `revealKey` sólo cuando el foco lo pidió (teclado/nav). Si viaja en cada
		-- render, la rueda scrollea y el host vuelve a saltar a la tarjeta
		-- enfocada: el scroll parecía no funcionar en Wallhaven.
		-- La key es la de la tarjeta (`item.id`), no "tile-<id>": el host
		-- busca un nodo con esa key exacta.
		revealKey = (revelar and focus_item) and focus_item.id or nil,
		onScroll = function(offset: any, max_offset: any)
			local pos = tonumber(offset) or 0
			local limit = tonumber(max_offset) or 0
			-- Cerca del final: sumar otra tanda y repintar.
			if window < #items and pos + 1200 >= limit then
				S.gridWindow = window + GRID_WINDOW
				render()
			end
		end,
	}, rows)
end


local function nowPlaying(items: { Item }, current: string?): any?
	local status = statusTable()
	local title = currentTitle(items)
	-- `running` era verdad con cualquier wallpaper aplicado (no sólo con el
	-- ciclo): la barra quedaba pegada al pie en todo momento, con su botón
	-- de Stop, y además duplicaba el "Stop" del header.
	local cycle = tableAt(status, "cycle")
	if tableAt(status, "running") ~= true or title == nil then
		return nil
	end
	if tableAt(cycle, "active") ~= true then
		return nil
	end
	local item = findItem(items, current)
	return ui.row({
		align = "center",
		gap = 10,
		padding = 8,
		radius = 9,
		fill = "surface_container/0.35",
		border = "outline_variant/0.30",
		borderWidth = 1,
	}, {
		ui.glyph({ name = "movie", size = 16, color = "primary" }),
		ui.label({ text = truncate(title :: string, 46), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
		ui.label({
			text = type(status.output) == "string" and status.output or "",
			fontSize = 11,
			color = "on_surface_variant",
			maxLines = 1,
		}),
		item ~= nil and ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.configure"),
			onClick = function()
				openOptions((item :: Item).id)
			end,
		}) or nil,
	})
end

local function browseView(items: { Item }): any
	local status = statusTable()
	local current = type(status.id) == "string" and status.id or nil
	-- Minimal es "sólo la galería": sin metadatos (lo que está sonando, el
	-- contador, los títulos de las tarjetas). Full los muestra.
	local minimal = minimalOn()
	local children: { any } = { header(items, minimal) }
	-- La barra de Wallhaven (filtros + buscador) es contenido, no chrome:
	-- en minimal se mantiene porque el buscador es la única forma de buscar.
	if activeSource() == "wallhaven" then
		append(children, wallhavenBar())
	end
	-- La barra de selección/ciclo es parte del modo selección múltiple: fuera
	-- de ese modo no se muestra (salvo que haya un ciclo corriendo, que hace
	-- falta para poder detenerlo).
	if S.selecting or tableAt(status, "cycle").active == true then
		append(children, cycleBar())
	end
	if #items == 0 then
		append(children, emptyState())
	elseif viewMode() == "grid" then
		append(children, grid(items, current))
	else
		append(children, carousel(items, current))
	end
	-- Minimal es "sólo la galería": sin metadatos (lo que está sonando, el
	-- contador, los títulos de las tarjetas). Full los muestra.
	if not minimal then
		append(children, nowPlaying(items, current))
	end
	-- En minimal el contenido va a sangre: menos gap y sin padding extra.
	return ui.column({ gap = minimal and 4 or 12, flexGrow = 1 }, children)
end

-- ── options ──────────────────────────────────────────────────────────────────

local function inheritedEngine(id: string?): { [string]: any }
	local store = storeTable()
	local merged = copy(tableAt(store, "defaults"))
	if id then
		for key, value in pairs(tableAt(tableAt(store, "overrides"), id)) do
			merged[key] = value
		end
	end
	return merged
end

-- Marca un punto cuando el campo tiene un valor propio distinto del heredado:
-- así se ve de un vistazo qué tocó el usuario sin abrir el resto.
local function modifiedDot(modified: boolean): any
	return ui.glyph({ name = modified and "circle-filled" or "circle", size = 7, color = modified and "primary" or "outline_variant" })
end

local function formRow(label: string, control: any, modified: boolean?): any
	return ui.row({ align = "center", gap = 10 }, {
		modifiedDot(modified == true),
		ui.label({ text = label, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		control,
	})
end

-- Tarjeta desplegable: la API no tiene acordeón, así que el título es un row
-- clickeable que muestra u oculta sus filas.
local function sectionCard(titleKey: string, group: string, rows: { any }): any
	-- Abierta por defecto: el estado se guarda sólo cuando el usuario la cierra.
	-- Con `== true` todas arrancaban colapsadas y parecía que las opciones
	-- habían desaparecido.
	local open = S.sections[group] ~= false
	local children: { any } = {
		ui.row({
			align = "center",
			gap = 8,
			onClick = function()
				S.sections[group] = not open
				render()
			end,
		}, {
			ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 15, color = "on_surface_variant" }),
			ui.label({
				text = tr(titleKey),
				fontSize = 12,
				fontWeight = "bold",
				color = "on_surface_variant",
				flexGrow = 1,
				maxLines = 1,
			}),
			ui.label({
				text = tostring(#rows),
				fontSize = 10,
				color = "outline_variant",
				maxLines = 1,
			}),
		}),
	}
	if open then
		for _, row in ipairs(rows) do
			children[#children + 1] = row
		end
	end
	return ui.column({
		gap = 10,
		padding = 10,
		radius = 10,
		fill = "surface_container/0.30",
		border = "outline_variant/0.25",
		borderWidth = 1,
	}, children)
end

local function enumRow(field: EngineField, current: any, unsetKey: string, modified: boolean): any
	local values = field.values or {}
	local labels = field.option_labels or {}
	local options: { string } = {}
	local selectedIndex = 0
	for index, value in ipairs(values) do
		local labelKey: string = index == 1 and unsetKey or (labels[index] or unsetKey)
		options[#options + 1] = tr(labelKey)
		if (current or "") == value then
			selectedIndex = index - 1
		end
	end
	return formRow(tr(field.label), ui.select({
		options = options,
		selectedIndex = selectedIndex,
		controlSize = "sm",
		width = 200,
		onChange = function(index: any)
			local picked = values[(math.floor(tonumber(index) or 0)) + 1]
			S.draft[field.key] = (picked ~= nil and picked ~= "") and picked or nil
			render()
		end,
	}), modified)
end

local function numberRow(field: EngineField, current: any, modified: boolean): any
	local lo = field.lo or 0
	local hi = field.hi or 100
	local value = math.floor(tonumber(current) or lo)
	return ui.row({ align = "center", gap = 10 }, {
		modifiedDot(modified),
		ui.label({ text = tr(field.label), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		ui.slider({
			min = lo,
			max = hi,
			step = 1,
			value = value,
			width = 260,
			onChange = function(next: any)
				local picked = tonumber(next)
				if picked then
					S.draft[field.key] = math.floor(picked + 0.5)
				end
			end,
			onDragEnd = function()
				render()
			end,
		}),
		ui.label({ text = tostring(value), fontSize = 11, color = "on_surface_variant", maxWidth = 48, textAlign = "end" }),
	})
end

local function boolRow(field: EngineField, current: any, modified: boolean): any
	local checked = current == true
	return formRow(tr(field.label), ui.toggle({
		checked = checked,
		onChange = function()
			S.draft[field.key] = not checked
			render()
		end,
	}), modified)
end

local function engineRow(field: EngineField, inherited: { [string]: any }, unsetKey: string): any
	local mine = S.draft[field.key]
	local current = mine
	if current == nil then
		current = inherited[field.key]
	end
	local modified = mine ~= nil and mine ~= inherited[field.key]
	if field.kind == "enum" then
		return enumRow(field, current, unsetKey, modified)
	elseif field.kind == "number" then
		return numberRow(field, current, modified)
	end
	return boolRow(field, current, modified)
end

local function resolvedEngine(id: string?): { [string]: any }
	local inherited = inheritedEngine(id)
	local engine: { [string]: any } = {}
	for _, field in ipairs(ENGINE_FIELDS) do
		local value = S.draft[field.key]
		if value == nil then
			value = inherited[field.key]
		end
		if value ~= nil and value ~= "" then
			engine[field.key] = value
		end
	end
	return engine
end

local function applyOptions(id: string?): ()
	local payload: { [string]: any } = { action = "set_options", engine = resolvedEngine(id) }
	if id then
		payload.id = id
	end
	send(payload)
end

local function clearOverrides(id: string?): ()
	S.draft = {}
	local payload: { [string]: any } = { action = "set_options", engine = {}, clear_overrides = true }
	if id then
		payload.id = id
	end
	send(payload)
end

-- Una fila = etiqueta + slider + valor. Las tres de antes eran la misma cosa
-- copiada: columnas, tamaño de card y separación.
local function sliderRow(
	label_key: string,
	lo: number,
	hi: number,
	step: number,
	current: number,
	on_change: (number) -> (),
	on_commit: () -> ()
): any
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = tr(label_key), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		ui.slider({
			min = lo,
			max = hi,
			step = step,
			value = current,
			width = 260,
			onChange = function(value: any)
				local picked = tonumber(value)
				if picked then
					on_change(math.max(lo, math.min(hi, math.floor(picked + 0.5))))
				end
			end,
			-- Se confirma al soltar: un request por tick haría republicar el
			-- store bajo el puntero.
			onDragEnd = on_commit,
		}),
		ui.label({ text = tostring(current), fontSize = 11, color = "on_surface_variant", maxWidth = 48, textAlign = "end" }),
	})
end

local function columnsRow(): any
	return sliderRow("settings.grid_columns.label", COLUMNS_MIN, COLUMNS_MAX, 1, S.columns or viewColumns(), function(picked)
		S.columns = picked
		render()
	end, function()
		if S.columns and S.columns ~= viewColumns() then
			send({ action = "set_view", columns = S.columns })
		end
		render()
	end)
end


local function spacingRow(): any
	return sliderRow("settings.carousel_spacing.label", 0, 100, 1, S.spacing or viewSpacing(), function(picked)
		S.spacing = picked
		S.lastFirm = nil
		render()
	end, function()
		if S.spacing and S.spacing ~= viewSpacing() then
			send({ action = "set_view", spacing = S.spacing })
		end
		render()
	end)
end

-- Orden del catálogo cuando la fuente es una carpeta local.
local function localSortRow(): any
	local SORTS = { "name", "date", "random" }
	local actual = tostring(storeValue("local_sort") or "name")
	local index = indexOf(SORTS, actual)
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = tr("settings.local_sort.label"), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		ui.select({
			options = { tr("settings.local_sort.name"), tr("settings.local_sort.date"), tr("settings.local_sort.random") },
			selectedIndex = math.max(0, index),
			controlSize = "sm",
			width = 190,
			onChange = function(value: any)
				local picked = SORTS[(tonumber(value) or 0) + 1]
				if picked then
					send({ action = "set_local_sort", sort = picked })
					render()
				end
			end,
		}),
	})
end

-- Color sólido como wallpaper (lo que el panel built-in hace con su color picker).
local function colorRow(): any
	local actual = tostring(storeValue("color") or "#1e1e2e")
	S.colorDraft = S.colorDraft or actual
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = tr("settings.color.label"), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		ui.box({ width = 28, height = 28, radius = 6, fill = S.colorDraft or actual }),
		ui.input({
			key = "color-hex",
			value = S.colorDraft or actual,
			placeholder = "#1e1e2e",
			controlSize = "sm",
			width = 110,
			onChange = function(value: any)
				S.colorDraft = tostring(value or "")
			end,
			onSubmit = function(value: any)
				local hex = tostring(value or "")
				if string.match(hex, "^#%x%x%x%x%x%x$") then
					send({ action = "apply_color", color = hex })
					render()
				end
			end,
		}),
		ui.button({
			text = tr("panel.apply"),
			variant = "secondary",
			controlSize = "sm",
			onClick = function()
				local hex = S.colorDraft or actual
				if string.match(hex, "^#%x%x%x%x%x%x$") then
					send({ action = "apply_color", color = hex })
					render()
				end
			end,
		}),
	})
end

-- El tema sigue la paleta del wallpaper (Noctalia la deriva de la imagen).
-- Interruptor del modo debug. Apagado por defecto: deja trazas de cada acción,
-- arranque de proceso y escaneo, más un reporte completo.
local function debugRow(): any
	local activo = storeTable().debug == true
	return ui.row({ align = "center", gap = 10 }, {
		ui.column({ gap = 2, flexGrow = 1 }, {
			ui.label({ text = tr("settings.debug.label"), fontSize = 12, color = "on_surface" }),
			ui.label({
				text = tr("settings.debug.description"),
				fontSize = 10,
				color = "on_surface_variant",
				maxLines = 2,
			}),
		}),
		ui.button({
			text = if activo then tr("settings.debug.on") else tr("settings.debug.off"),
			variant = if activo then "primary" else "outline",
			controlSize = "sm",
			onClick = function()
				send({ action = "set_debug", enabled = not activo })
				render()
			end,
		}),
	})
end

local function themeRow(): any
	local enabled = storeValue("sync_colors") ~= false
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = tr("settings.sync_colors.label"), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
		ui.toggle({
			checked = enabled,
			onChange = function(value: any)
				send({ action = "set_theme", enabled = value == true })
				render()
			end,
		}),
	})
end

local function optionsHeader(title: string, id: string?): any
	local actions: { any } = {
		ui.button({
			glyph = "arrow-left",
			variant = "ghost",
			controlSize = "sm",
			tooltip = tr("panel.back"),
			onClick = function()
				S.screen = "browse"
				render()
			end,
		}),
		ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1, maxLines = 1 }),
		ui.button({
			glyph = "check",
			text = tr("engine.apply"),
			variant = "primary",
			controlSize = "sm",
			onClick = function()
				applyOptions(id)
			end,
		}),
		ui.button({
			glyph = "restore",
			text = tr("engine.reset"),
			variant = "ghost",
			controlSize = "sm",
			onClick = function()
				S.draft = {}
				render()
			end,
		}),
	}
	if id then
		append(
			actions,
			ui.button({
				glyph = "trash",
				text = tr("engine.clear_overrides"),
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					clearOverrides(id)
				end,
			})
		)
	end
	return ui.row({ align = "center", gap = 8 }, actions)
end


-- Filtros de Wallhaven replicados del plugin oficial (pureza, categorías, orden,
-- resolución y proporción). Se editan acá y el service rearma la consulta.
local function wallhavenSection(): any
	local function row(labelKey: string, values: { string }, labels: { string }, current: string, field: string): any
		return ui.row({ align = "center", gap = 10 }, {
			ui.label({ text = tr(labelKey), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
			ui.select({
				options = labels,
				selectedIndex = indexOf(values, current),
				controlSize = "sm",
				width = 190,
				onChange = function(value: any)
					local index = tonumber(value)
					local picked = index and values[index + 1]
					if picked then
						sendWallhaven({ [field] = picked })
						render()
					end
				end,
			}),
		})
	end

	local WH_MAX_VALUES = { "120", "600", "1200", "2400" }
	local current_max = tostring(math.floor(tonumber(storeValue("wallhaven_max")) or 1200))
	local max_index = 2
	for index, value in ipairs(WH_MAX_VALUES) do
		if current_max == value then
			max_index = index
		end
	end

	return sectionCard("panel.options_wallhaven", "wallhaven", {
		-- Resolución: el oficial deja elegir mínimo o exacta y escribir el tamaño.
		ui.row({ align = "center", gap = 10 }, {
			ui.label({ text = tr("panel.wh_resolution"), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
			ui.select({
				options = { tr("panel.wh_res_atleast"), tr("panel.wh_res_exact") },
				selectedIndex = (S.wh.resmode == "exact") and 1 or 0,
				controlSize = "sm",
				width = 130,
				onChange = function(value: any)
					local index = tonumber(value) or 0
					S.wh.resmode = (index == 1) and "exact" or "atleast"
					sendWallhaven({ resmode = S.wh.resmode })
					render()
				end,
			}),
			ui.input({
				key = "wh-width",
				value = S.wh.width or "",
				placeholder = tr("panel.wh_width"),
				controlSize = "sm",
				width = 74,
				onChange = function(value: any)
					S.wh.width = tostring(value or ""):gsub("%D", "")
				end,
			}),
			ui.input({
				key = "wh-height",
				value = S.wh.height or "",
				placeholder = tr("panel.wh_height"),
				controlSize = "sm",
				width = 74,
				onChange = function(value: any)
					S.wh.height = tostring(value or ""):gsub("%D", "")
				end,
			}),
			ui.button({
				text = tr("panel.apply"),
				variant = "secondary",
				controlSize = "sm",
				onClick = function()
					local w = tonumber(S.wh.width or "")
					local h = tonumber(S.wh.height or "")
					if w and h and w > 0 and h > 0 then
						sendWallhaven({ res = w .. "x" .. h, resmode = S.wh.resmode })
					else
						-- Sin números, "aplicar" limpia el filtro.
						S.wh.width, S.wh.height = "", ""
						sendWallhaven({ res = "", resmode = S.wh.resmode })
					end
					render()
				end,
			}),
			iconButton("x", tr("panel.wh_clear"), function()
				S.wh.width, S.wh.height = "", ""
				sendWallhaven({ res = "", resmode = S.wh.resmode })
				render()
			end),
		}),
		ui.row({ align = "center", gap = 10 }, {
			ui.label({ text = tr("panel.wh_results"), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
			ui.select({
				options = { "120", "600", "1200", "2400" },
				selectedIndex = max_index - 1,
				controlSize = "sm",
				width = 190,
				onChange = function(value: any)
					local index = tonumber(value)
					local picked = index and ({ "120", "600", "1200", "2400" })[index + 1]
					if picked then
						send({ action = "set_wh_max", value = tonumber(picked) })
						render()
					end
				end,
			}),
		}),
	})
end

-- Propiedades del proyecto del wallpaper: en el plugin oficial es el botón
-- "Configurar" y escribe `--set-property`. Acá se editan como texto; vacío
-- quita la propiedad y vuelve al valor del proyecto.
local function propertiesCard(item: any): any?
	local props = item and item.props
	if type(props) ~= "table" or next(props) == nil then
		return nil
	end
	local saved = tableAt(tableAt(storeTable(), "properties"), item.id)
	local names: { string } = {}
	for name in pairs(props) do
		names[#names + 1] = name
	end
	table.sort(names)

	local rows: { any } = {}
	for _, name in ipairs(names) do
		local stored = saved[name]
		local current = if stored ~= nil then tostring(stored) else ""
		-- En project.json cada propiedad es una especificación
		-- { type, value, text, order }: el valor por defecto es `value` y el
		-- nombre legible sale de `text`.
		local spec = props[name]
		local default_text = ""
		local label = name
		if type(spec) == "table" then
			default_text = tostring(spec.value or "")
			if type(spec.text) == "string" and spec.text ~= "" then
				label = (spec.text:gsub("^ui_browse_properties_", ""))
			end
		else
			default_text = tostring(spec)
		end
		rows[#rows + 1] = ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = label, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 1 }),
			ui.input({
				key = "prop-" .. name,
				value = current,
				placeholder = default_text,
				controlSize = "sm",
				width = 150,
					onSubmit = function(value: any)
					send({ action = "set_property", id = item.id, name = name, value = tostring(value or "") })
					render()
				end,
			}),
		})
	end

	rows[#rows + 1] = ui.row({ align = "center", gap = 8 }, {
		ui.label({ text = tr("panel.props_hint"), fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
		ui.button({
			text = tr("panel.props_clear"),
			variant = "ghost",
			controlSize = "sm",
			onClick = function()
				send({ action = "clear_properties", id = item.id })
				render()
			end,
		}),
	})

	return sectionCard("panel.props_title", "properties", rows)
end

-- ── disposición (por modo) ───────────────────────────────────────────────────

-- Fila con interruptor y explicación, igual que la del modo debug.
local function switchRow(label_key: string, desc_key: string, value: boolean, on_toggle: () -> ()): any
	return ui.row({ align = "center", gap = 10 }, {
		ui.column({ gap = 2, flexGrow = 1 }, {
			ui.label({ text = tr(label_key), fontSize = 12, color = "on_surface", maxLines = 1 }),
			ui.label({ text = tr(desc_key), fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
		}),
		ui.toggle({
			value = value,
			onChange = function()
				on_toggle()
			end,
		}),
	})
end

-- Ancho/alto de una vista: 0 = automático (se deriva del contenido).
local function sizeRow(mode_key: string, dimension: string, lo: number, hi: number, step: number, current: number): any
	local label_key = "settings.layout." .. mode_key .. "_" .. dimension
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = tr(label_key), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
		ui.slider({
			min = lo,
			max = hi,
			step = step,
			value = current,
			width = 240,
			onChange = function(value: any)
				local picked = tonumber(value)
				if picked then
					local rounded = math.floor(picked + 0.5)
					-- 0 = automático: el primer paso del slider ya es el valor mínimo.
					if rounded < lo then
						rounded = 0
					end
					setPendingLayout(mode_key, dimension, rounded)
					render()
				end
			end,
			-- Se confirma al soltar: un request por tick haría republicar el store
			-- bajo el puntero. El pendiente se queda hasta que el store coincida.
			onDragEnd = function()
				local value = (S.pendingLayout or {})[mode_key .. "." .. dimension]
				if value ~= nil then
					send({ action = "set_view", [mode_key] = { [dimension] = value } })
				end
				render()
			end,
		}),
		ui.label({
			text = current == 0 and tr("settings.layout.auto") or tostring(current),
			fontSize = 11,
			color = "on_surface_variant",
			maxWidth = 48,
			textAlign = "end",
		}),
	})
end

-- Ancho del panel por modo. El host no redimensiona un panel abierto: el
-- valor elige el escalón de la escalera y el panel se cierra y se reabre al
-- soltar el slider. 0 = automático (el panel se ajusta a la tira).
local function panelWidthRow(mode_key: string): any
	local actual = math.floor(tonumber(layoutFor(mode_key).panel_w) or 0)
	local key = mode_key .. ".panel_w"
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({
			text = tr("settings.layout." .. mode_key .. "_panel_w"),
			fontSize = 12,
			color = "on_surface",
			flexGrow = 1,
			maxLines = 1,
		}),
		ui.slider({
			min = 0,
			max = PANEL_MAX_W,
			step = PANEL_STEP,
			value = actual,
			width = 240,
			onChange = function(value: any)
				local picked = tonumber(value)
				if picked then
					local rounded = math.floor(picked + 0.5)
					-- Por debajo del escalón mínimo el valor es "automático".
					if rounded < PANEL_MIN_W then
						rounded = 0
					end
					setPendingLayout(mode_key, "panel_w", rounded)
					render()
				end
			end,
			-- Se confirma al soltar: cada tick reabriría el panel.
			onDragEnd = function()
				local value = (S.pendingLayout or {})[key]
				if value ~= nil then
					send({ action = "set_view", [mode_key] = { panel_w = value } })
				end
				render()
			end,
		}),
		ui.label({
			text = actual == 0 and tr("settings.layout.auto") or tostring(actual),
			fontSize = 11,
			color = "on_surface_variant",
			maxWidth = 48,
			textAlign = "end",
		}),
	})
end

local function layoutBlock(mode_key: string, with_progress: boolean): { any }
	local conf = layoutFor(mode_key)
	local w = tonumber(conf.w) or 0
	local h = tonumber(conf.h) or 0
	local es_minimal = conf.layout == "minimal"
	-- Topes reales del contenedor: en el carrusel lo manda el ancho de la tira;
	-- en la grilla, dos columnas es el caso más ancho.
	local max_w = mode_key == "carousel" and maxCardW() or math.floor((PANEL_INNER - TILE_GAP) / 2)
	local filas: { any } = {
		ui.row({ align = "center", gap = 10 }, {
			ui.glyph({ name = mode_key == "carousel" and "gallery-horizontal" or "layout-grid", size = 16, color = "primary" }),
			ui.label({ text = tr("settings.layout." .. mode_key), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
			ui.button({
				text = tr(es_minimal and "settings.layout.minimal" or "settings.layout.full"),
				variant = es_minimal and "outline" or "primary",
				controlSize = "sm",
				tooltip = tr("settings.layout.style_hint"),
				onClick = function()
					local nuevo = es_minimal and "full" or "minimal"
					setPendingLayout(mode_key, "layout", nuevo)
					send({ action = "set_view", [mode_key] = { layout = nuevo } })
					render()
				end,
			}),
		}),
		sizeRow(mode_key, "w", 80, max_w, 10, w),
		sizeRow(mode_key, "h", 60, 420, 10, h),
		panelWidthRow(mode_key),
	}
	if mode_key == "carousel" then
		-- Cuántos wallpapers se ven a la vez: 3 (el enfocado y uno a cada
		-- lado) o 5 (el coverflow completo).
		--
		-- Es un select y no un slider porque los valores válidos son
		-- impares (el enfocado va al centro y los demás se reparten a partes
		-- iguales): con un slider se podrían elegir 4, que no se puede
		-- repartir.
		local slots = carouselSlots()
		filas[#filas + 1] = ui.row({ align = "center", gap = 10 }, {
			ui.label({ text = tr("settings.layout.carousel_slots"), fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
			ui.select({
				key = "carousel-slots",
				options = { "3", "5" },
				selectedIndex = (slots == 3) and 0 or 1,
				width = 96,
				controlSize = "sm",
				onChange = function(value: any)
					-- El callback entrega el ÍNDICE (0-based), como el resto de
					-- los select del panel.
					local valor = (math.floor(tonumber(value) or 0) == 0) and 3 or 5
					setPendingLayout("carousel", "slots", valor)
					send({ action = "set_view", carousel = { slots = valor } })
					render()
				end,
			}),
		})
	end
	if with_progress then
		filas[#filas + 1] = switchRow(
			"settings.layout.progress",
			"settings.layout.progress_desc",
			conf.progress ~= false,
			function()
				local nuevo = not (conf.progress ~= false)
				setPendingLayout("carousel", "progress", nuevo)
				send({ action = "set_view", carousel = { progress = nuevo } })
				render()
			end
		)
	end
	return filas
end

local function layoutSection(): any
	local view = tableAt(storeTable(), "view")
	local filas: { any } = {
		switchRow("settings.layout.apply_on", "settings.layout.apply_on_desc", viewFlag("apply_on"), function()
			local nuevo = not viewFlag("apply_on")
			setPendingFlag("apply_on", nuevo)
			send({ action = "set_view", apply_on = nuevo })
			render()
		end),
		switchRow("settings.layout.view_label", "settings.layout.view_label_desc", viewFlag("view_label"), function()
			local nuevo = not viewFlag("view_label")
			setPendingFlag("view_label", nuevo)
			send({ action = "set_view", view_label = nuevo })
			render()
		end),
	}
	for _, fila in ipairs(layoutBlock("carousel", true)) do
		filas[#filas + 1] = fila
	end
	for _, fila in ipairs(layoutBlock("grid", false)) do
		filas[#filas + 1] = fila
	end
	return sectionCard("panel.options_layout", "layout", filas)
end

local function optionsView(items: { Item }): any
	local id = S.optionsId
	local item = findItem(items, id)
	local title = item and truncate(itemTitle(item), 40) or tr("panel.defaults")
	local unsetKey = id and "engine.inherit" or "engine.unset"
	local inherited = inheritedEngine(id)

	-- Agrupados por para qué sirve cada flag: 13 filas sueltas era un muro.
	local groups = {
		{ key = "playback", fields = { "fps", "volume", "silent", "noautomute", "no_audio_processing" } },
		{ key = "image", fields = { "scaling", "clamp", "layer" } },
		{ key = "advanced", fields = { "disable_particles", "disable_parallax", "no_fullscreen_pause", "fullscreen_pause_only_active" } },
		{ key = "input", fields = { "disable_mouse" } },
	}

	local by_key: { [string]: EngineField } = {}
	for _, field in ipairs(ENGINE_FIELDS) do
		by_key[field.key] = field
	end

	local rows: { any } = {}
	-- Deja claro a qué fuentes aplican estos flags antes de listarlos.
	rows[#rows + 1] = ui.label({
		text = tr("panel.engine_scope"),
		fontSize = 11,
		color = "on_surface_variant",
		maxLines = 3,
	})
	for _, group in ipairs(groups) do
		local group_rows: { any } = {}
		for _, key in ipairs(group.fields) do
			local field = by_key[key]
			if field then
				group_rows[#group_rows + 1] = engineRow(field, inherited, unsetKey)
			end
		end
		if #group_rows > 0 then
			rows[#rows + 1] = sectionCard("engine.section_" .. group.key, group.key, group_rows)
		end
	end

	local props_card = propertiesCard(item)
	if props_card then
		rows[#rows + 1] = props_card
	end

	rows[#rows + 1] = wallhavenSection()
	if id == nil then
		rows[#rows + 1] = layoutSection()
	end

	if id == nil then
		rows[#rows + 1] = sectionCard("panel.settings", "settings", {
			columnsRow(), spacingRow(), themeRow(), localSortRow(), colorRow(), debugRow(),
		})
	end

	-- Cada fila envuelta con clave estable: `ui.scroll` la usa como `revealKey`
	-- para saltar de página con PgUp/PgDn.
	local keyed: { any } = {}
	for index, node in ipairs(rows) do
		keyed[index] = ui.column({ key = "opt-r" .. tostring(index) }, { node })
	end
	S.optRows = #rows
	if (S.optPage or 1) > #rows then
		S.optPage = math.max(1, #rows)
	end

	-- Todo el ancho del panel: en Opciones hay mucho contenido por fila y con el
	-- ancho del grid se leen las columnas de controles sin apilar.
	return ui.column({ gap = 12, flexGrow = 1, align = "stretch" }, {
		optionsHeader(title, id),
		-- Alto explícito: el panel es height="content" y un scroll con flexGrow
		-- dentro de un padre sin alto mide 0, así que Opciones se dibujaba
		-- apretado dentro del alto del carrusel.
		ui.scroll({
			key = "options-scroll",
			gap = 10,
			paddingH = 2,
			align = "stretch",
			height = OPTIONS_MAX_H,
			-- Página actual: PgUp/PgDn mueven este índice y el host scrollea
			-- hasta esa fila (alternativa al scroll con la rueda).
			revealKey = "opt-r" .. tostring(S.optPage or 1),
		}, keyed),
	})
end

-- ── gpu ──────────────────────────────────────────────────────────────────────

local function probeDone(): number
	local done = tableAt(tableAt(statusTable(), "probe"), "done")
	local count = 0
	for _ in pairs(done) do
		count += 1
	end
	return count
end

local function measuringName(items: { Item }): string
	local id = tableAt(statusTable(), "probe").id
	local name = currentTitle(items)
	if name == nil and type(id) == "string" then
		name = id
	end
	return truncate(name or "", 40)
end

local function probeStatusRow(items: { Item }, phase: string, done: number, total: number): any
	return ui.row({ align = "center", gap = 8 }, {
		ui.glyph({ name = "activity", size = 16, color = "primary" }),
		ui.label({
			text = phase == "idle" and tr("gpu.probe_all") or tr("gpu.probe_running", { name = measuringName(items) }),
			fontSize = 12,
			color = "on_surface",
			flexGrow = 1,
			maxLines = 1,
		}),
		ui.label({
			text = tr("gpu.probe_progress", { done = tostring(done), total = tostring(math.max(total, 1)) }),
			fontSize = 11,
			color = "on_surface_variant",
		}),
	})
end

-- Wallpapers the service would queue: never measured and not already blocked.
local function pendingCount(items: { Item }): number
	local pending = 0
	for _, item in ipairs(items) do
		if item.load == nil and blockEntry(item.id) == nil then
			pending += 1
		end
	end
	return pending
end

local function probeAll(items: { Item }): ()
	S.probeTotal = math.max(pendingCount(items), 1)
	send({ action = "probe_all" })
	render()
end

local function probeExplainer(items: { Item }, queued: number): any
	local sample = math.floor(tonumber(noctalia.getConfig("probe_sample_ms")) or 4000)
	local warmup = math.floor(tonumber(noctalia.getConfig("probe_warmup_ms")) or 3000)
	return ui.row({ align = "center", gap = 8 }, {
		ui.label({
			text = tr("gpu.explainer", { sample = tostring(sample), warmup = tostring(warmup) }),
			fontSize = 11,
			color = "on_surface_variant",
			flexGrow = 1,
			maxLines = 3,
		}),
		ui.button({
			glyph = "activity",
			text = tr("gpu.probe_all"),
			variant = "outline",
			controlSize = "sm",
			enabled = queued > 0,
			onClick = function()
				probeAll(items)
			end,
		}),
	})
end

local function probeSection(items: { Item }): any
	local probe = tableAt(statusTable(), "probe")
	local phase = type(probe.phase) == "string" and probe.phase or "idle"
	local done = probeDone()
	local total = math.max(S.probeTotal, done)
	local queued = pendingCount(items)

	local children: { any } = {
		probeStatusRow(items, phase, done, total),
		ui.progress({ progress = total > 0 and (done / total) or 0, height = 5, radius = 2 }),
		probeExplainer(items, queued),
	}
	if phase == "idle" and S.probeTotal > 0 and done > 0 then
		append(children, ui.label({ text = tr("gpu.probe_done"), fontSize = 11, color = "primary" }))
	end
	return ui.column({ gap = 10, padding = 10, radius = 10, fill = "surface_container/0.35" }, children)
end

local function blockedRows(items: { Item }): { any }
	local blocklist = tableAt(storeTable(), "blocklist")
	local ids: { string } = {}
	for id in pairs(blocklist) do
		ids[#ids + 1] = id
	end
	table.sort(ids, function(a: string, b: string): boolean
		local left = tonumber(tableAt(blocklist, a).busy_pct) or 0
		local right = tonumber(tableAt(blocklist, b).busy_pct) or 0
		return left > right
	end)

	local rows: { any } = {}
	for _, id in ipairs(ids) do
		local entry = tableAt(blocklist, id)
		local item = findItem(items, id)
		local title = item and truncate(itemTitle(item), 34) or id
		local busy = math.floor(tonumber(entry.busy_pct) or 0)
		local reasonKey = entry.reason == "manual" and "gpu.reason_manual" or "gpu.reason_gpu"
		rows[#rows + 1] = ui.row({
			key = "blocked-" .. id,
			align = "center",
			gap = 8,
			padding = 6,
			radius = 8,
			fill = "error/0.06",
		}, {
			ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
			ui.label({ text = title, fontSize = 12, color = "on_surface", maxLines = 1, width = 260 }),
			ui.label({ text = tr("gpu.busy", { pct = tostring(busy) }), fontSize = 11, color = "error", maxWidth = 90 }),
			ui.label({
				text = tr(reasonKey),
				fontSize = 11,
				color = "on_surface_variant",
				flexGrow = 1,
				maxLines = 2,
			}),
			ui.button({
				glyph = "check",
				text = tr("gpu.allow"),
				variant = "outline",
				controlSize = "sm",
				onClick = function()
					send({ action = "unblock", id = id })
					noctalia.notify(tr("panel.title"), tr("gpu.allowed", { name = title }))
				end,
			}),
		})
	end
	return rows
end

local function gpuView(items: { Item }): any
	local rows = blockedRows(items)
	local body: { any }
	if #rows == 0 then
		body = {
			ui.label({ text = tr("gpu.empty"), fontSize = 12, color = "on_surface_variant" }),
		}
	else
		body = rows
	end

	return ui.column({ gap = 12, flexGrow = 1 }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.button({
				glyph = "arrow-left",
				variant = "ghost",
				controlSize = "sm",
				tooltip = tr("panel.back"),
				onClick = function()
					S.screen = "browse"
					render()
				end,
			}),
			ui.label({
				text = tr("gpu.title"),
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				flexGrow = 1,
				maxLines = 1,
			}),
			ui.button({
				glyph = "refresh",
				variant = "ghost",
				controlSize = "sm",
				tooltip = tr("panel.refresh"),
				onClick = refresh,
			}),
		}),
		probeSection(items),
		-- Reporte autocontenido: estado, procesos vivos y el final del log del
		-- motor, escrito en la carpeta de datos del plugin.
		ui.row({ align = "center", gap = 8, padding = 8, radius = 9, fill = "surface_container/0.35" }, {
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = tr("gpu.dump_title"), fontSize = 12, color = "on_surface" }),
				ui.label({ text = tr("gpu.dump_desc"), fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
			}),
			ui.button({
				text = tr("gpu.dump_button"),
				variant = "secondary",
				controlSize = "sm",
				onClick = function()
					send({ action = "debug_dump" })
				end,
			}),
		}),
		-- Igual que Opciones: alto explícito o el panel queda del tamaño del
		-- carrusel y el diagnóstico se ve apretado.
		ui.scroll({ key = "gpu-scroll", gap = 6, paddingH = 8, align = "stretch", height = OPTIONS_MAX_H }, body),
	})
end

-- ── render ───────────────────────────────────────────────────────────────────

render = function(): ()
	-- Invalidar el memo de `catalogItems()`: sin esto devuelve la primera lista
	-- para siempre y el panel parece no cambiar de fuente.
	S.renderStamp = (S.renderStamp or 0) + 1
	if not S.open then
		return
	end
	local items = catalogItems()
	local screen: any
	if S.screen == "options" then
		screen = optionsView(items)
	elseif S.screen == "gpu" then
		screen = gpuView(items)
	else
		screen = browseView(items)
	end
	-- Fade-in al cambiar de vista o de fuente: no hay transiciones nativas en la
	-- API, así que la curva la maneja onFrameTick y acá solo se aplica el valor.
	-- El padding es FIJO: antes animaba y, con height="content", eso cambiaba
	-- el alto del panel en cada transición y el contenido saltaba.
	local eased = 1 - (1 - math.max(0, math.min(1, S.anim))) ^ 3
	-- `align = "stretch"`: sin esto los rows hijos de la raíz se miden por
-- contenido y el host no conoce su ancho. Con ancho desconocido, el reparto
-- de `flexGrow` no se aplica (el host lo salta) y los hijos con flexGrow
-- quedan en su mínimo. Con stretch, los rows heredan el ancho del panel y el
-- reparto funciona.
panel.render(ui.column({
		gap = 12,
		paddingH = PANEL_PAD_H,
		paddingV = 12,
		opacity = 0.3 + 0.7 * eased,
		align = "stretch",
		flexGrow = 1,
	}, { screen }))
end

-- ── host callbacks ───────────────────────────────────────────────────────────

local function open(context: any, ancho: number?, entry: string?)
	-- El entry pasa su ancho real: el host no permite redimensionar el panel
	-- en runtime, así que cada entry del manifiesto tiene un ancho propio y el
	-- layout se deriva de acá (ver `setPanelWidth`).
	if type(ancho) == "number" then
		setPanelWidth(ancho)
	end
	if type(entry) == "string" then
		CURRENT_ENTRY = entry
	end
	S.open = true
	S.screen = "browse"
	S.offset = 0
	S.probeTotal = 0
	-- El estado pendiente es de la sesión anterior: al reabrir el panel manda
	-- el store. Sin esto, el panel se abría con la vista que el usuario había
	-- pedido en la sesión previa y no con la del store.
	S.pendingView = nil
	SNAP.store = noctalia.state.get(STORE_KEY)
	SNAP.catalog = noctalia.state.get(CATALOG_KEY)
	SNAP.status = noctalia.state.get(STATUS_KEY)
	seedFromStore()
	-- El panel NO se reabre para cambiar de ancho. Antes lo hacía y el panel
	-- aparecía en la barra principal en vez de la barra desde donde se abrió:
	-- la reapertura va por IPC y ahí el host no recibe la barra de origen
	-- (`sourceBarName` sólo viaja en la apertura desde un widget). El ancho lo
	-- elige quien abre, resolviendo `panel-entries.json`; si abrió otra, el
	-- layout se ajusta a la ventana que hay y no se mueve de barra.
	if context == "options" then
		openOptions(nil)
		return
	end
	local status = statusTable()
	local appliedId = type(status.id) == "string" and status.id or nil
	if appliedId then
		for index, entry in ipairs(catalogItems()) do
			if entry.id == appliedId then
				S.focus = index - 1
				S.focusFrom = index - 1
				S.focusTo = index - 1
				S.focusT = 1
				S.offset = index - 1
				break
			end
		end
	end
	S.anim = 0
	S.warm = true
	panel.setNeedsFrameTick(true)
	dbgPanel("open", { source = activeSource(), items = #catalogItems() })
	render()
end

local function close()
	S.open = false
end

local function key(chord: any, pressed: any)
	if pressed ~= true or type(chord) ~= "string" then
		return
	end
	local key = string.lower(chord)
	-- En Opciones, PgUp/PgDn recorren el scroll por páginas. El scroll nativo
	-- anda con la rueda; esto es la alternativa cuando el puntero está lejos o
	-- se prefiere teclado.
	if S.screen == "options" then
		if key == "next" or key == "pagedown" or key == "down" then
			S.optPage = math.min(math.max(1, S.optRows or 1), (S.optPage or 1) + 4)
			render()
			return
		elseif key == "prior" or key == "pageup" or key == "up" then
			S.optPage = math.max(1, (S.optPage or 1) - 4)
			render()
			return
		elseif key == "home" then
			S.optPage = 1
			render()
			return
		elseif key == "end" then
			S.optPage = math.max(1, (S.optRows or 1) - 6)
			render()
			return
		end
	end
	local items = catalogItems()
	local focused = focusedIndex()
	local total = #items
	local step = 1
	if viewMode() == "grid" then
		-- En grilla el foco se mueve en dos ejes: una columna por izquierda o
		-- derecha, una fila por arriba o abajo.
		if key == "up" or key == "k" then
			focusTo(math.max(0, focused - viewColumns()))
			return
		elseif key == "down" or key == "j" then
			focusTo(math.min(total - 1, focused + viewColumns()))
			return
		end
	end
	if key == "left" or key == "h" or key == "up" or key == "k" then
		focusTo(focused - step)
	elseif key == "right" or key == "l" or key == "down" or key == "j" then
		focusTo(focused + step)
	elseif key == "prior" then
		focusTo(focused - 3)
	elseif key == "next" then
		focusTo(focused + 3)
	elseif key == "home" then
		focusTo(0)
	elseif key == "end" then
		focusTo(total - 1)
	elseif key == "f" then
		-- Los atajos de una letra secuestraban el buscador: escribir "g" o "f"
		-- en el input cambiaba de vista o marcaba favorito. Con el buscador
		-- con texto, la tecla es del usuario.
		if not searching() then
			local item = items[focusedIndex() + 1]
			if item then
				send({ action = "favorite", id = item.id })
			end
		end
	elseif key == "p" then
		if not searching() then
			local paused = tableAt(statusTable(), "paused") == true
			send({ action = paused and "resume" or "pause" })
		end
	elseif key == "return" or key == "enter" then
		-- Enter tiene dos destinos según el contexto. Si el usuario acaba de
		-- escribir en el buscador de Wallhaven, Enter lanza la búsqueda; si no,
		-- aplica el wallpaper enfocado.
		if S.screen == "browse" and S.searchDirty and activeSource() == "wallhaven" then
			S.searchDirty = false
			sendWallhaven({ query = S.wh.query })
		elseif S.screen == "browse" then
			local item = items[focusedIndex() + 1]
			if item then
				activate(item)
			end
		end
	elseif key == "g" then
		if not searching() then
			setView(viewMode() == "carousel" and "grid" or "carousel")
		end
	end
	-- Escape NO llega acá: el host se reserva la tecla Cancel y cierra el panel.
	-- Para volver de Opciones a la galería está el botón "atrás" de la cabecera.
end

-- The entry stays resident while the surface is closed; render() guards on that.
local function onState(value: any): ()
	-- Si el store ya refleja lo que el usuario pidió, el pendiente sobra.
	confirmPending()
	-- El service publica la página de Wallhaven junto al catálogo.
	local whstate = tableAt(value, "wallhaven")
	if type(whstate.page) == "number" then
		S.wh.page = whstate.page
	end
	if type(whstate.lastPage) == "number" then
		S.wh.lastPage = whstate.lastPage
	end
	render()
end

-- Scroll por hover: con el puntero sobre el primer o el último tile visible la
-- tira avanza un lugar. Es el desplazamiento con mouse que sí puede existir: el
-- panel no recibe rueda y un overlay para capturarla se comería los clics.
local function hoverTick(): ()
	if not S.open or S.screen ~= "browse" then
		return
	end
	if viewMode() ~= "carousel" then
		return
	end
	-- Zonas fijas en los extremos de la tira: el hover sobrevive a los renders
	-- (antes colgaba de la tarjeta, que se re-creaba en cada paso y cortaba el
	-- gesto después de un solo movimiento).
	if (S.hoverDir or 0) ~= 0 then
		-- Un paso por animación: reiniciarla a mitad no acelera, la vuelve nerviosa.
		if S.focusT >= 1 then
			focusTo(focusedIndex() + S.hoverDir)
		end
		return
	end
	if S.hoverId == nil then
		return
	end
	local items = catalogItems()
	if #items == 0 then
		return
	end
	local focused = focusedIndex()
	-- Mirar el vecino inmediato mueve el foco un lugar: es el gesto natural
	-- sobre un coverflow y no roba el clic porque onHover convive con onClick.
	local right = items[focused + 2]
	if right and right.id == S.hoverId then
		focusTo(focused + 1)
		return
	end
	local left = items[focused]
	if left and left.id == S.hoverId then
		focusTo(focused - 1)
	end
end

-- El hover de borde necesita un reloj: se pide un frame tick al abrir y se
-- avanza un tile cada HOVER_STEP_MS mientras el puntero siga en un extremo.
local HOVER_STEP_MS = 260
local hoverAccum = 0

local ANIM_MS = 180
local SLIDE_MS = 210
local FOCUS_MS = 260

local function frameTick(delta: any): ()
	local avance = tonumber(delta) or 0
	-- El host entrega el delta en ms, pero algunas versiones lo dan en segundos
	-- (0.016). Sin normalizar, FOCUS_MS=200 se convertía en tres minutos de
	-- transición: el carrusel "no animaba".
	if avance > 0 and avance < 1 then
		avance = avance * 1000
	end
	if S.warm then
		S.warm = false
		panel.setNeedsFrameTick(true)
		render()
		return
	end
	if S.focusT < 1 then
		S.focusT = math.min(1, S.focusT + avance / FOCUS_MS)
		S.focus = S.focusFrom + (S.focusTo - S.focusFrom) * easeOut(S.focusT)
		dbgPanel("anim", { t = string.format("%.2f", S.focusT), foco = string.format("%.2f", S.focus), delta = string.format("%.1f", avance) })
		local firm = carouselSignature(S.focus)
		if S.focusT >= 1 or firm ~= S.lastFirm then
			S.lastFirm = firm
			render()
		end
	end
	if S.slide < 1 then
		S.slide = math.min(1, S.slide + avance / SLIDE_MS)
		render()
	end
	if S.anim < 1 then
		S.anim = math.min(1, S.anim + avance / ANIM_MS)
		render()
	end
	-- El tick queda encendido mientras el panel está abierto: apagarlo con
	-- setNeedsFrameTick(false) NO se puede revertir desde el plugin, porque el
	-- primer render de una animación todavía no cambió el árbol y el host no
	-- repinta, así que el bucle no vuelve a arrancar.
	hoverAccum += avance
	if hoverAccum < HOVER_STEP_MS then
		return
	end
	hoverAccum = 0
	hoverTick()
end

-- La rueda sobre el widget de la barra es la única vía de scroll con mouse que
-- expone la API: el widget publica el paso y acá se mueve el offset del panel.
local function onNav(value: any): ()
	if type(value) ~= "table" then
		return
	end
	local delta = tonumber(value.delta) or 0
	if delta == 0 then
		return
	end
	local items = catalogItems()
	if #items == 0 then
		return
	end
	if viewMode() == "carousel" then
		focusTo(focusedIndex() + delta)
		return
	end
	S.offset = math.max(0, math.min(S.offset + delta * math.max(1, viewColumns()), maxOffset(#items)))
	S.slide = 0
	S.slideDir = delta > 0 and 1 or -1
	render()
end

noctalia.state.watch(CATALOG_KEY, function(value: any)
	SNAP.catalog = value
	onState(value)
end)
noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = value
	onState(value)
end)
noctalia.state.watch(STORE_KEY, function(value: any)
	SNAP.store = value
	onState(value)
end)
local function onScreen(value: any): ()
	if type(value) ~= "table" then
		return
	end
	-- El service publica `screen`; el alias viejo usaba `name`. Aceptar las
	-- dos: con una sola, `open_screen` era una acción inerte.
	local destino = value.screen or value.name
	if type(destino) ~= "string" then
		return
	end
	S.screen = destino
	S.optionsId = value.id
	S.anim = 0
	render()
end

noctalia.state.watch(NAV_KEY, onNav)
noctalia.state.watch("wes_screen", onScreen)

-- ── Módulo ────────────────────────────────────────────────────────────────
-- El host ejecuta cada entry en su propio ámbito: las funciones de ciclo de
-- vida de un `require` NO salen del módulo. Por eso este archivo exporta
-- los hooks y cada entry de la escalera (`panel_e<N>.luau`) los publica
-- como GLOBALS.
--
-- `ancho` lo pasa el entry: el host es dueño del tamaño del panel (el
-- manifiesto declara un ancho fijo por entry y no hay forma de
-- redimensionarlo en runtime), así que cada escalón sabe el suyo.
local M = {}

-- El spec de tests y el modo debug necesitan ver la geometría viva (el
-- ancho del panel cambia según la entry). Se expone por el módulo.
function M.geometry()
	return {
		panel_w = PANEL_W,
		panel_inner = PANEL_INNER,
		panel_content = PANEL_CONTENT,
		max_card_w = maxCardW(),
		entry = CURRENT_ENTRY,
		tiers = PANEL_TIERS,
	}
end

-- El entry que la configuración vigente necesita. Lo usa el entry real para
-- saber con qué ancho abrir y el runner de tests para simular el host.
M.desired = function(): (string, number)
	return desiredPanel()
end

M.open = function(context: any, ancho: number, entry: string?)
	open(context, ancho, entry)
end

M.close = function()
	close()
end

M.key = function(chord: any, pressed: any)
	key(chord, pressed)
end

M.frameTick = function(delta: any)
	frameTick(delta)
end

return M
