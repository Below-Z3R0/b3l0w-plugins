--!strict
-- Service de b3l0w/ytmusic: dueño del CLI y de TODO el estado.
--
-- El fetch real (innertube) y la reproducción (mpv) viven en el binario
-- `b3l0w ytmusic`: acá sólo se piden feeds y se publican. Parsear el JSON de
-- YouTube en este callback (1 MB, ~5000 nodos) revienta el presupuesto de
-- 25 ms y el host deshabilita el plugin a los tres timeouts.

local cli = require("./lib/cli.luau")

local HOME_KEY = "b3l0w_ytmusic_home"
local CHARTS_KEY = "b3l0w_ytmusic_charts"
local SEARCH_KEY = "b3l0w_ytmusic_search"
local QUEUE_KEY = "b3l0w_ytmusic_queue"
local PLAYER_KEY = "b3l0w_ytmusic_player"
local STATUS_KEY = "b3l0w_ytmusic_status"
local REQUEST_KEY = "b3l0w_ytmusic_request"
local SCREEN_KEY = "b3l0w_ytmusic_screen"

local FEED_KEY = { home = HOME_KEY, charts = CHARTS_KEY, search = SEARCH_KEY }
local THUMB_LIMIT = 24

local S = {
	dataDir = "",
	thumbsDir = "",
	feeds = {} :: { [string]: any },
	queue = nil :: any,
	player = { playing = false } :: any,
	thumbs = {} :: { [string]: string },
	session = "" :: string,
	busy = false,
	phase = "idle" :: string,
	error = nil :: string?,
	lastNonce = "" :: string,
	playerAt = 0,
	playerActive = false,
	advancing = false,
	tasks = {} :: { () -> () },
}

local function now(): number
	return os.time()
end

-- ── infraestructura ──────────────────────────────────────────────────

local function ensureDataDir(): ()
	if S.dataDir ~= "" then
		return
	end
	local dir = noctalia.pluginDataDir()
	if type(dir) == "string" and dir ~= "" then
		S.dataDir = dir
		S.thumbsDir = dir .. "/thumbs"
	end
end

-- Las dos banderas de ajustes se leen acá y no en el panel: el service es el
-- dueño del argv del CLI.
local function coversEnabled(): boolean
	return noctalia.getConfig("covers") ~= false
end

local function region(): string
	local value = noctalia.getConfig("region")
	if type(value) == "string" then
		return noctalia.string.trim(value)
	end
	return ""
end

-- Argumentos comunes. Las portadas se bajan acá porque ui.image no acepta
-- URLs: sin `--thumbs` las filas quedan con el rectángulo de color.
local function dataArgs(thumbs: boolean?): { string }
	local args: { string } = {}
	if S.dataDir ~= "" then
		table.insert(args, "--data-dir")
		table.insert(args, S.dataDir)
	end
	if thumbs and coversEnabled() and S.thumbsDir ~= "" then
		table.insert(args, "--thumbs")
		table.insert(args, S.thumbsDir)
		table.insert(args, "--limit")
		table.insert(args, tostring(THUMB_LIMIT))
	end
	return args
end

local function append(target: { string }, extra: { string }): ()
	for _, value in ipairs(extra) do
		table.insert(target, value)
	end
end

local function publishStatus(): ()
	noctalia.state.set(STATUS_KEY, {
		busy = S.busy,
		phase = S.phase,
		error = S.error,
		session = S.session,
		playing = S.player ~= nil and S.player.playing == true,
		homeCount = #(((S.feeds.home or {}).items) or {}),
		chartsCount = #(((S.feeds.charts or {}).items) or {}),
		searchCount = #(((S.feeds.search or {}).items) or {}),
		queueCount = #((S.queue or {}).items or {}),
	})
end

local function rememberThumbs(items: any): ()
	if type(items) ~= "table" then
		return
	end
	for _, item in ipairs(items) do
		if type(item) == "table" then
			local path = item.thumb
			if type(path) == "string" and path ~= "" then
				S.thumbs[tostring(item.videoId or "")] = path
			end
		end
	end
end

