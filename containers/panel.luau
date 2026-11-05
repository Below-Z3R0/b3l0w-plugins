--!strict
-- Panel de b3l0w/containers: contenedores, imágenes, volúmenes y redes en un
-- solo lugar (fusión de `containers` y `mini-docker`).

local anim = require("./lib/anim.luau")
local prefs = require("./lib/prefs.luau")
local state = require("./lib/state.luau")
local theme = require("./lib/theme.luau")
local layout = require("./lib/layout.luau")

local T = noctalia.tr

local SNAP_KEY = "b3l0w_containers_snapshot"
local STATUS_KEY = "b3l0w_containers_status"
local REQUEST_KEY = "b3l0w_containers_request"
local LOGS_KEY = "b3l0w_containers_logs"
local DETAIL_KEY = "b3l0w_containers_detail"
local DISK_KEY = "b3l0w_containers_disk"
local INFO_KEY = "b3l0w_containers_info"
local SCREEN_KEY = "b3l0w_containers_screen"

-- El MODO lo declara el ENTRY al abrir (`panel.luau` o `float.luau`), no
-- el setting `panel_mode`: el setting elige qué entry abre el widget, pero
-- si el usuario abre el otro entry desde el launcher, el código calculaba
-- los anchos sobre el panel equivocado (720 en vez de 1240).
--
-- El host es dueño del tamaño: estos valores son el ANCHO ÚTIL declarado en
-- el manifest (menos el margen), no una constante inventada.
local M: any = {}
local MODO = "compact"
local PANEL_W_BY_MODE = { compact = 748, float = 1228 }
local PANEL_H_BY_MODE = { compact = 720, float = 860 }

local function panelWidth(): number
	return PANEL_W_BY_MODE[MODO] or PANEL_W_BY_MODE.compact
end

local function panelHeight(): number
	return PANEL_H_BY_MODE[MODO] or PANEL_H_BY_MODE.compact
end

-- El ancho útil del contenido: el panel menos el padding horizontal.
-- Son FUNCIONES y no constantes: el modo lo declara el entry al abrir, así
-- que si se evaluaran al cargar el módulo quedarían con el ancho del
-- compacto (720) aunque el panel abierto fuera el float (1240).
local function PANEL_INNER(): number
	return panelWidth() - 12
end

local function ROW_W(): number
	return PANEL_INNER() - 12
end

local CHROME_H = 190

local function listHeight(): number
	return math.max(240, panelHeight() - CHROME_H)
end
local ROW_H_BY_DENSITY = { compact = 62, cozy = 70, comfortable = 78 }

-- El id del panel grande: lo abre el botón "Docker Desktop" de la cabecera.
local DESKTOP_PANEL = "b3l0w/containers:desktop"

local S = {
	tab = "containers" :: string,
	detail = nil :: string?,
	screen = "list" :: string,
	page = 1,
	confirm = nil :: string?,
	runForm = false,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
	requests = 0,
	form = { image = "", name = "", network = "", ports = "", env = "" } :: { [string]: string },
	detailTab = "summary" :: string,
	pruneWhat = nil :: string?,
	reveal = false :: boolean,
}

local TABS = {
	{ value = "containers", key = "panel.tab.containers" },
	{ value = "images", key = "panel.tab.images" },
	{ value = "volumes", key = "panel.tab.volumes" },
	{ value = "networks", key = "panel.tab.networks" },
	{ value = "projects", key = "panel.tab.stacks" },
}

local function rowHeight(): number
	return ROW_H_BY_DENSITY[prefs.density()] or 70
end

local function pageSize(): number
	return math.max(3, math.floor((listHeight() + 6) / (rowHeight() + 6)))
end

