--!strict
-- Service entry: es el único dueño de los procesos `linux-wallpaperengine`.
-- El panel solo publica requests por `noctalia.state`; acá se ejecutan.
--
-- No devuelve tabla: el host resuelve los callbacks `update`, `onConfigChanged`
-- y `onIpc` como globales de este script.

local util = require("./lib/util.luau")
local catalog = require("./lib/catalog.luau")
local engine = require("./lib/engine.luau")
local store = require("./lib/store.luau")
local gpuprobe = require("./lib/gpuprobe.luau")
local local_src = require("./lib/local.luau")
local wh = require("./lib/wallhaven.luau")
local panel_size = require("./lib/panel_size.luau")

-- Dónde se publica qué entrada de panel hay que abrir (lo leen otros plugins).
local PANEL_ENTRY_FILE = "~/.local/state/noctalia/panel-entries.json"

local BIN = "linux-wallpaperengine"

local STATUS_KEY = "wes_status"
local CATALOG_KEY = "wes_catalog"
local STORE_KEY = "wes_store"
local REQUEST_KEY = "wes_request"

local TICK_MS = 500
-- Cuántos wallpapers de Wallhaven se acumulan como máximo (24 por página).
-- Por defecto 1200; el ajuste `wallhaven_max` permite llegar a las ~2.400 que
-- devuelve la API para una búsqueda amplia, como el plugin de la casa.
local WALLHAVEN_CAP = 1200

local LOCAL_RESCAN_MS = 30000
local SAVE_DEBOUNCE_MS = 1500

type Proc = { id: string, output: string }

local S = {
	dataDir = nil :: string?,
	state = store.defaults(),
	catalogItems = {} :: { any },
	catalogStamp = nil :: number?,
	catalogRoot = nil :: string?,
	procs = {} :: { [string]: Proc },
	status = {
		running = false,
		id = nil :: string?,
		title = nil :: string?,
		output = nil :: string?,
		since = nil :: number?,
		fps = nil :: number?,
	},
	lastNonce = nil :: string?,
	dirtyAt = 0 :: number,
	cycle = { index = 0, nextAt = 0 :: number },
	wallhaven = {
		items = {} :: { any },
		page = 1,
		lastPage = 1,
		loading = false,
		seq = 0,
		-- El error de la búsqueda viaja al panel: antes una búsqueda fallida se
		-- veía como una pantalla vacía, sin explicación de por qué.
		-- OJO: `S.wallhaven` todavía no existe mientras se construye esta tabla
		-- (es la propia tabla que lo define): leerlo acá es indexar nil y el
		-- entry muere con "call to 'chunk' failed" en la línea del error.
		error = nil,
		filters = {
			query = "",
			purity = "sfw",
			categories = "all",
			sorting = "date_added",
		},
	},
	probe = {
		phase = "idle",
		queue = {} :: { string },
		id = nil :: string?,
		output = nil :: string?,
		startedAt = 0 :: number,
		prev = nil :: any,
		restore = {} :: { [string]: string },
		results = {} :: { [string]: any },
	},
}

local function now(): number
	return noctalia.nowMs()
end