local function publishPlayer(state: any): ()
	if type(state) ~= "table" then
		state = { playing = false }
	end
	local thumb = S.thumbs[tostring(state.videoId or "")]
	if thumb ~= nil then
		state.thumb = thumb
	end
	S.player = state
	S.playerAt = now()
	-- Se sigue consultando mientras haya proceso: `starting` (yt-dlp
	-- resolviendo) y `ended` (mpv en idle esperando la siguiente) también.
	S.playerActive = state.playing == true or state.starting == true or state.ended == true
	noctalia.state.set(PLAYER_KEY, state)
	publishStatus()
end

local function publishQueue(): ()
	local queue = S.queue
	if type(queue) ~= "table" then
		queue = { session = S.session, items = {}, cursor = 0 }
	end
	noctalia.state.set(QUEUE_KEY, {
		session = tostring(queue.session or S.session),
		seed = tostring(queue.seed or ""),
		items = queue.items or {},
		cursor = tonumber(queue.cursor) or 0,
		at = now(),
	})
	publishStatus()
end

local function publishFeed(kind: string, feed: any): ()
	S.feeds[kind] = feed
	noctalia.state.set(FEED_KEY[kind], feed)
	publishStatus()
end

-- ── cola de tareas ───────────────────────────────────────────────────
-- Una acción durante un fetch no puede perderse: el usuario clickea, no pasa
-- nada y no hay error. Se encola y se drena al terminar.

local function enqueue(task: () -> ()): ()
	table.insert(S.tasks, task)
end

local function drain(): ()
	if S.busy or #S.tasks == 0 then
		return
	end
	local task = table.remove(S.tasks, 1)
	if task ~= nil then
		task()
	end
end

local function beginWork(phase: string): ()
	S.busy = true
	S.phase = phase
	S.error = nil
	publishStatus()
end

local function finishWork(): ()
	S.busy = false
	S.phase = "idle"
	publishStatus()
	drain()
end

-- ── feeds ────────────────────────────────────────────────────────────

local function mergeItems(base: any, extra: any): { any }
	local seen: { [string]: boolean } = {}
	local out: { any } = {}
	for _, list in ipairs({ base or {}, extra or {} }) do
		if type(list) == "table" then
			for _, item in ipairs(list) do
				local id = tostring(item.videoId or "")
				if id ~= "" and not seen[id] then
					seen[id] = true
					table.insert(out, item)
				end
			end
		end
	end
	return out
end

local function feedArgs(kind: string, query: string, continuation: string): { string }
	local args: { string } = { kind }
	if kind == "search" then
		table.insert(args, query)
	end
	table.insert(args, "--json")
	if kind == "charts" then
		local country = region()
		if country ~= "" then
			table.insert(args, "--country")
			table.insert(args, country)
		end
	end
	append(args, dataArgs(true))
	if continuation ~= "" then
		table.insert(args, "--continuation")
		table.insert(args, continuation)
	end
	return args
end

local fetch: (string, string?, string?) -> ()

-- Pide una página. `continuation` no vacío = "cargar más": se appendea a lo que
-- ya está en pantalla, no se reemplaza (infinite pagination real).
function fetch(kind: string, query: string?, continuation: string?): ()
	local searchText = query or ""
	local token = continuation or ""
	if S.busy then
		enqueue(function()
			fetch(kind, searchText, token)
		end)
		return
	end
	ensureDataDir()
	beginWork(kind)

	local previous = S.feeds[kind] or {}
	local current = {
		kind = kind,
		title = tostring(previous.title or ""),
		query = if kind == "search" then searchText else tostring(previous.query or ""),
		items = if token == "" then {} else (previous.items or {}),
		continuation = tostring(previous.continuation or ""),
		loading = true,
		at = tonumber(previous.at) or 0,
	}
	publishFeed(kind, current)

	cli.json("ytmusic", feedArgs(kind, searchText, token), function(payload: any, err: string?)
		if err then
			S.error = kind .. ": " .. err
			current.loading = false
			current.error = S.error
			publishFeed(kind, current)
			finishWork()
			return
		end
		if type(payload) ~= "table" or type(payload.items) ~= "table" then
			S.error = kind .. ": respuesta inesperada del CLI"
			current.loading = false
			publishFeed(kind, current)
			finishWork()
			return
		end
		rememberThumbs(payload.items)
		current.items = mergeItems(if token == "" then {} else previous.items, payload.items)
		current.title = tostring(payload.title or "")
		current.continuation = tostring(payload.continuation or "")
		current.loading = false
		current.error = nil
		current.at = now()
		publishFeed(kind, current)
		-- Traza de una línea por fetch: es la prueba de que la pantalla tiene
		-- datos reales sin necesidad de ver el panel.
		noctalia.log(string.format(
			"[b3l0w-ytmusic] feed=%s items=%d cont=%s primera=%s",
			kind,
			#current.items,
			if current.continuation ~= "" then "si" else "no",
			string.sub(tostring((current.items[1] or {}).title or ""), 1, 32)
		))
		finishWork()
	end)
