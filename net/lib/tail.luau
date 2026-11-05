--!nonstrict
-- Parseo de Tailscale. Todo puro: entra texto, sale una tabla normalizada.
--
-- Los tres formatos que importan son distintos entre sí (`status --json` es
-- JSON, `netcheck` y `ping` son prosa con indentación), así que cada uno tiene
-- su parser y el service sólo publica el resultado.

local fmt = require("./fmt.luau")

local M = {}

local function as_string(value: any): string
	if type(value) == "string" then
		return value
	end
	return ""
end

local function as_list(value: any): table
	if type(value) == "table" then
		return value
	end
	return {}
end

-- Primera IPv4 de la lista de TailscaleIPs (la IPv6 trae ':').
local function first_v4(addresses: any): string
	for _, entry in ipairs(as_list(addresses)) do
		if type(entry) == "string" and not fmt.is_v6(entry) then
			return entry
		end
	end
	return ""
end

local function first_v6(addresses: any): string
	for _, entry in ipairs(as_list(addresses)) do
		if type(entry) == "string" and fmt.is_v6(entry) then
			return entry
		end
	end
	return ""
end

-- MagicDNS viene con punto final ("host.tail.ts.net."): el punto es del registro
-- DNS y en un panel sólo molesta al copiar.
local function strip_dot(value: any): string
	local text = as_string(value)
	if text ~= "" and string.sub(text, -1) == "." then
		return string.sub(text, 1, -2)
	end
	return text
end

-- Un peer va por relay DERP cuando Tailscale no logró un camino directo: en el
-- JSON eso es `CurAddr` vacío con `Relay` no vacío. Si está offline no se marca:
-- no hay conexión que explicar y el ámbar confundiría.
local function peer_from(key: string, raw: any): table
	local node = type(raw) == "table" and raw or {}
	local online = node.Online == true
	local relay = as_string(node.Relay)
	local cur = as_string(node.CurAddr)
	local ip4 = first_v4(node.TailscaleIPs)
	local label = as_string(node.HostName)
	if label == "" then
		label = strip_dot(node.DNSName)
	end
	if label == "" then
		label = key
	end
	return {
		key = key,
		-- El ID del nodo (la clave del mapa en `tailscale status --json`).
		-- Es lo que necesita `tailscale set --exit-node=<id>`.
		id = key,
		name = label,
		dns = strip_dot(node.DNSName),
		os = as_string(node.OS),
		ip4 = ip4,
		ip6 = first_v6(node.TailscaleIPs),
		online = online,
		active = node.Active == true,
		relay = relay,
		cur = cur,
		relayed = online and cur == "" and relay ~= "",
		last_seen = fmt.iso_epoch(node.LastSeen),
	}
end

local function peer_order(a: table, b: table): boolean
	if a.online ~= b.online then
		return a.online
	end
	return string.lower(a.name) < string.lower(b.name)
end

-- payload: `tailscale status --json` ya decodificado.
-- ip4_raw: salida de `tailscale ip -4` (la fuente que pide el pedido), usada si
-- el JSON no trae la dirección.

-- ── preferencias de Tailscale ───────────────────────────────────────────

-- `tailscale get --json` devuelve un objeto plano. El probe lo pasa
-- minificado (sin espacios ni saltos) para que viaje en una línea.
--
-- Las preferencias que importan: accept-dns (MagicDNS), accept-routes
-- (subnet routers), exit-node (salir por otro nodo), advertise-routes
-- (este nodo como router), shields-up (no aceptar conexiones) y hostname.
function M.parse_prefs(raw: any): table
	local texto = as_string(raw)
	if texto == "" then
		return {}
	end
	local ok, decoded = pcall(noctalia.json.decode, texto)
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	local prefs = {}
	for key, value in pairs(decoded) do
		prefs[tostring(key)] = value
	end
	return prefs
end

-- ¿Está configurado un exit node?
function M.exit_node(prefs: any): string
	if type(prefs) ~= "table" then
		return ""
	end
	return as_string(prefs["exit-node"])
end

-- ¿Se aceptan rutas (subnet routers)?
function M.accept_routes(prefs: any): boolean
	if type(prefs) ~= "table" then
		return false
	end
	return prefs["accept-routes"] == true
end

-- ¿Se usa el DNS de Tailscale?
function M.accept_dns(prefs: any): boolean
	if type(prefs) ~= "table" then
		return false
	end
	return prefs["accept-dns"] == true
end

-- ¿Este nodo anuncia rutas?
function M.advertised_routes(prefs: any): string
	if type(prefs) ~= "table" then
		return ""
	end
	return as_string(prefs["advertise-routes"])
end

