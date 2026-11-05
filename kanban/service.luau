--!nonstrict
-- Service de b3l0w/kanban: dueño de los procesos y del estado.
--
-- Todo el trabajo caro (gh) corre con `cli.jsonBin` (runAsync + callback). El
-- panel nunca lanza procesos: publica pedidos en `REQUEST_KEY` y dibuja desde
-- `noctalia.state`. Presupuesto del host: 25 ms de CPU por callback, así que
-- cada respuesta se publica tal cual y el parseo fino lo hace el panel.
--
-- Fuentes del tablero:
--   * "issues"  → `gh issue list`; columnas = estado (open/closed); mover =
--                 cerrar/reabrir.
--   * "project" → `gh project item-list`; columnas = opciones del campo Status;
--                 mover = `gh project item-edit`. Requiere scope read:project.

local cli = require("./lib/cli.luau")
local store = require("./lib/store.luau")
local gh = require("./lib/github.luau")

local STATUS_KEY = "b3l0w_kanban_status"
local BOARD_KEY = "b3l0w_kanban_board"
local META_KEY = "b3l0w_kanban_meta"
local REQUEST_KEY = "b3l0w_kanban_request"
local SCREEN_KEY = "b3l0w_kanban_screen"
local FEED_KEY = "b3l0w_kanban_feed"

local S = {
	busy = false,
	phase = "idle",
	error = nil,
	at = 0,
	auth = "checking",
	authAt = 0,
	authTries = 0,
	seq = 0,
	feedSeq = 0,
	lastNonce = "",
	lastBoardAt = 0,
	lastNotifAt = 0,
	lastFeedAt = 0,
	view = { source = "issues", repo = "", project = 0, owner = "" },
	board = nil,
	meta = nil,
	feed = nil,
	pending = nil,
	started = false,
}

local function now(): number
	return os.time()
end

-- Traza de estado: sin esto un proceso rechazado por el host (o un chequeo
-- que nunca responde) no deja ni una línea y el panel se ve "vacío" sin causa.
local function trace(where: string, extra: string?): ()
	noctalia.log("[b3l0w-kanban] " .. where
		.. " auth=" .. tostring(S.auth)
		.. " busy=" .. tostring(S.busy)
		.. " phase=" .. tostring(S.phase)
		.. " seq=" .. tostring(S.seq)
		.. " boardAt=" .. tostring(S.lastBoardAt)
		.. " cards=" .. tostring(S.board ~= nil and S.board.total or "nil")
		.. " " .. tostring(extra))
end

local function cfg_string(key: string, fallback: string): string
	local value = noctalia.getConfig(key)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return fallback
end

local function cfgInt(key: string, fallback: number, low: number, high: number): number
	local value = tonumber(noctalia.getConfig(key))
	if value == nil then
		return fallback
	end
	return math.clamp(value, low, high)
end

local function cfgBool(key: string, fallback: boolean): boolean
	local value = noctalia.getConfig(key)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function feedT(): any
	if type(S.feed) ~= "table" then
		S.feed = {}
	end
	return S.feed
end

local function metaT(): any
	if type(S.meta) ~= "table" then
		S.meta = { repos = {}, projects = {}, viewer = {} }
	end
	return S.meta
end

-- ── publicación ───────────────────────────────────────────────────────

local function publish_status(): ()
	local board = S.board
	local meta = metaT()
	local feed = feedT()
	local viewer = type(meta.viewer) == "table" and meta.viewer or {}
	noctalia.state.set(STATUS_KEY, {
		busy = S.busy,
		phase = S.phase,
		error = S.error,
		auth = S.auth,
		at = S.at,
		source = S.view.source,
		repo = S.view.repo,
		project = S.view.project,
		owner = S.view.owner,
		columns = board and #gh.asList(board.columns) or 0,
		cards = board and tonumber(board.total) or 0,
		unread = tonumber(feed.unread) or 0,
		login = tostring(viewer.login or ""),
	})
end

local function publish_board(): ()
	noctalia.state.set(BOARD_KEY, S.board or { columns = {}, total = 0, source = S.view.source, repo = S.view.repo })
end

-- El tablero se persiste para pintar al instante en el próximo arranque: sin
-- esto, cada reinicio de la shell deja el panel vacío hasta que gh responde.
local function save_board(): ()
	if type(S.board) == "table" and #gh.asList(S.board.columns) > 0 then
		store.save("board.json", S.board)
	end
end

local function publish_meta(): ()
	noctalia.state.set(META_KEY, metaT())
end

-- ── selección de repositorio ───────────────────────────────────────────

