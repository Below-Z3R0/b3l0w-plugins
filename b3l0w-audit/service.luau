--!nonstrict
-- Service de b3l0w/audit: dueño de todos los procesos y del estado compartido.
--
-- Tres fuentes, una sola superficie:
--   1. `arch-audit --json` — avisos del Arch Security Team enriquecidos con la
--      versión instalada (`pacman -Q`). Es la paridad con cero800/arch-audit:
--      severidad, filtro, lista de ignorados, notificación de CVEs nuevas e
--      intervalo configurable.
--   2. `pacman -Qu` — actualizaciones pendientes, separadas en paquetes
--      noctalia* y *umbriel*, más la versión que corre el binario de Noctalia
--      (`noctalia --version`).
--   3. mtime del CLI `b3l0w` contra el `.go` más nuevo del repo: el binario
--      "necesita recompilar" cuando la fuente es más nueva que él.
--
-- "Actualizar todo" corre sólo el subconjunto seguro: vuelve a listar con
-- `pacman -Qu` (cada paquete se actualiza con confirmación propia) y recompila
-- el CLI con `go build`. Nunca hace `pacman -Syu` por su cuenta.
--
-- Presupuesto: 25 ms de CPU por callback del host. Todo el trabajo pesado es
-- un `runAsync` y el parseo posterior es lineal sobre decenas de líneas.

local audit = require("./lib/audit.luau")
local cli = require("./lib/cli.luau")
local store = require("./lib/store.luau")

local STATE_KEY = "b3l0w_audit_state"
local UPDATES_KEY = "b3l0w_audit_updates"
local STATUS_KEY = "b3l0w_audit_status"
local REQUEST_KEY = "b3l0w_audit_request"
local SCREEN_KEY = "b3l0w_audit_screen"

local SNAPSHOT_FILE = "snapshot.json"
local SNAPSHOT_VERSION = 2

local BINARY_RECHECK_SECONDS = 600
local RETRY_SECONDS = 900
local STARTUP_DELAY_SECONDS = 8
local DUE_TICKS = 2
local MAX_QUERY_PACKAGES = 250
local MAX_ERROR_CHARS = 180
local DEFAULT_HOURS = 6
local DEFAULT_UPDATES_MINUTES = 15

local S = {
	phase = "idle",
	items = {},
	counts = audit.severity_counts(),
	total = 0,
	packageCount = 0,
	checkedAtMs = nil,
	newCount = 0,
	ignoredCount = 0,
	binaryMissing = false,
	err = nil,
	updates = nil,
	busy = false,
	busyWhat = nil,
	lastNonce = "",
	lastCheckAt = 0,
	lastUpdatesAt = 0,
	raw = nil,
	installed = {},
	seen = {},
	initialized = false,
	retryAfter = nil,
	dueTicks = 0,
	binaryRecheckAt = 0,
	loadedAt = 0,
	queue = {},
}

S.loadedAt = os.time()
S.binaryRecheckAt = S.loadedAt + BINARY_RECHECK_SECONDS

local function now()
	return os.time()
end

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function cfg(key)
	return noctalia.getConfig(key)
end

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── publicación ──────────────────────────────────────────────────────

local function publishState()
	noctalia.state.set(STATE_KEY, {
		phase = S.phase,
		total = S.total,
		packageCount = S.packageCount,
		counts = S.counts,
		items = S.items,
		severity = audit.max_severity(S.counts),
		checkedAtMs = S.checkedAtMs,
		newCount = S.newCount,
		ignoredCount = S.ignoredCount,
		binaryMissing = S.binaryMissing,
		err = S.err,
	})
end

local function emptyUpdates()
	return {
		at = 0,
		total = 0,
		rows = {},
		noctalia = { rows = {}, pending = 0 },
		umbriel = { rows = {}, pending = 0 },
		cli = { stale = false },
		err = nil,
	}
end

local function publishUpdates()
	noctalia.state.set(UPDATES_KEY, S.updates or emptyUpdates())
end