local function send(payload: any): ()
	S.requests += 1
	payload.nonce = tostring(math.floor(os.clock() * 1000)) .. ":" .. tostring(S.requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

-- El estado vive en `lib/state.luau`: el watcher entrega el valor NUEVO y
-- el render lee siempre de la caché (si leyera del `get`, iría un frame
-- atrás).
local function snapshot(key: string): { [string]: any }
	return state.table(key)
end

local function snap(): { [string]: any }
	return snapshot(SNAP_KEY)
end

local function status(): { [string]: any }
	return snapshot(STATUS_KEY)
end

local function list(tab: string): { any }
	local data = snap()
	local items = data[tab]
	return type(items) == "table" and items or {}
end

-- ── piezas ───────────────────────────────────────────────────────────

local function stateColor(estado: string): string
	if estado == "running" then
		return theme.ok()
	elseif estado == "paused" then
		return theme.warn()
	end
	return theme.dim()
end

-- `ui.box` es una hoja: no reconcilia hijos y el label se dropeaba (chip vacío).
-- Sólo `row`, `column` y `scroll` aceptan hijos.
local function chip(text: string, color: string, clickable: any): any
	return ui.row({
		fill = theme.chip(),
		radius = 6,
		paddingH = 6,
		paddingV = 2,
		align = "center",
		onClick = clickable,
		tooltip = if clickable ~= nil then text else nil,
	}, {
		ui.label({ text = layout.ellipsis(text, 50), fontSize = 11, color = color }),
	})
end

local function portChips(container: any): any
	local ports = type(container.ports) == "table" and container.ports or {}
	if #ports == 0 then
		return ui.box({ width = 0, height = 0, opacity = 0 })
	end
	local openUrl = noctalia.getConfig("open_url_on_click") ~= false
	local filas: { any } = {}
	for _, port in ipairs(ports) do
		local etiqueta = tostring(port.hostPort or 0) .. "→" .. tostring(port.containerPort or 0)
		if tonumber(port.hostPort) == 0 then
			etiqueta = tostring(port.containerPort or 0) .. "/" .. tostring(port.proto or "tcp")
		end
		local url = port.url
		table.insert(filas, chip(etiqueta, theme.info(), function()
			if openUrl and type(url) == "string" and url ~= "" then
				noctalia.runAsync({ "xdg-open", url })
			end
		end))
		if #filas >= 3 then
			break
		end
	end
	return ui.row({ gap = 4, align = "center" }, filas)
end

local function heroUptime(container: any): string
	local partes: { string } = {}
	if container.health ~= nil and container.health ~= "" then
		table.insert(partes, tostring(container.health))
	end
	if container.uptime ~= nil and container.uptime ~= "" then
		table.insert(partes, tostring(container.uptime))
	end
	if container.project ~= nil and container.project ~= "" then
		table.insert(partes, "compose:" .. tostring(container.project))
	end
	return table.concat(partes, "  ·  ")
end

-- ── filas ────────────────────────────────────────────────────────────

local function containerRow(container: any, index: number): any
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.04) else 1
	local running = container.state == "running"
	return ui.row({
		key = "c-" .. tostring(container.id),
		width = ROW_W(),
		height = rowHeight(),
		gap = 10,
		padding = 8,
		align = "center",
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.box({ width = 4, height = rowHeight() - 16, radius = 2, fill = stateColor(tostring(container.state or "")) }),
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.row({ gap = 6, align = "center" }, {
				ui.label({
					text = tostring(container.name or ""),
					fontSize = 14,
					fontWeight = "semibold",
					maxLines = 1,
					maxWidth = 220,
				}),
				chip(tostring(container.state or ""), stateColor(tostring(container.state or "")), nil),
				ui.label({ text = heroUptime(container), fontSize = 11, color = theme.muted(), maxLines = 1, maxWidth = 260 }),
			}),
			ui.row({ gap = 6, align = "center" }, {
				ui.label({ text = tostring(container.image or ""), fontSize = 11, color = theme.dim(), maxLines = 1, maxWidth = 260 }),
				portChips(container),
			}),
		}),
		ui.button({
			glyph = if running then "player-stop" else "player-play",
			controlSize = "sm",
			variant = "ghost",
			tooltip = if running then T("panel.stop") else T("panel.start"),
			onClick = function()
				send({ action = if running then "stop" else "start", id = container.id })
			end,
		}),
		ui.button({
			glyph = "refresh",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.restart"),
			onClick = function() send({ action = "restart", id = container.id }) end,
		}),
		ui.button({
			glyph = "file-text",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.logs"),
			onClick = function()
				S.detail = tostring(container.id)
				S.screen = "detail"
				S.detailTab = "summary"
				S.confirm = nil
				S.anim.t = 0
				send({ action = "detail", id = container.id })
				send({ action = "logs", id = container.id })
				render()
			end,
		}),
	})
end

