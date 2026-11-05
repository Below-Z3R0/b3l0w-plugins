--!nonstrict
-- Service de b3l0w/net: dueño de todos los procesos y del estado compartido.
--
-- Dos fuentes, una sola superficie de lectura:
--   Tailscale — `tailscale status --json` (+ `tailscale ip -4`), `netcheck` y
--               `ping` sólo bajo demanda.
--   Sunshine  — systemctl --user, puertos de `ss`, `curl` al panel web, el log
--               (encoder y última sesión) y la config (`capture`, `output_name`).
--
-- Regla dura del plugin: NINGUNA acción para, deshabilita ni reinicia un
-- servicio. Lo único que escribe es `reset-failed` + `start` en un unit que ya
-- está en `failed` (donde no hay sesión que cortar), y abrir el panel web.
-- Cualquier otra cosa que requiera parar algo se muestra como texto.
--
-- Presupuesto: 25 ms de CPU por callback. Todo el trabajo es un `runAsync`
-- (el filtrado caro lo hace grep, no Luau) y el parseo es lineal sobre decenas
-- de líneas: 1 peer y 24 líneas de log en esta máquina.

local fmt = require("./lib/fmt.luau")
local sun = require("./lib/sun.luau")
local tail = require("./lib/tail.luau")
local store = require("./lib/store.luau")

local STATE_KEY = "b3l0w_net_state"
local STATUS_KEY = "b3l0w_net_status"
local REQUEST_KEY = "b3l0w_net_request"
local SCREEN_KEY = "b3l0w_net_screen"
local NETCHECK_KEY = "b3l0w_net_netcheck"
local PING_KEY = "b3l0w_net_ping"
local EXIT_NODES_KEY = "b3l0w_net_exit_nodes"

local SNAPSHOT_FILE = "snapshot.json"
local SNAPSHOT_VERSION = 1
local DEFAULT_REFRESH = 20
local MIN_REFRESH = 5
local FOLLOWUP_SECONDS = 6
local MAX_DETAIL = 160
local MARK_IP4 = "@@IP4"
local MARK_LOG = "@@LOG"

-- Un solo proceso para las dos consultas: el JSON y la IPv4 que pide el pedido.
local TS_CMD = "tailscale status --json 2>/dev/null\nprintf '" .. MARK_IP4 .. "\\n'\ntailscale ip -4 2>/dev/null | head -n1"