end

-- ── reproducción ─────────────────────────────────────────────────────

local function playSong(song: any): ()
	if type(song) ~= "table" or tostring(song.videoId or "") == "" then
		return
	end
	local args: { string } = { "play", tostring(song.videoId), "--json" }
	if tostring(song.title or "") ~= "" then
		table.insert(args, "--title")
		table.insert(args, tostring(song.title))
	end
	if tostring(song.artist or "") ~= "" then
		table.insert(args, "--artist")
		table.insert(args, tostring(song.artist))
	end
	if tostring(song.duration or "") ~= "" then
		table.insert(args, "--duration")
		table.insert(args, tostring(song.duration))
	end
	if S.session ~= "" then
		table.insert(args, "--session")
		table.insert(args, S.session)
	end
	append(args, dataArgs(false))
	cli.json("ytmusic", args, function(state: any, err: string?)
		if err then
			S.error = "play: " .. err
			publishStatus()
			noctalia.notifyError("YouTube Music", err)
			return
		end
		if type(state) == "table" then
			noctalia.log(string.format(
				"[b3l0w-ytmusic] play=%s titulo=%s pid=%d",
				tostring(state.videoId or ""),
				string.sub(tostring(state.title or ""), 1, 32),
				tonumber(state.pid) or 0
			))
			-- El título real viene del CLI cuando se clickeó un feed sin metadata.
			if tostring(state.title or "") == "" then
				state.title = tostring(song.title or "")
			end
			publishPlayer(state)
		end
	end)
end

local function applySession(payload: any): ()
	if type(payload) ~= "table" then
		return
	end
	local items = type(payload.queue) == "table" and payload.queue or {}
	rememberThumbs(items)
	S.session = tostring(payload.id or "")
	S.queue = {
		session = S.session,
		seed = tostring(payload.seed or ""),
		items = items,
		cursor = tonumber(payload.cursor) or 0,
	}
	publishQueue()
end

-- Arranca una radio desde un videoId, publica la cola y reproduce la semilla.
-- Esta es la diferencia con el plugin original: la música no sale de un archivo
-- local con canciones ya agregadas, sale del automix de YouTube.
local function startRadio(videoId: string, song: any): ()
	if videoId == "" then
		return
	end
	if S.busy then
		enqueue(function()
			startRadio(videoId, song)
		end)
		return
	end
	ensureDataDir()
	beginWork("radio")
	local args: { string } = { "radio", videoId, "--json", "--limit", "18" }
	append(args, dataArgs(true))
	cli.json("ytmusic", args, function(payload: any, err: string?)
		if err then
			S.error = "radio: " .. err
			finishWork()
			noctalia.notifyError("YouTube Music", err)
			return
		end
		applySession(payload)
		finishWork()
		-- Se reproduce la semilla: es la primera de la cola, pero se busca por id
		-- porque YouTube a veces devuelve otra versión primero.
		local seed = song
		if type(payload) == "table" and type(payload.queue) == "table" then
			for _, item in ipairs(payload.queue) do
				if tostring(item.videoId) == videoId then
					seed = item
					break
				end
			end
		end
		playSong(seed)
	end)