local function publishStatus()
	local u = S.updates or emptyUpdates()
	noctalia.state.set(STATUS_KEY, {
		busy = S.busy,
		what = S.busyWhat,
		phase = S.phase,
		err = S.err or u.err,
		at = S.lastCheckAt,
		total = S.total,
		severity = audit.max_severity(S.counts),
		updates = tonumber(u.total) or 0,
		cliStale = type(u.cli) == "table" and u.cli.stale == true,
		binaryMissing = S.binaryMissing,
	})
end

local function resolvePhase()
	if S.busy and S.busyWhat == "check" then
		S.phase = "checking"
	elseif S.binaryMissing and S.total == 0 then
		S.phase = "missing"
	elseif S.err ~= nil and S.total == 0 then
		S.phase = "error"
	elseif S.total > 0 then
		S.phase = "ready"
	elseif S.checkedAtMs ~= nil then
		S.phase = "clean"
	else
		S.phase = "idle"
	end
end

-- Recalcula filas y conteos desde el payload cacheado. Se llama después de un
-- chequeo y cuando cambia la lista de ignorados, así el ajuste aplica al
-- instante sin otra vuelta a la red.
local function rebuild(publish)
	local normalized = audit.normalize(S.raw or {}, S.installed or {})
	local ignored = audit.ignore_set(cfg("ignore_packages"))
	local filtered = audit.apply_ignore(normalized.items, ignored)

	S.items = filtered.items
	S.counts = filtered.counts
	S.total = filtered.total
	S.ignoredCount = filtered.dropped

	local pkgset = {}
	for _, item in ipairs(S.items) do
		for _, name in ipairs(item.packages or {}) do
			pkgset[name] = true
		end
	end
	local pkgcount = 0
	for _ in pairs(pkgset) do
		pkgcount = pkgcount + 1
	end
	S.packageCount = pkgcount

	resolvePhase()
	if publish ~= false then
		publishState()
		publishStatus()
	end
end

-- ── persistencia ─────────────────────────────────────────────────────

local function saveSnapshot()
	local ok = store.save(SNAPSHOT_FILE, {
		version = SNAPSHOT_VERSION,
		checkedAtMs = S.checkedAtMs,
		raw = S.raw,
		installed = S.installed,
		seen = S.seen,
		initialized = S.initialized,
		updates = S.updates,
	})
	if not ok then
		noctalia.log("[b3l0w-audit] no se pudo guardar snapshot.json")
	end
end

local function loadSnapshot()
	local data = store.load(SNAPSHOT_FILE)
	if type(data) ~= "table" or data.version ~= SNAPSHOT_VERSION then
		return
	end

	if type(data.raw) == "table" and type(data.installed) == "table" then
		S.raw = data.raw
		S.installed = data.installed
		S.checkedAtMs = tonumber(data.checkedAtMs)
		S.initialized = data.initialized == true

		S.seen = {}
		if type(data.seen) == "table" then
			for id, value in pairs(data.seen) do
				if type(id) == "string" and value == true then
					S.seen[id] = true
				end
			end
		end
		rebuild(false)
	end

	if type(data.updates) == "table" then
		S.updates = data.updates
	end
end

-- ── avisos nuevos ────────────────────────────────────────────────────

