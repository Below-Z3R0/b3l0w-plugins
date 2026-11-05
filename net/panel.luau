--!nonstrict
-- Panel de b3l0w/net: estado de Tailscale y de Sunshine, sin tocar los servicios.
--
-- Dos pestañas:
--   Tailscale — self (hostname, MagicDNS, IPv4/IPv6), pares con estado, relay
--               DERP marcado en ámbar, netcheck bajo demanda y ping por par.
--   Sunshine  — unit, puertos, panel web, encoder en uso, última sesión y avisos
--               de config (capture / output_name).
--
-- El panel no lanza procesos: publica requests por estado y el service los
-- ejecuta. Lo único local es la copia al portapapeles, `panel.close()` y el
-- toggle del panel.
--
-- Nada acá ofrece parar, deshabilitar ni reiniciar un servicio. El único botón
-- que escribe sobre un unit corre reset-failed + start y sólo aparece cuando el
-- unit está en failed (donde no hay sesión que cortar).

local anim = require("./lib/anim.luau")
local fmt = require("./lib/fmt.luau")
local layout = require("./lib/layout.luau")
local prefs = require("./lib/prefs.luau")
local tail = require("./lib/tail.luau")
local theme = require("./lib/theme.luau")

local M: any = {}

local T = noctalia.tr

local STATE_KEY = "b3l0w_net_state"
local STATUS_KEY = "b3l0w_net_status"
local REQUEST_KEY = "b3l0w_net_request"
local SCREEN_KEY = "b3l0w_net_screen"
local NETCHECK_KEY = "b3l0w_net_netcheck"
local PING_KEY = "b3l0w_net_ping"

local WEB_PORT = 47990

local TABS = {
	{ value = "tailscale", key = "panel.tab.tailscale" },
	{ value = "sunshine", key = "panel.tab.sunshine" },
}

-- Código de aviso del service -> clave de traducción. Explícito a propósito: una
-- clave armada por concatenación se rompe sin que el auditor la vea.
local WARN_KEY = {
	capture = "panel.sun.warn_capture",
	output = "panel.sun.warn_output",
	encoder = "panel.sun.warn_encoder",
	ports = "panel.sun.warn_ports",
	http = "panel.sun.warn_http",
	state = "panel.sun.warn_state",
}

local PEER_H = { compact = 82, cozy = 90, comfortable = 100 }

local SELF_H = 96
local ACTIONS_H = 34
local NC_H = 124
local NC_RUN_H = 46
local NC_ERR_H = 56
local BANNER_H = 52
local PEERS_HEAD_H = 26
local PAGER_H = 30
local CARD_GAP = 6

local S = {
	tab = "tailscale",
	page = 1,
	confirm = nil,
	flash = nil,
	-- El selector de exit node: abierto/cerrado.
	exitPicker = false,
	flashAt = 0,
	requests = 0,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
}

-- Los snapshots van acá y no dentro de S: cualquier función de arriba que lea S
-- antes de su declaración ve un global nil.
local SNAP = { state = nil, status = nil, netcheck = nil, ping = nil }

-- El MODO lo pasa el entry (`panel_compact.luau` / `float.luau`), no el
-- setting: el setting `panel_mode` elige qué entry abre el WIDGET, pero si
-- el usuario abre el otro entry desde el launcher, el código calculaba los
-- anchos sobre el panel equivocado (560 en uno de 1180) y la card se
-- pasaba del borde.
local MODE = "compact"

local function panelWidth(): number
	return if MODE == "float" then 1180 else 560
end


-- La animación necesita un tick: sin él `S.anim.t` queda en 0 y las filas
-- se quedan con la opacidad del primer frame. Este hook lo publica el
-- entry (que es el que el host llama).
function onFrameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	S.anim.t = math.min(1, S.anim.t + (tonumber(delta) or 16) / (S.anim.ms or 220))
	render()
end

local function panelHeight(): number
	return if MODE == "float" then 880 else 720
end

-- El host recorta 12 px del ancho pedido del panel (contrato de layout del
-- host de Noctalia). Sin ese desconto el contenido se pasaba del borde.
local function inner(): number
	return panelWidth() - 12 - 12
end

-- el column raíz tiene padding 6 por lado: una fila más ancha se recorta
local function rowWidth(): number
	return inner() - 12
end

-- El cromo (cabecera + pestañas + pie) se calcula POR PARTES: cambia con el
-- modo y con la pestaña. Si la estimación se queda corta, la última fila
-- queda tapada contra el pie; por eso las partes se estiman de sobra.
local function bodyHeight(): number
	local cromo = layout.chrome({
		46, -- cabecera: título + chips de estado
		34, -- pestañas
		34, -- pie
	})
	return panelHeight() - cromo
end

local function peerHeight(): number
	return PEER_H[prefs.density()] or 100
end

