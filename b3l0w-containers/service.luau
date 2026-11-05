--!strict
-- Service de b3l0w/containers: dueño del CLI y del estado.
--
-- Todo el parseo vive en Go (`b3l0w docker snapshot --json`): el service sólo
-- publica y ejecuta acciones. El plugin original hacía `docker ps` + awk por
-- contenedor y decodificaba de a 25 filas por tick dentro del presupuesto de
-- 25 ms del host.

local cli = require("./lib/cli.luau")

local SNAP_KEY = "b3l0w_containers_snapshot"
local STATUS_KEY = "b3l0w_containers_status"
local REQUEST_KEY = "b3l0w_containers_request"
local LOGS_KEY = "b3l0w_containers_logs"
local DETAIL_KEY = "b3l0w_containers_detail"
local DISK_KEY = "b3l0w_containers_disk"
local INFO_KEY = "b3l0w_containers_info"
local SCREEN_KEY = "b3l0w_containers_screen"
local STATS_KEY = "b3l0w_containers_stats"
local EVENTS_KEY = "b3l0w_containers_events"
local EXEC_KEY = "b3l0w_containers_exec"
local TOP_KEY = "b3l0w_containers_top"
local HISTORY_KEY = "b3l0w_containers_history"
local DIFF_KEY = "b3l0w_containers_diff"
-- Puertos publicados, búsqueda en el Hub y detalle de volumen/red. Son
-- datos de una acción puntual, no del refresco: se guardan aparte para no
-- pisar el snapshot.
local PORTS_KEY = "b3l0w_containers_ports"
local HUB_KEY = "b3l0w_containers_hub"
local VOLINFO_KEY = "b3l0w_containers_volinfo"
local LOGSTREAM_KEY = "b3l0w_containers_logstream"
local COMPOSEFILE_KEY = "b3l0w_containers_composefile"
local NETINFO_KEY = "b3l0w_containers_netinfo"

local S = {
	snapshot = nil :: any,
	busy = false,
	phase = "idle" :: string,
	error = nil :: string?,
	lastNonce = "",
	lastAt = 0,
	queue = {} :: { any },
	detailId = nil :: string?,
	detail = nil :: any,
	top = nil :: any,
	history = nil :: any,
	diff = nil :: any,
	disk = nil :: any,
	info = nil :: any,
	stats = nil :: any,
	events = nil :: any,
	exec = nil :: any,
	ports = nil :: any,
	hub = nil :: any,
	volinfo = nil :: any,
	netinfo = nil :: any,
}

local function now(): number
	return os.time()
end

local function refreshSeconds(): number
	local value = noctalia.getConfig("refresh_seconds")
	if type(value) == "number" and value >= 2 then
		return value
	end
	return 5
end

local function includeStopped(): boolean
	return noctalia.getConfig("show_stopped") == true
end

local function publishStatus(): ()
	local snap = S.snapshot or {}
	noctalia.state.set(STATUS_KEY, {
		busy = S.busy,
		phase = S.phase,
		error = S.error,
		at = S.lastAt,
		running = snap.running or 0,
		stopped = snap.stopped or 0,
		unhealthy = snap.unhealthy or 0,
		containers = type(snap.containers) == "table" and #snap.containers or 0,
		images = type(snap.images) == "table" and #snap.images or 0,
		volumes = type(snap.volumes) == "table" and #snap.volumes or 0,
		networks = type(snap.networks) == "table" and #snap.networks or 0,
	})
end

local function publishSnapshot(): ()
	noctalia.state.set(SNAP_KEY, S.snapshot or { containers = {}, images = {}, volumes = {}, networks = {}, projects = {} })
end

-- Una sola ranura de "pendiente" hacía que el pedido nuevo pisara al anterior
-- (click en restart + apertura del detalle = restart perdido). Cola FIFO.
local function encolar(tarea: () -> ()): ()
	table.insert(S.queue, tarea)
end

local function finishPhase(): ()
	S.busy = false
	S.phase = "idle"
	publishStatus()
	if #S.queue > 0 then
		local siguiente = table.remove(S.queue, 1)
		siguiente()
	end
end

local function refreshCb(_payload: any, err: string?): ()
	if err then
		S.error = err
	end
	S.lastAt = now()
	finishPhase()
end

-- ── snapshot ─────────────────────────────────────────────────────────

local function refresh(): ()
	if S.busy then
		S.pending = { pedido = {}, run = function() refresh() end }
		return
	end
	S.busy = true
	S.phase = "refresh"
	publishStatus()
	local args: { string } = { "snapshot", "--json" }
	if includeStopped() then
		table.insert(args, "--all")
	end
	cli.json("docker", args, function(payload: any, err: string?)
		if err then
			S.error = err
			finishPhase()
			return
		end
		if type(payload) ~= "table" then
			S.error = "snapshot inválido"
			finishPhase()
			return
		end
		-- Normalización defensiva: un array vacío de Luau viaja como `{}` y el
		-- panel hace `#` sobre estos campos.
		-- `projects` también: sin él, la pestaña Stacks quedaba vacía
		-- aunque el snapshot trajera los stacks.
		for _, campo in ipairs({ "containers", "images", "volumes", "networks", "projects" }) do
			if type(payload[campo]) ~= "table" then
				payload[campo] = {}
			end
		end
		if type(payload.error) == "string" and payload.error ~= "" then
			S.error = payload.error
		else
			S.error = nil
		end
		S.snapshot = payload
		publishSnapshot()
		refreshCb(payload, nil)
	end)