local function notifyNewAdvisories(fresh)
	if #fresh == 0 or cfg("notify_new") == false then
		return
	end

	local threshold = audit.rank(cfg("notify_min_severity") or "high")
	local notifiable = {}
	for _, item in ipairs(fresh) do
		if audit.rank(item.severity) >= threshold then
			table.insert(notifiable, item)
		end
	end
	if #notifiable == 0 then
		return
	end

	local packages = {}
	local packageSeen = {}
	for _, item in ipairs(notifiable) do
		for _, name in ipairs(item.packages) do
			if not packageSeen[name] then
				packageSeen[name] = true
				table.insert(packages, name)
			end
		end
	end
	table.sort(packages)

	local shown = {}
	for index = 1, math.min(#packages, 3) do
		shown[index] = packages[index]
	end
	local packagesText = tr("notify.some_packages")
	if #shown > 0 then
		packagesText = table.concat(shown, ", ")
		if #packages > #shown then
			packagesText = packagesText .. " +" .. (#packages - #shown)
		end
	end

	noctalia.notify(
		tr("notify.title"),
		noctalia.trp("notify.body", #notifiable, { packages = packagesText })
	)
end

-- ── chequeo de vulnerabilidades ──────────────────────────────────────

local function completeCheck(raw, installed)
	local normalized = audit.normalize(raw, installed)
	local fresh = {}
	if S.initialized then
		fresh = audit.new_items(normalized.items, S.seen)
	end

	-- El set de vistos cubre los avisos antes del filtro de ignorados: ignorar
	-- un paquete y volver a mostrarlo no se lee como un hallazgo nuevo.
	S.seen = audit.ids(normalized.items)
	S.initialized = true
	S.raw = raw
	S.installed = installed
	S.checkedAtMs = os.time() * 1000
	S.binaryMissing = false
	S.err = nil
	S.retryAfter = nil
	S.newCount = #fresh
	S.lastCheckAt = now()

	rebuild(false)
	notifyNewAdvisories(fresh)
	saveSnapshot()
	publishState()
	publishStatus()
end

local function loadInstalled(names, cb)
	if #names == 0 then
		cb({})
		return
	end

	local parts = { "pacman", "-Q" }
	for index = 1, math.min(#names, MAX_QUERY_PACKAGES) do
		table.insert(parts, cli.quote(names[index]))
	end

	-- `pacman -Q` sale distinto de cero cuando algún paquete no está, pero
	-- igual imprime los que encontró: se parsea stdout e se ignora el código.
	cli.exit_code(table.concat(parts, " "), function(_code, stdout)
		cb(audit.parse_installed(stdout))
	end)
end

local function checkRaw(cb)
	S.binaryMissing = not noctalia.commandExists("arch-audit")
	if S.binaryMissing then
		S.err = tr("service.error.missing")
		S.binaryRecheckAt = now() + BINARY_RECHECK_SECONDS
		resolvePhase()
		publishState()
		publishStatus()
		cb()
		return
	end

	S.phase = "checking"
	S.err = nil
	S.retryAfter = nil
	publishState()
	publishStatus()

	cli.exit_code("arch-audit --json", function(code, stdout, stderr)
		if code ~= 0 then
			local detail = trim(stderr)
			if detail == "" then
				detail = trim(stdout)
			end
			if #detail > MAX_ERROR_CHARS then
				detail = detail:sub(1, MAX_ERROR_CHARS - 3) .. "..."
			end
			if detail == "" then
				detail = tr("service.error.no_detail")
			end
			S.err = tr("service.error.exit", { detail = detail })
			S.retryAfter = now() + RETRY_SECONDS
			resolvePhase()
			publishState()
			publishStatus()
			noctalia.log("[b3l0w-audit] arch-audit fallo: " .. tostring(S.err))
			cb()
			return
		end

		local raw = noctalia.json.decode(stdout)
		if type(raw) ~= "table" then
			S.err = tr("service.error.json")
			S.retryAfter = now() + RETRY_SECONDS
			resolvePhase()
			publishState()
			publishStatus()
			cb()
			return
		end

		local wanted = {}
		local wantedSeen = {}
		for _, entry in ipairs(raw) do
			if type(entry) == "table" and type(entry.packages) == "table" then
				for _, name in ipairs(entry.packages) do
					if type(name) == "string" and name ~= "" and not wantedSeen[name] then
						wantedSeen[name] = true
						table.insert(wanted, name)
					end
				end
			end
		end

		loadInstalled(wanted, function(installed)
			completeCheck(raw, installed)
			cb()
		end)
	end)
end

-- ── actualizaciones del sistema ──────────────────────────────────────

local function cliPaths()
	local repo = cfg("cli_repo")
	local bin = cfg("cli_bin")
	if type(repo) ~= "string" or repo == "" then
		repo = "~/Documents/Github/b3l0w"
	end
	if type(bin) ~= "string" or bin == "" then
		bin = "~/.local/bin/b3l0w"
	end
	return noctalia.expandPath(bin), noctalia.expandPath(repo)
end

-- Mide en una sola pasada: mtime del binario y del .go más nuevo del repo.
-- Dos `stat` + un `find` acotado al repo, sin recorrer nada más.
local function stalenessCommand(bin, repo)
	return "B=" .. cli.quote(bin) .. "; R=" .. cli.quote(repo) .. "; "
		.. "echo \"bin=$B\"; "
		.. "if [ -f \"$B\" ]; then echo \"binmtime=$(stat -c %Y \"$B\" 2>/dev/null || echo 0)\"; else echo binmtime=0; fi; "
		.. "if [ -d \"$R\" ]; then N=$(find \"$R\" -type f -name '*.go' -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -n1); echo \"newest=$N\"; else echo newest=; fi"
end

local function noctaliaVersionRaw(cb)
	cli.exit_code("noctalia --version 2>/dev/null", function(_code, stdout)
		cb(audit.parse_noctalia_version(stdout))
	end)
end

local function pacmanVersionsRaw(cb)
	cli.exit_code(
		"pacman -Q noctalia-git umbriel-git xdg-desktop-portal-umbriel-git 2>/dev/null",
		function(_code, stdout)
			cb(audit.parse_installed(stdout))
		end
	)
end

local function cliRaw(cb)
	local bin, repo = cliPaths()
	cli.exit_code(stalenessCommand(bin, repo), function(_code, stdout)
		local info = audit.parse_staleness(stdout)
		if info.bin == nil or info.bin == "" then
			info.bin = bin
		end

		local u = S.updates or emptyUpdates()
		u.cli = info
		S.updates = u
		if info.stale then
			noctalia.log(
				"[b3l0w-audit] cli necesita recompilar: bin=" .. tostring(info.bin)
					.. " binmtime=" .. tostring(info.binMtime)
					.. " fuente=" .. tostring(info.newestMtime)
					.. " " .. tostring(info.newestPath or "")
			)
		end
		publishUpdates()
		publishStatus()
		cb(info)
	end)
end

-- `pacman -Qu` compara contra la base local: si no se sincronizó nunca,
-- subreporta (en esta máquina 1 contra 32 reales). `checkupdates` hace el mismo
-- `-Qu` sobre una copia sincronizada en un directorio temporal y no necesita
-- root, así que se prefiere cuando existe. Mismo formato de salida.
local function updatesCommand()
	if noctalia.commandExists("checkupdates") then
		return { command = "checkupdates 2>/dev/null", name = "checkupdates" }
	end
	return { command = "pacman -Qu 2>/dev/null", name = "pacman -Qu" }
end

local function updatesRaw(cb)
	local pick = updatesCommand()
	cli.exit_code(pick.command, function(_code, stdout)
		local rows = audit.parse_updates(stdout)
		local noctaliaRows = audit.filter_updates(rows, "noctalia")
		local umbrielRows = audit.filter_updates(rows, "umbriel")
		local taken = {}
		for _, row in ipairs(noctaliaRows) do
			taken[row.name] = true
		end
		for _, row in ipairs(umbrielRows) do
			taken[row.name] = true
		end
		local systemRows = {}
		for _, row in ipairs(rows) do
			if not taken[row.name] then
				table.insert(systemRows, row)
			end
		end
		noctaliaVersionRaw(function(versionInfo)
			pacmanVersionsRaw(function(versions)
				local u = {
					at = os.time() * 1000,
					source = pick.name,
					total = #rows,
					rows = rows,
					noctalia = {
						rows = noctaliaRows,
						pending = #noctaliaRows,
						version = versionInfo.version,
						build = versionInfo.build,
						installed = versions["noctalia-git"],
					},
					umbriel = {
						rows = umbrielRows,
						pending = #umbrielRows,
						installed = versions["umbriel-git"],
						portal = versions["xdg-desktop-portal-umbriel-git"],
					},
					system = {
						rows = systemRows,
						pending = #systemRows,
					},
					cli = (S.updates and S.updates.cli) or { stale = false },
					err = nil,
				}
				S.updates = u
				S.lastUpdatesAt = now()
				publishUpdates()
				publishStatus()
				noctalia.log(
					"[b3l0w-audit] " .. pick.name .. ": total=" .. tostring(u.total)
						.. " noctalia=" .. tostring(u.noctalia.pending)
						.. " umbriel=" .. tostring(u.umbriel.pending)
						.. " sistema=" .. tostring(u.system.pending)
						.. " noctalia_bin=" .. tostring(versionInfo.version or "?")
				)
				cliRaw(function()
					cb(u)
				end)
			end)
		end)
	end)
end

-- Recompila el dispatcher. Se construye a un `.new`, se verifica que ejecute y
-- recién ahí se reemplaza: un build roto no puede dejar al usuario sin CLI.
local function rebuildRaw(cb)
	local bin, repo = cliPaths()
	local temp = bin .. ".new"
	local command = "cd " .. cli.quote(repo)
		.. " && go build -o " .. cli.quote(temp) .. " ./cmd/b3l0w"
		.. " && " .. cli.quote(temp) .. " --version >/dev/null 2>&1"
		.. " && mv -f " .. cli.quote(temp) .. " " .. cli.quote(bin)

	cli.exit_code(command, function(code, _stdout, stderr)
		if code ~= 0 then
			local detail = trim(stderr)
			if #detail > MAX_ERROR_CHARS then
				detail = detail:sub(1, MAX_ERROR_CHARS - 3) .. "..."
			end
			cli.run("rm -f " .. cli.quote(temp), function() end)
			noctalia.log("[b3l0w-audit] go build fallo: " .. detail)
			cb(false, detail)
			return
		end
		noctalia.log("[b3l0w-audit] cli recompilado en " .. bin)
		cb(true, nil)
	end)
end

-- Actualiza un paquete puntual con confirmación desde el panel. `pkexec` es la
-- única vía de root desde un servicio sin tty; si no hay agente polkit, el
-- error se muestra tal cual en vez de fallar en silencio.
local function updatePkg(name, cb)
	local clean = tostring(name or "")
	if clean == "" or clean:match("^[%w@%._%+%-]+$") == nil then
		noctalia.notifyError(tr("plugin.title"), tr("updates.invalid_package"))
		cb("invalid")
		return
	end

	if not noctalia.commandExists("pkexec") then
		noctalia.notifyError(tr("plugin.title"), tr("updates.no_pkexec"))
		cb("no_pkexec")
		return
	end

	local command = "pkexec pacman -S --noconfirm --needed " .. cli.quote(clean)
	cli.exit_code(command, function(code, stdout, stderr)
		if code == 0 then
			noctalia.notify(tr("plugin.title"), tr("updates.pkg_done", { name = clean }))
			noctalia.log("[b3l0w-audit] actualizado " .. clean)
		else
			local detail = trim(stderr)
			if detail == "" then
				detail = trim(stdout)
			end
			if #detail > MAX_ERROR_CHARS then
				detail = detail:sub(1, MAX_ERROR_CHARS - 3) .. "..."
			end
			if detail == "" then
				detail = tr("service.error.no_detail")
			end
			noctalia.notifyError(tr("plugin.title"), tr("updates.pkg_fail", { name = clean, detail = detail }))
			noctalia.log("[b3l0w-audit] fallo al actualizar " .. clean .. ": " .. detail)
		end
		cb("done")
	end)
end

-- "Actualizar todo": lista pendientes (cada uno con su confirmación) y
-- recompila el CLI. Cierra con un toast que dice exactamente qué se hizo.
local function updateAll(cb)
	updatesRaw(function(u)
		local pending = tonumber(u.total) or 0
		local stale = type(u.cli) == "table" and u.cli.stale == true

		if not stale then
			noctalia.notify(tr("plugin.title"), tr("updates.toast_summary", {
				cli = tr("updates.cli_uptodate"),
				pending = tostring(pending),
			}))
			cb()
			return
		end

		rebuildRaw(function(ok, detail)
			if not ok then
				cliRaw(function()
					noctalia.notifyError(tr("plugin.title"), tr("updates.cli_failed_detail", {
						detail = detail ~= "" and detail or tr("service.error.no_detail"),
					}))
					cb()
				end)
				return
			end
			cliRaw(function()
				noctalia.notify(tr("plugin.title"), tr("updates.toast_summary", {
					cli = tr("updates.cli_rebuilt"),
					pending = tostring(pending),
				}))
				saveSnapshot()
				cb()
			end)
		end)
	end)
end

local function updateCli(cb)
	rebuildRaw(function(ok, detail)
		if ok then
			noctalia.notify(tr("plugin.title"), tr("updates.cli_rebuilt"))
		else
			noctalia.notifyError(tr("plugin.title"), tr("updates.cli_failed_detail", {
				detail = detail ~= "" and detail or tr("service.error.no_detail"),
			}))
		end
		cliRaw(function()
			cb()
		end)
	end)
end

-- ── despacho ─────────────────────────────────────────────────────────

local function finish()
	S.busy = false
	S.busyWhat = nil
	resolvePhase()
	publishStatus()
	local nextTask = table.remove(S.queue, 1)
	if nextTask ~= nil then
		nextTask()
	end
end

-- Un trabajo pedido con el service ocupado se encola, nunca se descarta: un
-- `if busy then return end` deja el botón muerto sin ningún error visible.
local function runBusy(what, work)
	if S.busy then
		table.insert(S.queue, function()
			runBusy(what, work)
		end)
		return
	end
	S.busy = true
	S.busyWhat = what
	publishStatus()
	work(finish)
end

local function refreshAll()
	runBusy("refresh", function(done)
		checkRaw(function()
			updatesRaw(function()
				done()
			end)
		end)
	end)
end

local function handle(req)
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
	if action == "refresh" then
		refreshAll()
	elseif action == "check" then
		runBusy("check", checkRaw)
	elseif action == "updates" then
		runBusy("updates", updatesRaw)
	elseif action == "update_all" then
		runBusy("update_all", updateAll)
	elseif action == "update_cli" then
		runBusy("update_cli", updateCli)
	elseif action == "update_pkg" then
		runBusy("update_pkg", function(done)
			updatePkg(req.name, function()
				updatesRaw(function()
					done()
				end)
			end)
		end)
	elseif action == "open_settings" then
		noctalia.openSettings()
	elseif action == "screen" then
		noctalia.state.set(SCREEN_KEY, {
			tab = tostring(req.tab or "vulns"),
			nonce = tostring(now()) .. ":" .. nonce,
		})
	else
		-- Un typo en el panel o un payload roto no puede quedar invisible.
		noctalia.log("[b3l0w-audit] accion desconocida: " .. action)
		noctalia.notifyError(tr("plugin.title"), tr("panel.unknown_action", { action = action }))
	end
end

noctalia.state.watch(REQUEST_KEY, handle)

-- ── ciclo de vida ────────────────────────────────────────────────────

function update()
	if S.busy then
		return
	end

	local t = now()

	-- Recuperación automática si el usuario instala arch-audit con el service
	-- ya corriendo. El botón de refrescar es más rápido, esto es la red.
	if S.binaryMissing then
		if t >= S.binaryRecheckAt then
			S.binaryRecheckAt = t + BINARY_RECHECK_SECONDS
			if noctalia.commandExists("arch-audit") then
				S.binaryMissing = false
				S.err = nil
				refreshAll()
			end
		end
		return
	end

	if S.retryAfter ~= nil and t < S.retryAfter then
		return
	end

	local hours = tonumber(cfg("check_hours")) or DEFAULT_HOURS
	if hours < 1 then
		hours = DEFAULT_HOURS
	end

	local due
	if S.checkedAtMs ~= nil then
		due = math.floor(S.checkedAtMs / 1000) + hours * 3600
	else
		due = S.loadedAt + STARTUP_DELAY_SECONDS
	end

	if t >= due then
		S.dueTicks = S.dueTicks + 1
		if S.dueTicks >= DUE_TICKS then
			S.dueTicks = 0
			refreshAll()
			return
		end
	else
		S.dueTicks = 0
	end

	local minutes = tonumber(cfg("updates_minutes")) or DEFAULT_UPDATES_MINUTES
	if minutes < 2 then
		minutes = DEFAULT_UPDATES_MINUTES
	end
	if t - S.lastUpdatesAt >= minutes * 60 then
		runBusy("updates", updatesRaw)
	end
end

function onEnable()
	resolvePhase()
	publishState()
	publishUpdates()
	publishStatus()
	if not S.busy then
		refreshAll()
	end
end

function onConfigChanged()
	rebuild(true)
end

function onIpc(event, payload)
	local req = nil
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

loadSnapshot()

if not noctalia.commandExists("arch-audit") then
	S.binaryMissing = true
	if S.err == nil then
		S.err = tr("service.error.missing")
	end
end

resolvePhase()
publishState()
publishUpdates()
publishStatus()

noctalia.setUpdateInterval(1000)