-- El contador lleva siempre un número: dos acciones en el mismo milisegundo
-- comparten reloj y el service descartaría la segunda como duplicada.
local function send(payload)
	S.requests = S.requests + 1
	payload.nonce = tostring(math.floor(os.clock() * 1000)) .. ":" .. tostring(S.requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

local function snapshot(field, key)
	local cached = SNAP[field]
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(key)
	return if type(value) == "table" then value else {}
end

local function st()
	return snapshot("state", STATE_KEY)
end

local function status()
	return snapshot("status", STATUS_KEY)
end

local function netcheck()
	return snapshot("netcheck", NETCHECK_KEY)
end

local function ping()
	return snapshot("ping", PING_KEY)
end

local function tsTable(): table
	local value = st().ts
	return if type(value) == "table" then value else {}
end

local function sunTable(): table
	local value = st().sun
	return if type(value) == "table" then value else {}
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "wifi"
end

local function ageOf(stamp)
	return fmt.age_text(stamp, T, noctalia.trp)
end

-- Una píldora con borde y texto. `ui.box` es hoja: un label adentro se dropea
-- en silencio y queda un rectángulo vacío.
local function chip(text: string, color: string): any
	return ui.row({
		fill = theme.chip(),
		radius = 6,
		paddingH = 6,
		paddingV = 2,
		align = "center",
	}, {
		ui.label({ text = layout.ellipsis(text, 50), fontSize = 10, color = color }),
	})
end

local function copied(text: any)
	local value = tostring(text or "")
	if value == "" then
		return
	end
	noctalia.copyToClipboard(value, "text/plain")
	S.flash = T("panel.copied")
	S.flashAt = os.time()
	render()
end

-- Un bloque de diagnóstico listo para pegar en un issue: hoy hay que abrir
-- una terminal a mano y juntar tres comandos.
local function diagnostic(): string
	local ts = tsTable()
	local sun = sunTable()
	local nc = netcheck()
	local self_node = if type(ts.self) == "table" then ts.self else {}
	local lines: { string } = {}

	table.insert(lines, "== b3l0w-net diagnostic ==")
	table.insert(lines, "== Tailscale ==")
	table.insert(lines, "backend: " .. tostring(ts.backend or "?"))
	table.insert(lines, "host: " .. tostring(self_node.hostname or "?"))
	table.insert(lines, "ip4: " .. tostring(self_node.ip4 or "?"))
	table.insert(lines, "connection: " .. (if self_node.direct == true then "direct" else "relay:" .. tostring(self_node.relay or "?")))
	table.insert(lines, "exit_node: " .. tostring(self_node.exit_node == true))
	table.insert(lines, "peers: " .. tostring(tonumber((ts.counts or {}).total) or 0)
		.. " (online " .. tostring(tonumber((ts.counts or {}).online) or 0)
		.. ", relayed " .. tostring(tonumber((ts.counts or {}).relayed) or 0) .. ")")
	for _, peer in ipairs(if type(ts.peers) == "table" then ts.peers else {}) do
		table.insert(lines, string.format("  peer %s: online=%s relay=%s addr=%s",
			tostring(peer.name or peer.hostname or "?"),
			tostring(peer.online == true),
			tostring(peer.relay or ""),
			tostring(peer.addr or "")))
	end

	table.insert(lines, "== Netcheck ==")
	table.insert(lines, "udp: " .. tostring(nc.udp or "?"))
	table.insert(lines, "derp: " .. tostring(nc.nearest or "?"))
	table.insert(lines, "mapping: " .. tostring(nc.mapping or "?"))
	table.insert(lines, "captive: " .. tostring(nc.captive or "?"))

	table.insert(lines, "== Sunshine ==")
	table.insert(lines, "state: " .. tostring(sun.state or "?"))
	table.insert(lines, "substate: " .. tostring(sun.substate or "?"))
	table.insert(lines, "nrestarts: " .. tostring(tonumber(sun.nrestarts) or 0))
	table.insert(lines, "ports: " .. tostring(tonumber((sun.ports or {}).count) or 0))
	table.insert(lines, "http: " .. tostring(sun.http or "?"))
	table.insert(lines, "encoder: " .. tostring((sun.conf or {}).encoder or "?")
		.. " (detectado: " .. tostring((sun.encoder or {}).kind or "?") .. ")")
	table.insert(lines, "established: " .. tostring(tonumber(sun.established) or 0))
	table.insert(lines, "session: " .. (if tonumber((sun.session or {}).at) ~= nil then tostring(sun.session.stamp or "?") else "ninguna"))

	return table.concat(lines, "\n")
end

local function webUrl(): string
	local ip = tostring(st().local_ip or "")
	if ip == "" then
		ip = "127.0.0.1"
	end
	return "https://" .. ip .. ":" .. tostring(WEB_PORT)
end

-- ── cabecera y pestañas ──────────────────────────────────────────────

local function header(): any
	local ts = tsTable()
	local sun = sunTable()
	local subtitle = T("panel.loading")
	local color = theme.muted()

	if type(ts.counts) == "table" and ts.ok == true then
		subtitle = T("panel.subtitle", {
			online = tostring(tonumber(ts.counts.online) or 0),
			total = tostring(tonumber(ts.counts.total) or 0),
		})
	elseif ts.err ~= nil then
		subtitle = tostring(ts.err)
		color = theme.danger()
	end
	if sun.failed == true then
		subtitle = T("panel.sun_failed_sub")
		color = theme.danger()
	end

	return ui.row({ gap = 8, padding = 6, align = "center" }, {
		ui.glyph({
			name = glyphName(),
			size = 18,
			color = if ts.ok == true then theme.ok() elseif ts.err ~= nil then theme.danger() else "on_surface",
		}),
		ui.label({ text = T("panel.title"), fontSize = 16, fontWeight = "semibold" }),
		ui.label({ text = layout.ellipsis(subtitle, 48), fontSize = 11, color = color, maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			glyph = "refresh",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.refresh"),
			onClick = function()
				send({ action = "refresh" })
			end,
		}),
		ui.button({
			-- "document" no existe en el set de glyphs del host (el log
			-- avisa "missing glyph: document") y el botón salía vacío.
			glyph = "info",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.copy_diagnostic"),
			onClick = function()
				copied(diagnostic())
			end,
		}),
		ui.button({
			glyph = "settings",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "x",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

local function tabs(): any
	local buttons = {}
	for _, tab in ipairs(TABS) do
		local active = S.tab == tab.value
		table.insert(buttons, ui.button({
			text = T(tab.key),
			controlSize = "sm",
			variant = if active then "secondary" else "ghost",
			selected = active,
			onClick = function()
				if S.tab == tab.value then
					return
				end
				S.tab = tab.value
				S.page = 1
				S.confirm = nil
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}))
	end
	table.insert(buttons, ui.spacer({ flexGrow = 1 }))

	local ts = tsTable()
	local sun = sunTable()
	local counts = if type(ts.counts) == "table" then ts.counts else {}
	table.insert(buttons, chip(T("panel.ts.self_title") .. ": " .. tostring(ts.backend or "—"), theme.muted()))
	table.insert(buttons, chip(noctalia.trp("count.peers", tonumber(counts.online) or 0), theme.muted()))
	local sunColor = theme.ok()
	if sun.failed == true then
		sunColor = theme.danger()
	elseif sun.state ~= "active" then
		sunColor = theme.warn()
	end
	table.insert(buttons, chip(T("panel.tab.sunshine") .. ": " .. tostring(sun.state or "—"), sunColor))

	return ui.row({ gap = 8, paddingH = 6, align = "center" }, buttons)
end

-- ── pestaña Tailscale ────────────────────────────────────────────────

-- La salud del nodo local que reporta Tailscale. Sólo aparece si hay
-- algo que informar: en verde no vale la pena una línea.
local function healthText(): any
	local self_node = if type(st().ts.self) == "table" then st().ts.self else {}
	local health = if type(self_node.health) == "table" then self_node.health else {}
	if #health == 0 then
		return nil
	end
	local parts = {}
	for _, entry in ipairs(health) do
		table.insert(parts, tostring(entry))
	end
	return ui.label({
		text = T("panel.ts.health") .. ": " .. table.concat(parts, ", "),
		fontSize = 10,
		color = theme.warn(),
		maxLines = 2,
	})
end

local function selfCard(): any
	local ts = tsTable()
	local self_node = if type(ts.self) == "table" then ts.self else {}
	local online = ts.ok == true and self_node.online == true
	local ip4 = tostring(self_node.ip4 or "")
	local dns = tostring(self_node.dns or "")
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(1, anim.ease_out(S.anim.t), 0.04) else 1
	-- El estado de conexión del nodo local: `CurAddr` vacío + `Relay` con
	-- valor significa que esta máquina también va por DERP. Sin esto el
	-- panel decía "1 par por relay" y la causa de la latencia quedaba
	-- invisible.
	local direct = self_node.direct == true
	local relay = tostring(self_node.relay or "")
	local connText = T("panel.ts.conn_unknown")
	if direct then
		connText = T("panel.ts.conn_direct")
	elseif relay ~= "" then
		connText = T("panel.ts.conn_relay", { relay = relay })
	end

	return ui.column({
		key = "self-card",
		width = rowWidth(),
		height = SELF_H,
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = if online then "wifi" else "wifi-off", size = 14, color = if online then theme.ok() else theme.danger() }),
			ui.label({
				text = tostring(self_node.hostname or "—"),
				fontSize = 13,
				fontWeight = "semibold",
				maxLines = 1,
				flexGrow = 1,
			}),
			chip(tostring(ts.backend or "—"), if ts.running == true then theme.ok() else theme.warn()),
			chip(if online then T("panel.ts.online") else T("panel.ts.offline"), if online then theme.ok() else theme.danger()),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.ts.copy_ip"),
				enabled = ip4 ~= "",
				onClick = function()
					copied(ip4)
				end,
			}),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.ts.copy_dns"),
				enabled = dns ~= "",
				onClick = function()
					copied(dns)
				end,
			}),
		}),
		ui.label({
			text = T("panel.ts.magic") .. ": " .. (if dns ~= "" then dns else "—"),
			fontSize = 10,
			color = theme.muted(),
			maxLines = 1,
		}),
		ui.label({
			text = T("panel.ts.ip") .. ": " .. (if ip4 ~= "" then ip4 else "—")
				.. "   ·   " .. T("panel.ts.ipv6") .. ": " .. tostring(self_node.ip6 or "—"),
			fontSize = 10,
			color = theme.dim(),
			maxLines = 1,
		}),
		ui.label({
			text = connText,
			fontSize = 10,
			color = (if direct then theme.ok() else theme.warn()),
			maxLines = 1,
		}),
		-- `Self.Health` lo reporta Tailscale cuando algo anda mal (reloj
		-- desfasado, DNS roto, sin permisos). Venía parseado pero no se
		-- mostraba: era un dato disponible que se descartaba.
		healthText(),
	})