function M.parse(payload: any, ip4_raw: string): table
	local root = type(payload) == "table" and payload or {}
	local self_node = type(root.Self) == "table" and root.Self or {}
	local backend = as_string(root.BackendState)
	if backend == "" then
		backend = "Unknown"
	end

	local peers = {}
	for key, raw in pairs(as_list(root.Peer)) do
		table.insert(peers, peer_from(tostring(key), raw))
	end
	table.sort(peers, peer_order)

	local online, relayed = 0, 0
	for _, peer in ipairs(peers) do
		if peer.online then
			online = online + 1
		end
		if peer.relayed then
			relayed = relayed + 1
		end
	end

	local ip4 = fmt.trim(ip4_raw)
	if ip4 == "" then
		ip4 = first_v4(self_node.TailscaleIPs)
	end

	return {
		ok = true,
		backend = backend,
		running = backend == "Running",
		self = {
			hostname = as_string(self_node.HostName),
			dns = strip_dot(self_node.DNSName),
			ip4 = ip4,
			ip6 = first_v6(self_node.TailscaleIPs),
			online = self_node.Online == true,
			-- El estado de conexión del NODO LOCAL. `CurAddr` vacío + `Relay`
			-- con valor significa que esta máquina también va por DERP: sin
			-- esto el panel decía "1 par por relay" y la causa de la latencia
			-- quedaba invisible.
			cur_addr = as_string(self_node.CurAddr),
			relay = as_string(self_node.Relay),
			peer_relay = as_string(self_node.PeerRelay),
			direct = as_string(self_node.CurAddr) ~= "",
			exit_node = self_node.ExitNode == true,
			health = as_list(self_node.Health),
			capabilities = #as_list(self_node.CapMap),
		},
		peers = peers,
		counts = {
			total = #peers,
			online = online,
			relayed = relayed,
		},
	}
end

-- `tailscale netcheck`. Antes del bloque "Report:" hay decenas de líneas de log
-- de portmap que no aportan nada: se descartan.
function M.parse_netcheck(text: string): table
	local out = {
		ok = false,
		udp = "",
		ipv4 = "",
		ipv6 = "",
		mapping = "",
		portmap = "",
		nearest = "",
		captive = "",
		derps = {},
	}
	local in_report = false
	for _, line in ipairs(fmt.lines(text)) do
		if string.match(line, "^%s*Report:%s*$") ~= nil then
			in_report = true
		elseif in_report then
			local key, value = string.match(line, "^%s*%*%s*([^:]+):%s*(.*)$")
			if key ~= nil then
				out.ok = true
				local name = string.lower(fmt.trim(key))
				if name == "udp" then
					out.udp = fmt.trim(value)
				elseif name == "ipv4" then
					out.ipv4 = fmt.trim(value)
				elseif name == "ipv6" then
					out.ipv6 = fmt.trim(value)
				elseif name == "mappingvariesbydestip" then
					out.mapping = fmt.trim(value)
				elseif name == "portmapping" then
					out.portmap = fmt.trim(value)
				elseif name == "nearest derp" then
					out.nearest = fmt.trim(value)
				elseif name == "captiveportal" then
					out.captive = fmt.trim(value)
				end
			else
				local code, ms, label = string.match(line, "^%s*%-%s*(%w+):%s*([%d%.]+)ms%s*%(([^%)]*)%)")
				if code ~= nil then
					table.insert(out.derps, {
						code = code,
						ms = tonumber(ms) or 0,
						label = label,
					})
				end
			end
		end
	end
	return out
end

-- `tailscale ping -c N`. Tres respuestas posibles, todas reales en esta máquina:
--   pong from 100.x (host) via 192.168.1.12:46877 in 12ms      -> directo
--   pong from 100.x (host) via DERP(mia) in 120ms             -> relay
--   ping "100.x" timed out                                    -> sin respuesta
function M.parse_ping(text: string): table
	local out = {
		ok = false,
		direct = false,
		relay = "",
		via = "",
		latency = nil,
		lines = 0,
		detail = "",
	}
	for _, line in ipairs(fmt.lines(text)) do
		local clean = fmt.trim(line)
		if clean ~= "" then
			out.lines = out.lines + 1
			if string.sub(clean, 1, 9) == "pong from" then
				out.ok = true
				out.detail = clean
				local via = string.match(clean, " via ([^ ]+) ")
				if via == nil then
					via = string.match(clean, " via (.+)$")
				end
				out.via = via or ""
				local ms = string.match(clean, " in (%d+)ms")
				if ms ~= nil then
					out.latency = tonumber(ms)
				end
				if string.sub(out.via, 1, 4) == "DERP" then
					out.relay = string.match(out.via, "%((%w+)%)") or out.via
				else
					out.direct = out.via ~= ""
				end
			elseif string.find(clean, "timed out", 1, true) ~= nil
				or string.find(clean, "no reply", 1, true) ~= nil then
				out.detail = clean
			end
		end
	end
	return out
end

return M