end

local function step(direction: string): ()
	if S.session == "" then
		-- Sin cola: se siembra una radio desde lo que está sonando.
		local playing = S.player or {}
		if tostring(playing.videoId or "") ~= "" then
			startRadio(tostring(playing.videoId), playing)
		end
		return
	end
	if S.busy then
		enqueue(function()
			step(direction)
		end)
		return
	end
	ensureDataDir()
	beginWork(direction)
	local args: { string } = { direction, "--session", S.session, "--play", "--json" }
	append(args, dataArgs(true))
	cli.json("ytmusic", args, function(payload: any, err: string?)
		S.advancing = false
		if err then
			S.error = direction .. ": " .. err
			finishWork()
			return
		end
		if type(payload) ~= "table" then
			finishWork()
			return
		end
		local queue = S.queue or { items = {}, cursor = 0 }
		queue.cursor = tonumber(payload.cursor) or queue.cursor
		queue.session = tostring(payload.session or S.session)
		rememberThumbs({ payload.song })
		publishQueue()
		if type(payload.player) == "table" then
			publishPlayer(payload.player)
		end
		noctalia.log(string.format(
			"[b3l0w-ytmusic] step=%s cancion=%s (%d/%d) pid=%d",
			direction,
			string.sub(tostring((payload.song or {}).title or ""), 1, 32),
			tonumber(payload.cursor) or 0,
			tonumber(payload.queueLength) or 0,
			tonumber(((payload.player or {}).pid)) or 0
		))
		finishWork()
	end)
end

local function togglePause(): ()
	if S.busy then
		enqueue(togglePause)
		return
	end
	ensureDataDir()
	beginWork("pause")
	cli.json("ytmusic", (function()
		local args: { string } = { "pause", "--json" }
		append(args, dataArgs(false))
		return args
	end)(), function(state: any, err: string?)
		if err then
			S.error = "pause: " .. err
		elseif type(state) == "table" then
			publishPlayer(state)
		end
		finishWork()
	end)
end

local function stopPlayback(): ()
	ensureDataDir()
	local args: { string } = { "stop", "--json" }
	append(args, dataArgs(false))
	cli.json("ytmusic", args, function(_state: any, err: string?)
		if err then
			S.error = "stop: " .. err
		end
		publishPlayer({ playing = false })
	end)
end

local function shuffleQueue(): ()
	if S.session == "" then
		return
	end
	if S.busy then
		enqueue(shuffleQueue)
		return
	end
	ensureDataDir()
	beginWork("shuffle")
	local args: { string } = { "shuffle", "--session", S.session, "--json" }
	append(args, dataArgs(false))
	cli.json("ytmusic", args, function(payload: any, err: string?)
		if err then
			S.error = "shuffle: " .. err
			finishWork()
			return
		end
		if type(payload) == "table" and S.queue ~= nil then
			S.queue.items = payload.items or S.queue.items
			S.queue.cursor = tonumber(payload.cursor) or 0
			publishQueue()
		end
		finishWork()
	end)
end

local function seekTo(seconds: number): ()
	ensureDataDir()
	local args: { string } = { "seek", tostring(math.max(0, math.floor(seconds))), "--json" }
	append(args, dataArgs(false))
	cli.json("ytmusic", args, function(state: any, err: string?)
		if err then
			S.error = "seek: " .. err
			return
		end
		if type(state) == "table" then
			publishPlayer(state)
		end
	end)
end

local function refreshPlayer(): ()
	if S.dataDir == "" then
		return
	end
	local args: { string } = { "status", "--json" }
	append(args, dataArgs(false))
	cli.json("ytmusic", args, function(state: any, err: string?)
		if err or type(state) ~= "table" then
			return
		end
		publishPlayer(state)
		-- Auto-avance real: cuando mpv llega al final (eof-reached) o está a un
		-- segundo del final, se pide la siguiente de la cola. Sin esto la radio
		-- se queda muda al terminar cada tema.
		local position = tonumber(state.position) or 0
		local duration = tonumber(state.duration) or 0
		if S.advancing then
			return
		end
		if state.ended == true or (duration > 5 and position >= duration - 1 and state.paused ~= true) then
			S.advancing = true
			step("next")
		end
	end)