end

local function netcheckCard(): any
	local nc = netcheck()
	if nc.running == true then
		return ui.row({
			key = "nc-card",
			width = rowWidth(),
			height = NC_RUN_H,
			gap = 8,
			paddingH = 10,
			align = "center",
			fill = theme.surface(),
			radius = 10,
		}, {
			ui.glyph({ name = "activity", size = 14, color = theme.warn() }),
			ui.label({ text = T("panel.ts.netcheck_running"), fontSize = 11, color = theme.warn(), flexGrow = 1 }),
		})
	end
	if nc.err ~= nil then
		return ui.row({
			key = "nc-card",
			width = rowWidth(),
			height = NC_ERR_H,
			gap = 8,
			paddingH = 10,
			align = "center",
			fill = theme.chip(),
			radius = 10,
		}, {
			ui.glyph({ name = "alert-triangle", size = 14, color = theme.danger() }),
			ui.label({ text = tostring(nc.err), fontSize = 10, color = theme.danger(), flexGrow = 1, maxLines = 2 }),
		})
	end

	local udpOk = tostring(nc.udp) == "true"
	local mappingFlat = tostring(nc.mapping) == "false"
	local derps = {}
	for index = 1, math.min(#(nc.derps or {}), 3) do
		local entry = nc.derps[index]
		table.insert(derps, tostring(entry.code) .. " " .. tostring(math.floor(tonumber(entry.ms) or 0)) .. "ms")
	end

	return ui.column({
		key = "nc-card",
		width = rowWidth(),
		height = NC_H,
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = T("panel.ts.netcheck_title"), fontSize = 12, fontWeight = "semibold" }),
			ui.label({ text = ageOf(nc.at), fontSize = 10, color = theme.dim(), flexGrow = 1 }),
			chip(tostring(nc.nearest or "—"), theme.muted()),
		}),
		ui.row({ gap = 6, align = "center" }, {
			chip("UDP " .. tostring(nc.udp or "—"), if udpOk then theme.ok() else theme.danger()),
			chip("IPv4 " .. tostring(nc.ipv4 or "—"), if tostring(nc.ipv4):sub(1, 3) == "yes" then theme.ok() else theme.warn()),
			chip("IPv6 " .. tostring(nc.ipv6 or "—"), if tostring(nc.ipv6):sub(1, 3) == "yes" then theme.ok() else theme.muted()),
		}),
		ui.row({ gap = 6, align = "center" }, {
			chip("Mapping " .. tostring(nc.mapping or "—"), if mappingFlat then theme.ok() else theme.warn()),
			chip("PortMapping " .. tostring(nc.portmap or "—"), if tostring(nc.portmap) ~= "" then theme.ok() else theme.warn()),
		}),
		ui.label({
			text = "DERP: " .. (if #derps > 0 then table.concat(derps, "  ·  ") else "—"),
			fontSize = 10,
			color = theme.dim(),
			maxLines = 1,
		}),
	})
end

local function relayBanner(): any
	local counts = if type(tsTable().counts) == "table" then tsTable().counts else {}
	local relayed = tonumber(counts.relayed) or 0
	if relayed == 0 then
		return nil
	end
	return ui.row({
		key = "relay-banner",
		width = rowWidth(),
		height = BANNER_H,
		gap = 8,
		paddingH = 10,
		paddingV = 6,
		align = "center",
		fill = theme.chip(),
		radius = 10,
	}, {
		ui.glyph({ name = "world", size = 16, color = theme.warn() }),
		ui.column({ gap = 1, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({
				text = T("panel.ts.relay_banner_title", { count = tostring(relayed) }),
				fontSize = 11,
				fontWeight = "semibold",
				color = theme.warn(),
				maxLines = 1,
			}),
			ui.label({
				text = T("panel.ts.relay_banner_body"),
				fontSize = 10,
				color = theme.warn(),
				maxLines = 2,
			}),
		}),
	})
end