-- Un solo proceso para todo Sunshine. El log se filtra con grep: leer el archivo
-- entero en Luau se come el presupuesto del callback.
local SUN_CMD = [[
U=app-dev.lizardbyte.app.Sunshine.service
D="$HOME/.config/sunshine"
printf 'active=%s\n' "$(systemctl --user is-active "$U" 2>/dev/null || true)"
printf 'substate=%s\n' "$(systemctl --user show -p SubState --value "$U" 2>/dev/null || true)"
printf 'nrestarts=%s\n' "$(systemctl --user show -p NRestarts --value "$U" 2>/dev/null || true)"
printf 'ports=%s\n' "$(ss -tln 2>/dev/null | grep -oE ':(47984|47989|47990|48010)\b' | sort -u | tr '\n' ' ')"
	# Conexiones ESTABLISHED a los puertos de Sunshine: la verdad de campo
	# sobre si hay un cliente conectado. El log no registra el cierre abrupto
	# (si el cliente muere de golpe no hay DISCONNECTED) y el panel mostraba
	# "sesión activa" con cero conexiones.
	printf 'established=%s\n' "$(ss -tn state established 2>/dev/null | grep -cE ':(47984|47989|47990|48010)\b')"
printf 'http=%s\n' "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1:47990 2>/dev/null)"
printf 'capture=%s\n' "$(sed -n 's/^capture *= *//p' "$D"/*.conf 2>/dev/null | head -n1)"
printf 'output=%s\n' "$(sed -n 's/^output_name *= *//p' "$D"/*.conf 2>/dev/null | head -n1)"
printf 'encoder=%s\n' "$(sed -n 's/^encoder *= *//p' "$D"/*.conf 2>/dev/null | head -n1)"
	# Los nombres van separados por COMA en una sola línea: `fmt.kv` sólo
	# lee `clave=valor` en una línea, así que una lista multilínea dejaba el
	# valor vacío. Con `paste -sd' '` (un espacio) `parse_outputs` matcheaba
	# `^(%S+)%s` y devolvía sólo el primer monitor.
	printf 'outputs=%s\n' "$(umbriel outputs 2>/dev/null | grep -E '^[^ ]' | awk '{print $1}' | paste -sd, -)"
printf 'localip=%s\n' "$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | head -n1)"
	# Preferencias de Tailscale: accept-dns, accept-routes, exit-node,
	# advertise-routes y shields-up. Son las que el usuario cambia desde la
	# interfaz de tailscale y el plugin no las mostraba.
	printf 'prefs=%s\n' "$(tailscale get --json 2>/dev/null | tr -d '\n ')"
	# serve/funnel: si hay algo servido a la tailnet o a internet.
	printf 'serve=%s\n' "$(tailscale serve status 2>/dev/null | tr '\n' '|')"
printf '@@LOG\n'
	# El encoder se busca en TODO el log, no en las últimas 600 líneas:
	# Sunshine sólo lo loguea al arrancar y el poll HTTP del propio plugin
	# ("Web UI: not authorized") genera 3 líneas por minuto, así que la
	# línea del encoder salía de la ventana en ~26 minutos y el panel
	# mostraba el encoder como "—" y la sesión como desaparecida.
	# Para la sesión alcanza con las últimas líneas: es un evento reciente.
	grep -hE 'Found H\.264 encoder:|Found HEVC encoder:' "$D"/*.log 2>/dev/null | tail -n 4
	grep -hE 'CLIENT CONNECTED|CLIENT DISCONNECTED|Undo Cmd' "$D"/*.log 2>/dev/null | tail -n 24
]]

local S = {
	phase = "idle",
	at = 0,
	ts = nil,
	sun = nil,
	prefs = {},
	local_ip = "",
	busy = false,
	busyWhat = nil,
	queue = {},
	lastNonce = "",
	tsAt = 0,
	sunAt = 0,
	followupAt = nil,
}

local function now(): number
	return os.time()
end

local function tr(key: string, subst: any): string
	return noctalia.tr(key, subst)
end

local function cfg(key: string): any
	return noctalia.getConfig(key)
end

-- ── publicación ──────────────────────────────────────────────────────

local function resolvePhase()
	if S.ts == nil and S.sun == nil then
		S.phase = if S.busy then "loading" else "idle"
	elseif S.ts ~= nil and S.ts.err ~= nil and S.sun == nil then
		S.phase = "error"
	else
		S.phase = "ready"
	end
end

local function publish()
	resolvePhase()
	noctalia.state.set(STATE_KEY, {
		at = S.at,
		phase = S.phase,
		local_ip = S.local_ip,
		ts = S.ts,
		sun = S.sun,
		-- Las preferencias de Tailscale (MagicDNS, rutas, exit node,
		-- shields-up). Sin esto el panel no las tenía y la sección de
		-- preferencias nunca aparecía.
		prefs = S.prefs,
	})

	local counts = (S.ts and S.ts.counts) or {}
	local backend = (S.ts and S.ts.backend) or "unknown"
	noctalia.state.set(STATUS_KEY, {
		busy = S.busy,
		what = S.busyWhat,
		phase = S.phase,
		at = S.at,
		tsOk = S.ts ~= nil and S.ts.ok == true,
		backend = backend,
		peersOnline = tonumber(counts.online) or 0,
		peersTotal = tonumber(counts.total) or 0,
		relayed = tonumber(counts.relayed) or 0,
		sunState = (S.sun and S.sun.state) or "unknown",
		sunOk = S.sun ~= nil and S.sun.active == true,
	})
end

-- ── persistencia ─────────────────────────────────────────────────────

local function saveSnapshot()
	local ok = store.save(SNAPSHOT_FILE, {
		version = SNAPSHOT_VERSION,
		at = S.at,
		ts = S.ts,
		sun = S.sun,
		local_ip = S.local_ip,
	})
	if not ok then
		noctalia.log("[b3l0w-net] no se pudo guardar snapshot.json")
	end
end

-- Sembrar el último estado conocido hace que el panel abra con datos en vez de
-- esqueletos: el primer poll tarda lo que tarde `tailscale status`.
local function loadSnapshot()
	local data = store.load(SNAPSHOT_FILE)
	if type(data) ~= "table" or data.version ~= SNAPSHOT_VERSION then
		return
	end
	if type(data.ts) == "table" then
		S.ts = data.ts
	end
	if type(data.sun) == "table" then
		S.sun = data.sun
	end
	S.at = tonumber(data.at) or 0
	if type(data.local_ip) == "string" then
		S.local_ip = data.local_ip
	end
end

-- ── procesos ─────────────────────────────────────────────────────────

local function run(command: string, cb: (number, string, string) -> ()): ()
	noctalia.runAsync(command, function(result: any)
		local code = result and result.exitCode or -1
		cb(code, (result and result.stdout) or "", (result and result.stderr) or "")
	end)
end

local function split_at(text: string, marker: string): (string, string)
	local position = string.find(text, marker, 1, true)
	if position == nil then
		return text, ""
	end
	return string.sub(text, 1, position - 1), string.sub(text, position + #marker)
end

local function clampDetail(value: any): string
	local text = fmt.trim(value)
	if #text > MAX_DETAIL then
		text = string.sub(text, 1, MAX_DETAIL - 3) .. "..."
	end
	return text
end

local function emptyTs(err: string?): table
	return {
		ok = false,
		backend = "unknown",
		running = false,
		self = { hostname = "", dns = "", ip4 = "", ip6 = "", online = false },
		peers = {},
		counts = { total = 0, online = 0, relayed = 0 },
		err = err,
	}
end

local function probeTs(cb)
	if not noctalia.commandExists("tailscale") then
		S.ts = emptyTs(tr("service.error.ts_missing"))
		S.tsAt = now()
		publish()
		cb()
		return
	end

	run(TS_CMD, function(code, stdout, stderr)
		local body, ip4 = split_at(stdout, MARK_IP4)
		local decoded = noctalia.json.decode(body)
		if type(decoded) ~= "table" then
			local detail = clampDetail(if fmt.trim(stderr) ~= "" then stderr else stdout)
			if detail == "" then
				detail = "exit " .. tostring(code)
			end
			S.ts = emptyTs(tr("service.error.ts_exit", { detail = detail }))
		else
			S.ts = tail.parse(decoded, ip4)
			-- Con el daemon parado Tailscale igual imprime JSON (BackendState
			-- Stopped): eso es "offline", no un error del plugin.
			if not S.ts.running then
				S.ts.ok = false
			end
		end
		S.tsAt = now()
		publish()
		cb()
	end)
end

local function probeSun(cb)
	run(SUN_CMD, function(_code, stdout)
		local map, log_lines = fmt.kv(stdout, MARK_LOG)
		local parsed = sun.parse(map, log_lines)
		S.sun = parsed
		-- Las preferencias de Tailscale vienen en el mismo probe (evita un
		-- segundo proceso): `tailscale get --json` minificado en una línea.
		local prefs = tail.parse_prefs(map.prefs)
		if next(prefs) ~= nil then
			S.prefs = prefs
		end
		S.sunAt = now()
		-- El probe trae la IPv4 con máscara ("192.168.1.18/24"): el panel la
		-- concatena en una URL.
		local ip = string.match(tostring(parsed.local_ip or ""), "^([%d%.]+)") or ""
		if ip ~= "" then
			S.local_ip = ip
		end
		publish()
		cb()
	end)
end

-- ── acciones ─────────────────────────────────────────────────────────

-- ── preferencias de Tailscale ───────────────────────────────────────────

-- Cambiar una preferencia: `tailscale set <clave>=<valor>`.
--
-- `tailscale set` puede tardar (reconfigura el daemon), así que el comando
-- lleva timeout y el resultado se publica como feedback.
local function setPref(clave: string, valor: string, cb)
	-- `tailscale set` escribe en /var/lib/tailscale: hace falta root. Se usa
	-- `sudo -n` (NOPASSWD) y el prefijo `--`: sin él tailscale responde
	-- "too many non-flag arguments".
	local comando = "sudo -n tailscale set --" .. fmt.quote(clave .. "=" .. valor)
	run("timeout 30 " .. comando .. " 2>&1", function(code, stdout, stderr)
		local detalle = fmt.trim(stdout)
		if code ~= 0 then
			detalle = fmt.trim(stderr)
		end
		if detalle == "" then
			detalle = tr("service.prefs.ok")
		end
		S.feedback = detalle
		-- Se relee el estado para que el panel muestre el valor nuevo.
		probeTs(function()
			publish()
			if cb then
				cb()
			end
		end)
	end)
end

local function runNetcheck(cb)
	noctalia.state.set(NETCHECK_KEY, { running = true, at = now() })
	run("timeout 25 tailscale netcheck 2>&1", function(_code, stdout, stderr)
		local parsed = tail.parse_netcheck(stdout)
		parsed.running = false
		parsed.at = now()
		if not parsed.ok then
			local detail = clampDetail(if fmt.trim(stderr) ~= "" then stderr else stdout)
			parsed.err = tr("service.error.netcheck", { detail = detail })
		end
		noctalia.state.set(NETCHECK_KEY, parsed)
		noctalia.log("[b3l0w-net] netcheck udp=" .. tostring(parsed.udp) .. " derp=" .. tostring(parsed.nearest))
		cb()
	end)
end

local function runPing(target: string, cb)
	local ip = fmt.trim(target)
	-- Validación estricta: `^[%w%.:%-]+$` aceptaba "-x", "--help" y "--json".
	-- Con `fmt.quote` no hay inyección de shell, pero sí de FLAGS:
	-- `tailscale ping -c 3 '--help'` imprime el usage en vez de hacer ping.
	-- Se acepta sólo IPv4 (4 octetos) o IPv6 (hex y ':').
	local esIPv4 = string.match(ip, "^(%d+%.%d+%.%d+%.%d+)$") ~= nil
	local esIPv6 = string.match(ip, "^[%x:%.]+$") ~= nil
	local esHostname = string.match(ip, "^[%w][%w%-]*$") ~= nil
	if ip == "" or not (esIPv4 or esIPv6 or esHostname) then
		noctalia.notifyError(tr("plugin.title"), tr("service.error.ping_target"))
		cb()
		return
	end
	-- Un hostname no puede empezar con '-': sería un flag.
	if string.sub(ip, 1, 1) == "-" then
		noctalia.notifyError(tr("plugin.title"), tr("service.error.ping_target"))
		cb()
		return
	end

	noctalia.state.set(PING_KEY, { ip = ip, state = "running", at = now() })
	-- timeout 10: `tailscale ping` a un peer por relay puede quedarse colgado
	-- varios segundos por intento y sin tope el botón nunca vuelve.
	run("timeout 10 tailscale ping -c 3 " .. fmt.quote(ip) .. " 2>&1", function(code, stdout)
		local result = tail.parse_ping(stdout)
		local out = {
			ip = ip,
			at = now(),
			ok = result.ok,
			direct = result.direct,
			relay = result.relay,
			via = result.via,
			latency = result.latency,
			state = if result.ok then "ok" else "fail",
			detail = clampDetail(result.detail),
		}
		if not result.ok and out.detail == "" then
			out.detail = "exit " .. tostring(code)
		end
		noctalia.state.set(PING_KEY, out)
		noctalia.log(
			"[b3l0w-net] ping " .. ip .. " ok=" .. tostring(result.ok)
				.. " via=" .. tostring(result.via) .. " ms=" .. tostring(result.latency)
		)
		cb()
	end)
end

-- Único camino que escribe sobre el unit: reset-failed + start, y sólo si está
-- en failed. Nunca stop, disable ni restart. Con el unit en failed no hay sesión
-- activa, así que este botón no puede cortar un stream.
local function resetFailed(cb)
	local state = (S.sun and S.sun.state) or ""
	if state ~= "failed" then
		noctalia.notify(tr("plugin.title"), tr("service.reset_needs_failed"))
		cb()
		return
	end

	local command = "systemctl --user reset-failed " .. sun.UNIT
		.. " && systemctl --user start " .. sun.UNIT

	run(command, function(code, _stdout, stderr)
		if code == 0 then
			noctalia.notify(tr("plugin.title"), tr("service.reset_done"))
			noctalia.log("[b3l0w-net] reset-failed + start ok")
			-- El unit tiene ExecStartPre=/bin/sleep 5: un probe inmediato lo ve
			-- en activating. Se vuelve a mirar a los 6 s.
			S.followupAt = now() + FOLLOWUP_SECONDS
		else
			local detail = clampDetail(stderr)
			if detail == "" then
				detail = "exit " .. tostring(code)
			end
			noctalia.notifyError(tr("plugin.title"), tr("service.reset_fail", { detail = detail }))
			noctalia.log("[b3l0w-net] reset-failed fallo: " .. detail)
		end
		probeSun(function()
			cb()
		end)
	end)
end

local function openWeb(cb)
	local ip = S.local_ip
	if ip == "" then
		ip = "127.0.0.1"
	end
	local url = "https://" .. ip .. ":" .. tostring(sun.WEB_PORT)
	run("xdg-open " .. fmt.quote(url) .. " >/dev/null 2>&1", function()
		noctalia.log("[b3l0w-net] panel web: " .. url)
		cb()
	end)
end

-- ── despacho ─────────────────────────────────────────────────────────

local function finish()
	S.busy = false
	S.busyWhat = nil
	publish()
	local nextTask = table.remove(S.queue, 1)
	if nextTask ~= nil then
		nextTask()
	end
end

-- Un trabajo pedido con el service ocupado se encola, nunca se descarta: un
-- `if busy then return end` deja el botón muerto sin ningún error visible.
local function runBusy(what: string, work: (any) -> ())
	if S.busy then
		table.insert(S.queue, function()
			runBusy(what, work)
		end)
		return
	end
	S.busy = true
	S.busyWhat = what
	publish()
	work(finish)
end

local function poll()
	runBusy("poll", function(done)
		probeTs(function()
			probeSun(function()
				S.at = now()
				saveSnapshot()
				-- Una línea por poll: es la evidencia de que el service leyó
				-- datos reales sin necesidad de mirar la pantalla.
				local counts = (S.ts and S.ts.counts) or {}
				local ports = (S.sun and S.sun.ports) or {}
				noctalia.log(
					"[b3l0w-net] poll ts=" .. tostring(S.ts and S.ts.backend)
						.. " peers=" .. tostring(tonumber(counts.online) or 0) .. "/" .. tostring(tonumber(counts.total) or 0)
						.. " relayed=" .. tostring(tonumber(counts.relayed) or 0)
						.. " sun=" .. tostring(S.sun and S.sun.state)
						.. " ports=" .. tostring(tonumber(ports.count) or 0)
						.. " http=" .. tostring(S.sun and S.sun.http)
						.. " enc=" .. tostring(S.sun and S.sun.encoder and S.sun.encoder.kind)
				)
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
		poll()
	elseif action == "netcheck" then
		runBusy("netcheck", runNetcheck)
	elseif action == "ping" then
		runBusy("ping", function(done)
			runPing(tostring(req.ip or ""), done)
		end)
	elseif action == "reset_failed" then
		runBusy("reset_failed", resetFailed)
	elseif action == "open_web" then
		runBusy("open_web", openWeb)
	elseif action == "open_settings" then
		noctalia.openSettings()
	elseif action == "set_pref" then
		-- Preferencias de Tailscale: accept-dns, accept-routes, shields-up,
		-- exit-node, advertise-routes.
		runBusy("set_pref", function(done)
			setPref(tostring(req.key or ""), tostring(req.value or ""), done)
		end)
	elseif action == "toggle_exit_node" then
		-- Poner o quitar el exit node: se consulta el actual y se cambia.
		-- El valor es el ID del nodo (`tailscale status --json` lo usa como
		-- clave del mapa de peers), no el nombre.
		runBusy("toggle_exit_node", function(done)
			local actual = tail.exit_node(S.prefs)
			if actual ~= "" then
				setPref("exit-node", "", done)
			else
				setPref("exit-node", tostring(req.node or ""), done)
			end
		end)
	elseif action == "list_exit_nodes" then
		-- Los nodos que pueden ser exit node: los peers online. Se
		-- publica en el estado para que el panel muestre el selector.
		local candidatos = {}
		local peers = if type(S.ts) == "table" then (S.ts.peers or {}) else {}
		for _, peer in ipairs(peers) do
			if peer.online == true and peer.id ~= nil and peer.id ~= "" then
				table.insert(candidatos, { id = peer.id, name = peer.name })
			end
		end
		noctalia.state.set(EXIT_NODES_KEY, candidatos)
		publish()
	elseif action == "toggle_dns" then
		runBusy("toggle_dns", function(done)
			local actual = tail.accept_dns(S.prefs)
			setPref("accept-dns", actual and "false" or "true", done)
		end)
	elseif action == "toggle_routes" then
		runBusy("toggle_routes", function(done)
			local actual = tail.accept_routes(S.prefs)
			setPref("accept-routes", actual and "false" or "true", done)
		end)
	elseif action == "screen" then
		noctalia.state.set(SCREEN_KEY, {
			tab = tostring(req.tab or "tailscale"),
			nonce = tostring(now()) .. ":" .. nonce,
		})
	else
		-- Un typo en el panel o un payload roto no puede quedar invisible.
		noctalia.log("[b3l0w-net] accion desconocida: " .. action)
		noctalia.notifyError(tr("plugin.title"), tr("panel.unknown_action", { action = action }))
	end
end

noctalia.state.watch(REQUEST_KEY, handle)

-- ── ciclo de vida ────────────────────────────────────────────────────

function update()
	local t = now()

	if S.followupAt ~= nil and t >= S.followupAt then
		S.followupAt = nil
		probeSun(function() end)
	end

	if S.busy then
		return
	end

	local seconds = tonumber(cfg("refresh_seconds")) or DEFAULT_REFRESH
	if seconds < MIN_REFRESH then
		seconds = DEFAULT_REFRESH
	end
	if S.at == 0 or t - S.at >= seconds then
		poll()
	end
end

function onEnable()
	publish()
	if not S.busy then
		poll()
	end
end

function onConfigChanged()
	publish()
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

if not noctalia.commandExists("tailscale") then
	if S.ts == nil then
		S.ts = emptyTs(tr("service.error.ts_missing"))
	end
end

publish()

noctalia.setUpdateInterval(1000)