-- `gh issue list` responde con `[]` (sin error) cuando el repo TIENE los
-- issues habilitados pero no tiene ninguno: es un tablero vacío de verdad,
-- no un fallo. Y responde con error ("the repository has disabled issues")
-- cuando el repo los tiene deshabilitados: ese tablero NO se puede
-- mostrar nunca y hay que decirlo.
--
-- Sin esto los dos casos se veían igual: columnas vacías y ninguna
-- explicación, y el usuario leía "el kanban tiene contenido que no se
-- llega a ver" cuando en realidad no había nada que mostrar.
local function classify_issue_error(err: string): (string, string?)
	local lower = string.lower(err)
	if string.find(lower, "disabled issues", 1, true) then
		return "issues_disabled", err
	end
	if string.find(lower, "could not resolve to a repository", 1, true)
		or string.find(lower, "not found", 1, true)
		or string.find(lower, "no such repository", 1, true) then
		return "invalid_repo", err
	end
	return "error", err
end

-- El repo por defecto: el primero con issues HABILITADAS y con issues
-- ABIERTAS. `gh repo list` no ordena por nada útil y el primero era
-- `community-templates-1` (issues deshabilitados): el tablero salía mudo
-- siempre. Sin issues abiertas en ningún repo se cae al primero con los
-- issues habilitados (mejor un repo vacío que uno que no puede mostrar
-- issues) y, si tampoco hay, al primero de la lista.
local function pick_default_repo(repos: { any }): (string, string)
	local withIssues = ""
	local withOpen = ""
	local openCount = 0
	for _, repo in ipairs(repos) do
		if type(repo) == "table" then
			local name = tostring(repo.nameWithOwner or "")
			if name == "" then
				continue
			end
			if repo.hasIssuesEnabled == true then
				if withIssues == "" then
					withIssues = name
				end
				local count = tonumber((type(repo.issues) == "table" and repo.issues.totalCount) or 0) or 0
				if count > openCount then
					withOpen = name
					openCount = count
				end
			end
		end
	end
	if withOpen ~= "" then
		return withOpen, "issues abiertas: " .. tostring(openCount)
	end
	if withIssues ~= "" then
		return withIssues, "issues habilitadas (sin issues abiertas)"
	end
	local first = ""
	for _, repo in ipairs(repos) do
		if type(repo) == "table" and tostring(repo.nameWithOwner or "") ~= "" then
			first = tostring(repo.nameWithOwner)
			break
		end
	end
	return first, "sin issues habilitadas"
end

local function publish_feed(): ()
	noctalia.state.set(FEED_KEY, feedT())
end

local function saveView(): ()
	store.save("view.json", S.view)
end

local function finish(phase: string): ()
	S.busy = false
	S.phase = "idle"
	S.at = now()
	publish_status()
	if phase ~= "" then
		noctalia.log("[b3l0w-kanban] " .. phase)
	end
end

-- ── tablero ───────────────────────────────────────────────────────────