local function peerRow(peer: any, index: number): any
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.04) else 1
	local online = peer.online == true
	local relayed = peer.relayed == true
	local lastPing = ping()
	local pingMine = type(lastPing) == "table" and tostring(lastPing.ip) == tostring(peer.ip4)

	local sub = tostring(peer.os or "")
	if sub == "" then
		sub = "—"
	end
	sub = sub .. "  ·  " .. tostring(peer.ip4)
	if peer.last_seen ~= nil then
		sub = sub .. "  ·  " .. T("panel.ts.last_seen", { age = ageOf(peer.last_seen) })
	end

	local pingColor = theme.muted()
	if pingMine and lastPing.state == "ok" then
		pingColor = if lastPing.relay ~= "" and lastPing.relay ~= nil then theme.warn() else theme.ok()
		sub = T("panel.ts.ping_ok", {
			ms = tostring(tonumber(lastPing.latency) or 0),
			via = tostring(lastPing.via or "—"),
		})
	elseif pingMine and lastPing.state == "running" then
		pingColor = theme.warn()
		sub = T("panel.ts.pinging")
	elseif pingMine and lastPing.state == "fail" then
		pingColor = theme.danger()
		sub = T("panel.ts.ping_fail", { detail = tostring(lastPing.detail or "—") })
	end

	-- Sin CurAddr no hay camino directo. Si además hay Relay, el peer sale (o
	-- saldría) por DERP: se nombra siempre, aunque esté offline, para que la
	-- causa de la latencia quede a la vista.
	local cur = tostring(peer.cur or "")
	local relayName = tostring(peer.relay or "")
	local detail = cur
	if detail == "" then
		if relayName ~= "" then
			detail = "DERP " .. relayName .. " · " .. T("panel.ts.cur_none")
		else
			detail = T("panel.ts.cur_none")
		end
	end
	local transport = T("panel.ts.no_path")
	if relayed then
		transport = T("panel.ts.relay_chip", { relay = relayName })
	elseif cur ~= "" then
		transport = T("panel.ts.direct_chip")
	end
	local transportColor = if relayed then theme.warn() elseif cur ~= "" then theme.ok() else theme.dim()

	return ui.column({
		key = "peer-" .. tostring(peer.key),
		width = rowWidth(),
		height = peerHeight(),
		gap = 3,
		paddingH = 10,
		paddingV = 8,
		-- El peer relayed se distingue por el fondo: iba por DERP y es la
		-- causa de la latencia. Con las dos ramas iguales no se destacaba.
		fill = if relayed then theme.raised() else theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.box({ width = 6, height = 14, radius = 3, fill = if online then theme.ok() else theme.dim() }),
			ui.label({
				text = tostring(peer.name or "—"),
				fontSize = 13,
				fontWeight = "semibold",
				maxLines = 1,
				flexGrow = 1,
			}),
			chip(transport, transportColor),
			chip(if online then T("panel.ts.online") else T("panel.ts.offline"), if online then theme.ok() else theme.dim()),
			ui.button({
				text = T("panel.ts.ping"),
				glyph = "activity",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.ts.ping_tip"),
				enabled = tostring(peer.ip4 or "") ~= "" and status().busy ~= true,
				onClick = function()
					send({ action = "ping", ip = tostring(peer.ip4 or "") })
				end,
			}),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.ts.copy_ip"),
				enabled = tostring(peer.ip4 or "") ~= "",
				onClick = function()
					copied(peer.ip4)
				end,
			}),
		}),
		ui.label({
			text = sub,
			fontSize = 10,
			color = pingColor,
			maxLines = 1,
		}),
		ui.label({
			text = T("panel.ts.transport") .. ": " .. detail,
			fontSize = 10,
			color = theme.dim(),
			maxLines = 1,
		}),
	})
end

-- Alto real de la tarjeta de netcheck: 0 si no se dibuja, un valor chico
-- mientras corre o si falló, NC_H cuando ya tiene reporte. peerPageSize usa el
-- mismo número que dibuja netcheckCard: si divergen, la última fila se recorta.
local function netcheckHeight(): number
	local nc = netcheck()
	if nc.running == true then
		return NC_RUN_H
	end
	if nc.err ~= nil then
		return NC_ERR_H
	end
	if nc.udp ~= nil then
		return NC_H
	end
	return 0
end

-- ── el alto de la lista de peers (lo pone el contenido) ───────────────
--
-- Antes el scroll de peers llevaba `bodyHeight() - 240`: un número FIJO.
-- Pero arriba de la lista va la card del nodo, las preferencias, la fila y
-- la card de netcheck, el banner de relay y la cabecera de Peers — mucho
-- más que 240. El árbol pedía más alto del que el manifest permite
-- (`max_height`) y el host recortaba justo la lista: con cada peer nuevo
-- la última fila se iba fuera de la vista y no había scroll para llegar.
--
-- Ahora el viewport es el espacio que REALMENTE queda:
--   min(alto de las filas, bodyHeight - alto de lo de arriba)
-- Con pocos peers da el alto exacto del contenido (el panel se ajusta y no
-- hay scroll inútil); con muchos da el espacio libre y la lista scrollea.
-- El alto de las preferencias se estima A FAVOR: de más deja un hueco
-- abajo, de menos recorta la última fila.
local PREFS_CARD_H = 190

local function peersViewport(count: number, ncVisible: boolean, hasBanner: boolean): number
	local arriba = SELF_H + ACTIONS_H + PEERS_HEAD_H + PREFS_CARD_H + 6 * CARD_GAP
	if ncVisible then
		arriba = arriba + netcheckHeight() + CARD_GAP
	end
	if hasBanner then
		arriba = arriba + BANNER_H + CARD_GAP
	end
	local contenido = 0
	if count > 0 then
		contenido = count * peerHeight() + (count - 1) * CARD_GAP
	end
	local libre = bodyHeight() - arriba
	return math.max(120, math.min(contenido, libre))
end

-- Filas de par que entran en la página. Sin rueda en los paneles, el paginado
-- es la única forma de llegar al resto de la lista: el alto se calcula, no se
-- confía en que el contenido recorte solo.
local function peerPageSize(): number
	local available = bodyHeight() - SELF_H - ACTIONS_H - PEERS_HEAD_H - PAGER_H - CARD_GAP * 4
	local ncHeight = netcheckHeight()
	if ncHeight > 0 then
		available = available - ncHeight - CARD_GAP
	end
	local counts = if type(tsTable().counts) == "table" then tsTable().counts else {}
	if (tonumber(counts.relayed) or 0) > 0 then
		available = available - BANNER_H - CARD_GAP
	end
	return math.max(1, math.floor(available / (peerHeight() + CARD_GAP)))
end

