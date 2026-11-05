--!strict
-- Service de b3l0w/anilist: dueño del CLI y de todo el estado.
--
-- Corrección de raíz del bug del plugin original: las carátulas NO son un campo
-- de la entrada. Viven en su propia clave de estado (`b3l0w_anilist_covers`) que
-- sólo escribe la sincronización de imágenes, así un refresco de la lista no
-- puede dejar la UI sin rutas (que era exactamente el síntoma: "las imágenes
-- desaparecen a los pocos segundos").

local cli = require("./lib/cli.luau")
local store = require("./lib/store.luau")

local STATS_KEY = "b3l0w_anilist_stats"
local LIBRARY_KEY = "b3l0w_anilist_library"
local COVERS_KEY = "b3l0w_anilist_covers"
local STATUS_KEY = "b3l0w_anilist_status"
local REQUEST_KEY = "b3l0w_anilist_request"
local DISCOVER_KEY = "b3l0w_anilist_discover"
local SCREEN_KEY = "b3l0w_anilist_screen"
local DETAIL_KEY = "b3l0w_anilist_detail"
local SCHEDULE_KEY = "b3l0w_anilist_schedule"
local FILTER_KEY = "b3l0w_anilist_filters"

local REFRESH_MINUTES_DEFAULT = 30
local LEGACY_DATA = "/home/b3low-z3r0/.local/state/noctalia/plugins/data/cleboost/anilist"

-- Los estados y los órdenes que el panel ofrece. Son las MISMAS listas que
-- usa panel.luau (STATUS_FILTERS y SORT_OPTIONS): si acá aceptáramos un
-- valor que el panel no conoce, el service lo guardaría, el selector caería
-- en el primer item sin avisar, y el valor persistido no correspondía con
-- lo que se veía en pantalla.
--
-- El estado vacío significa "todos" (no es un filtro).
local ESTADOS: { [string]: boolean } = {
	CURRENT = true,
	PLANNING = true,
	COMPLETED = true,
	DROPPED = true,
	PAUSED = true,
	REPEATING = true,
}

local ORDENES: { [string]: boolean } = {
	updated = true,
	title = true,
	progress = true,
	airing = true,
	score = true,
}

local S = {
	viewer = nil :: any,
	anime = {} :: { any },
	manga = {} :: { any },
	covers = {} :: { [string]: string },
	fetchedAt = 0,
	partial = false,
	busy = false,
	phase = "idle" :: string,
	error = nil :: string?,
	lastNonce = "",
	discover = nil :: any,
	dataDir = "" :: string,
	tokenChecked = false,
	detail = nil :: any,
	schedule = nil :: any,
	-- La agenda tiene su propio ciclo de carga: es una consulta aparte de
	-- la biblioteca y el panel necesita distinguir "cargando" de "vacío".
	scheduleLoading = false :: boolean,
	scheduleFetching = false :: boolean,
	-- Filtros y orden que pidió el panel. El service los aplica sobre la
	-- biblioteca y publica la lista YA filtrada: el panel no decide qué se ve.
	filters = { status = "", genre = "", sort = "" } :: { status: string, genre: string, sort: string },
}

local function now(): number
	return os.time()
end

-- El ajuste access_token estaba declarado en el manifest y el service nunca lo
-- leía: el CLI sólo miraba token.json. Si el usuario lo pega en Ajustes, tiene
-- que llegar al binario.
local function tokenArgs(): { string }
	local value = noctalia.getConfig("access_token")
	if type(value) == "string" and value ~= "" then
		return { "--token", value }
	end
	return {}
end

local function refreshMinutes(): number
	local value = noctalia.getConfig("refresh_minutes")
	if type(value) == "number" and value >= 1 then
		return value
	end
	return REFRESH_MINUTES_DEFAULT
end

local function countCovers(): number
	local total = 0
	for _ in pairs(S.covers) do
		total += 1
	end
	return total
end

local function entranceCount(): number
	local total = 0
	for _, entry in ipairs(S.anime) do
		if entry.status == "CURRENT" then
			total += 1
		end
	end
	for _, entry in ipairs(S.manga) do
		if entry.status == "CURRENT" then
			total += 1
		end
	end
	return total
end

-- ── publicación ──────────────────────────────────────────────────────

local function publishStatus(): ()
	noctalia.state.set(STATUS_KEY, {
		busy = S.busy,
		phase = S.phase,
		error = S.error,
		fetchedAt = S.fetchedAt,
		anime = #S.anime,
		manga = #S.manga,
		covers = countCovers(),
		current = entranceCount(),
		partial = S.partial,
		loggedIn = S.viewer ~= nil,
	})
end

local function publishLibrary(): ()
	noctalia.state.set(LIBRARY_KEY, {
		viewer = S.viewer,
		anime = S.anime,
		manga = S.manga,
		fetchedAt = S.fetchedAt,
		partial = S.partial,
	})
end

-- El service publica los filtros activos y la lista de géneros disponibles.
-- El panel lee de acá: un solo dueño del estado de "qué se está viendo".
--
-- La lista de géneros se cuenta sobre la biblioteca COMPLETA, no sobre la
-- filtrada: si se contara sobre la filtrada, elegir un género vaciaría el
-- selector y no habría forma de volver a "Todos".
local function genresDisponibles(): { string }
	local vistos: { [string]: boolean } = {}
	local lista: { string } = {}
	for _, entries in ipairs({ S.anime, S.manga }) do
		for _, entry in ipairs(entries) do
			local genres = entry.genres
			if type(genres) == "table" then
				for _, genero in ipairs(genres) do
					local nombre = tostring(genero or "")
					if nombre ~= "" and not vistos[nombre] then
						vistos[nombre] = true
						table.insert(lista, nombre)
					end
				end
			end
		end
	end
	table.sort(lista)
	return lista
end

local function publishFilters(): ()
	noctalia.state.set(FILTER_KEY, {
		status = S.filters.status,
		genre = S.filters.genre,
		sort = S.filters.sort,
		genres = genresDisponibles(),
	})
end

-- Los filtros se guardan en disco: el panel se cierra y se abre, y el filtro
-- elegido tiene que seguir ahí. El store escribe diferido, así que el costo
-- es uno por cambio de filtro.
local FILTERS_FILE = "filters.json"

local function saveFilters(): ()
	store.save(FILTERS_FILE, {
		status = S.filters.status,
		genre = S.filters.genre,
		sort = S.filters.sort,
	})
end

local function loadFilters(): ()
	local data = store.load(FILTERS_FILE)
	if type(data) ~= "table" then
		return
	end
	local estado = data.status
	local genero = data.genre
	local orden = data.sort
	-- Se validan igual que los que llegan por IPC: un archivo guardado con
	-- un valor que el panel no conoce (de una versión anterior, o escrito
	-- a mano) haría que el selector mostrara una cosa y la lista fuera otra.
	if type(estado) == "string" and (estado == "" or ESTADOS[estado]) then
		S.filters.status = estado
	end
	if type(genero) == "string" then
		S.filters.genre = genero
	end
	if type(orden) == "string" and ORDENES[orden] then
		S.filters.sort = orden
	end
end

-- Sólo la sincronización de carátulas llama a esta función.
-- Sin persistir acá, las carátulas ganadas en discover viven sólo en memoria:
-- al recargar el plugin covers.json vuelve a la versión de la biblioteca y las
-- portadas de las páginas exploradas desaparecen (bug A14).





-- El mapa se persiste: si el service arranca con el mapa vacío, todas las
-- carátulas se ven como placeholders hasta que termina la pasada de imágenes
-- (varios segundos), que es justo el síntoma que hay que evitar.

local function coversCachePath(): string
	return S.dataDir .. "/covers.json"
end

local SAVE_EVERY = 4 -- segundos; un sync toca las carátulas muchas veces
local lastSaveAt = 0

local function saveCoversCache(force: boolean?): ()
	if S.dataDir == "" then
		return
	end
	if not force and now() - lastSaveAt < SAVE_EVERY then
		return
	end
	lastSaveAt = now()
	noctalia.writeFile(coversCachePath(), noctalia.json.encode(S.covers))
end


local function publishCovers(): ()
	noctalia.state.set(COVERS_KEY, S.covers)
	saveCoversCache()
end

local function loadCoversCache(): ()
	if S.dataDir == "" then
		return
	end
	local raw = noctalia.readFile(coversCachePath())
	if type(raw) ~= "string" or raw == "" then
		return
	end
	local decoded = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		return
	end
	local covers: { [string]: string } = {}
	for key, value in pairs(decoded) do
		if type(value) == "string" then
			covers[tostring(key)] = value
		end
	end
	if next(covers) ~= nil then
		S.covers = covers
		publishCovers()
	end
end

-- ── data dir y token ─────────────────────────────────────────────────

local function ensureDataDir(): ()
	if S.dataDir ~= "" then
		return
	end
	local dir = noctalia.pluginDataDir()
	if type(dir) == "string" and dir ~= "" then
		S.dataDir = dir
	end
end

-- El plugin original ya tenía el token guardado: se copia una vez para no
-- obligar a re-loguear. Sin esto el usuario abre su propio plugin y ve "login".
local function migrateToken(): ()
	if S.tokenChecked then
		return
	end
	S.tokenChecked = true
	ensureDataDir()
	if S.dataDir == "" then
		return
	end
	local target = S.dataDir .. "/token.json"
	if noctalia.fileExists(target) then
		return
	end
	local legacy = LEGACY_DATA .. "/token.json"
	if not noctalia.fileExists(legacy) then
		return
	end
	local raw = noctalia.readFile(legacy)
	if type(raw) == "string" and raw ~= "" then
		noctalia.writeFile(target, raw)
	end
end

-- ── sincronización ───────────────────────────────────────────────────

-- Cola de un solo pedido: con `busy` las acciones se descartaban calladas, así
-- que clickear "Descubrir" mientras el sync inicial corría no hacía nada.
local PENDING: any = nil

local function queueOrRun(pedido: any, run: (any) -> ()): ()
	if S.busy then
		PENDING = { pedido = pedido, run = run }
		return
	end
	run(pedido)
end

local function runPending(): ()
	local pendiente = PENDING
	PENDING = nil
	if pendiente ~= nil then
		pendiente.run(pendiente.pedido)
	end
end

local function finishPhase(): ()
	S.busy = false
	S.phase = "idle"
	publishStatus()
	runPending()
end

-- Lista y carátulas se aplican por separado: la lista se publica apenas llega
-- (~3 s) y las imágenes entran después. Antes las dos cosas viajaban en una
-- sola llamada y el panel quedaba vacío ~13 s.
local function applyLibrary(payload: any): boolean
	if type(payload) ~= "table" then
		return false
	end
	if type(payload.viewer) == "table" and payload.viewer.id ~= nil then
		S.viewer = payload.viewer
	end
	S.anime = type(payload.anime) == "table" and payload.anime or {}
	S.manga = type(payload.manga) == "table" and payload.manga or {}
	S.fetchedAt = tonumber(payload.fetchedAt) or now()
	S.partial = payload.partial == true
	S.error = nil
	return true
end

local function applyCovers(mapa: any): ()
	if type(mapa) ~= "table" then
		return
	end
	local covers: { [string]: string } = {}
	for key, value in pairs(mapa) do
		if type(value) == "string" then
			covers[tostring(key)] = value
		end
	end
	if next(covers) == nil then
		return
	end
	-- Merge: el mapa de la biblioteca y el del catálogo conviven, y una pasada
	-- de carátulas de la lista no puede borrar las de descubrimiento.
	for key, value in pairs(covers) do
		S.covers[key] = value
	end
	publishCovers()
	saveCoversCache()
end

local function commonArgs(): { string }
	local args: { string } = {}
	if S.dataDir ~= "" then
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
	end
	for _, value in ipairs(tokenArgs()) do
		table.insert(args, value)
	end
	return args
end

local function libraryPath(): string
	return S.dataDir .. "/library.json"
end

-- Segunda fase: bajar/validar carátulas de lo que ya está en pantalla. Corre
-- después de publicar la lista, con la biblioteca escrita a disco para no
-- volver a pedirle nada a la API.
local function fetchCovers(): ()
	local args: { string } = { "covers", "--json", "--library", libraryPath() }
	if S.dataDir ~= "" then
		table.insert(args, "--covers-dir")
		table.insert(args, S.dataDir .. "/covers")
		table.insert(args, "--reuse")
		table.insert(args, LEGACY_DATA .. "/covers/v2")
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
	end
	for _, value in ipairs(tokenArgs()) do
		table.insert(args, value)
	end
	cli.json("anilist", args, function(payload: any, err: string?)
		if err then
			return
		end
		if type(payload) == "table" then
			applyCovers(payload.covers)
		end
	end)
end

local function sync(force: boolean): ()
	local age = now() - S.fetchedAt
	-- Sin refresco silencioso al abrir: si los datos son recientes, no se pide
	-- nada. Era el disparador del bug original (cada apertura recargaba).
	if not force and S.fetchedAt > 0 and age < refreshMinutes() * 60 then
		return
	end
	if S.busy then
		PENDING = { pedido = { force = force }, run = function(p: any) sync(p.force == true) end }
		return
	end
	ensureDataDir()
	migrateToken()
	S.busy = true
	S.phase = "sync"
	publishStatus()

	local args: { string } = { "library", "--json" }
	for _, value in ipairs(commonArgs()) do
		table.insert(args, value)
	end

	cli.json("anilist", args, function(payload: any, err: string?)
		if err then
			S.error = err
			finishPhase()
			return
		end
		if not applyLibrary(payload) then
			S.error = "respuesta inesperada del CLI"
			finishPhase()
			return
		end
		publishLibrary()
		finishPhase()
		-- Los géneros disponibles salen de la biblioteca recién traída: sin
		-- esto el selector de género arranca vacío hasta el próximo sync.
		publishFilters()
		-- La biblioteca queda en disco para que la fase de carátulas no repita
		-- el fetch de la API.
		if S.dataDir ~= "" then
			noctalia.writeFile(libraryPath(), noctalia.json.encode({
				anime = S.anime,
				manga = S.manga,
				viewer = S.viewer,
				fetchedAt = S.fetchedAt,
			}))
		end
		fetchCovers()
	end)
end

-- ── mutaciones ───────────────────────────────────────────────────────

local function findEntry(mediaId: number): any
	for _, list in ipairs({ S.anime, S.manga }) do
		for _, entry in ipairs(list) do
			if tonumber(entry.mediaId) == mediaId then
				return entry
			end
		end
	end
	return nil
end

local function applyProgress(mediaId: number, progress: number, status: string?): ()
	local entry = findEntry(mediaId)
	if entry == nil then
		return
	end
	local total = tonumber(entry.total) or 0
	local clamped = math.max(0, progress)
	if total > 0 then
		clamped = math.min(total, clamped)
	end
	entry.progress = clamped
	if status ~= nil and status ~= "" then
		entry.status = status
	elseif total > 0 and clamped >= total then
		entry.status = "COMPLETED"
	end
end

local function mutate(mediaId: number, progress: number, status: string): ()
	local args: { string } = {
		"mutate",
		"--json",
		"--media-id",
		tostring(mediaId),
		"--progress",
		tostring(progress),
	}
	if status ~= "" then
		table.insert(args, "--status")
		table.insert(args, status)
	end
	if S.dataDir ~= "" then
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
	end
	-- Optimista: la UI responde ya y se revierte si el CLI falla.
	local before = findEntry(mediaId)
	local known = before ~= nil
	local previousProgress = before and before.progress or 0
	local previousStatus = before and before.status or ""
	if known then
		applyProgress(mediaId, progress, status)
		publishLibrary()
		publishStatus()
	end

	cli.json("anilist", args, function(result: any, err: string?)
		if err then
			if known then
				applyProgress(mediaId, previousProgress, previousStatus)
				publishLibrary()
				publishStatus()
			end
			noctalia.notifyError("AniList", err)
			return
		end
		if type(result) == "table" and type(result.progress) == "number" then
			if known then
				applyProgress(mediaId, result.progress, result.status)
				publishLibrary()
				publishStatus()
			else
				-- Vino del catálogo: ahora sí está en la lista, se refresca para
				-- que aparezca con su fila real.
				sync(true)
			end
		end
	end)
end

-- ── descubrimiento ───────────────────────────────────────────────────

local function publishDiscover(): ()
	noctalia.state.set(DISCOVER_KEY, S.discover or { kind = "trending", page = 1, items = {} })
end

local function discover(kind: string, page: number, tab: string): ()
	if S.busy then
		PENDING = { pedido = { kind = kind, page = page, tab = tab }, run = function(p: any)
			discover(p.kind, p.page, p.tab)
		end }
		return
	end
	S.busy = true
	S.phase = "discover"
	publishStatus()

	ensureDataDir()
	local args: { string } = { "discover", "--json", "--kind", kind, "--page", tostring(page) }
	if S.dataDir ~= "" then
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
		table.insert(args, "--covers-dir")
		table.insert(args, S.dataDir .. "/covers")
	end
	for _, value in ipairs(tokenArgs()) do
		table.insert(args, value)
	end

	cli.json("anilist", args, function(payload: any, err: string?)
		if err then
			S.error = err
			finishPhase()
			return
		end
		if type(payload) ~= "table" or type(payload.items) ~= "table" then
			S.error = "descubrimiento: respuesta inesperada"
			finishPhase()
			return
		end
		S.discover = {
			kind = tostring(payload.kind or kind),
			page = tonumber(payload.page) or page,
			hasNext = payload.hasNext == true,
			total = tonumber(payload.total) or 0,
			items = payload.items,
			fetchedAt = tonumber(payload.fetchedAt) or now(),
		}
		-- Las carátulas del catálogo entran al MISMO mapa que la biblioteca: la
		-- UI resuelve todo por id y no hay dos caminos de imágenes.
		if type(payload.covers) == "table" then
			for key, value in pairs(payload.covers) do
				if type(value) == "string" then
					S.covers[tostring(key)] = value
				end
			end
			publishCovers()
		end
		S.error = nil
		publishDiscover()
		finishPhase()
	end)
end

-- ── ficha de serie y agenda de emisión ──────────────────────────────

-- La ficha (sinopsis, géneros, próximo capítulo) NO viene con la biblioteca:
-- meterle la sinopsis de 300 entradas al estado del panel sería un payload
-- imposible. Se pide sólo para la serie que se está mirando.
local function publishDetail(): ()
	noctalia.state.set(DETAIL_KEY, S.detail or { loading = true })
end

local function fetchDetail(mediaId: number): ()
	ensureDataDir()
	local args: { string } = { "media", "--json", "--media-id", tostring(mediaId) }
	if S.dataDir ~= "" then
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
	end
	for _, value in ipairs(tokenArgs()) do
		table.insert(args, value)
	end
	cli.json("anilist", args, function(payload: any, err: string?)
		if err then
			noctalia.log("[b3l0w-anilist] ficha " .. tostring(mediaId) .. ": " .. err)
			noctalia.notifyError("AniList", err)
			S.detail = { error = err, mediaId = mediaId }
			publishDetail()
			return
		end
		if type(payload) ~= "table" then
			S.detail = { error = "respuesta inesperada", mediaId = mediaId }
			publishDetail()
			return
		end
		S.detail = payload
		publishDetail()
	end)
end

-- La agenda de emisión son los capítulos que vienen de las series que el
-- usuario está viendo. Es una consulta aparte de la biblioteca: cambia cada
-- hora y la biblioteca se refresca cada 30 minutos.
--
-- `loading` viaja en el estado porque el panel lo necesita para distinguir
-- tres situaciones que si no se ven iguales: cargando, error y "no hay
-- capítulos". Sin la bandera el panel muestra la lista vacía y dice "no hay
-- capítulos próximos" mientras la consulta todavía no volvió.
local function publishSchedule(): ()
	if S.scheduleLoading then
		noctalia.state.set(SCHEDULE_KEY, { loading = true, items = {} })
		return
	end
	noctalia.state.set(SCHEDULE_KEY, S.schedule or { loading = false, items = {} })
end

local function fetchSchedule(): ()
	-- Una consulta en vuelo: la agenda se pide desde varios lados (el clic
	-- en la pestaña, el panel al abrirse, el IPC) y no pueden pisarse.
	if S.scheduleFetching then
		return
	end
	S.scheduleFetching = true
	S.scheduleLoading = true
	publishSchedule()
	ensureDataDir()
	local args: { string } = { "schedule", "--json" }
	if S.dataDir ~= "" then
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
	end
	for _, value in ipairs(tokenArgs()) do
		table.insert(args, value)
	end
	cli.json("anilist", args, function(payload: any, err: string?)
		S.scheduleFetching = false
		S.scheduleLoading = false
		if err then
			noctalia.log("[b3l0w-anilist] agenda: " .. err)
			S.schedule = { error = err, items = {} }
			publishSchedule()
			return
		end
		if type(payload) ~= "table" or type(payload.items) ~= "table" then
			S.schedule = { error = "respuesta inesperada", items = {} }
			publishSchedule()
			return
		end
		S.schedule = payload
		publishSchedule()
	end)
end

-- ── requests del panel y del widget ──────────────────────────────────

-- Estadísticas del usuario: el CLI las cachea 30 min, así que pedirlas al abrir
-- el panel no cuesta una query cada vez.
local function loadStats(force: boolean?): ()
	local args = { "stats", "--json", "--data-dir", tostring(S.dataDir) }
	if force then
		table.insert(args, "--refresh")
	end
	cli.json("anilist", args, function(datos: any, err: string?)
		if err or type(datos) ~= "table" then
			if err then
				noctalia.log("[b3l0w-anilist] stats: " .. err)
			end
			return
		end
		noctalia.state.set(STATS_KEY, datos)
	end)
end

local function handle(req: any): ()
	if type(req) ~= "table" then
		return
	end
	local nonce = tostring(req.nonce or "")
	if nonce ~= "" then
		if nonce == S.lastNonce then
			return
		end
		S.lastNonce = nonce
	end
	local action = tostring(req.action or "")
	if action == "sync" or action == "refresh" then
		sync(true)
	elseif action == "mutate" then
		local mediaId = tonumber(req.mediaId)
		local progress = tonumber(req.progress)
		if mediaId ~= nil and progress ~= nil then
			mutate(mediaId, progress, tostring(req.status or ""))
		end
	elseif action == "discover" then
		discover(tostring(req.kind or "trending"), tonumber(req.page) or 1, tostring(req.tab or "ANIME"))
	elseif action == "view" then
		-- Permite abrir una vista concreta por IPC (y así testear por CLI).
		local view = tostring(req.view or "library")
		local page = tonumber(req.page) or 1
		noctalia.state.set(SCREEN_KEY, {
			tab = tostring(req.tab or "ANIME"),
			view = view,
			page = page,
			preview = req.preview,
			screen = req.screen,
			nonce = tostring(now()) .. ":" .. tostring(req.nonce or ""),
		})
		-- Cambiar de vista sin pedir la página deja al panel mostrando el
		-- catálogo de la página anterior con el número nuevo.
		if view == "discover" then
			local actual = S.discover and tonumber(S.discover.page) or 0
			if actual ~= page then
				discover(tostring(req.kind or (S.discover and S.discover.kind) or "trending"), page, tostring(req.tab or "ANIME"))
			end
		end
	elseif action == "status" then
		publishStatus()
		publishLibrary()
		publishCovers()
	elseif action == "stats" then
		loadStats(req.refresh == true)
	elseif action == "detail" then
		-- Ficha de una serie: la pide el panel al abrir el detalle.
		local mediaId = tonumber(req.mediaId)
		if mediaId ~= nil and mediaId > 0 then
			S.detail = { loading = true, mediaId = mediaId }
			publishDetail()
			fetchDetail(mediaId)
		end
	elseif action == "schedule" then
		-- Agenda de emisión: los capítulos que vienen. `fetchSchedule` se
		-- encarga del estado de carga y de no pisar una consulta en vuelo.
		fetchSchedule()
	elseif action == "filters" then
		-- Los filtros del panel (estado, género, orden). El panel los aplica
		-- sobre la lista publicada; el service los recuerda y los guarda para
		-- que sobrevivan al cierre del panel.
		--
		-- El orden se valida contra la lista real: si se guardara uno que el
		-- panel no conoce, el selector caería en "Recently updated" sin
		-- avisar y el valor persistsente no correspondía con lo que se
		-- veía. Lo mismo con el estado: sólo los de AniList.
		local estado = req.status
		local genero = req.genre
		local orden = req.sort
		local estadoValido = if type(estado) == "string" and ESTADOS[estado] then estado else ""
		local generoValido = if type(genero) == "string" and genero ~= "" then genero else ""
		local ordenValido = if type(orden) == "string" and ORDENES[orden] then orden else "updated"
		S.filters = {
			status = estadoValido,
			genre = generoValido,
			sort = ordenValido,
		}
		saveFilters()
		publishFilters()
	else
		noctalia.log("[b3l0w-anilist] accion desconocida: " .. tostring(action))
		noctalia.notifyError("AniList", "acción desconocida: " .. tostring(action))
	end
end

noctalia.state.watch(REQUEST_KEY, handle)

-- ── ciclo de vida ────────────────────────────────────────────────────

function update(): ()
	if S.busy then
		return
	end
	if S.fetchedAt == 0 then
		sync(false)
		return
	end
	if now() - S.fetchedAt > refreshMinutes() * 60 then
		sync(false)
	end
end

function onEnable(): ()
	loadStats()
	ensureDataDir()
	migrateToken()
	loadFilters()
	publishStatus()
	publishFilters()
	publishSchedule()
	sync(false)
	-- La agenda se pide una vez al habilitar el plugin: así el panel que
	-- abre en la pestaña Emisión ya tiene capítulos y no muestra "no hay
	-- capítulos próximos" mientras la consulta vuelve.
	fetchSchedule()
end

function onIpc(event: string, payload: any): ()
	local req: any = nil
	if type(payload) == "table" then
		req = payload
	elseif type(payload) == "string" and payload ~= "" then
		local decoded = noctalia.json.decode(payload)
		if type(decoded) == "table" then
			req = decoded
		end
	end
	if req == nil then
		req = {}
	end
	req.action = req.action or event
	handle(req)
end

ensureDataDir()
loadCoversCache()
publishStatus()
publishDiscover()