local function simpleRow(tab: string, title: string, subtitle: string, id: string, canRemove: boolean, index: number): any
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.04) else 1
	local children: { any } = {
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({ text = layout.ellipsis(title, 40), fontSize = 13, fontWeight = "semibold", maxLines = 1, maxWidth = 420 }),
			ui.label({ text = layout.ellipsis(subtitle, 46), fontSize = 11, color = theme.dim(), maxLines = 1, maxWidth = 420 }),
		}),
	}
	if canRemove then
		local confirming = S.confirm == id
		table.insert(children, ui.button({
			text = if confirming then T("panel.confirm") else "",
			glyph = if confirming then nil else "trash",
			controlSize = "sm",
			variant = if confirming then "destructive" else "ghost",
			enabled = true,
			onClick = function()
				if not confirming then
					S.confirm = id
					render()
					return
				end
				S.confirm = nil
				local accion = if tab == "images" then "rmi" elseif tab == "volumes" then "volume-rm" else "network-rm"
				send({ action = accion, id = id })
				render()
			end,
		}))
	end
	return ui.row({
		key = tab .. "-" .. id,
		width = ROW_W(),
		height = rowHeight(),
		gap = 10,
		padding = 8,
		align = "center",
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, children)
end

-- ── vistas ───────────────────────────────────────────────────────────

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "brand-docker"
end

local function header(): any
	local st = status()
	local busy = st.busy == true
	return ui.row({ gap = 8, padding = 8, align = "center" }, {
		ui.glyph({ name = glyphName(), size = 18 }),
		ui.label({ text = "Containers", fontSize = 16, fontWeight = "semibold" }),
		ui.label({
			-- La versión del daemon: si el service no pudo cargarla sale "unknown".
			text = (function()
				local info = state.table(INFO_KEY)
				local v = tostring(info.serverVersion or "")
				return if v ~= "" then "Docker " .. v else T("panel.daemon_unknown")
			end)(),
			fontSize = 11,
			color = theme.dim(),
		}),
		ui.label({
			text = if busy then T("panel.refreshing") else (tostring(st.running or 0) .. " · " .. tostring(st.stopped or 0)),
			fontSize = 12,
			color = if busy then theme.warn() else theme.muted(),
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			glyph = "layout-dashboard",
			controlSize = "sm",
			variant = "outline",
			tooltip = T("desktop.open"),
			onClick = function()
				noctalia.togglePanel(DESKTOP_PANEL)
			end,
		}),
		ui.button({ glyph = "plus", controlSize = "sm", variant = "ghost", tooltip = T("panel.run"), onClick = function()
			S.form = { image = "", name = "", network = "", ports = "", env = "" }
			S.runForm = true
			S.screen = "run"
			S.anim.t = 0
			render()
		end }),
		ui.button({ glyph = "refresh", controlSize = "sm", variant = "ghost", tooltip = T("panel.refresh"), onClick = function()
			send({ action = "refresh" })
		end }),
		ui.button({ glyph = "settings", controlSize = "sm", variant = "ghost", tooltip = T("panel.settings"), onClick = function()
			noctalia.openSettings()
		end }),
	})
end

local function tabs(): any
	local botones: { any } = {}
	for _, tab in ipairs(TABS) do
		local activa = S.tab == tab.value and S.screen == "list"
		table.insert(botones, ui.button({
			text = T(tab.key),
			controlSize = "sm",
			variant = if activa then "secondary" else "ghost",
			selected = activa,
			onClick = function()
				if S.tab == tab.value and S.screen == "list" then
					return
				end
				S.tab = tab.value
				S.screen = "list"
				S.page = 1
				S.confirm = nil
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}))
	end
	table.insert(botones, ui.spacer({ flexGrow = 1 }))
	local st = status()
	table.insert(botones, ui.label({
		text = T("panel.counts", {
			containers = tostring(st.containers or 0),
			images = tostring(st.images or 0),
			volumes = tostring(st.volumes or 0),
		}),
		fontSize = 11,
		color = theme.dim(),
		maxWidth = 240,
	}))
	return ui.row({ gap = 8, paddingH = 8, align = "center" }, botones)
end

local function pageFooter(total: number, pages: number, onPage: (number) -> ()): any
	return ui.row({ gap = 8, padding = 4, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page > 1,
			onClick = function()
				onPage(math.max(1, S.page - 1))
			end,
		}),
		ui.label({
			text = T("panel.page_of", { page = tostring(S.page), pages = tostring(pages), total = tostring(total) }),
			fontSize = 12,
			color = theme.muted(),
			maxWidth = 320,
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page < pages,
			onClick = function()
				onPage(math.min(pages, S.page + 1))
			end,
		}),
	})
end

local PRUNE_TARGETS = {
	{ value = "builder", key = "panel.disk.builder" },
	{ value = "images", key = "panel.disk.images" },
	{ value = "containers", key = "panel.disk.containers" },
	{ value = "volumes", key = "panel.disk.volumes" },
	{ value = "system", key = "panel.disk.system" },
}

local function gb(bytes: number): string
	if bytes <= 0 then
		return "0"
	end
	return string.format("%.1f GB", bytes / 1073741824)
end