-- Selector de exit node: los peers online de la tailnet. `tailscale set
-- exit-node` necesita el ID del nodo, no su nombre.
local function exitNodePicker(): any
	if S.exitPicker ~= true then
		return ui.label({ text = "", fontSize = 10 })
	end
	local peers = tsTable().peers or {}
	local items: { any } = {}
	for _, peer in ipairs(peers) do
		if peer.online == true and peer.id ~= nil and peer.id ~= "" then
			table.insert(items, ui.button({
				label = peer.name,
				controlSize = "sm",
				variant = "outline",
				onClick = function()
					S.exitPicker = false
					send({ action = "toggle_exit_node", node = peer.id })
				end,
			}))
		end
	end
	if #items == 0 then
		table.insert(items, ui.label({
			text = T("panel.ts.exit_none"),
			fontSize = 11,
			color = theme.dim(),
		}))
	end
	return ui.column({ gap = 4, align = "stretch" }, items)
end

-- ── preferencias de Tailscale ────────────────────────────────────────────

-- Las preferencias que el plugin no tenía: MagicDNS, aceptación de rutas
-- (subnet routers), exit node y las rutas que anuncia este nodo. Son las que
-- se cambian desde la interfaz de tailscale y desde el panel quedaban
-- invisibles: el usuario no tenía forma de saber por qué su tailnet se
-- comporta como se comporta.
local function prefsCard(): any
	local state = st()
	-- `prefsData` y no `prefs`: el módulo `prefs` (los ajustes del plugin)
	-- está declarado arriba y una local con el mismo nombre lo sombrea.
	local prefsData = if type(state.prefs) == "table" then state.prefs else {}
	if next(prefsData) == nil then
		return nil
	end

	local busy = status().busy == true
	local dnsOn = prefsData["accept-dns"] == true
	local routesOn = prefsData["accept-routes"] == true
	local shields = prefsData["shields-up"] == true
	local exitNode = tostring(prefsData["exit-node"] or "")
	local advertised = tail.advertised_routes(prefsData)

	local function toggle(key: string, valor: boolean): any
		return ui.button({
			glyph = if valor then "check" else "minus",
			controlSize = "sm",
			variant = if valor then "primary" else "outline",
			enabled = not busy,
			onClick = function()
				send({ action = "set_pref", key = key, value = (if valor then "false" else "true") })
			end,
		})
	end

	-- Las rutas que anuncia este nodo: sólo aparecen si hay alguna.
	local function advertisedRow(advertised: string): any
		if advertised == "" then
			return ui.label({ text = "", fontSize = 10 })
		end
		return ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = T("panel.ts.pref_advertise"), fontSize = 11, color = theme.muted(), maxLines = 1 }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({ text = advertised, fontSize = 10, color = theme.dim(), maxLines = 1 }),
		})
	end

	local function row(key: string, etiqueta: string, valor: string, control: any): any
		return ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = etiqueta, fontSize = 11, color = theme.muted(), maxLines = 1 }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = valor,
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
			}),
			control,
		})
	end

	return ui.column({
		key = "ts-prefs",
		width = rowWidth(),
		gap = 6,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
		border = theme.chip(),
		borderWidth = 1,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "settings", size = 14, color = theme.dim() }),
			ui.label({ text = T("panel.ts.prefs"), fontSize = 12, fontWeight = "semibold" }),
		}),
		row("accept-dns", T("panel.ts.pref_dns"), (if dnsOn then T("panel.ts.pref_on") else T("panel.ts.pref_off")),
			toggle("accept-dns", dnsOn)),
		row("accept-routes", T("panel.ts.pref_routes"), (if routesOn then T("panel.ts.pref_on") else T("panel.ts.pref_off")),
			toggle("accept-routes", routesOn)),
		row("shields-up", T("panel.ts.pref_shields"), (if shields then T("panel.ts.pref_on") else T("panel.ts.pref_off")),
			toggle("shields-up", shields)),
		row("exit-node", T("panel.ts.pref_exit"), (if exitNode ~= "" then exitNode else T("panel.ts.pref_none")),
			ui.button({
				glyph = if exitNode ~= "" then "x" else "world",
				controlSize = "sm",
				variant = "outline",
				enabled = not busy,
				tooltip = T("panel.ts.pref_exit_tip"),
				onClick = function()
					if exitNode ~= "" then
						send({ action = "toggle_exit_node" })
					else
						-- Sin exit node: se ofrece elegir uno de los peers
						-- online. `tailscale set --exit-node` necesita el ID.
						send({ action = "list_exit_nodes" })
						S.exitPicker = not S.exitPicker
					end
				end,
			})),
		-- Las rutas que anuncia este nodo: sólo aparecen si hay alguna.
		advertisedRow(advertised),
		exitNodePicker(),
	})
end