end

-- ── requests del panel ───────────────────────────────────────────────

local ACTIONS: { [string]: (any) -> () } = {
	home = function()
		fetch("home")
	end,
	charts = function()
		fetch("charts")
	end,
	search = function(req: any)
		-- Sin texto nuevo se reusa la última consulta: el botón de refrescar del
		-- panel no manda query y un "falta la consulta" sería un error falso.
		local query = tostring(req.query or "")
		if query == "" and type(S.feeds.search) == "table" then
			query = tostring(S.feeds.search.query or "")
		end
		if query == "" then
			return
		end
		fetch("search", query)
	end,
	more = function(req: any)
		fetch(tostring(req.kind or "home"), tostring(req.query or ""), tostring(req.continuation or ""))
	end,
	play_item = function(req: any)
		if type(req.item) == "table" and tostring(req.item.videoId or "") ~= "" then
			startRadio(tostring(req.item.videoId), req.item)
		end
	end,
	radio = function(req: any)
		startRadio(tostring(req.videoId or ""), req.item)
	end,
	next = function()
		step("next")
	end,
	prev = function()
		step("prev")
	end,
	pause = function()
		togglePause()
	end,
	stop = function()
		stopPlayback()
	end,
	shuffle = function()
		shuffleQueue()
	end,
	seek = function(req: any)
		seekTo(tonumber(req.seconds) or 0)
	end,
	queue = function()
		publishQueue()
	end,
	status = function()
		publishStatus()
		publishPlayer(S.player)
		publishQueue()
		if type(S.feeds.home) == "table" then
			publishFeed("home", S.feeds.home)
		end
		if type(S.feeds.charts) == "table" then
			publishFeed("charts", S.feeds.charts)
		end
		if type(S.feeds.search) == "table" then
			publishFeed("search", S.feeds.search)
		end
	end,
	screen = function(req: any)
		-- Permite abrir una pantalla por IPC y así probar el panel sin clickear.
		noctalia.state.set(SCREEN_KEY, {
			screen = tostring(req.screen or "home"),
			tab = tostring(req.tab or ""),
			nonce = tostring(now()) .. ":" .. tostring(req.nonce or ""),
		})
	end,
}

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
	local handler = ACTIONS[action]
	if handler == nil then
		noctalia.log("[b3l0w-ytmusic] accion desconocida: " .. action)
		return
	end
	handler(req)
end

noctalia.state.watch(REQUEST_KEY, handle)

-- ── ciclo de vida ────────────────────────────────────────────────────


function update(): ()
	-- El polling sigue siempre, no sólo cuando `playerActive` lo dice: la
	-- reproducción puede venir de un `b3l0w ytmusic play` externo (o de otra
	-- sesión) y el service tiene que enterarse o la playerbar queda en
	-- "Nothing playing" con la música sonando.
	--
	-- Cada 3 s: el `status` del backend es local (lee un JSON y consulta el
	-- socket de mpv), pero el proceso de Go tiene coste. Con 1 s el service
	-- lanzaba un binario por segundo sin motivo.
	if now() - S.playerAt < 3 then
		return
	end
	refreshPlayer()
end

function onEnable(): ()
	ensureDataDir()
	publishStatus()
	publishQueue()
	publishPlayer({ playing = false })
	fetch("home")
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

function onExit(_signal: number, reason: string?): ()
	-- Sólo se corta la música cuando el plugin se apaga de verdad: en un reload
	-- (editar un .luau) el proceso está detachado y debe seguir sonando.
	if reason == "disable" or reason == "uninstall" then
		local command = "b3l0w ytmusic stop --json"
		if S.dataDir ~= "" then
			command = command .. " --data-dir '" .. S.dataDir .. "'"
		end
		noctalia.runAsync(command)
	end
end

-- ── arranque ─────────────────────────────────────────────────────────

noctalia.setUpdateInterval(1000)
ensureDataDir()
publishStatus()
publishQueue()
publishPlayer({ playing = false })