local function systemFooter(): any
	local info = snapshot(INFO_KEY)
	if type(info) ~= "table" or info.ncpu == nil then
		return ui.box({ height = 0 })
	end
	local funcionando = tonumber(info.running) or 0
	local total = tonumber(info.containers) or 0
	return ui.row({ gap = 14, padding = 4, align = "center" }, {
		ui.glyph({ name = "cpu", size = 13 }),
		ui.label({ text = tostring(info.ncpu or 0) .. " vCPU · " .. gb(tonumber(info.memTotal) or 0), fontSize = 11, color = theme.muted() }),
		ui.label({ text = tostring(info.serverVersion or "") .. " · " .. tostring(info.driver or ""), fontSize = 11, color = theme.dim() }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({
			text = funcionando .. "/" .. total .. " " .. T("panel.detail.running"),
			fontSize = 11,
			color = if funcionando == total then "#7dc47d" else theme.warn(),
		}),
		ui.label({ text = tostring(info.images or 0) .. " " .. T("panel.tab.images"), fontSize = 11, color = theme.dim() }),
	})
end

local function pruneIndex(): number
	for i, destino in ipairs(PRUNE_TARGETS) do
		if destino.value == (S.pruneWhat or "builder") then
			return i - 1
		end
	end
	return 0
end

local function diskFooter(): any
	local disco = snapshot(DISK_KEY)
	local filas = type(disco.rows) == "table" and disco.rows or {}
	local resumen: { string } = {}
	local total = 0
	for _, fila in ipairs(filas) do
		local rec = tostring(fila.reclaimable or "0B")
		if rec ~= "0B" and rec ~= "" then
			table.insert(resumen, tostring(fila.type or "") .. " " .. rec)
			total += 1
		end
	end
	local etiqueta = if #resumen > 0 then T("panel.disk.reclaimable") .. ": " .. table.concat(resumen, "  ·  ") else T("panel.disk.clean")
	local confirmando = S.confirm == "prune"
	local opciones: { string } = {}
	for _, destino in ipairs(PRUNE_TARGETS) do
		table.insert(opciones, T(destino.key))
	end
	return ui.row({ gap = 8, padding = 4, align = "center" }, {
		ui.glyph({ name = "database", size = 14 }),
		ui.label({ text = etiqueta, fontSize = 11, color = theme.dim(), maxWidth = 380, maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		ui.select({
			options = opciones,
			selectedIndex = pruneIndex(),
			controlSize = "sm",
			width = 150,
			onChange = function(index: any)
				S.pruneWhat = PRUNE_TARGETS[(tonumber(index) or 0) + 1].value
			end,
		}),
		ui.button({
			text = if confirmando then T("panel.confirm") else T("panel.disk.prune"),
			controlSize = "sm",
			variant = if confirmando then "destructive" else "outline",
			enabled = total > 0 or confirmando,
			onClick = function()
				if not confirmando then
					S.confirm = "prune"
					render()
					return
				end
				S.confirm = nil
				send({ action = "prune", what = S.pruneWhat or "builder" })
				render()
			end,
		}),
	})
end

-- Un stack: estado agregado del proyecto de compose y acciones sobre el
-- conjunto, que es lo que hace docker desktop y no un listado plano.
local function projectRow(project: any, rel: number): any
	local alpha = 1
	if S.anim.t < 1 then
		alpha = 0.85 + 0.15 * anim.stagger(rel, anim.ease_out(S.anim.t), 0.04)
	end
	local estado = tostring(project.state or "stopped")
	local color = if estado == "running" then theme.ok() elseif estado == "partial" then theme.warn() else theme.dim()
	local servicios: { string } = {}
	for _, servicio in ipairs(type(project.services) == "table" and project.services or {}) do
		table.insert(servicios, tostring(servicio))
	end
	local funcionando = tonumber(project.running) or 0
	local total = tonumber(project.containers) or 0
	return ui.row({
		key = "stack-" .. tostring(project.name or ""),
		width = ROW_W(),
		height = rowHeight(),
		gap = 10,
		padding = 8,
		align = "center",
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.box({ width = 4, height = rowHeight() - 16, radius = 2, fill = color }),
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.row({ gap = 6, align = "center" }, {
				ui.label({ text = tostring(project.name or ""), fontSize = 14, fontWeight = "semibold", maxLines = 1, maxWidth = 220 }),
				chip(estado, color, nil),
				ui.label({
					text = tostring(funcionando) .. "/" .. tostring(total) .. " " .. T("panel.detail.running"),
					fontSize = 11,
					color = theme.muted(),
				}),
			}),
			ui.label({
				text = table.concat(servicios, ", "),
				fontSize = 11,
				color = theme.dim(),
				maxWidth = ROW_W() - 260,
				maxLines = 1,
			}),
		}),
		ui.button({
			glyph = "refresh",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.restart"),
			onClick = function()
				send({ action = "compose", project = tostring(project.name or ""), verb = "restart" })
			end,
		}),
		ui.button({
			glyph = "player-play",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.start"),
			enabled = funcionando < total,
			onClick = function()
				send({ action = "compose", project = tostring(project.name or ""), verb = "up" })
			end,
		}),
		ui.button({
			glyph = "player-stop",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.stop"),
			enabled = funcionando > 0,
			onClick = function()
				send({ action = "compose", project = tostring(project.name or ""), verb = "stop" })
			end,
		}),
	})
end

local function listView(): any
	local items = list(S.tab)
	local children: { any } = { header(), tabs() }
	local st = status()
	if st.error ~= nil and st.error ~= "" then
		table.insert(children, ui.label({ text = tostring(st.error), fontSize = 12, color = theme.danger(), maxWidth = PANEL_INNER(), maxLines = 2 }))
	end
	if #items == 0 then
		table.insert(children, ui.column({ padding = 24, align = "center" }, {
			ui.label({
				text = if st.busy == true then T("panel.loading") else T("panel.empty"),
				fontSize = 13,
				color = theme.muted(),
			}),
		}))
		return ui.column({ gap = 6 }, children)
	end
	local perPage = pageSize()
	local pages = math.max(1, math.ceil(#items / perPage))
	-- Acotar SIN mutar S.page: mutarlo durante el render compite con el
	-- reset de página al cambiar de vista y deja la paginación apuntando a
	-- una página inexistente (la lista se vacía sin aviso).
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#items, first + perPage - 1)
	local filas: { any } = {}
	for index = first, last do
		local item = items[index]
		local rel = index - first + 1
		if S.tab == "containers" then
			table.insert(filas, containerRow(item, rel))
		elseif S.tab == "images" then
			local titulo = tostring(item.repository or "") .. ":" .. tostring(item.tag or "")
			if item.dangling then
				titulo = T("panel.dangling")
			end
			table.insert(filas, simpleRow("images", titulo, tostring(item.id or "") .. "  ·  " .. tostring(item.size or ""), tostring(item.id or ""), true, rel))
		elseif S.tab == "projects" then
			table.insert(filas, projectRow(item, rel))
		elseif S.tab == "volumes" then
			table.insert(filas, simpleRow("volumes", tostring(item.name or ""), tostring(item.driver or "") .. "  ·  " .. tostring(item.mountpoint or ""), tostring(item.name or ""), true, rel))
		else
			table.insert(filas, simpleRow("networks", tostring(item.name or ""), tostring(item.driver or "") .. "  ·  " .. tostring(item.scope or ""), tostring(item.name or ""), item.builtin ~= true, rel))
		end
	end
	table.insert(children, ui.scroll(layout.merge({ key = "cont-scroll", gap = 6, paddingH = 2, align = "center" }, layout.scrollExtra(math.max(1, #filas) * (rowHeight() + 6) - 6, MODO == "float")), filas))
	table.insert(children, systemFooter())
	table.insert(children, diskFooter())
	table.insert(children, pageFooter(#items, pages, function(page: number)
		S.page = page
		S.confirm = nil
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	end))
	return ui.column({ gap = 6 }, children)
end

local function findContainer(id: string): any
	for _, container in ipairs(list("containers")) do
		if tostring(container.id) == id then
			return container
		end
	end
	return nil
end

local SECRET_KEY = "b3l0w_containers_reveal"
-- Por substring alcanza con las que no aparecen en palabras normales; las
-- cortas (PASS, KEY, AUTH) se comparan por segmento para no ocultar AUTHOR.
local SECRETOS_SUB = { "PASSWORD", "PASSWD", "TOKEN", "SECRET", "APIKEY", "API_KEY", "PRIVATE", "CREDENTIAL", "PASSWORT" }
local SECRETOS_SEG = { "PASS", "KEY", "AUTH", "PWD", "SECRETS" }

local function esSecreto(variable: string): boolean
	local clave = string.upper(string.match(variable, "^([^=]+)=") or "")
	for _, palabra in ipairs(SECRETOS_SUB) do
		if string.find(clave, palabra, 1, true) ~= nil then
			return true
		end
	end
	for segmento in string.gmatch(clave, "[^_]+") do
		for _, palabra in ipairs(SECRETOS_SEG) do
			if segmento == palabra then
				return true
			end
		end
	end
	return false
end

local function enmascarar(variable: string): string
	local clave, valor = string.match(variable, "^([^=]+)=(.*)$")
	if clave == nil then
		return variable
	end
	if valor == "" then
		return clave .. "="
	end
	return clave .. "=" .. string.rep("•", math.min(12, #valor))
end

local DETAIL_TABS = {
	{ value = "summary", key = "panel.detail.summary" },
	{ value = "ports", key = "panel.detail.ports" },
	{ value = "mounts", key = "panel.detail.mounts" },
	{ value = "env", key = "panel.detail.env" },
	{ value = "logs", key = "panel.detail.logs" },
}

local function meter(etiqueta: string, valor: number, detalle: string): any
	return ui.column({ gap = 2, flexGrow = 1, minWidth = 0 }, {
		ui.row({ gap = 6, align = "center", justify = "space_between" }, {
			ui.label({ text = etiqueta, fontSize = 11, color = theme.muted() }),
			ui.label({ text = string.format("%.1f%%", valor) .. "  " .. detalle, fontSize = 11, color = "#c9cede", maxWidth = 200 }),
		}),
		ui.progress({ progress = math.min(1, valor / 100), height = 6, radius = 3 }),
	})
end

local function detailTab(value: string, activa: string, onClick: () -> ()): any
	return ui.button({
		text = T(value),
		controlSize = "sm",
		variant = if activa == value then "secondary" else "ghost",
		selected = activa == value,
		onClick = onClick,
	})
end

local function detailView(): any
	local container = findContainer(S.detail or "")
	local data = snapshot(DETAIL_KEY)
	local info = if type(data.inspect) == "table" then data.inspect else {}
	local stats = if type(data.stats) == "table" then data.stats[S.detail or ""] or data.stats[tostring((container or {}).name or "")] else nil
	local nombre = tostring((container and container.name) or info.name or S.detail or "")
	if container == nil and info.name == nil then
		S.screen = "list"
		return listView()
	end
	local running = (container and container.state == "running") or info.state == "running"
	local confirmando = S.confirm == tostring(S.detail)

	local tabsRow: { any } = {}
	for _, tab in ipairs(DETAIL_TABS) do
		table.insert(tabsRow, detailTab(tab.key, S.detailTab, function()
			if S.detailTab == tab.value then
				return
			end
			S.detailTab = tab.value
			S.anim.t = if prefs.animations() then 0 else 1
			render()
		end))
	end
	table.insert(tabsRow, ui.spacer({ flexGrow = 1 }))

	local cuerpo: any
	if S.detailTab == "summary" then
		local filas: { any } = {
			ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = tostring(info.image or (container and container.image) or ""), fontSize = 12, color = theme.muted(), maxWidth = PANEL_INNER() - 40, maxLines = 1 }),
			}),
			ui.row({ gap = 16, align = "center" }, {
				ui.label({ text = T("panel.detail.started") .. ": " .. tostring(info.startedAt or "-"), fontSize = 11, color = theme.dim(), maxWidth = 300, maxLines = 1 }),
				ui.label({ text = T("panel.detail.restarts") .. ": " .. tostring(info.restartCount or 0), fontSize = 11, color = theme.dim() }),
				ui.label({ text = T("panel.detail.policy") .. ": " .. tostring(info.restartPolicy or "-"), fontSize = 11, color = theme.dim() }),
			}),
		}
		if type(info.networks) == "table" and #info.networks > 0 then
			table.insert(filas, ui.label({ text = T("panel.detail.networks") .. ": " .. table.concat(info.networks, ", "), fontSize = 11, color = theme.info(), maxWidth = PANEL_INNER() - 40 }))
		end
		if stats ~= nil then
			table.insert(filas, meter(T("panel.detail.cpu"), tonumber(stats.cpuPct) or 0, ""))
			table.insert(filas, meter(T("panel.detail.memory"), tonumber(stats.memPct) or 0, tostring(stats.memUsage or "")))
			table.insert(filas, ui.row({ gap = 16, align = "center" }, {
				ui.label({ text = "net " .. tostring(stats.netIo or "-"), fontSize = 11, color = theme.dim() }),
				ui.label({ text = "io " .. tostring(stats.blockIo or "-"), fontSize = 11, color = theme.dim() }),
				ui.label({ text = "pids " .. tostring(stats.pids or 0), fontSize = 11, color = theme.dim() }),
			}))
		else
			table.insert(filas, ui.label({ text = T("panel.detail.no_stats"), fontSize = 11, color = theme.dim() }))
		end
		if type(info.healthLog) == "table" and #info.healthLog > 0 then
			table.insert(filas, ui.label({ text = T("panel.detail.health") .. ": " .. tostring(info.healthLog[1]):sub(1, 140), fontSize = 11, color = theme.warn(), maxWidth = PANEL_INNER() - 40, maxLines = 2 }))
		end
		cuerpo = ui.column({ gap = 8, align = "start" }, filas)
	elseif S.detailTab == "ports" then
		local filas: { any } = {}
		for _, port in ipairs((container and container.ports) or {}) do
			table.insert(filas, ui.row({ gap = 8, align = "center" }, {
				ui.label({
					text = tostring(port.hostIp or "") .. ":" .. tostring(port.hostPort or 0) .. " → " .. tostring(port.containerPort or 0) .. "/" .. tostring(port.proto or "tcp"),
					fontSize = 12,
					color = theme.info(),
					maxWidth = 380,
				}),
				ui.button({
					text = T("panel.detail.open"),
					controlSize = "sm",
					variant = "ghost",
					enabled = type(port.url) == "string" and port.url ~= "",
					onClick = function()
						if type(port.url) == "string" and port.url ~= "" then
							noctalia.runAsync({ "xdg-open", port.url })
						end
					end,
				}),
				ui.button({
					glyph = "copy",
					controlSize = "sm",
					variant = "ghost",
					tooltip = T("panel.detail.copy"),
					onClick = function()
						noctalia.copyToClipboard(tostring(port.hostPort or 0), "text/plain")
					end,
				}),
			}))
		end
		if #filas == 0 then
			table.insert(filas, ui.label({ text = T("panel.no_ports"), fontSize = 12, color = theme.dim() }))
		end
		cuerpo = ui.column({ gap = 6, align = "start" }, filas)
	elseif S.detailTab == "mounts" then
		local filas: { any } = {}
		for _, mount in ipairs(type(info.mounts) == "table" and info.mounts or {}) do
			table.insert(filas, ui.column({ gap = 1, align = "start" }, {
				ui.label({ text = tostring(mount.destination or ""), fontSize = 12, fontWeight = "semibold", maxWidth = 400 }),
				ui.label({
					text = tostring(mount.source or "") .. "  ·  " .. tostring(mount.type or "") .. (mount.readOnly and "  ·  ro" or ""),
					fontSize = 11,
					color = theme.dim(),
					maxWidth = PANEL_INNER() - 40,
					maxLines = 1,
				}),
			}))
		end
		if #filas == 0 then
			table.insert(filas, ui.label({ text = T("panel.detail.no_mounts"), fontSize = 12, color = theme.dim() }))
		end
		cuerpo = ui.scroll(layout.merge({ key = "mounts-scroll", align = "stretch", gap = 6 }, layout.scrollExtra(300)), filas)
	elseif S.detailTab == "env" then
		local filas: { any } = {}
		local revelar = S.reveal == true
		local ocultos = 0
		for _, variable in ipairs(type(info.env) == "table" and info.env or {}) do
			local texto = tostring(variable)
			if not revelar and esSecreto(texto) then
				ocultos += 1
				texto = enmascarar(texto)
			end
			table.insert(filas, ui.label({ text = texto, fontSize = 11, color = theme.text(), maxWidth = PANEL_INNER() - 40, maxLines = 1 }))
		end
		if type(info.labels) == "table" then
			for clave, valor in pairs(info.labels) do
				table.insert(filas, ui.label({ text = tostring(clave) .. "=" .. tostring(valor), fontSize = 11, color = theme.dim(), maxWidth = PANEL_INNER() - 40, maxLines = 1 }))
			end
		end
		if #filas == 0 then
			table.insert(filas, ui.label({ text = T("panel.detail.no_env"), fontSize = 12, color = theme.dim() }))
		elseif ocultos > 0 or S.reveal == true then
			table.insert(filas, 1, ui.row({ gap = 8, align = "center" }, {
				ui.button({
					text = if S.reveal == true then T("panel.detail.hide") else T("panel.detail.reveal") .. " (" .. tostring(ocultos) .. ")",
					controlSize = "sm",
					variant = if S.reveal == true then "destructive" else "outline",
					onClick = function()
						S.reveal = not (S.reveal == true)
						render()
					end,
				}),
				ui.label({ text = T("panel.detail.masked_hint"), fontSize = 11, color = theme.dim() }),
			}))
		end
		cuerpo = ui.scroll(layout.merge({ key = "env-scroll", align = "stretch", gap = 4 }, layout.scrollExtra(300)), filas)
	else
		local logs = snapshot(LOGS_KEY)
		local texto = if tostring(logs.id or "") == tostring(S.detail) then tostring(logs.text or "") else T("panel.logs_loading")
		cuerpo = ui.row({ gap = 8, align = "start" }, {
			ui.scroll(layout.merge({ key = "logs-scroll", align = "stretch", paddingH = 4 }, layout.scrollExtra(340)), {
				ui.label({ text = texto, fontSize = 11, color = theme.text(), maxWidth = PANEL_INNER() - 40 }),
			}),
		})
	end

	return ui.column({ gap = 8, padding = 8, flexGrow = 1 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.button({ glyph = "arrow-left", controlSize = "sm", variant = "ghost", onClick = function()
				send({ action = "undetail" })
				S.screen = "list"
				S.detail = nil
				S.confirm = nil
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end }),
			ui.label({ text = nombre, fontSize = 16, fontWeight = "semibold", maxLines = 1, maxWidth = 260 }),
			chip(tostring(info.state or (container and container.state) or ""), stateColor(tostring(info.state or "")), nil),
			ui.spacer({ flexGrow = 1 }),
			ui.button({
				text = if running then T("panel.stop") else T("panel.start"),
				controlSize = "sm",
				variant = "primary",
				onClick = function()
					send({ action = if running then "stop" else "start", id = S.detail })
				end,
			}),
			ui.button({ text = T("panel.restart"), controlSize = "sm", onClick = function()
				send({ action = "restart", id = S.detail })
			end }),
			ui.button({
				glyph = "terminal-2",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.detail.shell"),
				enabled = running,
				onClick = function()
					noctalia.runInTerminal("docker exec -it " .. nombre .. " sh")
				end,
			}),
			ui.button({
				text = if confirmando then T("panel.confirm") else T("panel.remove"),
				controlSize = "sm",
				variant = if confirmando then "destructive" else "outline",
				onClick = function()
					if not confirmando then
						S.confirm = tostring(S.detail)
						render()
						return
					end
					S.confirm = nil
					send({ action = "remove", id = S.detail })
					S.screen = "list"
					S.detail = nil
					render()
				end,
			}),
		}),
		ui.row({ gap = 6, align = "center" }, tabsRow),
		cuerpo,
	})
end

local function runView(): any
	local st = status()
	local form = S.form
	local function campo(etiqueta: string, clave: string, placeholder: string)
		return ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = etiqueta, fontSize = 12, color = theme.muted(), maxWidth = 120 }),
			ui.input({
				key = "run-" .. clave,
				value = tostring(form[clave] or ""),
				placeholder = placeholder,
				controlSize = "sm",
				width = 420,
				onChange = function(texto: any)
					form[clave] = tostring(texto or "")
				end,
			}),
		})
	end
	return ui.column({ gap = 10, padding = 12 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.button({ glyph = "arrow-left", controlSize = "sm", variant = "ghost", onClick = function()
				S.screen = "list"
				S.runForm = false
				render()
			end }),
			ui.label({ text = T("panel.run_title"), fontSize = 16, fontWeight = "semibold" }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({ text = if st.busy == true then T("panel.refreshing") else "", fontSize = 11, color = theme.warn() }),
		}),
		ui.label({ text = T("panel.run_help"), fontSize = 11, color = theme.dim(), maxWidth = PANEL_INNER() }),
		campo(T("panel.form.image"), "image", "nginx:latest"),
		campo(T("panel.form.name"), "name", "mi-nginx"),
		campo(T("panel.form.network"), "network", "bridge"),
		campo(T("panel.form.ports"), "ports", "8080:80"),
		campo(T("panel.form.env"), "env", "KEY=valor"),
		ui.row({ gap = 8, align = "center" }, {
			ui.button({
				text = T("panel.form.create"),
				variant = "primary",
				controlSize = "sm",
				enabled = tostring(form.image or "") ~= "",
				onClick = function()
					local ports: { string } = {}
					for puerto in tostring(form.ports or ""):gmatch("[^,\n]+") do
						local limpio = puerto:gsub("%s", "")
						if limpio ~= "" then
							table.insert(ports, limpio)
						end
					end
					local env: { string } = {}
					if form.env ~= nil and form.env ~= "" then
						table.insert(env, tostring(form.env))
					end
					send({
						action = "run",
						image = tostring(form.image or ""),
						name = tostring(form.name or ""),
						network = tostring(form.network or ""),
						ports = ports,
						env = env,
					})
					S.screen = "list"
					S.runForm = false
					render()
				end,
			}),
			ui.label({ text = T("panel.form.hint"), fontSize = 11, color = theme.dim(), maxWidth = 420 }),
		}),
	})