local function tailscaleView(): any
	local ts = tsTable()
	local children = {}

	table.insert(children, selfCard())

	local prefsNode = prefsCard()
	if prefsNode ~= nil then
		table.insert(children, prefsNode)
	end

	local ncVisible = netcheckHeight() > 0
	table.insert(children, ui.row({ gap = 8, paddingH = 6, align = "center", height = ACTIONS_H }, {
		ui.button({
			text = T("panel.ts.netcheck"),
			glyph = "radar",
			controlSize = "sm",
			variant = "outline",
			tooltip = T("panel.ts.netcheck_tip"),
			enabled = status().busy ~= true,
			onClick = function()
				send({ action = "netcheck" })
			end,
		}),
		ui.label({
			text = if ncVisible then T("panel.ts.netcheck_hint") else T("panel.ts.netcheck_idle"),
			fontSize = 10,
			color = theme.dim(),
			maxLines = 1,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.label({
			text = noctalia.trp("count.relayed", tonumber((ts.counts or {}).relayed) or 0),
			fontSize = 10,
			color = theme.dim(),
		}),
	}))

	if ncVisible then
		table.insert(children, netcheckCard())
	end

	local banner = relayBanner()
	if banner ~= nil then
		table.insert(children, banner)
	end

	local peers = if type(ts.peers) == "table" then ts.peers else {}
	table.insert(children, ui.row({ gap = 8, paddingH = 6, align = "center", height = PEERS_HEAD_H }, {
		ui.label({ text = T("panel.ts.peers"), fontSize = 12, fontWeight = "semibold" }),
		ui.label({
			text = noctalia.trp("count.peers", #peers),
			fontSize = 10,
			color = theme.dim(),
			flexGrow = 1,
		}),
		ui.label({ text = T("panel.ts.from_json"), fontSize = 9, color = theme.dim(), maxLines = 1 }),
	}))

	if #peers == 0 then
		table.insert(children, ui.column({ height = 110, align = "center", justify = "center", gap = 6 }, {
			ui.glyph({ name = if ts.err ~= nil then "alert-triangle" else "device-mobile", size = 26, color = theme.dim() }),
			ui.label({
				text = if ts.err ~= nil then tostring(ts.err) else T("panel.ts.no_peers"),
				fontSize = 11,
				color = theme.muted(),
				textAlign = "center",
				maxLines = 2,
			}),
		}))
		return ui.column({ gap = CARD_GAP, align = "stretch", flexGrow = 1 }, children)
	end

	-- MODO AUTOMÁTICO: la lista va en un scroll con viewport y SIN paginación.
	-- Paginar con alturas estimadas tapa la última fila cuando una fila crece
	-- de más (un nombre en dos líneas), y duplica el cálculo del alto. Con el
	-- scroll, el host mide el contenido y el usuario lo recorre con la rueda.
	-- MODO FIJO: se mantiene la paginación con alturas por densidad.
	if layout.is_auto() then
		local filas: { any } = {}
		for position, peer in ipairs(peers) do
			table.insert(filas, peerRow(peer, position))
		end
		table.insert(children, ui.scroll(layout.merge({
			key = "peers-scroll",
			
			width = layout.row(rowWidth()),
			align = "stretch",
			gap = CARD_GAP,
			paddingH = 2,
		}, layout.scrollExtra(peersViewport(#peers, ncVisible, banner ~= nil))), filas))
		return ui.column({ gap = CARD_GAP, align = "stretch", flexGrow = 1 }, children)
	end

	local perPage = peerPageSize()
	local pages = math.max(1, math.ceil(#peers / perPage))
	-- Acotar SIN mutar S.page: mutarlo durante el render compite con el
	-- reset de página al cambiar de vista y deja la paginación apuntando a
	-- una página inexistente (la lista se vacía sin aviso).
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#peers, first + perPage - 1)

	for position = first, last do
		table.insert(children, peerRow(peers[position], position - first + 1))
	end

	table.insert(children, ui.row({ gap = 8, paddingH = 6, align = "center", justify = "center", height = PAGER_H }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page > 1,
			onClick = function()
				S.page = math.max(1, S.page - 1)
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
		ui.label({
			-- La etiqueta usa la página ACOTADA: el contenido dibuja la
			-- acotada, así que con S.page > pages la etiqueta mentía
			-- ("page 3 of 2"). Pasa porque la lista se achica entre polls
			-- y quedan menos páginas.
			text = T("panel.ts.page_of", {
				page = tostring(math.max(1, math.min(S.page, pages))),
				pages = tostring(pages),
				total = tostring(#peers),
			}),
			fontSize = 10,
			color = theme.muted(),
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page < pages,
			onClick = function()
				S.page = math.min(pages, S.page + 1)
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
	}))

	return ui.column({ gap = CARD_GAP, align = "stretch", flexGrow = 1 }, children)
end

-- ── pestaña Sunshine ─────────────────────────────────────────────────

local function sunStateColor(state: string): string
	if state == "active" then
		return theme.ok()
	end
	if state == "failed" then
		return theme.danger()
	end
	return theme.warn()
end

local function sunStatusCard(): any
	local data = sunTable()
	local state = tostring(data.state or "—")
	local ports = if type(data.ports) == "table" then data.ports else {}
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(1, anim.ease_out(S.anim.t), 0.04) else 1

	local portColor = theme.ok()
	if (tonumber(ports.count) or 0) < (tonumber(ports.expected) or 4) then
		portColor = theme.warn()
	end
	local httpColor = if data.http_ok == true then theme.ok() else theme.danger()

	return ui.column({
		key = "sun-card",
		width = rowWidth(),
		height = 104,
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "screen-share", size = 14, color = sunStateColor(state) }),
			ui.label({ text = T("panel.sun.unit_title"), fontSize = 13, fontWeight = "semibold" }),
			chip(state, sunStateColor(state)),
			chip(T("panel.sun.ports") .. " " .. tostring(tonumber(ports.count) or 0) .. "/" .. tostring(tonumber(ports.expected) or 4), portColor),
			chip(T("panel.sun.web") .. " " .. (if tostring(data.http or "") ~= "" then tostring(data.http) else "—"), httpColor),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = tostring(data.substate or ""),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
			}),
		}),
		-- Reinicios del unit: Sunshine se cae y vuelve solo, y el panel no lo
		-- mostraba. Con NRestarts > 0 el problema es del servicio, no de la
		-- config.
		ui.label({
			text = T("panel.sun.nrestarts", { n = tostring(tonumber(data.nrestarts) or 0) })
				.. (if tonumber(data.nrestarts) and tonumber(data.nrestarts) > 0 then "  " .. T("panel.sun.nrestarts_warn") else ""),
			fontSize = 10,
			color = (if tonumber(data.nrestarts) and tonumber(data.nrestarts) > 0 then theme.warn() else theme.dim()),
			maxLines = 1,
		}),
		ui.label({
			text = T("panel.sun.no_touch"),
			fontSize = 10,
			color = theme.dim(),
			maxLines = 2,
		}),
		ui.row({ gap = 8, align = "center" }, {
			ui.label({
				text = T("panel.sun.ports_list", { list = table.concat(ports.list or {}, ", ") }),
				fontSize = 10,
				color = theme.muted(),
				maxLines = 1,
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.button({
				text = T("panel.sun.open_web"),
				glyph = "external-link",
				controlSize = "sm",
				variant = "primary",
				tooltip = T("panel.sun.open_web_tip") .. " " .. webUrl(),
				enabled = status().busy ~= true,
				onClick = function()
					S.flash = T("panel.sun.opening")
					S.flashAt = os.time()
					send({ action = "open_web" })
					render()
				end,
			}),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.sun.copy_url"),
				onClick = function()
					copied(webUrl())
				end,
			}),
		}),
	})
end

-- reset-failed + start: el único botón que escribe sobre el unit. Se pide
-- confirmación en dos pasos porque la acción levanta un servicio, y el texto
-- dice exactamente qué corre.
local function fixRow(): any
	local data = sunTable()
	if data.failed ~= true then
		return nil
	end
	local confirming = S.confirm == "sun-fix"
	return ui.row({
		key = "sun-fix",
		width = rowWidth(),
		height = 72,
		gap = 8,
		paddingH = 10,
		paddingV = 8,
		align = "center",
		fill = theme.chip(),
		radius = 10,
	}, {
		ui.glyph({ name = "alert-triangle", size = 16, color = theme.danger() }),
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({
				text = T("panel.sun.fix_hint"),
				fontSize = 10,
				color = theme.danger(),
				maxLines = 2,
			}),
			ui.label({
				text = if confirming then T("panel.sun.fix_confirm_text") else T("panel.sun.fix_cmd"),
				fontSize = 9,
				color = theme.danger(),
				maxLines = 1,
			}),
		}),
		ui.button({
			text = if confirming then T("panel.sun.fix_do") else T("panel.sun.fix"),
			glyph = "arrow-back-up",
			controlSize = "sm",
			variant = if confirming then "primary" else "outline",
			tooltip = T("panel.sun.fix_tip"),
			enabled = status().busy ~= true,
			onClick = function()
				if S.confirm ~= "sun-fix" then
					S.confirm = "sun-fix"
					render()
					return
				end
				S.confirm = nil
				send({ action = "reset_failed" })
				render()
			end,
		}),
	})
end

local function encoderCard(): any
	local data = sunTable()
	local encoder = if type(data.encoder) == "table" then data.encoder else {}
	local kind = tostring(encoder.kind or "")
	local good = kind == "vaapi"
	local bad = tostring(encoder.bad or "")

	return ui.column({
		key = "sun-encoder",
		width = rowWidth(),
		height = 96,
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = T("panel.sun.encoder_title"), fontSize = 12, fontWeight = "semibold" }),
			chip(if kind ~= "" then kind else "—", if good then theme.ok() else theme.warn() ),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = T("panel.sun.encoder_conf", { value = tostring((data.conf or {}).encoder or "—") }),
				fontSize = 10,
				color = theme.dim(),
			}),
		}),
		ui.label({
			text = "H.264: " .. (if tostring(encoder.h264 or "") ~= "" then tostring(encoder.h264) else T("panel.sun.encoder_none")),
			fontSize = 10,
			color = if good then theme.muted() else theme.dim(),
			maxLines = 1,
		}),
		ui.label({
			text = "HEVC: " .. (if tostring(encoder.hevc or "") ~= "" then tostring(encoder.hevc) else T("panel.sun.encoder_none")),
			fontSize = 10,
			color = if good then theme.muted() else theme.dim(),
			maxLines = 1,
		}),
		ui.label({
			text = if bad ~= "" then T("panel.sun.encoder_bad", { value = bad }) else T("panel.sun.encoder_ok"),
			fontSize = 10,
			color = if bad ~= "" then theme.danger() else theme.ok(),
			maxLines = 1,
		}),
	})
