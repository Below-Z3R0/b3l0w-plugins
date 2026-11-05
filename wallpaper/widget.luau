--!nonstrict
-- Bar widget. The host resolves `onClick` and `onScroll` as globals of this
-- script and provides `barWidget`, so the file is deliberately not module-shaped.

local STATUS_KEY = "wes_status"
local STORE_KEY = "wes_store"
local CATALOG_KEY = "wes_catalog"
local REQUEST_KEY = "wes_request"
local NAV_KEY = "wes_nav"
local GLYPH = "movie"
local TITLE_MAX = 20

local requestCount = 0
local navCount = 0

local function getTable(key: string): any
	local value = noctalia.state.get(key)
	if type(value) ~= "table" then
		return nil
	end
	return value
end

-- Titles come from Workshop authors, so cut on codepoints instead of bytes.
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

local function paint(status)
	status = type(status) == "table" and status or getTable(STATUS_KEY)
	barWidget.setGlyph(GLYPH)

	if not status or status.running ~= true then
		barWidget.setTooltip(noctalia.tr("widget.idle"))
		return
	end

	local cycle = status.cycle
	if type(cycle) == "table" and cycle.active == true then
		local count = tonumber(cycle.count) or 0
		barWidget.setTooltip(noctalia.tr("widget.cycling", { count = tostring(count) }))
		return
	end

	local title = type(status.title) == "string" and status.title or ""
	if title == "" then
		barWidget.setTooltip(noctalia.tr("widget.playing_unknown"))
		return
	end
	local suffix = ""
	local store = getTable(STORE_KEY)
	local favorites = type(store) == "table" and store.favorites or nil
	if type(favorites) == "table" and favorites[status.id] == true then
		suffix = " ★"
	end
	barWidget.setTooltip(noctalia.tr("widget.playing", { name = truncate(title, TITLE_MAX) }) .. suffix)
end

-- Sin ciclo activo la rueda no tiene que aplicar nada: mueve la vista del
-- panel, que es lo que el usuario espera al scrollear sobre el ícono.
local function sendNav(direction: number)
	navCount += 1
	noctalia.state.set(NAV_KEY, {
		delta = direction,
		nonce = noctalia.nowMs() .. ":" .. navCount,
	})
end

local function sendApply(id: string)
	requestCount += 1
	noctalia.state.set(REQUEST_KEY, {
		action = "apply",
		id = id,
		nonce = noctalia.nowMs() .. ":" .. requestCount,
	})
end

-- Only while a cycle runs: one wheel notch walks one catalog entry from the
-- wallpaper currently on screen, wrapping at both ends. Any axis steps the
-- cycle, because a vertical bar has no horizontal scroll to offer.
local function cycleStep(direction: number): boolean
	local status = getTable(STATUS_KEY)
	if not status or status.running ~= true then
		return false
	end
	local cycle = status.cycle
	if type(cycle) ~= "table" or cycle.active ~= true then
		return false
	end

	local catalog = getTable(CATALOG_KEY)
	local items = catalog and catalog.items
	if type(items) ~= "table" or #items == 0 then
		return false
	end

	local current = nil
	for index, item in ipairs(items) do
		if type(item) == "table" and item.id == status.id then
			current = index
			break
		end
	end

	local offset = current or (direction > 0 and 0 or 1)
	local nextIndex = ((offset - 1 + direction) % #items) + 1
	local target = items[nextIndex]
	if type(target) == "table" and type(target.id) == "string" then
		sendApply(target.id)
		return true
	end
	return false
end

local BASE_PANEL = "b3l0w/wallpaper:panel"

-- La entrada real la publica el service en `panel_entry`: el ancho del panel
-- depende de la configuración y el host no puede redimensionar un panel
-- abierto. Abrir siempre `:panel` obligaba al panel a cerrarse y reabrirse
-- para cambiar de ancho, y esa reapertura desde la CLI pierde la barra de
-- origen: el panel terminaba en la barra por defecto en vez de en la del
-- widget. Resolviendo acá, el panel abre directo en la entrada correcta.
local PANEL_ENTRY_FILE = "~/.local/state/noctalia/panel-entries.json"

local function panel_entry(): string
	local texto = noctalia.readFile(PANEL_ENTRY_FILE)
	if type(texto) == "string" and texto ~= "" then
		local mapa = noctalia.json.decode(texto)
		if type(mapa) == "table" then
			local real = mapa[BASE_PANEL]
			if type(real) == "string" and real ~= "" then
				return real
			end
		end
	end
	return BASE_PANEL
end

function onClick()
	noctalia.togglePanel(panel_entry())
end

-- Botón del medio: marca o quita de favoritos el wallpaper que está en pantalla.
-- (En las tarjetas del panel el host sólo entrega click izquierdo y derecho.)
function onMiddleClick()
	local status = getTable(STATUS_KEY)
	local id = type(status) == "table" and status.id or nil
	if type(id) ~= "string" or id == "" then
		noctalia.notify(noctalia.tr("widget.idle"))
		return
	end
	requestCount += 1
	noctalia.state.set(REQUEST_KEY, {
		action = "favorite",
		id = id,
		nonce = noctalia.nowMs() .. ":" .. requestCount,
	})
end

function onScroll(axis, steps, startsGesture)
	if type(steps) ~= "number" or steps == 0 then
		return
	end
	if not cycleStep(if steps > 0 then 1 else -1) then
		sendNav(if steps > 0 then 1 else -1)
	end
end

noctalia.state.watch(STATUS_KEY, paint)
-- El favorito vive en el store: sin esto el ★ del tooltip no aparecía hasta
-- el próximo cambio de wallpaper.
noctalia.state.watch(STORE_KEY, paint)
paint()