end

-- ── render ───────────────────────────────────────────────────────────

local lastTrace = ""

function render(): ()
	local st = status()
	local data = snap()
	local detalle = snapshot(DETAIL_KEY)
	local info = type(detalle.inspect) == "table" and detalle.inspect or {}
	local trace = tostring(#list(S.tab)) .. "/" .. tostring(st.running or 0) .. "/" .. S.tab .. "/" .. S.screen .. "/p" .. tostring(S.page)
		.. "/" .. S.detailTab .. "/ports=" .. tostring(#(type(list("containers")[1]) == "table" and list("containers")[1].ports or {}))
		.. "/mounts=" .. tostring(type(info.mounts) == "table" and #info.mounts or 0)
		.. "/env=" .. tostring(type(info.env) == "table" and #info.env or 0)
	if trace ~= lastTrace then
		lastTrace = trace
		noctalia.log("[b3l0w-containers] items/running/tab/vista/pagina = " .. trace)
	end
	local body: any
	if S.screen == "detail" then
		body = detailView()
	elseif S.screen == "run" then
		body = runView()
	else
		body = listView()
	end
	panel.render(ui.column({ height = panelHeight(),  gap = 4, padding = 6, width = layout.width(PANEL_INNER()) }, { body }))
end

function onFrameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	S.anim.t = math.min(1, S.anim.t + (tonumber(delta) or 16) / (S.anim.ms or 220))
	render()
end

-- El entry declara el modo ANTES de abrir: `M.open(context, "float")`.
-- El setting `panel_mode` elige qué entry abre el widget, no el ancho del
-- panel ya abierto.
function M.open(context: any, modo: string)
	MODO = if modo == "float" then "float" else "compact"
	onOpen(context)
end

function M.setMode(modo: string)
	MODO = if modo == "float" then "float" else "compact"
end

-- Wrappers de los hooks: en este plugin los hooks son GLOBALES (el host los
-- llama por nombre), así que `require` no los exporta. El entry flotante
-- los invoca a través de estos wrappers.
function M.close()
	onClose()
end

function M.frameTick(delta: number)
	onFrameTick(delta)
end

function onOpen(_context: any): ()
	lastTrace = ""
	state.store(SNAP_KEY, noctalia.state.get(SNAP_KEY))
	state.store(STATUS_KEY, noctalia.state.get(STATUS_KEY))
	state.store(LOGS_KEY, noctalia.state.get(LOGS_KEY))
	state.store(DETAIL_KEY, noctalia.state.get(DETAIL_KEY))
	state.store(DISK_KEY, noctalia.state.get(DISK_KEY))
	state.store(INFO_KEY, noctalia.state.get(INFO_KEY))
	local pantalla = noctalia.state.get(SCREEN_KEY)
	if type(pantalla) == "table" then
		for _, tab in ipairs(TABS) do
			if pantalla.tab == tab.value then
				S.tab = tab.value
			end
		end
		if type(pantalla.id) == "string" and pantalla.id ~= "" then
			S.detail = pantalla.id
			S.screen = "detail"
		end
		if type(pantalla.detTab) == "string" and pantalla.detTab ~= "" then
			S.detailTab = pantalla.detTab
		end
	end
	S.anim.t = if prefs.animations() then 0 else 1
	panel.setNeedsFrameTick(true)
	render()
end

function onClose(): ()
	S.detail = nil
	S.screen = "list"
	S.confirm = nil
end

function onKey(chord: string, pressed: boolean): ()
	if not pressed then
		return
	end
	if chord == "g" then
		local indice = 1
		for index, tab in ipairs(TABS) do
			if tab.value == S.tab then
				indice = index
			end
		end
		S.tab = TABS[(indice % #TABS) + 1].value
		S.page = 1
		S.screen = "list"
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Prior" or chord == "Next" then
		local total = #list(S.tab)
		local pages = math.max(1, math.ceil(total / pageSize()))
		if chord == "Next" then
			S.page = math.min(pages, S.page + 1)
		else
			S.page = math.max(1, S.page - 1)
		end
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Left" or chord == "Right" then
		local indice = 1
		for index, tab in ipairs(TABS) do
			if tab.value == S.tab then
				indice = index
			end
		end
		local delta = if chord == "Right" then 1 else -1
		local nuevo = ((indice - 1 + delta) % #TABS) + 1
		S.tab = TABS[nuevo].value
		S.page = 1
		S.screen = "list"
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	end
end

state.watch(SNAP_KEY, function(_value: any)
	render()
end)

state.watch(STATUS_KEY, function(_value: any)
	render()
end)

state.watch(LOGS_KEY, function(_value: any)
	if S.screen == "detail" then
		render()
	end
end)

state.watch(DETAIL_KEY, function(_value: any)
	if S.screen == "detail" then
		render()
	end
end)

state.watch(INFO_KEY, function(_value: any)
	render()
end)

state.watch(DISK_KEY, function(_value: any)
	render()
end)

noctalia.state.watch(SCREEN_KEY, function(value: any)
	if type(value) ~= "table" then
		return
	end
	if type(value.detTab) == "string" and value.detTab ~= "" then
		S.detailTab = value.detTab
	end
	for _, tab in ipairs(TABS) do
		if value.tab == tab.value then
			S.tab = tab.value
		end
	end
	if type(value.id) == "string" and value.id ~= "" then
		S.detail = value.id
		S.screen = "detail"
	end
	render()
end)

-- `require` necesita que el módulo retorne la tabla: este archivo
-- también es el entry directo del panel compacto, así que el retorno no
-- molesta al host.
return M