end

local function sessionCard(): any
	local data = sunTable()
	local session = if type(data.session) == "table" then data.session else {}
	local has = tonumber(session.at) ~= nil
	-- La verdad de campo: conexiones ESTABLISHED a los puertos de Sunshine.
	-- El log no registra el cierre abrupto, así que un cliente muerto dejaba
	-- el panel diciendo "sesión activa" indefinidamente.
	local established = tonumber(data.established) or 0
	local live = established > 0
	local text = T("panel.sun.session_none")
	local color = theme.dim()
	if has then
		if session.ended == true then
			text = T("panel.sun.session_ended", {
				stamp = tostring(session.stamp or "—"),
				age = ageOf(session.at),
				by = tostring(session.ended_by or ""),
			})
			color = theme.muted()
		else
			if live then
				text = T("panel.sun.session_active", {
					stamp = tostring(session.stamp or "—"),
					age = ageOf(session.at),
				})
				color = theme.ok()
			else
				-- El log dice que conectó pero no hay ninguna conexión
				-- establecida: el cliente se fue sin cerrar la sesión.
				text = T("panel.sun.session_ended", {
					stamp = tostring(session.stamp or "—"),
					age = ageOf(session.at),
					by = "sin conexión",
				})
				color = theme.muted()
			end
		end
	end

	return ui.column({
		key = "sun-session",
		width = rowWidth(),
		height = 74,
		gap = 3,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = T("panel.sun.session_title"), fontSize = 12, fontWeight = "semibold" }),
			chip(if live then T("panel.sun.session_live") else T("panel.sun.session_idle"), if live then theme.ok() else theme.dim()),
		}),
		ui.label({ text = layout.ellipsis(text, 50), fontSize = 10, color = color, maxLines = 2 }),
	})
end