local function labelList(raw: any): { any }
	local out = {}
	for _, item in ipairs(gh.asList(raw)) do
		if type(item) == "table" then
			out[#out + 1] = { name = tostring(item.name or ""), color = tostring(item.color or "") }
		end
	end
	return out
end

local function loginList(raw: any): { string }
	local out = {}
	for _, item in ipairs(gh.asList(raw)) do
		if type(item) == "table" then
			out[#out + 1] = tostring(item.login or "")
		elseif type(item) == "string" then
			out[#out + 1] = item
		end
	end
	return out
end

local function sort_cards(cards: { any }): { any }
	table.sort(cards, function(a: any, b: any)
		return tostring(a.updatedAt or "") > tostring(b.updatedAt or "")
	end)
	return cards
end

local function issues_board(items: any): any
	local open_cards = {}
	local closed_cards = {}
	local total = 0
	for _, item in ipairs(gh.asList(items)) do
		if type(item) == "table" then
			local state = string.lower(tostring(item.state or "open"))
			local card = {
				id = tostring(item.number or ""),
				number = tonumber(item.number) or 0,
				title = tostring(item.title or ""),
				url = tostring(item.url or ""),
				state = state,
				updatedAt = tostring(item.updatedAt or ""),
				author = type(item.author) == "table" and tostring(item.author.login or "") or "",
				comments = 0,
				labels = labelList(item.labels),
				assignees = loginList(item.assignees),
				itemId = "",
			}
			if state == "closed" then
				closed_cards[#closed_cards + 1] = card
			else
				open_cards[#open_cards + 1] = card
			end
			total += 1
		end
	end
	return {
		source = "issues",
		repo = S.view.repo,
		total = total,
		at = now(),
		columns = {
			{ id = "open", name = "Open", state = "open", cards = sort_cards(open_cards) },
			{ id = "closed", name = "Closed", state = "closed", cards = sort_cards(closed_cards) },
		},
	}
end

local function project_board(fields: any, items: any): any
	local wanted = cfg_string("board_status_field", "Status")
	local status_field = nil
	for _, field in ipairs(gh.list(fields, "fields")) do
		if type(field) == "table" and tostring(field.name or "") == wanted then
			status_field = field
		end
	end
	if status_field == nil then
		for _, field in ipairs(gh.list(fields, "fields")) do
			if type(field) == "table" and type(field.options) == "table" and #field.options > 0 then
				status_field = field
				break
			end
		end
	end
	local columns = {}
	local byName = {}
	local options = {}
	local function column(name: string): any
		local key = tostring(name)
		local existing = byName[key]
		if existing ~= nil then
			return existing
		end
		local created = { id = key, name = key, cards = {} }
		byName[key] = created
		columns[#columns + 1] = created
		return created
	end
	for _, option in ipairs(status_field ~= nil and gh.asList(status_field.options) or {}) do
		if type(option) == "table" then
			local name = tostring(option.name or "")
			options[name] = tostring(option.id or "")
			column(name)
		end
	end
	local total = 0
	for _, item in ipairs(gh.list(items, "items")) do
		if type(item) == "table" then
			local content = type(item.content) == "table" and item.content or {}
			local name = tostring(item.status or item.Status or content.status or "")
			if name == "" then
				name = tostring(item["status"] or "")
			end
			if name == "" then
				name = "No status"
			end
			local target = column(name)
			target.cards[#target.cards + 1] = {
				id = tostring(item.id or tostring(content.number or "")),
				itemId = tostring(item.id or ""),
				number = tonumber(content.number) or 0,
				title = tostring(content.title or item.title or ""),
				url = tostring(content.url or item.url or ""),
				state = string.lower(tostring(content.state or "")),
				updatedAt = tostring(item.updatedAt or content.updatedAt or ""),
				author = type(content.author) == "table" and tostring(content.author.login or "") or "",
				comments = 0,
				labels = labelList(content.labels),
				assignees = loginList(content.assignees),
				kind = tostring(content.type or ""),
			}
			total += 1
		end
	end
	for _, col in ipairs(columns) do
		sort_cards(col.cards)
	end
	return {
		source = "project",
		repo = S.view.repo,
		project = S.view.project,
		owner = S.view.owner,
		projectId = "",
		fieldId = status_field ~= nil and tostring(status_field.id or "") or "",
		options = options,
		total = total,
		at = now(),
		columns = columns,
	}
end

-- El proyecto (PVT_...) y su id no vienen en item-list: se resuelven del listado
-- que ya trajo `discover`. Sin eso, mover una tarjeta no tiene project-id.
local function project_meta(number: number): any
	local meta = metaT()
	for _, project in ipairs(gh.asList(meta.projects)) do
		if type(project) == "table" and tonumber(project.number) == number then
			return project
		end
	end
	return nil
end

local function refresh_board(): ()
	S.seq += 1
	local seq = S.seq
	S.busy = true
	S.phase = "board"
	publish_status()

	local source = S.view.source
	if source == "project" then
		if tonumber(S.view.project) == nil or tonumber(S.view.project) <= 0 then
			S.board = { source = "project", columns = {}, total = 0, note = "no_project", at = now() }
			S.lastBoardAt = now()
			publish_board()
			finish("sin proyecto seleccionado")
			return
		end
		local owner = S.view.owner ~= "" and S.view.owner or tostring((metaT().viewer or {}).login or "")
		if owner == "" then
			S.board = { source = "project", columns = {}, total = 0, note = "no_project", at = now() }
			S.lastBoardAt = now()
			publish_board()
			finish("sin owner para el proyecto")
			return
		end
		local limit = cfgInt("board_cards_per_column", 25, 5, 100)
		cli.jsonBin("gh", gh.projectFields(S.view.project, owner), function(fields: any, err: string?)
			if seq ~= S.seq then
				return
			end
			if err then
				S.error = err
				finish("field-list falló: " .. err)
				return
			end
			cli.jsonBin("gh", gh.projectItems(S.view.project, owner, limit), function(items: any, err2: string?)
				if seq ~= S.seq then
					return
				end
				if err2 then
					S.error = err2
					finish("item-list falló: " .. err2)
					return
				end
				local board = project_board(fields, items)
				local project = project_meta(tonumber(S.view.project) or 0)
				if project ~= nil then
					board.projectId = tostring(project.id or "")
				end
				-- Un proyecto sin items tampoco es un tablero mudo: el panel
				-- tiene que decirlo (las columnas del Status field existen
				-- siempre, así que sin esto se veían 3 columnas vacías).
				if board.total == 0 then
					board.note = "no_project_items"
				end
				S.board = board
				S.error = nil
				S.lastBoardAt = now()
				publish_board()
				save_board()
				finish("tablero de proyecto: " .. tostring(board.total) .. " tarjetas")
			end)
		end)
		return
	end

	if S.view.repo == "" then
		S.board = { source = "issues", columns = {}, total = 0, note = "no_repo", at = now() }
		-- Sin esto, update() vuelve a pedir el tablero en cada tick (lastBoardAt
		-- en 0) y el log se llena del mismo mensaje.
		S.lastBoardAt = now()
		publish_board()
		finish("sin repositorio seleccionado")
		return
	end
	local issueLimit = cfgInt("board_cards_per_column", 25, 5, 100) * 2
	cli.jsonBin("gh", gh.issueList(S.view.repo, issueLimit, "all"), function(items: any, err: string?)
		if seq ~= S.seq then
			return
		end
		if err then
			-- Un fallo de permisos, un repo sin issues o un repo que no
			-- existe NO es un tablero vacío: se guarda el motivo para que el
			-- panel lo muestre en vez de quedarse girando.
			--
			-- El motivo se CLASSIFICA: "issues deshabilitados" y "repo
			-- inválido" son cosas distintas y cada una necesita su texto.
			-- Con el texto crudo de gh el panel decía "the 'X' repository
			-- has disabled issues" (en inglés y sin contexto).
			--
			-- `S.error` queda en nil para los casos clasificados: el panel
			-- muestra su mensaje y el motivo crudo queda en `board.error`
			-- (y en el log). Con `S.error` puesto, el panel pintaba el
			-- texto de gh en vez del mensaje que explica qué hacer.
			local kind, detail = classify_issue_error(err)
			S.error = if kind == "error" then detail else nil
			S.board = {
				source = "issues",
				columns = {},
				total = 0,
				note = kind,
				error = detail,
				at = now(),
			}
			S.lastBoardAt = now()
			publish_board()
			publish_status()
			finish("issue list falló (" .. kind .. "): " .. err)
			return
		end
		S.board = issues_board(items)
		S.error = nil
		-- Repo con los issues habilitados pero sin ninguno: el tablero está
		-- vacío de verdad. Antes se publicaban las columnas igual y el panel
		-- pintaba 2-3 columnas vacías sin explicar nada.
		if S.board.total == 0 then
			S.board.note = "no_issues"
			S.board.empty = true
		end
		S.lastBoardAt = now()
		publish_board()
		save_board()
		finish("tablero de issues: " .. tostring(S.board.total) .. " tarjetas")
	end)
end

-- ── metadatos: repos, proyectos y login ───────────────────────────────

-- Sin el scope read:project esto devuelve error; se guarda y el panel lo
-- muestra en el selector en vez de dejar la lista vacía sin explicación.
local function load_projects(owner: string): ()
	if owner == "" then
		return
	end
	local meta = metaT()
	cli.jsonBin("gh", gh.projects(owner), function(rows: any, err: string?)
		if err then
			meta.projectsError = err
			meta.projects = {}
			publish_meta()
			return
		end
		meta.projects = gh.list(rows, "projects")
		meta.projectsError = ""
		publish_meta()
	end)
end

-- El chequeo de auth va aparte de load_meta porque el host puede rechazar el
-- proceso (runAsync devuelve false y el callback no llega): update() lo
-- reintenta mientras S.auth siga en "checking".
local function check_auth(): ()
	S.authAt = now()
	S.authTries += 1
	cli.jsonBin("gh", gh.user(), function(user: any, err: string?)
		if err then
			S.auth = "auth_error"
			S.error = err
			noctalia.log("[b3l0w-kanban] auth_error: " .. err)
			publish_status()
			return
		end
		local meta = metaT()
		if type(user) == "table" then
			-- `ui.image` sólo lee rutas locales: la URL del avatar se descarga
			-- una vez al data dir y se publica la ruta. Sin esto el panel sólo
			-- podía mostrar un glifo de reemplazo.
			local url = tostring(user.avatar_url or "")
			if url ~= "" then
				local ok, dir = pcall(function()
					return noctalia.pluginDataDir()
				end)
				if ok and type(dir) == "string" and dir ~= "" then
					local destino = dir .. "/avatar.png"
					user.avatarPath = destino
					cli.textBin("curl", { "-sL", "--max-time", "10", url, "-o", destino }, function(_cuerpo: string?, error: string?)
						if error then
							user.avatarPath = nil
							noctalia.log("[b3l0w-kanban] avatar falló: " .. error)
						else
							noctalia.log("[b3l0w-kanban] avatar ok: " .. destino)
						end
						-- El panel abrió antes de que terminara la descarga: sin este
						-- publish se queda con el glifo hasta el próximo refresco.
						publish_meta()
					end)
				end
			end
			meta.viewer = user
			S.auth = "ok"
			noctalia.log("[b3l0w-kanban] auth=ok login=" .. tostring(user.login or ""))
			publish_meta()
			publish_status()
			if cfg_string("board_project_owner", "") == "" and tostring(user.login or "") ~= "" then
				S.view.owner = tostring(user.login)
				load_projects(S.view.owner)
			end
			-- Sin repo guardado, el listado siguiente lo elige.
			if S.view.repo == "" then
				refresh_board()
			end
		end
	end)
end

local function load_meta(reload: boolean): ()
	local meta = metaT()
	if reload then
		meta.repos = {}
		meta.projects = {}
	end
	publish_meta()
	check_auth()
	cli.jsonBin("gh", gh.repos(40), function(rows: any, err: string?)
		if err then
			meta.reposError = err
			publish_meta()
			return
		end
		meta.repos = gh.asList(rows)
		meta.reposError = ""
		publish_meta()
		if S.view.repo == "" and #meta.repos > 0 then
			-- El repo por defecto NO es el primero de la lista: es el
			-- primero con issues habilitadas (y con issues abiertas si
			-- hay). Antes era `meta.repos[1]`, que fue
			-- `community-templates-1` (issues deshabilitados) y dejaba el
			-- tablero mudo para siempre.
			local elegido, motivo = pick_default_repo(meta.repos)
			if elegido ~= "" then
				S.view.repo = elegido
				saveView()
				publish_status()
				refresh_board()
				noctalia.log("[b3l0w-kanban] repo por defecto: " .. elegido .. " (" .. motivo .. ")")
			end
		end
	end)
	local owner = cfg_string("board_project_owner", "")
	load_projects(owner)
end

-- ── feeds: notificaciones, actividad, following, overview ─────────────

local function refresh_notifications(): ()
	local feed = feedT()
	cli.jsonBin("gh", gh.notifications(25), function(rows: any, err: string?)
		if err then
			feed.notificationsError = err
			publish_feed()
			return
		end
		local unread = 0
		local items = {}
		for _, row in ipairs(gh.asList(rows)) do
			if type(row) == "table" then
				if row.unread == true then
					unread += 1
				end
				items[#items + 1] = {
					id = tostring(row.id or ""),
					unread = row.unread == true,
					reason = tostring(row.reason or ""),
					updatedAt = tostring(row.updated_at or ""),
					title = tostring(row.title or ""),
					kind = tostring(row.kind or ""),
					url = tostring(row.url or ""),
					repository = tostring(row.repository or ""),
				}
			end
		end
		feed.notifications = items
		feed.unread = unread
		feed.notificationsError = ""
		S.lastNotifAt = now()
		publish_feed()
		publish_status()
	end)
end

local function merge_search(target: { any }, seen: { [string]: boolean }, rows: any, scope: string, kind: string)
	for _, row in ipairs(gh.asList(rows)) do
		if type(row) == "table" then
			local repo = type(row.repository) == "table" and tostring(row.repository.nameWithOwner or "") or ""
			local key = kind .. ":" .. repo .. "#" .. tostring(row.number or "")
			if not seen[key] then
				seen[key] = true
				target[#target + 1] = {
					number = tonumber(row.number) or 0,
					title = tostring(row.title or ""),
					state = string.lower(tostring(row.state or "")),
					updatedAt = tostring(row.updatedAt or ""),
					url = tostring(row.url or ""),
					repository = repo,
					kind = kind,
					scope = scope,
				}
			end
		end
	end
end

local function refresh_activity(): ()
	local feed = feedT()
	-- El panel muestra este error: si no se limpia al empezar, un fallo
	-- transitorio deja la pestaña con el cartel para siempre.
	feed.activityError = ""
	local prs = {}
	local seenPr = {}
	local issues = {}
	local seenIssue = {}
	cli.jsonBin("gh", gh.searchPrs("created", 20), function(rows: any, err: string?)
		if err then
			feed.activityError = err
			publish_feed()
			return
		end
		merge_search(prs, seenPr, rows, "created", "pr")
		feed.prs = prs
		publish_feed()
	end)
	cli.jsonBin("gh", gh.searchPrs("review", 20), function(rows: any, err: string?)
		if err then
			return
		end
		merge_search(prs, seenPr, rows, "review", "pr")
		feed.prs = prs
		publish_feed()
	end)
	cli.jsonBin("gh", gh.searchIssues("created", 20), function(rows: any, err: string?)
		if err then
			feed.activityError = err
			publish_feed()
			return
		end
		merge_search(issues, seenIssue, rows, "created", "issue")
		feed.issues = issues
		publish_feed()
	end)
	cli.jsonBin("gh", gh.searchIssues("assigned", 20), function(rows: any, err: string?)
		if err then
			return
		end
		merge_search(issues, seenIssue, rows, "assigned", "issue")
		feed.issues = issues
		publish_feed()
	end)
	if S.view.repo ~= "" then
		cli.jsonBin("gh", gh.runs(S.view.repo, 5), function(rows: any, err: string?)
			if err then
				return
			end
			local runs = {}
			for _, row in ipairs(gh.asList(rows)) do
				if type(row) == "table" then
					runs[#runs + 1] = {
						id = tostring(row.databaseId or ""),
						name = tostring(row.workflowName or row.name or ""),
						status = tostring(row.status or ""),
						conclusion = tostring(row.conclusion or ""),
						branch = tostring(row.headBranch or ""),
						url = tostring(row.url or ""),
						createdAt = tostring(row.createdAt or ""),
					}
				end
			end
			feed.runs = runs
			publish_feed()
		end)
	end
end

local function refresh_following(): ()
	local feed = feedT()
	feed.followingError = ""
	local login = tostring((metaT().viewer or {}).login or "")
	if login == "" then
		return
	end
	local limit = cfgInt("following_events_per_user", 15, 1, 30)
	cli.jsonBin("gh", gh.events(login, limit), function(rows: any, err: string?)
		if err then
			feed.followingError = err
			publish_feed()
			return
		end
		local events = {}
		for _, row in ipairs(gh.asList(rows)) do
			if type(row) == "table" then
				events[#events + 1] = {
					id = tostring(row.id or ""),
					type = tostring(row.type or ""),
					createdAt = tostring(row.created_at or ""),
					repo = tostring(row.repo or ""),
					actor = tostring(row.actor or ""),
					actorType = tostring(row.actor_type or ""),
					action = tostring(row.action or ""),
					ref = tostring(row.ref or ""),
					refType = tostring(row.ref_type or ""),
					prTitle = tostring(row.pr_title or ""),
					prUrl = tostring(row.pr_url or ""),
					issueTitle = tostring(row.issue_title or ""),
					issueUrl = tostring(row.issue_url or ""),
					releaseName = tostring(row.release_name or row.release_tag or ""),
					releaseUrl = tostring(row.release_url or ""),
					releasePre = row.release_pre == true,
					forkee = tostring(row.forkee or ""),
					forkeeUrl = tostring(row.forkee_url or ""),
					commit = tostring(row.commit or ""),
				}
			end
		end
		feed.events = events
		publish_feed()
	end)
	local starLimit = cfgInt("starred_repository_limit", 30, 10, 100)
	cli.jsonBin("gh", gh.starredReleases(starLimit), function(payload: any, err: string?)
		if err then
			return
		end
		local nodes = type(payload) == "table" and type(payload.data) == "table"
			and type(payload.data.viewer) == "table"
			and type(payload.data.viewer.starredRepositories) == "table"
			and payload.data.viewer.starredRepositories.nodes or {}
		local releases = {}
		for _, node in ipairs(gh.asList(nodes)) do
			local list = type(node) == "table" and type(node.releases) == "table" and node.releases.nodes or {}
			for _, rel in ipairs(gh.asList(list)) do
				if type(rel) == "table" then
					releases[#releases + 1] = {
						repo = tostring(node.nameWithOwner or ""),
						name = tostring(rel.name or rel.tagName or ""),
						url = tostring(rel.url or ""),
						publishedAt = tostring(rel.publishedAt or ""),
						prerelease = rel.isPrerelease == true,
					}
				end
			end
		end
		feed.releases = releases
		publish_feed()
	end)
end

local function refresh_overview(): ()
	local feed = feedT()
	cli.jsonBin("gh", gh.contributions(), function(payload: any, err: string?)
		if err then
			return
		end
		local cal = type(payload) == "table" and type(payload.data) == "table"
			and type(payload.data.viewer) == "table"
			and type(payload.data.viewer.contributionsCollection) == "table"
			and type(payload.data.viewer.contributionsCollection.contributionCalendar) == "table"
			and payload.data.viewer.contributionsCollection.contributionCalendar or nil
		if cal == nil then
			return
		end
		local weeks = {}
		for _, week in ipairs(gh.asList(cal.weeks)) do
			local days = {}
			for _, day in ipairs(gh.asList(type(week) == "table" and week.contributionDays or {})) do
				if type(day) == "table" then
					days[#days + 1] = { date = tostring(day.date or ""), count = tonumber(day.contributionCount) or 0 }
				end
			end
			weeks[#weeks + 1] = days
		end
		feed.calendar = { total = tonumber(cal.totalContributions) or 0, weeks = weeks }
		publish_feed()
	end)
end

local function refresh_feeds(): ()
	S.feedSeq += 1
	local seq = S.feedSeq
	S.lastFeedAt = now()
	publish_feed()
	-- Cada dataset publica por su cuenta: la UI muestra notificaciones mientras
	-- el calendario todavía está en vuelo.
	refresh_notifications()
	refresh_activity()
	refresh_following()
	refresh_overview()
	if seq ~= S.feedSeq then
		noctalia.log("[b3l0w-kanban] feed descartado por secuencia")
	end
end

local function refresh_all(): ()
	load_meta(false)
	refresh_board()
	refresh_feeds()
end

-- ── mutaciones ────────────────────────────────────────────────────────

local function find_card(id: string): any
	local board = S.board
	if type(board) ~= "table" then
		return nil
	end
	for _, col in ipairs(gh.asList(board.columns)) do
		for _, card in ipairs(gh.asList(col.cards)) do
			if tostring(card.id) == id then
				return card, tostring(col.name or "")
			end
		end
	end
	return nil
end

local function move_card(id: string, target: string): ()
	local board = S.board
	if type(board) ~= "table" then
		return
	end
	local card = find_card(id)
	if card == nil then
		S.error = "tarjeta inexistente: " .. id
		noctalia.log("[b3l0w-kanban] move: tarjeta inexistente " .. id)
		publish_status()
		return
	end
	S.phase = "move"
	S.busy = true
	publish_status()
	if board.source == "project" then
		local optionId = type(board.options) == "table" and tostring(board.options[target] or "") or ""
		if board.projectId == "" or board.fieldId == "" or optionId == "" then
			S.error = "proyecto sin campo/opción para mover"
			finish("mover sin metadatos")
			return
		end
		cli.textBin("gh", gh.projectItemMove(board.projectId, tostring(card.itemId or ""), board.fieldId, optionId), function(_out: string?, err: string?)
			if err then
				S.error = err
				noctalia.notifyError("Kanban", err)
			else
				noctalia.notify("Kanban", noctalia.tr("status.moved"))
				noctalia.log("[b3l0w-kanban] move " .. id .. " -> " .. target)
			end
			finish("move proyecto")
			refresh_board()
		end)
		return
	end
	local argv = if target == "closed"
		then gh.issueClose(S.view.repo, tonumber(card.number) or 0)
		else gh.issueReopen(S.view.repo, tonumber(card.number) or 0)
	cli.textBin("gh", argv, function(_out: string?, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Kanban", err)
		else
			noctalia.notify("Kanban", noctalia.tr("status.moved"))
			noctalia.log("[b3l0w-kanban] move " .. id .. " -> " .. target)
		end
		finish("move issue")
		refresh_board()
	end)
end

local function create_issue(req: any): ()
	local repo = tostring(req.repo or S.view.repo)
	local title = tostring(req.title or "")
	if title == "" or repo == "" then
		S.error = "falta título o repositorio"
		publish_status()
		return
	end
	local argv = gh.issueCreate(repo)
	table.insert(argv, "--title")
	table.insert(argv, title)
	local body = tostring(req.body or "")
	if body ~= "" then
		table.insert(argv, "--body")
		table.insert(argv, body)
	end
	local labels = tostring(req.labels or "")
	for label in string.gmatch(labels .. ",", "([^,]+),") do
		local limpio = string.gsub(label, "^%s*(.-)%s*$", "%1")
		if limpio ~= "" then
			table.insert(argv, "--label")
			table.insert(argv, limpio)
		end
	end
	S.phase = "create"
	S.busy = true
	publish_status()
	cli.textBin("gh", argv, function(out: string?, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Kanban", err)
			finish("create falló")
			return
		end
		local url = string.match(out or "", "(https://github%.com/%S+)") or ""
		noctalia.notify("Kanban", noctalia.tr("status.created"))
		noctalia.state.set(SCREEN_KEY, { tab = "board", url = url, nonce = tostring(now()) .. ":" .. tostring(S.seq) })
		finish("issue creada")
		refresh_board()
	end)
end

local function open_url(url: string): ()
	if not cfgBool("open_links", true) then
		return
	end
	if not noctalia.commandExists("xdg-open") then
		noctalia.notifyError("Kanban", noctalia.tr("status.missing_xdg_open"))
		return
	end
	if url ~= "" then
		noctalia.runAsync({ "xdg-open", url })
	end
end

local function mark_read(id: string, all: boolean): ()
	local argv = if all then gh.notificationsReadAll() else gh.notificationRead(id)
	cli.textBin("gh", argv, function(_out: string?, err: string?)
		if err then
			noctalia.notifyError("Kanban", err)
			return
		end
		refresh_notifications()
	end)
end

-- ── requests ──────────────────────────────────────────────────────────

local function handle(req: any): ()
	if type(req) ~= "table" then
		return
	end
	local nonce = tostring(req.nonce or "")
	trace("handle", "action=" .. tostring(req.action) .. " nonce=" .. nonce)
	if nonce ~= "" then
		if nonce == S.lastNonce then
			return
		end
		S.lastNonce = nonce
	end
	local action = tostring(req.action or "")
	if action == "refresh" then
		refresh_all()
	elseif action == "discover" then
		load_meta(true)
	elseif action == "set_repo" then
		S.view.repo = tostring(req.repo or "")
		saveView()
		-- Publicar primero: el switcher se cierra al instante y el tablero
		-- llega cuando gh termina.
		S.board = { source = S.view.source, columns = {}, total = 0, at = now() }
		publish_status()
		publish_board()
		refresh_board()
		refresh_feeds()
	elseif action == "set_source" then
		S.view.source = if tostring(req.source or "") == "project" then "project" else "issues"
		saveView()
		S.board = { source = S.view.source, columns = {}, total = 0, at = now() }
		publish_status()
		publish_board()
		refresh_board()
	elseif action == "set_project" then
		S.view.project = tonumber(req.project) or 0
		if req.owner ~= nil and tostring(req.owner) ~= "" then
			S.view.owner = tostring(req.owner)
		end
		S.view.source = "project"
		saveView()
		publish_status()
		refresh_board()
	elseif action == "move" then
		move_card(tostring(req.id or ""), tostring(req.target or ""))
	elseif action == "create" then
		create_issue(req)
	elseif action == "open" then
		open_url(tostring(req.url or ""))
	elseif action == "mark_read" then
		mark_read(tostring(req.id or ""), false)
	elseif action == "mark_all_read" then
		mark_read("", true)
	elseif action == "view" then
		noctalia.state.set(SCREEN_KEY, {
			tab = tostring(req.tab or "board"),
			nonce = tostring(now()) .. ":" .. nonce,
		})
	else
		noctalia.log("[b3l0w-kanban] acción desconocida: " .. action)
		noctalia.notifyError("Kanban", "acción desconocida: " .. action)
	end
end

noctalia.state.watch(REQUEST_KEY, handle)

-- ── ciclo de vida ─────────────────────────────────────────────────────

local function restore(): ()
	-- Los [[setting]] son el default inicial; view.json (lo guardado) pisa.
	S.view.source = if cfg_string("board_source", "issues") == "project" then "project" else "issues"
	S.view.repo = cfg_string("board_repo", "")
	S.view.project = cfgInt("board_project_number", 0, 0, 999999)
	S.view.owner = cfg_string("board_project_owner", "")
	local saved = store.load("view.json")
	if type(saved) == "table" then
		if type(saved.repo) == "string" and saved.repo ~= "" then
			S.view.repo = saved.repo
		end
		if saved.source == "project" or saved.source == "issues" then
			S.view.source = saved.source
		end
		-- 0 = "sin definir": no debe pisar el número configurado en Ajustes.
		local savedProject = tonumber(saved.project) or 0
		if savedProject > 0 then
			S.view.project = savedProject
		end
		if type(saved.owner) == "string" and saved.owner ~= "" then
			S.view.owner = saved.owner
		end
	end
	local cached = store.load("board.json")
	if type(cached) == "table" and type(cached.columns) == "table" then
		S.board = cached
		publish_board()
	end
end

function update(): ()
	-- Primero relanzar lo que el host rechazó (runAsync devolvió false): si no,
	-- esos callbacks no llegan nunca y el estado se queda en el inicial.
	local relanzados = cli.pump()
	if relanzados > 0 then
		trace("pump", "relanzados=" .. tostring(relanzados))
	end
	-- Watchdog de auth: "checking" es el estado inicial, así que si seguimos ahí
	-- el chequeo no llegó al host. Se reintenta hasta 20 veces.
	if S.auth == "checking" and S.authTries < 20 and now() - S.authAt >= 5 then
		trace("auth-watchdog", "retry=" .. tostring(S.authTries + 1))
		check_auth()
	end
	if S.busy then
		return
	end
	local minutes = cfgInt("refresh_interval_minutes", 15, 1, 240)
	if now() - S.lastBoardAt >= minutes * 60 then
		refresh_board()
	end
	local notifSeconds = cfgInt("notification_refresh_interval_seconds", 120, 30, 900)
	if cfgBool("show_notifications", true) and now() - S.lastNotifAt >= notifSeconds then
		refresh_notifications()
	end
	local feedMinutes = math.max(5, minutes)
	if now() - S.lastFeedAt >= feedMinutes * 60 then
		refresh_feeds()
	end
end

function onEnable(): ()
	restore()
	S.started = true
	S.auth = "checking"
	S.authAt = now()
	publish_status()
	trace("enable", "source=" .. tostring(S.view.source) .. " repo=" .. tostring(S.view.repo))
	load_meta(true)
	refresh_board()
	refresh_notifications()
end

function onConfigChanged(): ()
	S.view.owner = if cfg_string("board_project_owner", "") ~= "" then cfg_string("board_project_owner", "") else S.view.owner
	noctalia.log("[b3l0w-kanban] settings recargados")
	publish_status()
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

-- Arranque: el host puede cargar el service antes de que exista un panel.
--
-- `onEnable()` NO corre en un arranque normal de Noctalia: la doc del host dice
-- que describe "an explicit plugin-manager action" y que no se llama en el
-- startup, en un reload de script ni en un restart por ajustes ("use top-level
-- initialization for normal service startup"). Con la inicialización viviendo
-- sólo en onEnable(), el chequeo de auth no se lanzaba nunca: S.auth se quedaba
-- en su valor inicial "checking" para siempre, el Overview decía "no iniciaste
-- sesión" y el avatar no se descargaba, mientras update() seguía refrescando el
-- tablero — exactamente la traza `2 cols/0 cards/.../checking`.
restore()
publish_status()
publish_feed()
publish_meta()
publish_board()
trace("load", "init")
S.authAt = now()
load_meta(true)
refresh_board()
refresh_notifications()