-- Trazas de diagnóstico. Apagadas salvo que el modo debug esté activo: el log
-- del host es uno solo para todos los plugins y el ruido tapa los errores.
local function dbg(event: string, data: any?)
	if not (type(S.state) == "table" and S.state.debug == true) then
		return
	end
	local partes = { "[dbg] " .. event }
	if type(data) == "table" then
		for key, value in pairs(data) do
			partes[#partes + 1] = tostring(key) .. "=" .. tostring(value)
		end
	end
	noctalia.log(table.concat(partes, " "))
end

local function setting(key: string, fallback: any): any
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

-- El ajuste `debug` del manifiesto es el valor inicial; en cuanto el usuario usa
-- el interruptor del panel, el store manda y queda persistido.
local function seed_debug()
	if S.state.debug == nil then
		S.state.debug = setting("debug", false) == true
	end
end

-- Primer arranque: la vista inicial sale de los ajustes del manifiesto. Después
-- manda el store (lo que el usuario elige en Opciones), que es donde vive la
-- verdad; si no, cambiar `default_view` en el manifiesto no hacía nada.
local function seed_view()
	local mode = tostring(setting("default_view", "carousel"))
	if mode == "grid" or mode == "carousel" then
		S.state.view.mode = mode
	end
	local columns = tonumber(setting("grid_columns", 0))
	if columns and columns >= 2 and columns <= 8 then
		S.state.view.columns = math.floor(columns)
	end
end

local function wallhaven_cap(): number
	-- Lo elegido en el panel manda sobre el ajuste del host.
	local value = tonumber(S.state.wallhaven_max) or tonumber(setting("wallhaven_max", 1200)) or 1200
	return math.max(24, math.min(2400, math.floor(value)))
end

-- ── publicación hacia el panel ────────────────────────────────────────────────

local function publish_status()
	local cycle = S.state.cycle
	S.status.running = next(S.procs) ~= nil
	noctalia.state.set(STATUS_KEY, {
		running = S.status.running,
		-- `paused` no se publicaba: el panel lo leía siempre como false y la
		-- tecla `p` mandaba `pause` para siempre (no había forma de reanudar).
		paused = S.status.paused == true,
		id = S.status.id,
		title = S.status.title,
		output = S.status.output,
		since = S.status.since,
		fps = S.status.fps,
		cycle = {
			active = cycle.active == true,
			minutes = cycle.minutes,
			order = cycle.order,
			count = #(cycle.ids or {}),
		},
		-- El estado de Wallhaven se publica desde S: antes se publicaba un
		-- bloque literal con valores por defecto, así que la paginación, el
		-- spinner de carga y el error de búsqueda nunca llegaban al panel.
		wallhaven = {
		page = S.wallhaven.page,
		lastPage = S.wallhaven.lastPage,
		loading = S.wallhaven.loading == true,
		error = S.wallhaven.error,
		pending = S.wallhaven.pending,
		filters = {
			query = S.wallhaven.filters.query,
			purity = S.wallhaven.filters.purity,
			categories = S.wallhaven.filters.categories,
			sorting = S.wallhaven.filters.sorting,
		},
	},
	probe = { phase = S.probe.phase, id = S.probe.id, done = S.probe.results },
	})
end

-- ── Qué entrada de panel abrir ───────────────────────────────────────────
-- El host ancla un panel `attached` a la barra DESDE DONDE SE ABRE: el
-- `sourceBarName` sólo viaja cuando la apertura viene de un widget. Cerrar y
-- reabrir el panel desde la CLI para cambiar de ancho perdía esa barra y el
-- panel terminaba en la barra por defecto — que es justo lo que no quería
-- quien lo abre desde una hover zone de la barra de abajo.
--
-- Por eso el plugin no cambia de entrada a la fuerza: publica este mapa y el
-- que abre (widget, hover zone, cualquier otro) resuelve la entrada con él.
-- La convención es una sola: `panel_entry`, un mapa id-base → id-real.
local function publish_panel_entry()
	local view = S.state.view or {}
	local carousel = view.carousel or {}
	local grid = view.grid or {}
	local ancho: number
	if (view.mode or "carousel") == "carousel" then
		ancho = panel_size.carousel(
			math.floor(tonumber(carousel.slots) or 5),
			math.max(0, math.min(100, tonumber(view.spacing) or 0)),
			tonumber(carousel.w) or 0,
			math.floor(tonumber(carousel.panel_w) or 0)
		)
	else
		ancho = panel_size.grid(math.floor(tonumber(grid.panel_w) or 0))
	end
	local entrada = panel_size.entryFor(ancho)
	dbg("panel_entry", { ancho = ancho, entry = entrada })
	-- Dos destinos: `state` para el panel y el widget de este plugin, y un
	-- archivo para los otros plugins. `noctalia.state` NO se comparte entre
	-- plugins, y quien abre el panel casi siempre es otro plugin (una hover
	-- zone), así que sin el archivo no hay forma de que acierte la entrada.
	local mapa = { ["b3l0w/wallpaper:panel"] = entrada }
	noctalia.state.set("panel_entry", mapa)
	local texto = noctalia.json.encode(mapa)
	if type(texto) == "string" then
		noctalia.writeFile(PANEL_ENTRY_FILE, texto)
	end
end

local function publish_store()
	noctalia.state.set(STORE_KEY, S.state)
	publish_panel_entry()
end

local function publish_catalog()
	-- Traza útil: qué fuente está publicada y cuántos items, sin spam (sólo
	-- cuando cambia la firma).
	local firma = tostring(S.state.source or "engine") .. ":" .. tostring(#S.catalogItems)
	if S.publishedFirma ~= firma then
		S.publishedFirma = firma
		noctalia.log("[publish] " .. firma)
	end
	dbg("publish", { source = tostring(S.state.source), items = #S.catalogItems })
	noctalia.state.set(CATALOG_KEY, {
		items = S.catalogItems,
		ts = S.catalogStamp or 0,
		root = S.catalogRoot,
		wallhaven = {
			page = S.wallhaven.page,
			lastPage = S.wallhaven.lastPage,
		},
	})
end

local function save()
	S.dirtyAt = now()
end

local function flush()
	if S.dirtyAt == 0 or now() - S.dirtyAt < SAVE_DEBOUNCE_MS then
		return
	end
	S.dirtyAt = 0
	if S.dataDir then
		store.save(S.dataDir, S.state)
	end
end

-- ── catálogo ─────────────────────────────────────────────────────────────────

-- Aplicar no puede depender de qué fuente está mirando el panel: si el usuario
-- cambia de fuente (o el service acaba de arrancar y no escaneó nada), el id no
-- está en el catálogo aunque la ruta exista. Se reconstruye el item mínimo.
local function item_from_id(id: string): any?
	if string.sub(id, 1, 1) ~= "/" then
		return nil
	end
	local lower = string.lower(id)
	local name = string.match(id, "([^/]+)$") or id
	local title = string.gsub(string.gsub(name, "%.[^.]+$", ""), "[/_%-]", " ")
	for _, ext in ipairs({ ".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v" }) do
		if string.sub(lower, -#ext) == ext then
			return { id = id, file = id, type = "video", title = title }
		end
	end
	for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".avif", ".gif", ".tif", ".tiff" }) do
		if string.sub(lower, -#ext) == ext then
			return { id = id, file = id, type = "image", title = title }
		end
	end
	return nil
end

local function find_item(id: string): any?
	for _, item in ipairs(S.catalogItems) do
		if item.id == id then
			return item
		end
	end
	return nil
end

-- Fuente activa: engine (workshop), images o videos (carpetas locales).
local function source(): string
	local value = S.state.source
	if value == "images" or value == "videos" or value == "wallhaven" then
		return value
	end
	return "engine"
end

local function local_dir(kind: string): string
	local key = kind == "videos" and "videos_dir" or "images_dir"
	local value = setting(key, "")
	if type(value) ~= "string" or value == "" then
		return ""
	end
	-- El setting guarda la ruta tal cual la escribió el usuario: expandPath es
	-- lo que convierte "~/Pictures" en una ruta que listDir puede abrir.
	return noctalia.expandPath(value)
end

local function wallhaven_dir(): string
	return (S.dataDir or "/tmp") .. "/wallhaven"
end

-- Descarga las miniaturas que falten, de a una: la API no deja pedir varias y
-- el panel necesita rutas locales porque ui.image no carga URLs.
local function wallhaven_thumbs()
	-- Cada miniatura que llega republica el catálogo y obliga al panel a
	-- re-renderizar: con 24 items eso era un re-render por imagen. Se publica
	-- cada 4 descargas.
	local pending = 0
	for _, item in ipairs(S.wallhaven.items) do
		if item.thumb == nil and type(item.thumb_url) == "string" then
			local dest = wallhaven_dir() .. "/thumb-" .. item.id .. ".jpg"
			if noctalia.fileExists(dest) then
				item.thumb = dest
			else
				noctalia.download(item.thumb_url, dest, function(ok)
					if ok then
						item.thumb = dest
						pending = pending + 1
						if pending % 4 == 0 and source() == "wallhaven" then
							publish_catalog()
						end
					end
				end)
			end
		end
	end
	publish_catalog()
end

local function wallhaven_fetch(page_override: number?, append: boolean?)
	dbg("wallhaven-fetch", { page = tostring(page_override), append = tostring(append) })
	-- La ruta viene de pluginDataDir, no del usuario: no hace falta escaparla.
	noctalia.runAsync("mkdir -p '" .. wallhaven_dir() .. "'", nil, 3000)

	-- Secuencia: si el usuario cambia de filtro mientras hay un pedido en vuelo,
	-- la respuesta vieja se descarta en vez de pisar la nueva (y en vez de
	-- bloquear el cambio, que era lo que pasaba con el flag `loading`).
	S.wallhaven.seq = S.wallhaven.seq + 1
	local seq = S.wallhaven.seq
	local page = page_override or S.wallhaven.page
	local filters = S.wallhaven.filters
	-- Con orden por relevancia y sin texto, la API devuelve vacía la primera
	-- página: el oficial pide page+1 y descuenta una del total.
	local relevance_no_query = filters.sorting == "relevance"
		and (type(filters.query) ~= "string" or filters.query == "")
	local api_page = page + (relevance_no_query and 1 or 0)
	local url = wh.build_url({
		page = api_page,
		query = filters.query,
		purity = filters.purity,
		categories = filters.categories,
		sorting = filters.sorting,
		order = filters.order,
		atleast = filters.atleast,
		res = filters.res,
		resmode = filters.resmode,
		ratios = filters.ratios,
	})

	local ok = noctalia.http({
		url = url,
		headers = wh.headers(setting("wallhaven_api_key", "")),
	}, function(response)
		if seq ~= S.wallhaven.seq then
			return
		end
		S.wallhaven.loading = false
		local body = type(response) == "table" and (response.body or response.text) or nil
		local data, err, lastPage = wh.parse(body)
		if not data then
			S.wallhaven.error = err
			-- El error se guardaba pero no llegaba a nadie: la búsqueda
			-- fallaba y el panel mostraba una pantalla vacía sin explicación.
			publish_status()
			-- Reintentar la misma página: la API corta por ritmo y la carga se
			-- quedaba a mitad de camino sin avisar.
			local tries = (S.wallhaven.retries or 0) + 1
			S.wallhaven.retries = tries
			if tries <= 3 and source() == "wallhaven" then
				S.wallhaven.pending = page
				S.wallhaven.nextAt = now() + 4000 * tries
			end
			noctalia.log("[wallhaven] " .. tostring(err))
			-- Publicar solo si el usuario está mirando wallhaven: una respuesta
			-- tardía no puede reemplazar el catálogo de otra fuente.
			if source() == "wallhaven" then
				S.catalogItems = S.wallhaven.items
				publish_catalog()
			end
			return
		end
		S.wallhaven.error = nil
		S.wallhaven.retries = 0
		if relevance_no_query then
			lastPage = math.max(1, lastPage - 1)
		end
		S.wallhaven.lastPage = lastPage
		-- El total de páginas recién se conoce con la respuesta: se refleja acá
		-- (publicando cada tanto, no en cada página).
		local published = S.state.wallhaven_filters
		if published then
			published.page = page
			published.last_page = lastPage
			if page % 5 == 0 or page >= lastPage then
				publish_store()
			end
		end
		local fresh = wh.to_items(data)
		if append and #S.wallhaven.items > 0 then
			-- Los páginas siguientes se suman: la lista queda con todas las que
			-- trajo la búsqueda, no sólo las 24 de la primera.
			local known: { [string]: boolean } = {}
			for _, item in ipairs(S.wallhaven.items) do
				known[item.id] = true
			end
			for _, item in ipairs(fresh) do
				if not known[item.id] then
					known[item.id] = true
					S.wallhaven.items[#S.wallhaven.items + 1] = item
				end
			end
		else
			S.wallhaven.items = fresh
		end
		noctalia.log(string.format(
			"[wallhaven] %d items, página %d/%d (%s/%s/%s ord=%s min=%s ratio=%s q=%s)",
			#S.wallhaven.items, page, lastPage, filters.purity, filters.categories, filters.sorting,
			tostring(filters.order or "desc"),
			(filters.resmode == "exact" and "res=" or "min=") .. tostring(filters.res or "-"),
			tostring(filters.ratios or "any"), tostring(filters.query or "")
		))
		if source() == "wallhaven" then
			S.catalogItems = S.wallhaven.items
			publish_catalog()
		end
		wallhaven_thumbs()

		-- Seguir trayendo páginas hasta el tope, sin bloquear: cada respuesta
		-- agenda la siguiente y update() la dispara.
		if source() == "wallhaven" and #S.wallhaven.items < wallhaven_cap() and page < lastPage then
			S.wallhaven.pending = page + 1
		else
			S.wallhaven.pending = nil
		end
	end)

	if not ok and seq == S.wallhaven.seq then
		S.wallhaven.loading = false
		S.wallhaven.error = "no se pudo iniciar la petición"
	end
end

-- Miniaturas de videos locales: mpvpaper no deja pedir un frame, así que se
-- delega al CLI (`b3l0w we still`), que usa ffmpeg y tarda ~0.4 s por video.
-- El resultado se cachea por ruta para no repetirlo en cada escaneo.
-- Comilla simple para los comandos de shell. Va antes de su primer uso:
-- el listado de miniaturas lo necesita y el auditor exige que no se use una
-- función declarada más abajo.
local function quote(value: string): string
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function video_thumb_path(path: string): string
	local hash = 5381
	for index = 1, #path do
		hash = (hash * 33 + string.byte(path, index)) % 4294967296
	end
	return (S.dataDir or "/tmp") .. "/thumbs/v-" .. string.format("%x", hash) .. ".jpg"
end

-- Reengancha las miniaturas ya generadas: el catálogo se recrea en cada
-- escaneo y los items nuevos vienen sin `thumb`.
-- Umbriel no repinta una superficie de fondo que ya existe: cambiarle la imagen
-- con `setWallpaper` deja el valor nuevo pero en pantalla sigue la anterior. Se
-- destruye y se recrea la superficie, que es lo único que la hace pintar otra
-- vez desde el plugin.
local function repaint(target: string, path: string?)
	if path then
		noctalia.setWallpaper(target, path)
	end
	noctalia.setWallpaperEnabled(target, false)
	noctalia.runAsync("sleep 0.12", function()
		noctalia.setWallpaperEnabled(target, true)
	end)
end

local function apply_cached_thumbs(kind: string, lista: { any }?)
	-- Una imagen ya es su propia miniatura: acá no hay nada que reenganchar y
	-- recorrer 400 items en el callback se come el presupuesto de CPU.
	if kind == "images" then
		return
	end
	local dir = (S.dataDir or "/tmp") .. "/thumbs"
	-- El listado se guarda 15 s: escanear la carpeta en cada pasada era trabajo
	-- repetido sobre el mismo contenido.
	--
	-- `listDir` es una llamada al host y con 97 miniaturas se comía el
	-- presupuesto de CPU del callback: el host mataba el service con
	-- "exceeded its CPU budget" y el escaneo del engine no terminaba.
	-- Ahora el listado se pide por shell (fuera del hilo del service) y se
	-- cachea; mientras no llegue, las miniaturas se enganchan en el próximo
	-- Escaneo de carpetas locales por el CLI Go.
--
-- Recorrer ~/Pictures en Luau se comía el presupuesto de 25 ms por callback: el
-- host mataba el service a timeouts, el catálogo quedaba vacío y desde ahí
-- ningún wallpaper se aplicaba (find_item no encontraba nada). El CLI lo hace en
-- milisegundos, fuera del hilo del service.

-- barrido.
	local cache = S.thumbCache
	if not cache or now() - (S.thumbCacheAt or 0) > 15000 then
		if S.thumbCachePending then
			return
		end
		S.thumbCachePending = true
		noctalia.runAsync("ls -1 " .. quote(dir) .. " 2>/dev/null", function(result: any)
			S.thumbCachePending = false
			S.thumbCacheAt = now()
			if type(result) ~= "table" or type(result.stdout) ~= "string" then
				return
			end
			local nuevo: { [string]: boolean } = {}
			for line in string.gmatch(result.stdout, "[^\n]+") do
				local name = line:gsub("^%s+", ""):gsub("%s+$", "")
				if name ~= "" then
					nuevo[name] = true
				end
			end
			S.thumbCache = nuevo
			-- El listado llegó tarde: se engancha ahora, sin volver a escanear.
			apply_cached_thumbs(kind, lista)
		end)
		return
	end
	for _, item in ipairs(lista or S.catalogItems) do
		if item.thumb == nil then
			local source_path = item.file
			if kind == "engine" and type(item.preview) == "string" then
				source_path = item.preview
			end
			if type(source_path) == "string" and source_path ~= "" then
				local base = string.match(video_thumb_path(source_path), "([^/]+)$")
				if base and cache[base] then
					item.thumb = dir .. "/" .. base
				end
			end
		end
	end
end

local function scan_local(kind: string, dir: string, depth: number)
	S.scanToken = (S.scanToken or 0) + 1
	local token = S.scanToken
	-- Reservar ANTES de lanzar el CLI: `ensure_catalog` corre cada 500 ms y sin
	-- esto veía la carpeta vieja, lanzaba otro escaneo y descartaba el anterior
	-- por token. Resultado: el catálogo podía tardar 8 s en aparecer.
	S.catalogRoot = dir
	S.catalogStamp = now()
	local cli_kind = (kind == "videos") and "video" or "image"
	local sort = tostring(S.state.local_sort or "name")
	local base = "b3l0w we scan --kind " .. cli_kind .. " --sort " .. sort
		.. " --max 400 --depth " .. tostring(depth)
		.. " --json --dir " .. quote(dir)
	local thumbs = (S.dataDir or "/tmp") .. "/thumbs"

	local function publicar(items: any)
		dbg("scan", { kind = kind, items = #items, dir = dir })
		S.catalogItems = items
		S.catalogRoot = dir
		S.catalogStamp = now()
		noctalia.log(string.format("[%s] %d items en %s", kind, #S.catalogItems, dir == "" and "(sin carpeta)" or dir))
		publish_catalog()
	end

	-- Fase 1: catálogo ya. Las miniaturas de imágenes tardan ~4 s la primera vez
	-- (ffmpeg sobre PNG 4K) y no pueden bloquear la lista.
	noctalia.runAsync(base, function(result: any)
		if S.scanToken ~= token then
			return
		end
		local items = nil
		if type(result) == "table" and type(result.stdout) == "string" then
			items = noctalia.json.decode(result.stdout)
		end
		if type(items) ~= "table" then
			items = local_src.scan(dir, kind, 120, math.min(depth, 1))
			publicar(items)
			return
		end
		if kind == "images" then
			apply_cached_thumbs("images", items)
		end
		publicar(items)

		-- Fase 2: miniaturas (sólo imágenes). Al terminar se republica el mismo
		-- catálogo con los `thumb` puestos.
		if kind ~= "images" then
			return
		end
		noctalia.runAsync(base .. " --thumbs " .. quote(thumbs), function(second: any)
			if S.scanToken ~= token then
				return
			end
			local hechas = nil
			if type(second) == "table" and type(second.stdout) == "string" then
				hechas = noctalia.json.decode(second.stdout)
			end
			if type(hechas) ~= "table" then
				return
			end
			local mapa: { [string]: string } = {}
			for _, entry in ipairs(hechas) do
				if type(entry) == "table" and type(entry.id) == "string" and type(entry.thumb) == "string" then
					mapa[entry.id] = entry.thumb
				end
			end
			local puestas = 0
			for _, item in ipairs(S.catalogItems) do
				local found = mapa[item.id]
				if found and found ~= "" then
					item.thumb = found
					puestas = puestas + 1
				end
			end
			if puestas > 0 then
				noctalia.log(string.format("[images] %d miniaturas", puestas))
				publish_catalog()
			end
		end)
	end)
end

-- Escaneo del Workshop por el CLI. El mismo recorrido en Luau medía 26-30 ms
-- fríos contra un presupuesto de 25 ms por callback: `set_source` moría a mitad
-- y la fuente no cambiaba. En Go tarda 2 ms y trae también las propiedades.
local function scan_engine(force: boolean)
	local root = catalog.find_root()
	if root == nil then
		S.catalogItems = {}
		S.catalogRoot = ""
		publish_catalog()
		return
	end
	local stamp = S.catalogStamp or 0
	if not force and root == (S.catalogRoot or "") and (now() - stamp) < LOCAL_RESCAN_MS then
		return
	end
	S.scanToken = (S.scanToken or 0) + 1
	local token = S.scanToken
	dbg("scan-engine", { root = root, force = tostring(force) })
	S.catalogRoot = root
	S.catalogStamp = now()

	noctalia.runAsync("b3l0w we list --json --root " .. quote(root), function(result: any)
		dbg("scan-callback", { token = tostring(token), actual = tostring(S.scanToken), tipo = type(result) })
		if S.scanToken ~= token then
			return
		end
		local items = nil
		if type(result) == "table" and type(result.stdout) == "string" then
			items = noctalia.json.decode(result.stdout)
		end
		local origen = "CLI"
		if type(items) ~= "table" then
			-- Sin CLI: respaldo en Luau, acotado para no romper el presupuesto.
			origen = "respaldo Luau"
			local fallback = catalog.scan(root)
			items = {}
			for index, item in ipairs(fallback.items) do
				if index > 120 then
					break
				end
				items[index] = item
			end
			noctalia.log("[engine] el CLI no respondió; se usa el respaldo en Luau")
		end
		S.catalogItems = items
		apply_cached_thumbs("engine", items)
		publish_catalog()
		-- El origen va en el log: decía "desde el CLI" aunque vino del respaldo.
		noctalia.log(string.format("[engine] %d items desde %s", #items, origen))
	end)
end

local function ensure_catalog(force: boolean)
	local kind = source()
	if kind == "wallhaven" then
		if #S.wallhaven.items == 0 then
			-- Sin ventana de reintento: si el flag `loading` quedó en true por un
			-- pedido que nunca volvió, la fuente no cargaba nunca más.
			if now() - (S.wallhaven.at or 0) > 3000 then
				S.wallhaven.at = now()
				wallhaven_fetch()
			end
		elseif S.catalogItems ~= S.wallhaven.items then
			-- Volver a wallhaven con resultados ya cargados: se republica lo que
			-- hay en vez de dejar el catálogo de la fuente anterior.
			S.catalogItems = S.wallhaven.items
			publish_catalog()
		end
		return
	end

	if kind ~= "engine" then
		local dir = local_dir(kind)
		-- update() corre cada 500 ms: sin esta ventana se reescanearía la
		-- carpeta dos veces por segundo para nada.
		local stamp = S.catalogStamp or 0
		local fresh = force or dir ~= (S.catalogRoot or "") or (now() - stamp) > LOCAL_RESCAN_MS
		if fresh then
			local depth = tonumber(setting("scan_depth", 2)) or 2
			S.catalogRoot = dir
			S.catalogStamp = now()
			scan_local(kind, dir, depth)
		end
		return
	end

	scan_engine(force)
end

-- ── procesos ─────────────────────────────────────────────────────────────────
--
-- `runAsync` con argv no deja el proceso desprendido; el patrón que funciona en
-- esta shell es un comando de shell con `&` y el PID anotado en un archivo, que
-- además permite matar exactamente ese proceso y no otro.

local function pid_path(output: string): string
	return (S.dataDir or "/tmp") .. "/pid-" .. output .. ".pid"
end


-- `pkill -f` matchea también la shell que corre el comando, porque su propia
-- línea de comandos contiene el patrón: con `&` en la misma línea eso la mata
-- antes de lanzar nada. Se listan los PIDs y se excluye el de la shell.
local function kill_matching(pattern: string): string
	return "for p in $(pgrep -f " .. quote(pattern) .. " 2>/dev/null); do "
		.. "[ \"$p\" = \"$$\" ] || kill -9 \"$p\" 2>/dev/null; done; true"
end

local function read_pid(output: string): number?
	local raw = noctalia.readFile(pid_path(output))
	if not raw then
		return nil
	end
	return tonumber(noctalia.string.trim(raw))
end

local function is_alive(pid: number): boolean
	return noctalia.fileExists("/proc/" .. tostring(pid))
end

-- Regla dura: un solo wallpaper vivo. Antes de aplicar cualquiera (motor,
-- video, imagen o wallhaven) se barren TODOS los motores y reproductores: si
-- quedara uno viejo habría dos wallpapers compitiendo por la GPU.
-- Barre los motores huérfanos (los que quedaron sin pidfile, de una versión
-- anterior o de otro plugin). NO puede matar los de otra salida: con
-- `output = "*"` se aplica en varios monitores y el sweep del segundo
-- mataba lo que se acababa de lanzar en el primero.
local function sweep_all(keep: { [string]: boolean }?)
	local keep_patterns: { string } = {}
	if type(keep) == "table" then
		for output in pairs(keep) do
			keep_patterns[#keep_patterns + 1] = output
		end
	end
	local parts: { string } = {}
	for _, pattern in ipairs({ "[l]inux-wallpaperengine", "[m]pvpaper" }) do
		-- Con keep: se|match el proceso salvo que su --screen-root sea una de
		-- las salidas que hay que preservar.
		if #keep_patterns == 0 then
			parts[#parts + 1] = kill_matching(pattern)
		else
			local guards: { string } = {}
			for _, output in ipairs(keep_patterns) do
				guards[#guards + 1] = "ps -eo args= | grep -F -- '--screen-root " .. output .. "' | grep -qv grep"
			end
			parts[#parts + 1] = "for p in $(pgrep -f '" .. pattern .. "' 2>/dev/null); do "
				.. "alive=1; "
				.. table.concat(guards, "; ") .. " && alive=0; "
				.. "[ \"$alive\" = 1 ] && kill \"$p\" 2>/dev/null; done; true"
		end
	end
	noctalia.runAsync(table.concat(parts, "; "), nil, 5000)
end

-- Salida sobre la que actuar cuando no hay foco de ventana: dentro de un
-- callback asíncrono `focusedOutputName()` puede venir vacío.
local function current_output(): string?
	local focused = noctalia.focusedOutputName()
	if focused then
		return focused
	end
	if type(S.status.output) == "string" then
		return S.status.output
	end
	local lastApplied = S.state.last
	if type(lastApplied) == "table" and type(lastApplied.output) == "string" then
		return lastApplied.output
	end
	local outputs = noctalia.outputs()
	if type(outputs) == "table" and type(outputs[1]) == "table" then
		return outputs[1].name
	end
	return nil
end

local function stop_on(output: string)
	local pid = read_pid(output)
	noctalia.removeFile(pid_path(output))
	S.procs[output] = nil

	-- Siempre se barre la línea de comandos además del PID: un proceso lanzado por
	-- una versión anterior (o por otro plugin) no deja pidfile y si sobrevive
	-- duplica el render, que es lo que satura el GPU.
	local sweep = kill_matching("[l]inux-wallpaperengine.*--screen-root " .. output) .. "; "
		.. kill_matching("[m]pvpaper.*" .. output)

	if pid and is_alive(pid) then
		-- linux-wallpaperengine ignora SIGTERM: se le da una ventana y se escala.
		noctalia.runAsync(string.format(
			"kill %d 2>/dev/null; n=0; while kill -0 %d 2>/dev/null && [ $n -lt 10 ]; do sleep 0.2; n=$((n+1)); done; kill -9 %d 2>/dev/null; %s",
			pid, pid, pid, sweep
		), nil, 6000)
	else
		noctalia.runAsync(sweep, nil, 4000)
	end
end

-- Reemplazo atómico: matar y relanzar en el mismo comando de shell. Si se
-- hicieran como dos runAsync separados, el barrido del stop puede alcanzar al
-- proceso que acaba de arrancar y el wallpaper queda sin superficie.
-- Lanza un cliente de wallpaper: barre TODO motor/reproductor vivo, desprende
-- el nuevo con setsid (sin él el host mata el grupo al terminar runAsync) y
-- anota su PID. Motor y video comparten este único camino.
local function spawn(argv: string, output: string): boolean
	-- El comando termina en `& echo $! > pid`: el shell sale 0 aunque el binario
	-- no exista, así que `runAsync == true` sólo decía "se despachó". Con un
	-- motor inexistente el panel decía "aplicado" y no había nada en pantalla.
	-- `commandExists` está en la API del host (luau_host.cpp: luau_commandExists).
	local binario = argv:match("^setsid nohup ([%w%-_]+)")
	if binario and not noctalia.commandExists(binario) then
		noctalia.notifyError(noctalia.tr("panel.apply_failed"))
		dbg("spawn-missing", { binary = binario })
		return false
	end
	local pid = read_pid(output)
	local kill = kill_matching("[l]inux-wallpaperengine") .. "; " .. kill_matching("[m]pvpaper")
	if pid and is_alive(pid) then
		kill = string.format(
			"kill %d 2>/dev/null; n=0; while kill -0 %d 2>/dev/null && [ $n -lt 10 ]; do sleep 0.2; n=$((n+1)); done; kill -9 %d 2>/dev/null; %s",
			pid, pid, pid, kill
		)
	end
	local cmd = argv
		.. " > " .. quote((S.dataDir or "/tmp") .. "/engine.log") .. " 2>&1 & echo $! > " .. quote(pid_path(output))
	dbg("spawn", { output = output, argv = argv:sub(1, 160) })
	local ok = noctalia.runAsync(kill .. "; sleep 0.3; " .. cmd, nil, 8000) == true
	dbg("spawn-result", { output = output, ok = tostring(ok) })
	return ok
end

-- Deja el estado de "esto está en pantalla" y devuelve true.
local function mark_running(item: any, output: string, fps: number?): boolean
	S.procs[output] = { id = item.id, output = output }
	S.status.id = item.id
	S.status.title = item.title
	S.status.output = output
	S.status.since = now()
	S.status.fps = fps
	return true
end

local function launch(item: any, output: string, opts: any): boolean
	local parts: { string } = {
		"setsid nohup linux-wallpaperengine",
		"--screen-root " .. quote(output),
		"--bg " .. quote(item.id),
	}
	for _, arg in ipairs(engine.to_argv(opts)) do
		parts[#parts + 1] = quote(arg)
	end
	-- Propiedades propias del wallpaper (equivalente al "Configurar" del panel
	-- oficial): se suman después de las opciones globales.
	for _, arg in ipairs(engine.properties_argv(S.state.properties[item.id])) do
		parts[#parts + 1] = quote(arg)
	end

	if not spawn(table.concat(parts, " "), output) then
		noctalia.notifyError(noctalia.tr("panel.apply_failed"), item.title)
		return false
	end
	return mark_running(item, output, opts.fps)
end

-- Video local: mpvpaper en la capa de fondo. Mismo patrón de proceso que el
-- motor (nohup + pidfile) porque runAsync con argv no desprende el proceso.


local function video_thumbs()
	local kind = source()
	if kind ~= "videos" and kind ~= "engine" then
		return
	end
	local dir = (S.dataDir or "/tmp") .. "/thumbs"
	noctalia.runAsync("mkdir -p " .. quote(dir), nil, 3000)

	local started = 0
	local changed = false
	for _, item in ipairs(S.catalogItems) do
		-- Video local: el archivo. Workshop: el preview GIF, que animado en cada
		-- tarjeta cuesta caro; w-engine lo congela a JPEG y acá igual.
		local path = item.file
		if kind == "engine" and item.thumb == nil and type(item.preview) == "string" then
			path = item.preview
		end
		if type(path) == "string" and item.thumb == nil and path ~= "" then
			local dest = video_thumb_path(path)
			if noctalia.fileExists(dest) then
				item.thumb = dest
				changed = true
			elseif started < 4 then
				started = started + 1
				local target = item
				noctalia.runAsync(
					"b3l0w we still --file " .. quote(path) .. " --out " .. quote(dest),
					function(result: any)
						local code = type(result) == "table" and result.exitCode or -1
						if noctalia.fileExists(dest) then
							target.thumb = dest
							publish_catalog()
						else
							noctalia.log("[thumbs] FALLO code=" .. tostring(code) .. " err=" .. string.sub(tostring(type(result) == "table" and (result.stderr or "") or ""), 1, 160))
						end
					end
				)
			end
		end
	end
	if changed then
		publish_catalog()
	end
end

local function launch_video(item: any, output: string): boolean
	-- Opciones de reproducción: mismo conjunto que expone el plugin oficial de
	-- mpvpaper, tomadas de los ajustes para no hardcodear el comportamiento.
	local opts: { string } = {}
	if setting("video_loop", true) ~= false then
		opts[#opts + 1] = "loop"
	end
	if setting("video_mute", true) ~= false then
		opts[#opts + 1] = "--no-audio"
	end
	if setting("video_hwdec", true) ~= false then
		opts[#opts + 1] = "--hwdec=auto-safe"
	end
	local extra = setting("video_options", "")
	if type(extra) == "string" then
		local clean = (extra:gsub("'", ""))
		if clean ~= "" then
			opts[#opts + 1] = clean
		end
	end
	local cmd = "setsid nohup mpvpaper -l background -o '" .. table.concat(opts, " ") .. "' "
		.. quote(output) .. " " .. quote(item.file)

	if not spawn(cmd, output) then
		noctalia.notifyError(noctalia.tr("panel.apply_failed"), item.title)
		return false
	end
	return mark_running(item, output)
end

local function options_for(id: string): any
	local overrides = S.state.overrides or {}
	return engine.resolve(S.state.defaults or {}, overrides[id])
end

-- El generador de paleta de Noctalia trabaja sobre una imagen: se le pasa el
-- preview del wallpaper y se apaga la superficie para que no tape la animación.
local function sync_palette(output: string, item: any)
	-- Preferencia elegida en el panel; si no hay, el ajuste del host.
	if S.state.sync_colors == false or setting("sync_colors", true) == false then
		return
	end
	local still = item.thumb or item.preview
	if not still then
		return
	end
	noctalia.setWallpaper(output, still)
	noctalia.setWallpaperEnabled(output, false)
end

-- Quedó aplicado: estado en pantalla + última elección + persistencia. Estaba
-- copiado en las cuatro ramas de apply (wallhaven, imagen, video y motor).
local function mark_applied(item: any, target: string, fps: number?)
	S.status.id = item.id
	S.status.title = item.title
	S.status.output = target
	S.status.since = now()
	S.status.fps = fps
	S.state.last = { id = item.id, output = target }
	save()
	publish_status()
end

local function apply(id: string, output: string?, force: boolean?, preserve: { [string]: boolean }?)
	-- Buscar en el catálogo actual, después por la ruta (imágenes y videos) y
	-- por último en el workshop: aplicar no puede depender de la vista abierta.
	local item = find_item(id) or item_from_id(id) or catalog.find_by_id(id)
	if not item then
		noctalia.notifyError(noctalia.tr("panel.missing_item"), id)
		return
	end

	-- "*" = todas las salidas (lo que hace `setWallpaper(path)` sin conector).
	if output == "*" then
		local ok = true
		-- `apply` toma el id y resuelve el item por su cuenta; se propaga la
		-- misma bandera de forzado para no duplicar el lanzamiento.
		-- Cada iteración barre los motores: sin preservar las salidas ya
		-- aplicadas, el segundo monitor mataba lo del primero.
		local preserve: { [string]: boolean } = {}
		for _, entry in ipairs(noctalia.outputs()) do
			preserve[entry.name] = true
			ok = apply(item.id, entry.name, force, preserve) and ok
		end
		S.status.output = "*"
		publish_status()
		return ok
	end

	local target = output or current_output()
	if not target then
		noctalia.notifyError(noctalia.tr("panel.apply_failed"), item.title)
		return
	end

	local blocked = store.is_blocked(S.state, id)
	if blocked and not force then
		noctalia.notifyError(noctalia.tr("gpu.blocked", { name = item.title }))
		return
	end

	-- Wallhaven: la imagen se baja primero; ui.image y setWallpaper necesitan
	-- una ruta local, no una URL.
	if item.type == "wallhaven" then
		if type(item.full) ~= "string" then
			noctalia.notifyError(noctalia.tr("panel.apply_failed"), item.title)
			return
		end
		-- Carpeta de descargas: si el usuario eligió una, se usa esa; si no, la
		-- carpeta de datos del plugin.
		local chosen = setting("download_dir", "")
		local base = wallhaven_dir()
		if type(chosen) == "string" and chosen ~= "" then
			base = noctalia.expandPath(chosen)
			noctalia.runAsync("mkdir -p " .. quote(base), nil, 3000)
		end
		local dest = base .. "/" .. item.id .. "." .. wh.extension(item)
		local function use(path: string)
			stop_on(target)
			sweep_all(preserve)
			noctalia.setWallpaper(target, path)
			noctalia.setWallpaperEnabled(target, true)
			mark_applied(item, target)
		end
		if noctalia.fileExists(dest) then
			use(dest)
			return
		end
		noctalia.download(item.full, dest, function(ok)
			if ok then
				use(dest)
			else
				noctalia.notifyError(noctalia.tr("panel.apply_failed"), item.title)
			end
		end)
		return
	end

	-- Imagen local: se le pasa la ruta directo al host y no corre ningún motor.
	if item.type == "image" then
		stop_on(target)
		sweep_all(preserve)
		repaint(target, item.file)
		mark_applied(item, target)
		return
	end

	-- Video local: lo reproduce mpvpaper, no el motor.
	if item.type == "video" and string.sub(id, 1, 1) == "/" then
		if not launch_video(item, target) then
			return
		end
		mark_applied(item, target)
		return
	end

	local opts = options_for(id)
	if not launch(item, target, opts) then
		return
	end

	sync_palette(target, item)
	-- Un wallpaper nuevo arranca reproduciendo: si venía pausado, el estado
	-- viejo dejaba al panel creyendo que seguía congelado.
	S.status.paused = false
	mark_applied(item, target, opts.fps)
end

local function stop(output: string?)
	local target = output or current_output()
	if not target then
		return
	end
	dbg("stop", { output = target })
	stop_on(target)
	-- Sin motor no queda ninguna superficie de fondo: se devuelve el wallpaper
	-- propio de Noctalia para no dejar la salida vacía.
	noctalia.setWallpaperEnabled(target, true)
	S.status.id = nil
	S.status.title = nil
	S.status.output = nil
	S.status.since = nil
	S.status.paused = false
	-- `last` es lo que el arranque usa para relanzar el wallpaper: si queda
	-- puesto, al recargar el shell el wallpaper vuelve solo.
	S.state.last = { id = nil, output = nil }
	save()
	publish_store()
	publish_status()
end

-- ── ciclo ────────────────────────────────────────────────────────────────────

local function cycle_ids(): { string }
	local ids = (S.state.cycle and S.state.cycle.ids) or {}
	if #ids > 0 then
		return ids
	end
	local all: { string } = {}
	for _, item in ipairs(S.catalogItems) do
		all[#all + 1] = item.id
	end
	return all
end

local function pick_next(ids: { string }): string?
	if #ids == 0 then
		return nil
	end
	if (S.state.cycle.order or "sequential") == "random" then
		return ids[math.random(#ids)]
	end
	S.cycle.index = (S.cycle.index % #ids) + 1
	return ids[S.cycle.index]
end

local function cycle_tick()
	local cycle = S.state.cycle
	if not cycle.active then
		return
	end

	if now() < S.cycle.nextAt then
		return
	end

	local ids = cycle_ids()
	local nextId = pick_next(ids)
	if not nextId then
		return
	end

	apply(nextId, nil, false)
	S.cycle.nextAt = now() + math.max(1, tonumber(cycle.minutes) or 15) * 60000
	publish_status()
end

-- ── medición de GPU ──────────────────────────────────────────────────────────

local function probe_finish()
	local id = S.probe.id
	local result = S.probe.results[id or ""]

	if result then
		local threshold = tonumber(setting("gpu_threshold", 85)) or 85
		local verdict = gpuprobe.classify(result, threshold)
		if verdict == "heavy" then
			S.state = store.block(S.state, id, result, "gpu")
			noctalia.notify(noctalia.tr("gpu.marked"), noctalia.tr("gpu.marked_body", {
				busy = tostring(math.floor(result.busy_pct)),
			}))
			save()
			publish_store()
		end
	end

	for output, restoreId in pairs(S.probe.restore) do
		local item = find_item(restoreId)
		-- Se restaura el tipo que había: un video local vuelve con mpvpaper
		-- y una imagen con setWallpaper. Con `launch` (el motor) un video
		-- reaparecía como `linux-wallpaperengine --bg '/ruta/al.mp4'`.
		if item and item.type == "video" and string.sub(restoreId, 1, 1) == "/" then
			launch_video(item, output)
		elseif item and item.type == "image" then
			stop_on(output)
			sweep_all()
			repaint(output, item.file)
			mark_applied(item, output)
		elseif item then
			launch(item, output, options_for(restoreId))
		else
			stop_on(output)
		end
	end
	S.probe.restore = {}
	S.probe.id = nil
	S.probe.output = nil
	S.probe.prev = nil
	S.probe.phase = "idle"
	publish_status()
end

local function probe_start(id: string)
	local item = find_item(id)
	local output = noctalia.focusedOutputName()
	if not item or not output then
		return
	end

	if not gpuprobe.available() then
		noctalia.notifyError(noctalia.tr("gpu.unavailable"))
		return
	end

	-- Guarda qué había en pantalla para devolverlo al terminar la medición.
	local previous = S.procs[output]
	if previous then
		S.probe.restore[output] = previous.id
	end

	launch(item, output, options_for(id))
	S.probe.id = id
	S.probe.output = output
	S.probe.startedAt = now()
	S.probe.prev = gpuprobe.read()
	S.probe.phase = "warmup"
	publish_status()
end

local function probe_tick()
	local phase = S.probe.phase
	if phase == "idle" then
		if #S.probe.queue > 0 then
			local nextId = table.remove(S.probe.queue, 1)
			if nextId then
				probe_start(nextId)
			end
		end
		return
	end

	local warmup = tonumber(setting("probe_warmup_ms", 3000)) or 3000
	local sample = tonumber(setting("probe_sample_ms", 4000)) or 4000
	local elapsed = now() - S.probe.startedAt

	if phase == "warmup" and elapsed >= warmup then
		S.probe.prev = gpuprobe.read()
		S.probe.startedAt = now()
		S.probe.phase = "sample"
		return
	end

	if phase == "sample" and elapsed >= sample then
		local current = gpuprobe.read()
		local prev = S.probe.prev
		if current and prev then
			local profile = gpuprobe.profile(prev, current, elapsed)
			if profile and S.probe.id then
				S.probe.results[S.probe.id :: string] = profile
			end
		end
		probe_finish()
	end
end

-- ── requests del panel ───────────────────────────────────────────────────────

local function cycle_set(ids: { string }?, minutes: any, order: any, active: boolean)
	local cycle = S.state.cycle
	-- Sin duplicados: el mismo fondo aplicado dos veces seguidas (el store
	-- tenía "2688873830" repetido) es un turno de más en el ciclo.
	local source_ids = ids or cycle.ids or {}
	local limpios: { string } = {}
	local vistos: { [string]: boolean } = {}
	for _, id in ipairs(source_ids) do
		if type(id) == "string" and id ~= "" and not vistos[id] then
			vistos[id] = true
			limpios[#limpios + 1] = id
		end
	end
	cycle.ids = limpios
	cycle.minutes = math.max(1, tonumber(minutes) or cycle.minutes or 15)
	cycle.order = (order == "random") and "random" or "sequential"
	cycle.active = active
	S.cycle.index = 0
	if active then
		cycle_tick()
	end
	save()
	publish_status()
end

-- Relanza lo que está en pantalla para que tome las opciones nuevas.
local function restart_running()
	for output, proc in pairs(S.procs) do
		local item = find_item(proc.id)
		if item == nil then
			continue
		end
		-- Un video local lo reproduce mpvpaper, no el motor: relanzarlo con
		-- `launch` arrancaba `linux-wallpaperengine --bg '/ruta/al.mp4'` y
		-- mataba el video. Las imágenes locales tampoco pasan por el motor.
		if item.type == "video" and string.sub(proc.id, 1, 1) == "/" then
			launch_video(item, output)
		elseif item.type == "image" then
			stop_on(output)
			sweep_all()
			repaint(output, item.file)
			mark_applied(item, output)
		else
			launch(item, output, options_for(proc.id))
		end
	end
	publish_status()
end

-- ── acciones del panel ───────────────────────────────────────────────────────
--
-- Una tabla en vez de una cadena de veinte `elseif`: cada acción tiene nombre,
-- se puede probar sola y agregar una nueva no toca las demás.

local function act_set_options(req: any)
	if req.id then
		S.state = store.replace_override(S.state, req.id, req.engine)
	else
		local changed: { string } = {}
		for _, field in ipairs(engine.FIELDS) do
			local before = (S.state.defaults or {})[field.key]
			local after = (req.engine or {})[field.key]
			if before ~= after then
				changed[#changed + 1] = field.key
			end
		end
		S.state = store.replace_defaults(S.state, req.engine)
		if req.clear_overrides and #changed > 0 then
			S.state = store.drop_override_keys(S.state, changed)
		end
	end
	save()
	publish_store()
	-- Las opciones son argumentos de línea de comandos: solo valen en un
	-- proceso nuevo, así que se relanza lo que esté en pantalla.
	if req.restart ~= false then
		restart_running()
	end
end

local function act_set_view(req: any)
	local view = S.state.view
	if req.mode == "grid" or req.mode == "carousel" then
		view.mode = req.mode
	end
	if req.columns then
		view.columns = util.clamp(tonumber(req.columns) or view.columns, 2, 8)
	end
	if req.spacing then
		view.spacing = util.clamp(tonumber(req.spacing) or view.spacing, 0, 100)
	end
	if type(req.apply_on) == "boolean" then
		view.apply_on = req.apply_on
	end
	if type(req.view_label) == "boolean" then
		view.view_label = req.view_label
	end
	-- Disposición por modo: cada uno con su layout y sus medidas (0 = automático).
	for _, key in ipairs({ "carousel", "grid" }) do
		local patch = req[key]
		if type(patch) == "table" then
			local actual = view[key]
			if patch.layout == "full" or patch.layout == "minimal" then
				actual.layout = patch.layout
			end
			if patch.w ~= nil then
				actual.w = util.clamp(tonumber(patch.w) or actual.w, 0, 1200)
			end
			-- Ancho pedido para el panel de esta vista (0 = automático).
			-- El panel elige el escalón de la escalera de entries con esto.
			if patch.panel_w ~= nil then
				actual.panel_w = util.clamp(tonumber(patch.panel_w) or actual.panel_w or 0, 0, 1900)
			end
			if patch.h ~= nil then
				actual.h = util.clamp(tonumber(patch.h) or actual.h, 0, 900)
			end
			if type(patch.progress) == "boolean" then
				actual.progress = patch.progress
			end
			-- Cuántos wallpapers se ven a la vez en el carrusel (3 o 5).
			-- Siempre impar: el enfocado va al centro y los demás se reparten
			-- a partes iguales a cada lado.
			if patch.slots ~= nil then
				local valor = math.floor(tonumber(patch.slots) or actual.slots or 5)
				if valor % 2 == 0 then
					valor = valor + 1
				end
				valor = math.max(3, math.min(5, valor))
				-- Si cambió el conteo, el panel tiene que cambiar de entrada:
				-- el ancho es el del manifiesto y no se puede redimensionar.
				actual.slots = valor
			end
		end
	end
	save()
	publish_store()
end

-- Publica los filtros vigentes: el panel dibuja los chips con esto.
local function publish_wallhaven_filters()
	local filters = S.wallhaven.filters
	S.state.wallhaven_filters = {
		purity = filters.purity,
		categories = filters.categories,
		sorting = filters.sorting,
		order = filters.order,
		ratios = filters.ratios,
		res = filters.res,
		resmode = filters.resmode,
		query = filters.query,
		page = S.wallhaven.page,
		last_page = S.wallhaven.lastPage,
	}
	save()
	publish_store()
end

-- Los filtros se guardan en el store y se publicaban, pero al arrancar nadie
-- los copiaba a S.wallhaven.filters: la búsqueda empezaba siempre en los
-- valores por defecto y el panel mostraba otra cosa. Se siembran una vez, al
-- arrancar, y el store manda.
local function seed_wallhaven_filters()
	local guardados = S.state.wallhaven_filters
	if type(guardados) ~= "table" then
		return
	end
	local filters = S.wallhaven.filters
	for _, campo in ipairs({ "query", "purity", "categories", "sorting", "order", "ratios", "res", "resmode" }) do
		if type(guardados[campo]) == "string" then
			filters[campo] = guardados[campo]
		end
	end
	if tonumber(guardados.page) then
		S.wallhaven.page = math.max(1, math.floor(tonumber(guardados.page)))
	end
end

local function act_set_wallhaven(req: any)
	local filters = S.wallhaven.filters
	local changed = false

	-- Cada filtro se copia sólo si vino en el pedido, y cualquier cambio
	-- distinto de la página reinicia la búsqueda desde la primera.
	if type(req.query) == "string" then
		filters.query = req.query
		changed = true
		-- `toplist` + texto devuelve un puñado de resultados (55 en "cyberpunk");
		-- con relevancia son miles.
		if req.query ~= "" and filters.sorting == "toplist" then
			filters.sorting = "relevance"
		end
	end
	for _, campo in ipairs({ "purity", "categories", "sorting", "order", "ratios" }) do
		if type(req[campo]) == "string" then
			filters[campo] = req[campo]
			changed = true
		end
	end
	if req.res ~= nil then
		-- Cadena vacía = limpiar la resolución.
		filters.res = req.res
		changed = true
	elseif type(req.atleast) == "string" then
		filters.res = req.atleast
		changed = true
	end
	if req.resmode ~= nil then
		filters.resmode = (req.resmode == "exact") and "exact" or "atleast"
		changed = true
	end

	if req.page then
		S.wallhaven.page = math.max(1, math.floor(tonumber(req.page) or 1))
	elseif changed then
		S.wallhaven.page = 1
	end

	publish_wallhaven_filters()

	-- Se limpia siempre: lo acumulado era de la búsqueda anterior.
	S.wallhaven.items = {}
	S.wallhaven.pending = nil
	S.wallhaven.retries = 0
	wallhaven_fetch(S.wallhaven.page, false)
end

local function act_property(req: any, clear: boolean)
	local id = tostring(req.id or "")
	if id == "" then
		return
	end
	if clear then
		S.state.properties[id] = nil
	else
		local name = tostring(req.name or "")
		if name == "" then
			return
		end
		local current = S.state.properties[id] or {}
		if req.value == nil or tostring(req.value) == "" then
			current[name] = nil
		else
			current[name] = req.value
		end
		S.state.properties[id] = current
	end
	save()
	publish_store()
	if S.status.id == id then
		restart_running()
	end
end

local function act_pause(paused: boolean)
	-- SIGSTOP/SIGCONT sobre el proceso que está en pantalla: congela el
	-- wallpaper sin matarlo, así se reanuda donde estaba.
	local signal = if paused then "STOP" else "CONT"
	for _, entry in pairs(S.procs) do
		-- El PID vive en el pidfile: se lo pasa a kill sin leerlo en Luau.
		noctalia.runAsync(
			"pid=$(cat " .. quote(pid_path(entry.output)) .. " 2>/dev/null); "
				.. "[ -n \"$pid\" ] && kill -" .. signal .. " \"$pid\" 2>/dev/null; true",
			nil,
			3000
		)
	end
	S.status.paused = paused
	publish_status()
end

local function act_favorite(req: any)
	if type(req.id) ~= "string" then
		return
	end
	local item = find_item(req.id)
	local title = item and item.title or req.id
	S.state = store.toggle_favorite(S.state, req.id)
	save()
	publish_store()
	-- Confirmación visible: el widget marca con el botón del medio y no hay
	-- otra señal en pantalla de que el cambio se aplicó.
	noctalia.notify(title .. ((S.state.favorites or {})[req.id] and " ★" or " ☆"))
end

local function act_source(req: any)
	local next_source = req.source
	if next_source == "engine" or next_source == "images" or next_source == "videos" or next_source == "wallhaven" then
		S.state.source = next_source
		-- Salir de Wallhaven cancela la página agendada: si no, al volver a la
		-- fuente arrancaba un fetch de la consulta anterior.
		if next_source ~= "wallhaven" then
			S.wallhaven.pending = nil
			S.wallhaven.loading = false
		end
		save()
		-- Publicar primero: el panel tiene que reflejar la fuente al instante.
		-- El escaneo de la carpeta puede tardar y no debe bloquear la UI.
		publish_store()
		ensure_catalog(true)
	end
end

local function act_screen(req: any)
	noctalia.state.set("wes_screen", {
		screen = tostring(req.screen or "browse"),
		id = req.id,
		nonce = tostring(now()) .. ":" .. tostring(math.random(1, 1000000)),
	})
end

local ACTIONS: { [string]: (any) -> () } = {
	apply = function(req)
		apply(req.id, req.output, req.force == true)
	end,
	stop = function(req)
		stop(req.output)
	end,
	cycle_start = function(req)
		cycle_set(req.ids, req.minutes, req.order, true)
	end,
	cycle_stop = function()
		cycle_set(nil, nil, nil, false)
	end,
	refresh = function()
		ensure_catalog(true)
	end,
	probe = function(req)
		if req.id then
			if S.probe.phase == "idle" then
				probe_start(req.id)
			else
				table.insert(S.probe.queue, req.id)
			end
		end
	end,
	probe_all = function()
		for _, item in ipairs(S.catalogItems) do
			if not store.is_blocked(S.state, item.id) and S.probe.results[item.id] == nil then
				table.insert(S.probe.queue, item.id)
			end
		end
		publish_status()
	end,
	set_options = act_set_options,
	set_property = function(req)
		act_property(req, false)
	end,
	clear_properties = function(req)
		act_property(req, true)
	end,
	set_wh_max = function(req)
		S.state.wallhaven_max = math.max(24, math.min(2400, tonumber(req.value) or 1200))
		save()
		-- Sin publicar, el select del panel seguía mostrando el valor viejo
		-- hasta que otra acción republicara el store.
		publish_store()
		-- Cambiar el tope reinicia la carga acumulada: se vuelve a pedir desde 1.
		S.wallhaven.items = {}
		S.wallhaven.page = 1
		S.wallhaven.pending = nil
		wallhaven_fetch(1, false)
	end,
	set_debug = function(req)
		S.state.debug = req.enabled ~= false
		save()
		publish_store()
		noctalia.log("[debug] " .. (S.state.debug and "activado" or "desactivado"))
	end,
	-- Vuelca un reporte autocontenido: estado, catálogo, procesos vivos y las
	-- últimas líneas del log del motor. Sirve para diagnosticar sin acceso a la
	-- máquina.
	debug_dump = function()
		local reporte: { string } = {
			"# b3l0w wallpaper — reporte de diagnóstico",
			"fecha: " .. os.date("%Y-%m-%d %H:%M:%S"),
			"fuente: " .. tostring(S.state.source) .. " | items: " .. tostring(#S.catalogItems)
				.. " | debug: " .. tostring(S.state.debug == true),
			"vista: " .. tostring(S.state.view.mode) .. " | columnas: " .. tostring(S.state.view.columns)
				.. " | carrusel: " .. tostring(S.state.view.carousel.w) .. "x" .. tostring(S.state.view.carousel.h)
				.. " | grilla: " .. tostring(S.state.view.grid.w) .. "x" .. tostring(S.state.view.grid.h),
			"wallhaven: página " .. tostring(S.wallhaven.page) .. "/" .. tostring(S.wallhaven.lastPage)
				.. " | items " .. tostring(#S.wallhaven.items) .. " | tope " .. tostring(wallhaven_cap()),
			"status: id=" .. tostring(S.status.id) .. " output=" .. tostring(S.status.output)
				.. " paused=" .. tostring(S.status.paused == true) .. " fps=" .. tostring(S.status.fps),
			"catálogo: root=" .. tostring(S.catalogRoot) .. " items=" .. tostring(#S.catalogItems),
		}
		noctalia.runAsync("pgrep -af '[l]inux-wallpaperengine|[m]pvpaper' || true", function(result: any)
			local procs = "ninguno"
			if type(result) == "table" and type(result.stdout) == "string" and result.stdout ~= "" then
				procs = result.stdout:gsub("\n", " | ")
			end
			table.insert(reporte, "procesos: " .. procs)
			local log_path = (S.dataDir or "/tmp") .. "/engine.log"
			local motor = noctalia.readFile(log_path)
			if type(motor) == "string" and motor ~= "" then
				local lineas: { string } = {}
				for linea in motor:gmatch("[^\n]+") do
					lineas[#lineas + 1] = linea
				end
				local desde = math.max(1, #lineas - 15)
				table.insert(reporte, "--- engine.log (últimas " .. tostring(#lineas - desde + 1) .. " líneas) ---")
				for index = desde, #lineas do
					table.insert(reporte, lineas[index])
				end
			end
			local texto = table.concat(reporte, "\n")
			local destino = (S.dataDir or "/tmp") .. "/debug-report.txt"
			local ok = noctalia.writeFile(destino, texto)
			for linea in texto:gmatch("[^\n]+") do
				noctalia.log("[reporte] " .. linea)
			end
			if ok then
				noctalia.notify("b3l0w wallpaper", "Reporte en " .. destino)
			else
				noctalia.notifyError("b3l0w wallpaper", "No se pudo escribir el reporte")
			end
		end)
	end,
	set_theme = function(req)
		S.state.sync_colors = req.enabled ~= false
		save()
		publish_store()
	end,
	favorite = act_favorite,
	pause = function()
		act_pause(true)
	end,
	resume = function()
		act_pause(false)
	end,
	unblock = function(req)
		S.state = store.unblock(S.state, req.id)
		save()
		publish_store()
		-- Desbloqueado: si era el que estaba en pantalla, se puede reintentar.
		restart_running()
	end,
	open_screen = act_screen,
	-- Alias viejo (`screen` con `name`): lo usaba el CLI antes de open_screen.
	screen = function(req)
		act_screen({ screen = req.name or req.screen, id = req.id })
	end,
	nav = function(req)
		-- La rueda sobre el widget de la barra llega acá; también sirve para
		-- manejar la vista del panel desde el CLI, sin tocar la UI.
		noctalia.state.set("wes_nav", {
			delta = tonumber(req.delta) or 0,
			nonce = tostring(now()) .. ":" .. tostring(math.random(1, 1000000)),
		})
	end,
	set_wallhaven = act_set_wallhaven,
	set_source = act_source,
	set_local_sort = function(req)
		local sort = tostring(req.sort or "name")
		if sort ~= "date" and sort ~= "random" then
			sort = "name"
		end
		S.state.local_sort = sort
		save()
		publish_store()
		-- Reordenar = volver a escanear la carpeta de la fuente actual.
		ensure_catalog(true)
	end,
	apply_color = function(req)
		local hex = tostring(req.color or ""):gsub("#", "")
		if not string.match(hex, "^%x%x%x%x%x%x$") then
			noctalia.notifyError(noctalia.tr("panel.color_invalid"), tostring(req.color or ""))
			return
		end
		local out = (S.dataDir or "/tmp") .. "/wallpapers/color-" .. hex .. ".png"
		noctalia.runAsync(
			"b3l0w we solid --color '#'" .. hex .. " --out " .. quote(out),
			function(result: any)
				if not noctalia.fileExists(out) then
					noctalia.notifyError(noctalia.tr("panel.apply_failed"), "color #" .. hex)
					return
				end
				local target = current_output()
				if not target then
					noctalia.notifyError(noctalia.tr("panel.apply_failed"), "color #" .. hex)
					return
				end
				stop_on(target)
				sweep_all()
				repaint(target, out)
				S.state.color = "#" .. hex
				S.state.last = nil
				save()
				publish_store()
				S.status.id = "color:#" .. hex
				S.status.title = "Color #" .. hex
				S.status.output = target
				S.status.since = now()
				S.status.fps = nil
				publish_status()
			end
		)
	end,
	set_view = act_set_view,
}

local function handle(req: any)
	if type(req) ~= "table" then
		return
	end
	if req.nonce ~= nil and req.nonce == S.lastNonce then
		return
	end
	S.lastNonce = req.nonce

	local action = tostring(req.action or "")
	dbg("ipc", { action = action, id = req.id, output = req.output })
	local run = ACTIONS[action]
	if run then
		run(req)
	else
		noctalia.log("[req] acción desconocida: " .. action)
	end
end

-- ── callbacks del host ───────────────────────────────────────────────────────

function onConfigChanged()
	noctalia.log("[service] settings actualizados")
	ensure_catalog(false)
	publish_status()
end

-- Permite manejar el service desde la CLI, además del panel:
--   noctalia msg plugin b3l0w/wallpaper:start all apply '{"id":"123","output":"eDP-1"}'
function onIpc(event: string, payload: any)
	if event == "refresh" then
		ensure_catalog(true)
		return
	end

	local request: any = nil
	if type(payload) == "table" then
		request = payload
	elseif type(payload) == "string" and payload ~= "" then
		local decoded = noctalia.json.decode(payload)
		if type(decoded) == "table" then
			request = decoded
		end
	end

	if request == nil then
		return
	end
	request.action = request.action or event
	handle(request)
end

function update()
	-- El catálogo no cambia cada 500 ms: escanear o listar en cada tick era lo
	-- que hacía saltar el presupuesto de 25 ms del callback.
	if now() - (S.catalogTickAt or 0) > 1000 then
		S.catalogTickAt = now()
		ensure_catalog(false)
	end
	if now() - (S.thumbsAt or 0) > 5000 then
		S.thumbsAt = now()
		video_thumbs()
	end
	-- Página siguiente de Wallhaven, espaciada para no encadenar pedidos.
	-- Arranque rápido (400 ms) mientras la lista es corta; después 1,2 s para no
	-- chocar con el límite de la API.
	local gap = (#S.wallhaven.items < 120) and 400 or 1200
	if S.wallhaven.pending and source() == "wallhaven" and now() - (S.wallhaven.nextAt or 0) > gap then
		local next_page = S.wallhaven.pending
		S.wallhaven.nextAt = now()
		S.wallhaven.pending = nil
		wallhaven_fetch(next_page, true)
	end
	cycle_tick()
	probe_tick()
	flush()
end

-- ── arranque ─────────────────────────────────────────────────────────────────

local dataDir = noctalia.pluginDataDir()
S.dataDir = dataDir

local fresh_state = dataDir ~= nil and not store.has_state(dataDir)

if dataDir then
	S.state = store.load(dataDir)
else
	S.state = store.defaults()
	noctalia.log("[service] sin directorio de datos: la configuración no se persiste")
end
seed_debug()
seed_wallhaven_filters()
-- `seed_view` y `save` están declarados arriba: el arranque corre al final del
-- archivo, así que se llaman acá y no dentro de seed_debug.
if fresh_state then
	seed_view()
	save()
	noctalia.log("[store] primer arranque: vista desde el manifiesto")
end

math.randomseed(math.floor(now() % 2147483647))

noctalia.state.watch(REQUEST_KEY, handle)
noctalia.setUpdateInterval(TICK_MS)

ensure_catalog(false)
publish_store()
publish_status()

-- Restaura lo que estaba sonando antes de una recarga del shell.
local last = S.state.last
if type(last) == "table" and type(last.id) == "string" then
	local item = find_item(last.id)
	if item and last.output then
		launch(item, last.output, options_for(last.id))
		publish_status()
	end
end