end

-- ── acciones ─────────────────────────────────────────────────────────

-- Las acciones con la forma `docker <cmd> <id>` y las que piden `--id <id>`.
-- El segundo campo es el estilo del argumento: "id" (posicional) o "flag".
local ACTIONS = {
	start = { "start", "id" },
	stop = { "stop", "id" },
	restart = { "restart", "id" },
	remove = { "remove", "id" },
	rmi = { "rmi", "id" },
	["volume-rm"] = { "volume-rm", "id" },
	["network-rm"] = { "network-rm", "id" },
	pause = { "pause", "flag" },
	unpause = { "unpause", "flag" },
	top = { "top", "id" },
	history = { "history", "id" },
}

local function runAction(action: string, id: string): ()
	if S.busy then
		encolar(function() runAction(action, id) end)
		return
	end
	local plantilla = ACTIONS[action]
	if plantilla == nil then
		S.error = "acción desconocida: " .. action
		publishStatus()
		return
	end
	S.busy = true
	S.phase = action
	publishStatus()

	local args: { string } = { plantilla[1] }
	if plantilla[2] == "flag" then
		table.insert(args, "--id")
	end
	table.insert(args, id)
	table.insert(args, "--json")
	cli.json("docker", args, function(result: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", action .. ": " .. err)
			finishPhase()
			refresh()
			return
		end
		if type(result) == "table" and result.ok == true then
			noctalia.log("[b3l0w-containers] " .. action .. " " .. id .. " ok")
		end
		if type(result) == "table" and result.ok == false then
			S.error = tostring(result.error or result.output or "la acción falló")
			noctalia.notifyError("Docker", tostring(result.output or action))
		end
		finishPhase()
		refresh()
	end)
end

local function runImage(req: any): ()
	if S.busy then
		S.pending = { pedido = req, run = runImage }
		return
	end
	S.busy = true
	S.phase = "run"
	publishStatus()
	local args: { string } = { "run", "--json", "--image", tostring(req.image or "") }
	if req.name ~= nil and req.name ~= "" then
		table.insert(args, "--name")
		table.insert(args, tostring(req.name))
	end
	if req.network ~= nil and req.network ~= "" then
		table.insert(args, "--network")
		table.insert(args, tostring(req.network))
	end
	if type(req.ports) == "table" then
		for _, port in ipairs(req.ports) do
			table.insert(args, "--port")
			table.insert(args, tostring(port))
		end
	end
	if type(req.env) == "table" then
		for _, variable in ipairs(req.env) do
			table.insert(args, "--env")
			table.insert(args, tostring(variable))
		end
	end
	cli.json("docker", args, function(result: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", err)
		elseif type(result) == "table" and result.ok == false then
			S.error = tostring(result.output or "no se pudo correr la imagen")
			noctalia.notifyError("Docker", tostring(result.output or ""))
		else
			noctalia.notify("Docker", tostring(result and result.output or "contenedor creado"))
		end
		finishPhase()
		refresh()
	end)
end

local function loadLogs(id: string): ()
	if S.busy then
		-- Antes se descartaba: el panel ya cambiaba a detalle y quedaba en
		-- "cargando logs" para siempre hasta un refresh manual.
		encolar(function() loadLogs(id) end)
		return
	end
	S.busy = true
	S.phase = "logs"
	publishStatus()
	cli.text("docker", { "logs", id, "--tail", "80" }, function(texto: string?, err: string?)
		if err then
			noctalia.log("[b3l0w-containers] logs de " .. id .. ": " .. err)
			noctalia.notifyError("Docker", "logs: " .. err)
			noctalia.state.set(LOGS_KEY, { id = id, text = "error: " .. err })
		else
			-- 80 líneas de un contenedor hablador son ~15 KB: si el estado es muy
			-- grande no llega al panel y queda en "cargando" para siempre.
			local limpio = texto or ""
			if #limpio > 6000 then
				limpio = string.sub(limpio, #limpio - 6000)
			end
			local lineas = {}
			for linea in string.gmatch(limpio, "[^\n]+") do
				table.insert(lineas, linea)
			end
			if #lineas > 40 then
				local recorte = {}
				for i = #lineas - 39, #lineas do
					table.insert(recorte, lineas[i])
				end
				lineas = recorte
			end
			noctalia.log("[b3l0w-containers] logs " .. id .. ": " .. tostring(#lineas) .. " líneas")
			noctalia.state.set(LOGS_KEY, { id = id, text = table.concat(lineas, "\n"), lines = #lineas })
		end
		finishPhase()
	end)
end

-- ── detalle, métricas y disco ────────────────────────────────────────

local function publishDetail(): ()
	noctalia.state.set(DETAIL_KEY, S.detail or { id = S.detailId, stats = nil, inspect = nil })
end

local function publishDisk(): ()
	noctalia.state.set(DISK_KEY, S.disk or { rows = {}, at = 0 })
end


-- El CLI devuelve { ok, command, output } con el texto plano. Se convierte
-- en filas (una por línea) para que el panel pueda listarlas.
local function lineasDe(resultado: any): { string }
	local filas: { string } = {}
	if type(resultado) ~= "table" then
		return filas
	end
	local texto = tostring(resultado.output or "")
	for linea in string.gmatch(texto, "([^\n]+)") do
		if linea ~= "" then
			table.insert(filas, linea)
		end
	end
	return filas
end

-- Los procesos del contenedor (docker top).
local function publishTop(): ()
	noctalia.state.set(TOP_KEY, S.top or { rows = {}, at = 0 })
end

-- El historial de capas de una imagen (docker history).
local function publishHistory(): ()
	noctalia.state.set(HISTORY_KEY, S.history or { rows = {}, at = 0 })
end

-- Los cambios del filesystem del contenedor (docker diff).
local function publishDiff(): ()
	noctalia.state.set(DIFF_KEY, S.diff or { rows = {}, at = 0 })
end

local function publishPorts(): ()
	noctalia.state.set(PORTS_KEY, S.ports or { rows = {}, at = 0 })
end

local function publishHub(): ()
	noctalia.state.set(HUB_KEY, S.hub or { rows = {}, at = 0 })
end

local function publishVolInfo(): ()
	noctalia.state.set(VOLINFO_KEY, S.volinfo or { rows = {}, at = 0 })
end

local function publishNetInfo(): ()
	noctalia.state.set(NETINFO_KEY, S.netinfo or { rows = {}, at = 0 })
end

-- inspect (env/montajes/redes/health) + stats (CPU/RAM/IO) en dos llamadas:
-- juntas son ~1,2 s, así el panel muestra lo primero apenas llega.
local function loadDetail(id: string): ()
	if S.busy then
		encolar(function() loadDetail(id) end)
		return
	end
	S.busy = true
	S.phase = "detail"
	S.detailId = id
	publishStatus()
	cli.json("docker", { "inspect", id, "--json" }, function(info: any, err: string?)
		if err then
			S.detail = { id = id, error = err }
			publishDetail()
			finishPhase()
			return
		end
		S.detail = { id = id, inspect = info, stats = S.detail and S.detail.stats or nil }
		publishDetail()
		finishPhase()
		cli.json("docker", { "stats", "--json" }, function(datos: any, err2: string?)
			if err2 or type(datos) ~= "table" then
				return
			end
			local stats = {}
			for _, fila in ipairs(type(datos.stats) == "table" and datos.stats or {}) do
				stats[tostring(fila.name or "")] = fila
			end
			S.detail = { id = id, inspect = S.detail and S.detail.inspect or nil, stats = stats }
			publishDetail()
		end)
	end)
end

local function publishInfo(): ()
	noctalia.state.set(INFO_KEY, S.info or {})
end

-- Datos del daemon: sin NCPU/MemTotal, un "100% de CPU" de stats (que es
-- relativo a un core) se lee mal.
local function loadInfo(): ()
	cli.json("docker", { "info", "--json" }, function(datos: any, err: string?)
		if err or type(datos) ~= "table" then
			return
		end
		S.info = datos
		publishInfo()
	end)
end

local function loadDisk(): ()
	cli.json("docker", { "df", "--json" }, function(datos: any, err: string?)
		if err or type(datos) ~= "table" then
			return
		end
		S.disk = { rows = datos.rows or {}, total = tostring(datos.total or ""), at = now() }
		publishDisk()
	end)
end

-- ── métricas, eventos y exec ──────────────────────────────────────────

local function publishStats(): ()
	noctalia.state.set(STATS_KEY, S.stats or { rows = {}, at = 0 })
end

local function publishEvents(): ()
	noctalia.state.set(EVENTS_KEY, S.events or { rows = {}, at = 0 })
end

local function publishExec(): ()
	noctalia.state.set(EXEC_KEY, S.exec or {})
end

-- Una muestra de `docker stats --no-stream`: tarda ~1 s, así que va por su
-- cuenta (no toma el lock de `busy` y no bloquea el refresco del snapshot).
local function loadStats(): ()
	cli.json("docker", { "stats", "--json" }, function(datos: any, err: string?)
		if err or type(datos) ~= "table" then
			return
		end
		local filas = type(datos.stats) == "table" and datos.stats or {}
		S.stats = { rows = filas, at = now() }
		publishStats()
	end)
end

-- `docker events` con ventana: los últimos eventos de contenedor.
local function loadEvents(): ()
	cli.json("docker", { "events", "--since", "6h", "--json" }, function(datos: any, err: string?)
		if err or type(datos) ~= "table" then
			return
		end
		local filas = type(datos.events) == "table" and datos.events or {}
		S.events = { rows = filas, at = now() }
		publishEvents()
	end)
end

-- `docker exec` sin TTY: corre un comando dentro del contenedor y devuelve
-- la salida. Es lo que ejecuta la terminal del panel grande.
local function runExec(req: any): ()
	local id = tostring(req.id or "")
	local comando = tostring(req.command or "")
	if id == "" or comando == "" then
		S.error = "exec: falta el contenedor o el comando"
		publishStatus()
		return
	end
	if S.busy then
		encolar(function() runExec(req) end)
		return
	end
	-- El comando se parte por espacios: cada parte va como argumento de
	-- `docker exec`, así que no puede traer comillas propias.
	local argv: { string } = {}
	for parte in string.gmatch(comando, "%S+") do
		table.insert(argv, parte)
	end
	if #argv == 0 then
		S.error = "exec: comando vacío"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "exec"
	publishStatus()
	local args: { string } = { "exec", "--id", id }
	for _, parte in ipairs(argv) do
		table.insert(args, parte)
	end
	table.insert(args, "--json")
	cli.json("docker", args, function(resultado: any, err: string?)
		local salida = ""
		local ok = false
		if err then
			salida = err
		elseif type(resultado) == "table" then
			salida = tostring(resultado.output or "")
			ok = resultado.ok == true
		end
		S.exec = { id = id, command = comando, output = salida, ok = ok, at = now() }
		publishExec()
		noctalia.log("[b3l0w-containers] exec " .. id .. " (" .. comando .. "): " .. tostring(#salida) .. " bytes")
		if not ok then
			noctalia.notifyError("Docker", "exec: " .. salida)
		end
		finishPhase()
	end)
end

-- `docker commit`: crea una imagen desde el estado actual del contenedor.
local function runCommit(req: any): ()
	local id = tostring(req.id or "")
	local repo = tostring(req.repo or "")
	if id == "" or repo == "" then
		S.error = "commit: falta el contenedor o el repositorio"
		publishStatus()
		return
	end
	if S.busy then
		encolar(function() runCommit(req) end)
		return
	end
	S.busy = true
	S.phase = "commit"
	publishStatus()
	local args: { string } = { "commit", "--id", id, "--repo", repo }
	local tag = tostring(req.tag or "")
	if tag ~= "" then
		table.insert(args, "--tag")
		table.insert(args, tag)
	end
	local mensaje = tostring(req.message or "")
	if mensaje ~= "" then
		table.insert(args, "--message")
		table.insert(args, mensaje)
	end
	table.insert(args, "--json")
	cli.json("docker", args, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "commit: " .. err)
		elseif type(resultado) == "table" and resultado.ok == false then
			S.error = tostring(resultado.output or "commit falló")
			noctalia.notifyError("Docker", tostring(resultado.output or ""))
		else
			noctalia.notify("Docker", "imagen creada: " .. repo)
		end
		finishPhase()
		refresh()
	end)
end

-- `docker rename`: cambia el nombre de un contenedor.
local function runRename(req: any): ()
	local id = tostring(req.id or "")
	local nombre = tostring(req.name or "")
	if id == "" or nombre == "" then
		S.error = "rename: falta el contenedor o el nombre"
		publishStatus()
		return
	end
	if S.busy then
		encolar(function() runRename(req) end)
		return
	end
	S.busy = true
	S.phase = "rename"
	publishStatus()
	local args: { string } = { "rename", "--id", id, "--name", nombre, "--json" }
	cli.json("docker", args, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "rename: " .. err)
		elseif type(resultado) == "table" and resultado.ok == false then
			S.error = tostring(resultado.output or "rename falló")
			noctalia.notifyError("Docker", tostring(resultado.output or ""))
		else
			noctalia.notify("Docker", "renombrado a " .. nombre)
		end
		finishPhase()
		refresh()
	end)
end

-- `docker tag`: etiqueta una imagen con otro repositorio/tag.
local function runTag(req: any): ()
	local id = tostring(req.id or "")
	local repo = tostring(req.repo or "")
	if id == "" or repo == "" then
		S.error = "tag: falta la imagen o el repositorio"
		publishStatus()
		return
	end
	if S.busy then
		encolar(function() runTag(req) end)
		return
	end
	S.busy = true
	S.phase = "tag"
	publishStatus()
	local args: { string } = { "tag", "--id", id, "--repo", repo }
	local tag = tostring(req.tag or "")
	if tag ~= "" then
		table.insert(args, "--tag")
		table.insert(args, tag)
	end
	table.insert(args, "--json")
	cli.json("docker", args, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "tag: " .. err)
		elseif type(resultado) == "table" and resultado.ok == false then
			S.error = tostring(resultado.output or "tag falló")
			noctalia.notifyError("Docker", tostring(resultado.output or ""))
		else
			noctalia.notify("Docker", "etiqueta " .. repo)
		end
		finishPhase()
		refresh()
	end)
end

-- `docker cp`: copia un archivo del contenedor al host.
--
-- Va por `b3l0w docker cp`, que ya normaliza las rutas como docker
-- ("id:" = dentro del contenedor) y arma el comando bien. Antes se corría
-- `docker cp` directo porque el CLI descartaba el resto de `extraerValor`
-- y dejaba el `--from` en el comando ("unknown flag: --from"); ese bug ya
-- está corregido.
local function runCopy(req: any): ()
	local id = tostring(req.id or "")
	local origen = tostring(req.source or "")
	local destino = tostring(req.target or "")
	if id == "" or origen == "" or destino == "" then
		S.error = "cp: falta el contenedor, el origen o el destino"
		publishStatus()
		return
	end
	if S.busy then
		encolar(function() runCopy(req) end)
		return
	end
	S.busy = true
	S.phase = "copy"
	publishStatus()
	-- El origen vive en el sistema de archivos del contenedor: el `~` del
	-- host no aplica ahí. El destino sí es del host, y se expande.
	-- "id:" delata la ruta del contenedor; el destino del host va pelado.
	cli.json("docker", { "cp", "--from", id, "id:" .. origen, "--to", noctalia.expandPath(destino) }, function(_: any, err: string?)
		if err == nil then
			noctalia.notify("Docker", "copiado a " .. destino)
		else
			S.error = err
			noctalia.notifyError("Docker", "cp: " .. err)
		end
		finishPhase()
	end)
end

-- `docker build`: el CLI de b3l0w ya expone el verbo, con sus validaciones
-- (la etiqueta y el contexto no pueden empezar con "-"). Pasa por ahí, como
-- el resto de las acciones: el panel nunca lanza procesos sueltos.
local function runBuild(req: any): ()
	local tag = tostring(req.tag or "")
	local contexto = tostring(req.context or ".")
	local dockerfile = tostring(req.dockerfile or "")
	if tag == "" then
		S.error = "build: falta la etiqueta de la imagen"
		publishStatus()
		return
	end
	if S.busy then
		encolar(function() runBuild(req) end)
		return
	end
	S.busy = true
	S.phase = "build"
	publishStatus()
	local args = { "build", "--tag", tag, "--context", contexto }
	if dockerfile ~= "" then
		table.insert(args, "--file", dockerfile)
	end
	cli.json("docker", args, function(resultado: any, err: string?)
		if err == nil then
			-- La salida del build es larga: se queda la última línea, que es
			-- la que dice "DONE".
			local ultima = ""
			local salida = tostring((resultado or {}).output or "")
			for linea in string.gmatch(salida, "[^\n]+") do
				ultima = linea
			end
			noctalia.notify("Docker", "build " .. tag .. ": " .. (ultima ~= "" and ultima or "hecho"))
		else
			S.error = err
			noctalia.notifyError("Docker", "build: " .. err)
		end
		finishPhase()
		refresh()
	end)
end

-- Acción sobre un stack completo (docker compose -p <proyecto> <acción>).
local function composeAction(proyecto: string, hacer: string): ()
	if proyecto == "" then
		noctalia.notifyError("Docker", "stack vacío")
		return
	end
	if S.busy then
		encolar(function() composeAction(proyecto, hacer) end)
		return
	end
	S.busy = true
	S.phase = "compose"
	publishStatus()
	cli.json("docker", { "compose", proyecto, "--action", hacer, "--json" }, function(resultado: any, err: string?)
		if err then
			noctalia.log("[b3l0w-containers] compose " .. proyecto .. " " .. hacer .. ": " .. err)
			noctalia.notifyError("Docker", proyecto .. ": " .. err)
		elseif type(resultado) == "table" and resultado.ok == false then
			local motivo = tostring(resultado.error or resultado.output or "falló")
			noctalia.log("[b3l0w-containers] compose " .. proyecto .. ": " .. motivo)
			noctalia.notifyError("Docker", proyecto .. ": " .. motivo)
		else
			noctalia.log("[b3l0w-containers] compose " .. proyecto .. " " .. hacer .. " ok")
			noctalia.notify("Docker", proyecto .. ": " .. hacer .. " ok")
		end
		finishPhase()
		refresh()
	end)
end

local function prune(what: string): ()
	if S.busy then
		encolar(function() prune(what) end)
		return
	end
	S.busy = true
	S.phase = "prune"
	publishStatus()
	cli.json("docker", { "prune", what, "--json" }, function(resultado: any, err: string?)
		if err then
			noctalia.log("[b3l0w-containers] prune " .. what .. " falló: " .. err)
			noctalia.notifyError("Docker", "prune " .. what .. ": " .. err)
		elseif type(resultado) == "table" and resultado.ok == false then
			local motivo = tostring(resultado.error or resultado.output or "falló")
			noctalia.log("[b3l0w-containers] prune " .. what .. ": " .. motivo)
			noctalia.notifyError("Docker", "prune " .. what .. ": " .. motivo)
		else
			local texto = type(resultado) == "table" and tostring(resultado.output or "") or ""
			noctalia.notify("Docker", "prune " .. what .. ": " .. (texto ~= "" and texto or "hecho"))
		end
		finishPhase()
		loadDisk()
		refresh()
	end)
end

-- ── acciones de control ────────────────────────────────────────────────

-- Envuelve una acción simple del CLI: arma los argumentos, corre el
-- comando y publica el error o el aviso. Es la forma corta de las
-- acciones que no necesitan estado propio (pause, start, pull...).
local function accionSimple(
	nombre: string,
	args: { string },
	exito: string,
	alTerminar: (() -> ())?
): ()
	-- El auditor no resuelve los parámetros de función: se captura en una
	-- local para que el nombre quede dentro del alcance.
	local etiqueta = nombre
	if S.busy then
		encolar(function()
			accionSimple(etiqueta, args, exito, alTerminar)
		end)
		return
	end
	S.busy = true
	S.phase = etiqueta
	publishStatus()
	local conJson: { string } = {}
	for _, a in ipairs(args) do
		table.insert(conJson, a)
	end
	table.insert(conJson, "--json")
	cli.json("docker", conJson, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", etiqueta .. ": " .. err)
		elseif type(resultado) == "table" and resultado.ok == false then
			S.error = tostring(resultado.output or (etiqueta .. " falló"))
			noctalia.notifyError("Docker", tostring(resultado.output or (etiqueta .. " falló")))
		else
			local texto = type(resultado) == "table" and tostring(resultado.output or "") or ""
			noctalia.notify("Docker", exito .. (texto ~= "" and (": " .. texto) or ""))
		end
		finishPhase()
		if alTerminar then
			alTerminar()
		else
			refresh()
		end
	end)
end

-- Pausa o reanuda un contenedor.
local function runRegistry(req: any): ()
	local imagen = tostring(req.image or "")
	local verb = tostring(req.verb or "pull")
	if imagen == "" then
		S.error = verb .. ": falta la imagen"
		publishStatus()
		return
	end
	accionSimple(verb, { imagen }, verb .. " " .. imagen)
end

-- Crea un volumen o una red nueva.
local function runCreate(req: any): ()
	local nombre = tostring(req.name or "")
	local clase = tostring(req.kind or "volume")
	if nombre == "" then
		S.error = clase .. "-create: falta el nombre"
		publishStatus()
		return
	end
	accionSimple(clase .. "-create", { nombre }, clase .. " " .. nombre)
end

-- Los procesos que corren dentro del contenedor (docker top).
local function runTop(req: any): ()
	local id = tostring(req.id or "")
	if id == "" then
		S.error = "top: falta el contenedor"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "top"
	publishStatus()
	cli.json("docker", { "top", id, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "top: " .. err)
		else
			S.top = { rows = lineasDe(resultado), at = now() }
			publishTop()
		end
		finishPhase()
	end)
end

-- El historial de capas de una imagen (docker history).
local function runHistory(req: any): ()
	-- El panel manda el id de la imagen; `image` es el alias del formulario.
	local imagen = tostring(req.image or req.id or "")
	if imagen == "" then
		S.error = "history: falta la imagen"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "history"
	publishStatus()
	cli.json("docker", { "history", imagen, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "history: " .. err)
		else
			S.history = { rows = lineasDe(resultado), at = now() }
			publishHistory()
		end
		finishPhase()
	end)
end

-- Los cambios del sistema de archivos del contenedor (docker diff).
local function runDiff(req: any): ()
	local id = tostring(req.id or "")
	if id == "" then
		S.error = "diff: falta el contenedor"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "diff"
	publishStatus()
	cli.json("docker", { "diff", "--id", id, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "diff: " .. err)
		else
			S.diff = { rows = lineasDe(resultado), at = now() }
			publishDiff()
		end
		finishPhase()
	end)
end

-- ── puertos, límites y respaldo de volúmenes ─────────────────────────

-- Los puertos publicados por un contenedor. El panel los necesita para
-- ofrecer "abrir en el navegador": sin este dato habría que adivinar.
local function runPorts(req: any): ()
	local id = tostring(req.id or "")
	if id == "" then
		S.error = "ports: falta el contenedor"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "ports"
	publishStatus()
	cli.json("docker", { "port", id, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "ports: " .. err)
		else
			S.ports = { rows = lineasDe(resultado), id = id, at = now() }
			publishPorts()
		end
		finishPhase()
	end)
end

-- Busca imágenes en Docker Hub. No pide login: la búsqueda es anónima.
local function runHubSearch(req: any): ()
	local termino = tostring(req.query or req.term or "")
	if termino == "" then
		S.error = "search: falta el término"
		publishStatus()
		return
	end
	-- Un término que empieza con "-" se convertiría en una opción de docker.
	if string.sub(termino, 1, 1) == "-" then
		S.error = "search: el término no puede empezar con -"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "search"
	publishStatus()
	cli.json("docker", { "search", termino, "--limit", "25", "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "search: " .. err)
		else
			-- El CLI pide `docker search --format json`: una línea JSON por
			-- resultado. Se parsea acá para que el panel no dependa del
			-- formato de tabla de texto (se rompía con las descripciones).
			local filas: { any } = {}
			for _, linea in ipairs(lineasDe(resultado)) do
				local ok, dato = pcall(noctalia.json.decode, linea)
				if ok and type(dato) == "table" and dato.Name ~= nil then
					table.insert(filas, {
						name = tostring(dato.Name),
						description = tostring(dato.Description or ""),
						stars = tonumber(dato.StarCount) or 0,
						official = tostring(dato.IsOfficial) == "true",
					})
				end
			end
			S.hub = { rows = filas, query = termino, at = now() }
			publishHub()
		end
		finishPhase()
	end)
end

-- Límites de CPU y memoria de un contenedor vivo (`docker update`).
local function runUpdateLimits(req: any): ()
	local id = tostring(req.id or "")
	local cpus = tostring(req.cpus or "")
	local memoria = tostring(req.memory or "")
	if id == "" then
		S.error = "update: falta el contenedor"
		publishStatus()
		return
	end
	if cpus == "" and memoria == "" then
		S.error = "update: falta al menos un límite (CPU o memoria)"
		publishStatus()
		return
	end
	local args = { "update", "--id", id }
	if cpus ~= "" then
		table.insert(args, "--cpus")
		table.insert(args, cpus)
	end
	if memoria ~= "" then
		table.insert(args, "--memory")
		table.insert(args, memoria)
	end
	table.insert(args, "--json")
	S.busy = true
	S.phase = "update"
	publishStatus()
	cli.json("docker", args, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "update: " .. err)
		else
			noctalia.notify("Docker", "límites aplicados a " .. id)
			refresh()
		end
		finishPhase()
	end)
end

-- Respalda un volumen a un tar.gz. La ruta la elige el usuario: por defecto
-- el panel propone ~/Documents/backups/<volumen>.tar.gz.
local function runVolumeExport(req: any): ()
	local nombre = tostring(req.name or "")
	local destino = tostring(req.out or "")
	if nombre == "" or destino == "" then
		S.error = "volume-export: faltan el volumen y la ruta"
		publishStatus()
		return
	end
	if string.sub(nombre, 1, 1) == "-" or string.sub(destino, 1, 1) == "-" then
		S.error = "volume-export: ni el volumen ni la ruta pueden empezar con -"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "volume-export"
	publishStatus()
	local ruta = noctalia.expandPath(destino)
	cli.json("docker", { "volume-export", "--name", nombre, "--out", ruta, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "respaldo: " .. err)
		else
			noctalia.notify("Docker", "respaldo de " .. nombre .. " en " .. ruta)
		end
		finishPhase()
	end)
end

-- Restaura un tar.gz dentro de un volumen (lo crea si no existe).
local function runVolumeImport(req: any): ()
	local nombre = tostring(req.name or "")
	local origen = tostring(req.inPath or req.file or "")
	if nombre == "" or origen == "" then
		S.error = "volume-import: faltan el volumen y el archivo"
		publishStatus()
		return
	end
	if string.sub(nombre, 1, 1) == "-" or string.sub(origen, 1, 1) == "-" then
		S.error = "volume-import: ni el volumen ni el archivo pueden empezar con -"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "volume-import"
	publishStatus()
	local ruta = noctalia.expandPath(origen)
	cli.json("docker", { "volume-import", "--name", nombre, "--in", ruta, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "restauración: " .. err)
		else
			noctalia.notify("Docker", "restaurado " .. nombre)
			refresh()
		end
		finishPhase()
	end)
end

-- Aplana un JSON de docker a filas {key, value}. El `inspect` devuelve un
-- objeto anidado de 150+ líneas: mostrarlo crudo en el panel es ilegible y
-- las líneas largas se salen del ancho. Se corta a 3 niveles, que es donde
-- está todo lo útil, y se ordenan las claves para que no salgan mezcladas.
local function aplanarInspect(valor: any, prefijo: string, salida: { any }, nivel: number): ()
	if nivel > 3 or #salida > 220 then
		return
	end
	if type(valor) ~= "table" then
		table.insert(salida, { key = prefijo, value = tostring(valor) })
		return
	end
	local claves: { string } = {}
	for clave in pairs(valor) do
		table.insert(claves, tostring(clave))
	end
	table.sort(claves)
	for _, clave in ipairs(claves) do
		local nombre = if prefijo == "" then clave else prefijo .. "." .. clave
		aplanarInspect(valor[clave], nombre, salida, nivel + 1)
	end
end

local function filasDeInspect(texto: string): { any }
	local filas: { any } = {}
	local ok, dato = pcall(noctalia.json.decode, texto)
	if ok and type(dato) == "table" then
		-- `docker inspect` devuelve un array de un elemento.
		local raiz = if #dato > 0 then dato[1] else dato
		aplanarInspect(raiz, "", filas, 1)
	end
	return filas
end

-- Detalle de un volumen o de una red. Se muestran como líneas de texto
-- (el JSON crudo de docker es ilegible en un panel).
local function runVolumeInspect(req: any): ()
	local nombre = tostring(req.name or "")
	if nombre == "" then
		S.error = "volume-inspect: falta el volumen"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "volume-inspect"
	publishStatus()
	cli.json("docker", { "volume-inspect", nombre, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "volume-inspect: " .. err)
		else
			S.volinfo = { rows = filasDeInspect(tostring(resultado.output or "")), name = nombre, at = now() }
			publishVolInfo()
		end
		finishPhase()
	end)
end

local function runNetworkInspect(req: any): ()
	local nombre = tostring(req.name or "")
	if nombre == "" then
		S.error = "network-inspect: falta la red"
		publishStatus()
		return
	end
	S.busy = true
	S.phase = "network-inspect"
	publishStatus()
	cli.json("docker", { "network-inspect", nombre, "--json" }, function(resultado: any, err: string?)
		if err then
			S.error = err
			noctalia.notifyError("Docker", "network-inspect: " .. err)
		else
			S.netinfo = { rows = filasDeInspect(tostring(resultado.output or "")), name = nombre, at = now() }
			publishNetInfo()
		end
		finishPhase()
	end)
end

-- ── logs en vivo ───────────────────────────────────────────────────────
--
-- Noctalia no tiene timers ni exec asíncrono en Lua: un `docker logs -f`
-- no se puede mantener desde acá. El seguimiento lo hace el CLI
-- (`b3l0w-docker logs-stream`), que deja el proceso desacoplado escribiendo
-- a un archivo. El service sólo dispara y publica la RUTA; el panel la lee
-- con `readFile` y se refresca con un botón.
-- `cli.text` es ASÍNCRONO: una función que haga `cli.text(...)` y devuelva
-- la ruta retorna antes de que llegue la respuesta (siempre nil). El estado
-- se publica dentro del callback.
local function seguirLogs(id: string): ()
	if id == "" then
		return
	end
	cli.text("docker", { "logs-stream", id }, function(texto: string?, err: string?)
		if err then
			noctalia.log("[b3l0w-containers] logs-stream: " .. err)
			noctalia.state.set(LOGSTREAM_KEY, { id = id, active = false, error = err })
			return
		end
		local ruta = (texto or ""):gsub("%s+$", "")
		if ruta == "" then
			noctalia.state.set(LOGSTREAM_KEY, { id = id, active = false, error = "sin ruta" })
			return
		end
		noctalia.state.set(LOGSTREAM_KEY, { id = id, active = true, path = ruta, at = now() })
	end)
end

local function cortarLogs(id: string): ()
	if id ~= "" then
		cli.text("docker", { "logs-stop", id }, function(_: string?, err: string?)
			if err then
				noctalia.log("[b3l0w-containers] logs-stop: " .. err)
			end
		end)
	end
	noctalia.state.set(LOGSTREAM_KEY, { id = id, active = false })
end

-- ── compose: el YAML del stack ─────────────────────────────────────────

local function cargarCompose(nombre: string): ()
	if nombre == "" then
		return
	end
	cli.text("docker", { "compose-file", nombre }, function(texto: string?, err: string?)
		if err then
			noctalia.log("[b3l0w-containers] compose-file: " .. err)
			noctalia.state.set(COMPOSEFILE_KEY, { name = nombre, error = err })
			return
		end
		local limpio = texto or ""
		-- Un compose grande no pasa por el bus de estado: se corta.
		if #limpio > 12000 then
			limpio = string.sub(limpio, 1, 12000) .. "\n… (cortado)"
		end
		noctalia.state.set(COMPOSEFILE_KEY, { name = nombre, text = limpio, at = now() })
	end)
end

-- ── requests ─────────────────────────────────────────────────────────

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
	if action == "refresh" then
		refresh()
	elseif action == "logs" then
		loadLogs(tostring(req.id or ""))
	elseif action == "detail" then
		loadDetail(tostring(req.id or ""))
	elseif action == "undetail" then
		S.detailId = nil
		S.detail = nil
		publishDetail()
	elseif action == "disk" then
		loadDisk()
	elseif action == "info" then
		loadInfo()
	elseif action == "stats" then
		loadStats()
	elseif action == "events" then
		loadEvents()
	elseif action == "exec" then
		runExec(req)
	elseif action == "commit" then
		runCommit(req)
	elseif action == "rename" then
		runRename(req)
	elseif action == "tag" then
		runTag(req)
	elseif action == "cp" then
		runCopy(req)
	elseif action == "build" then
		runBuild(req)
	elseif action == "compose" then
		composeAction(tostring(req.project or ""), tostring(req.verb or "restart"))
	elseif action == "prune" then
		prune(tostring(req.what or ""))
	elseif action == "registry" then
		runRegistry(req)
	elseif action == "create" then
		runCreate(req)
	elseif action == "top" then
		runTop(req)
	elseif action == "history" then
		runHistory(req)
	elseif action == "diff" then
		runDiff(req)
	elseif action == "ports" then
		runPorts(req)
	elseif action == "update_limits" then
		runUpdateLimits(req)
	elseif action == "hub_search" then
		runHubSearch(req)
	elseif action == "volume_export" then
		runVolumeExport(req)
	elseif action == "volume_import" then
		runVolumeImport(req)
	elseif action == "volume_inspect" then
		runVolumeInspect(req)
	elseif action == "network_inspect" then
		runNetworkInspect(req)
	elseif action == "run" then
		runImage(req)
	elseif action == "logs_stream" then
		-- El cuerpo del IPC ES `req`: no hay un `payload` aparte.
		seguirLogs(tostring(req.id or ""))
	elseif action == "logs_stop" then
		cortarLogs(tostring(req.id or ""))
	elseif action == "compose_file" then
		cargarCompose(tostring(req.name or ""))
	elseif action == "view" then
		noctalia.state.set(SCREEN_KEY, {
			tab = tostring(req.tab or "containers"),
			id = req.id,
			detTab = req.detTab,
			-- Contexto para las vistas que lo necesitan: el detalle de un
			-- volumen/red y el formulario de respaldo. Sin esto la vista
			-- abría vacía porque el nombre no viajaba.
			name = req.name,
			kind = req.kind,
			nonce = tostring(now()) .. ":" .. nonce,
		})
	elseif ACTIONS[action] ~= nil then
		runAction(action, tostring(req.id or ""))
	else
		-- Un typo en el panel o un payload roto no puede quedar invisible.
		noctalia.log("[b3l0w-containers] accion desconocida: " .. tostring(action))
		noctalia.notifyError("Docker", "acción desconocida: " .. tostring(action))
	end
end

noctalia.state.watch(REQUEST_KEY, handle)

function update(): ()
	if S.busy then
		return
	end
	if now() - S.lastAt >= refreshSeconds() then
		refresh()
		if S.detailId ~= nil then
			local id = S.detailId
			S.detailId = nil
			loadDetail(id)
		end
	end
end

function onEnable(): ()
	publishStatus()
	refresh()
	loadDisk()
	loadInfo()
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

publishStatus()