local function configCard(): any
	local data = sunTable()
	local conf = if type(data.conf) == "table" then data.conf else {}
	local capture = tostring(conf.capture or "")
	local output = tostring(conf.output or "")
	local outputs = if type(data.outputs) == "table" then data.outputs else {}
	local outputOk = data.output_ok ~= false

	local warnings = {}
	for _, entry in ipairs(data.warnings or {}) do
		local key = WARN_KEY[tostring(entry.code or "")]
		if key ~= nil then
			table.insert(warnings, ui.label({
				text = T(key, { value = tostring(entry.value or "") }),
				fontSize = 10,
				color = theme.warn(),
				maxLines = 2,
			}))
		end
	end

	local children = {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = T("panel.sun.config_title"), fontSize = 12, fontWeight = "semibold" }),
			chip("capture " .. (if capture ~= "" then capture else "—"), if capture == "wlr" then theme.ok() else theme.warn()),
			chip("output " .. (if output ~= "" then output else "—"), if outputOk then theme.ok() else theme.warn()),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = T("panel.sun.outputs", { list = if #outputs > 0 then table.concat(outputs, ", ") else "—" }),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
			}),
		}),
	}
	for _, warning in ipairs(warnings) do
		table.insert(children, warning)
	end
	if #warnings == 0 then
		table.insert(children, ui.label({
			text = T("panel.sun.config_ok"),
			fontSize = 10,
			color = theme.ok(),
			maxLines = 1,
		}))
	end

	return ui.column({
		key = "sun-config",
		width = rowWidth(),
		height = math.max(80, 40 + #children * 18),
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
	}, children)
end

local function sunshineView(): any
	local children = { sunStatusCard() }
	local fix = fixRow()
	if fix ~= nil then
		table.insert(children, fix)
	end
	table.insert(children, encoderCard())
	table.insert(children, sessionCard())
	table.insert(children, configCard())

	return ui.column({ gap = CARD_GAP, align = "stretch", flexGrow = 1 }, children)
end

-- ── pie ──────────────────────────────────────────────────────────────

local function footer(): any
	local state = st()
	local children = {
		ui.label({
			text = T("panel.updated", { age = if tonumber(state.at) ~= nil and tonumber(state.at) > 0 then ageOf(state.at) else T("time.never") }),
			fontSize = 10,
			color = theme.dim(),
			flexGrow = 1,
		}),
	}
	if S.flash ~= nil then
		table.insert(children, ui.label({ text = S.flash, fontSize = 10, color = theme.ok() }))
	end
	if status().busy == true then
		table.insert(children, ui.label({ text = T("panel.working"), fontSize = 10, color = theme.warn() }))
	end
	table.insert(children, ui.label({ text = T("panel.readonly"), fontSize = 10, color = theme.dim() }))
	return ui.row({ gap = 8, paddingH = 6, align = "center" }, children)
end

-- ── render ───────────────────────────────────────────────────────────

local lastTrace = ""

function render()
	local state = st()
	local ts = tsTable()
	local sun = sunTable()
	local nc = netcheck()
	local trace = tostring(S.tab)
		.. "/phase=" .. tostring(state.phase)
		.. "/backend=" .. tostring(ts.backend)
		.. "/ip=" .. tostring((ts.self or {}).ip4)
		.. "/peers=" .. tostring(tonumber((ts.counts or {}).total) or 0)
		.. "/online=" .. tostring(tonumber((ts.counts or {}).online) or 0)
		.. "/relayed=" .. tostring(tonumber((ts.counts or {}).relayed) or 0)
		.. "/sun=" .. tostring(sun.state)
		.. "/ports=" .. tostring(tonumber((sun.ports or {}).count) or 0)
		.. "/http=" .. tostring(sun.http)
		.. "/enc=" .. tostring((sun.encoder or {}).kind)
		.. "/nc=" .. tostring(nc.udp)
		.. "/page=" .. tostring(S.page)
		.. "/pageSize=" .. tostring(peerPageSize())
		.. "/mode=" .. prefs.panel_mode()
		.. "/density=" .. prefs.density()
		-- el texto traducido va en la traza: delata una clave de i18n que no
		-- resuelve (se vería el key crudo) sin mirar la pantalla
		.. "/label=" .. noctalia.trp("count.peers", tonumber((ts.counts or {}).online) or 0)
	if trace ~= lastTrace then
		lastTrace = trace
		noctalia.log("[b3l0w-net] " .. trace)
	end

	local body = if S.tab == "sunshine" then sunshineView() else tailscaleView()

	-- El host es dueño del tamaño: sin `width`/`height` fijos, el panel
	-- toma el ancho y el alto que declara el manifest y el contenido se
	-- estira dentro. El body crece con `flexGrow` (eje principal de la
	-- column = alto) y el footer queda pegado abajo.
	panel.render(ui.column({
		-- La raíz lleva el ancho del surface: sin él mide por contenido y
		-- la fila más ancha (pestañas + chips) empuja el recorte del host.
		width = layout.width(inner()),
		gap = 4,
		padding = 6,
		align = "stretch",
		flexGrow = 1,
	}, {
		header(),
		tabs(),
		body,
		footer(),
	}))
end

function M.frameTick(delta: any)
	if S.flash ~= nil and os.time() - S.flashAt >= 3 then
		S.flash = nil
		render()
	end
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	local advance = tonumber(delta) or 16
	if advance > 0 and advance < 1 then
		advance = advance * 1000
	end
	S.anim.t = math.min(1, S.anim.t + advance / (S.anim.ms or 220))
	render()
end

function M.open(context: any, mode: string?)
	-- El entry dice qué panel es: el host no lo pasa por el contexto.
	if mode == "compact" or mode == "float" then
		MODE = mode
	end
	lastTrace = ""
	-- Contexto: `noctalia msg panel-open b3l0w/net:panel sunshine` abre
	-- directo en la pestaña Sunshine. El widget puede usarlo para saltar
	-- a una vista sin que el usuario tenga que hacer clic.
	if type(context) == "string" and context ~= "" then
		for _, tab in ipairs(TABS) do
			if tab.value == context then
				S.tab = context
			end
		end
	end
	SNAP.state = noctalia.state.get(STATE_KEY)
	SNAP.status = noctalia.state.get(STATUS_KEY)
	SNAP.netcheck = noctalia.state.get(NETCHECK_KEY)
	SNAP.ping = noctalia.state.get(PING_KEY)
	S.confirm = nil
	S.flash = nil
	S.page = 1

	-- Una orden de una sola vez (IPC) se siembra acá además del watcher: el
	-- entry del panel se instancia al abrir, así que un cambio previo no existe
	-- para ningún watcher.
	local screen = noctalia.state.get(SCREEN_KEY)
	if type(screen) == "table" and type(screen.tab) == "string" then
		for _, tab in ipairs(TABS) do
			if screen.tab == tab.value then
				S.tab = tab.value
			end
		end
	end

	S.anim.t = if prefs.animations() then 0 else 1
	panel.setNeedsFrameTick(true)
	render()
end

function M.close()
	S.tab = "tailscale"
	S.page = 1
	S.confirm = nil
	S.flash = nil
end

function onKey(chord: string, pressed: boolean)
	if not pressed then
		return
	end
	if chord == "Prior" or chord == "Next" then
		local peers = if type(tsTable().peers) == "table" then tsTable().peers else {}
		local pages = math.max(1, math.ceil(#peers / peerPageSize()))
		if chord == "Next" then
			S.page = math.min(pages, S.page + 1)
		else
			S.page = math.max(1, S.page - 1)
		end
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Left" or chord == "Right" then
		local index = 1
		for position, tab in ipairs(TABS) do
			if tab.value == S.tab then
				index = position
			end
		end
		local delta = if chord == "Right" then 1 else -1
		local nextIndex = ((index - 1 + delta) % #TABS) + 1
		S.tab = TABS[nextIndex].value
		S.page = 1
		S.confirm = nil
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	end
end

noctalia.state.watch(STATE_KEY, function(value: any)
	SNAP.state = value
	render()
end)

noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = value
	render()
end)

noctalia.state.watch(NETCHECK_KEY, function(value: any)
	SNAP.netcheck = value
	render()
end)

noctalia.state.watch(PING_KEY, function(value: any)
	SNAP.ping = value
	render()
end)

noctalia.state.watch(SCREEN_KEY, function(value: any)
	if type(value) ~= "table" then
		return
	end
	for _, tab in ipairs(TABS) do
		if value.tab == tab.value then
			S.tab = tab.value
			S.page = 1
		end
	end
	render()
end)

SNAP.state = noctalia.state.get(STATE_KEY)
SNAP.status = noctalia.state.get(STATUS_KEY)
SNAP.netcheck = noctalia.state.get(NETCHECK_KEY)
SNAP.ping = noctalia.state.get(PING_KEY)

-- El host llama a `onConfigChanged` cuando cambia un ajuste: los entries
-- finos lo reenvían acá (si no, `app.configChanged` sería nil).
function M.configChanged(): ()
	render()
end

return M
