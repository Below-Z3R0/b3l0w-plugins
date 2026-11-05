--!strict
-- Panel grande de b3l0w/containers: tipo Docker Desktop.
--
-- El host es dueño del tamaño: el manifest declara este panel con
-- `width = "fill"` / `height = "fill"`, así que ocupa todo el monitor y el
-- árbol hereda el tamaño real con `align = "stretch"`. Por eso los scrolls
-- usan `scrollExtra(..., true)` (flexGrow, sin alto declarado): con un alto
-- fijo quedaría un bloque muerto o el contenido se recortaría al cambiar el
-- tamaño de la ventana.
--
-- Es un entry aparte del panel compacto. Cada entry corre en su propia VM,
-- así que este panel habla con el service por las mismas claves de estado
-- que el compacto (`lib/state.luau`).

local anim = require("./lib/anim.luau")
local layout = require("./lib/layout.luau")
local prefs = require("./lib/prefs.luau")
local state = require("./lib/state.luau")
local theme = require("./lib/theme.luau")
local columns = require("./lib/columns.luau")

local T = noctalia.tr

-- Claves del service: el estado es global al plugin, así que este panel ve
-- exactamente lo mismo que el compacto.
local SNAP_KEY = "b3l0w_containers_snapshot"
local STATUS_KEY = "b3l0w_containers_status"
local REQUEST_KEY = "b3l0w_containers_request"
local LOGS_KEY = "b3l0w_containers_logs"
local DETAIL_KEY = "b3l0w_containers_detail"
local DISK_KEY = "b3l0w_containers_disk"
local INFO_KEY = "b3l0w_containers_info"
local STATS_KEY = "b3l0w_containers_stats"
local EVENTS_KEY = "b3l0w_containers_events"
local EXEC_KEY = "b3l0w_containers_exec"
local TOP_KEY = "b3l0w_containers_top"
local HISTORY_KEY = "b3l0w_containers_history"
local DIFF_KEY = "b3l0w_containers_diff"
-- Datos de acciones puntuales (no del refresco).
local PORTS_KEY = "b3l0w_containers_ports"
local HUB_KEY = "b3l0w_containers_hub"
local VOLINFO_KEY = "b3l0w_containers_volinfo"
local NETINFO_KEY = "b3l0w_containers_netinfo"
-- Lo publica el service con la acción `view`: permite que el panel compacto
-- (u otro entry) abra el desktop directo en una sección.
local SCREEN_KEY = "b3l0w_containers_screen"
local LOGSTREAM_KEY = "b3l0w_containers_logstream"
local COMPOSEFILE_KEY = "b3l0w_containers_composefile"

-- El manifest declara 1400x900. El host recorta 12 px del ancho pedido, así
-- que el ancho útil es 1388. Acá sólo se usa el alto (para el viewport de
-- los scrolls) y el ancho de la barra lateral.
local PANEL_W = 1400
-- Con `height = "fill"` el panel ocupa el monitor entero. El alto lo usa
-- `pageSizeFor` para calcular cuántas filas entran de verdad: con 900 fijo
-- (el tamaño viejo) y el alto de fila de los contenedores, Events mostraba
-- 10 entradas en un panel de 1080 y dejaba media pantalla vacía.
local PANEL_H = 1080
local USABLE_W = PANEL_W - 12
local TOPBAR_H = 56
local SIDEBAR_W = 220
local TOOLBAR_H = 44
local FOOTER_H = 34
local ROW_H = 64

local S = {
	section = "dashboard" :: string,
	page = 1,
	filter = "all" :: string,
	query = "",
	target = nil :: string?,
	detailTab = "summary" :: string,
	confirm = nil :: string?,
	-- Qué recurso se está inspeccionando (volumen o red) y cuál.
	inspectKind = "volumes" :: string,
	inspectName = "" :: string,
	execId = "",
	execCommand = "ls -la",
	execHistory = {} :: { string },
	requests = 0,
	lastStats = 0,
	lastEvents = 0,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
	form = {
		rename = "",
		commitRepo = "",
		commitTag = "latest",
		commitMessage = "",
		copySource = "",
		copyTarget = "",
		tagRepo = "",
		tagTag = "latest",
		runImage = "",
		runName = "",
		runPorts = "",
		runEnv = "",
		buildTag = "",
		buildContext = ".",
		buildDockerfile = "Dockerfile",
		volBackupName = "",
		volBackupPath = "",
		limitCpus = "",
		limitMemory = "",
		volRestorePath = "",
		hubQuery = "",
	} :: { [string]: string },
}

local SECTIONS = {
	{ value = "dashboard", key = "desktop.section.dashboard", glyph = "layout-dashboard" },
	{ value = "containers", key = "desktop.section.containers", glyph = "box" },
	{ value = "images", key = "desktop.section.images", glyph = "photo" },
	{ value = "volumes", key = "desktop.section.volumes", glyph = "database" },
	{ value = "networks", key = "desktop.section.networks", glyph = "network" },
	{ value = "compose", key = "desktop.section.compose", glyph = "stack-2" },
	{ value = "terminal", key = "desktop.section.terminal", glyph = "terminal-2" },
	{ value = "build", key = "desktop.section.build", glyph = "hammer" },
	{ value = "disk", key = "desktop.section.disk", glyph = "trash" },
	{ value = "events", key = "desktop.section.events", glyph = "activity" },
}

-- Una celda de ancho FIJO. El `width` de un label lo descarta el host, así
-- que la columna va dentro de un flex con `width` (el host lo traduce a
-- minWidth = maxWidth). Sin esto cada fila arranca en una x distinta.
local function celda(texto: any, ancho: number, props: any): any
	return ui.column(layout.colProps(ancho), { ui.label(layout.celdaProps(texto, props)) })
end

-- ── acceso a los datos ─────────────────────────────────────────────────

local function send(payload: any): ()
	S.requests += 1
	payload.nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(S.requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

local function snap(): { [string]: any }
	return state.table(SNAP_KEY)
end

local function status(): { [string]: any }
	return state.table(STATUS_KEY)
end

local function list(tab: string): { any }
	local items = snap()[tab]
	return type(items) == "table" and items or {}
end

local function statsRows(): { any }
	-- El estado directo es la fuente de verdad: la caché del módulo puede
	-- seguir con el valor viejo si el service publicó antes de que el panel
	-- abriera (el watch sólo actualiza a partir de ese momento).
	local datos = noctalia.state.get(STATS_KEY)
	if type(datos) ~= "table" or type(datos.rows) ~= "table" or #datos.rows == 0 then
		datos = state.table(STATS_KEY)
	end
	return type(datos.rows) == "table" and datos.rows or {}
end

local function statsByName(): { [string]: any }
	local salida: { [string]: any } = {}
	for _, fila in ipairs(statsRows()) do
		salida[tostring(fila.name or "")] = fila
	end
	return salida
end

local function eventRows(): { any }
	-- El estado directo es la fuente de verdad: la caché del módulo puede
	-- seguir con el valor viejo si el service publicó antes de que el panel
	-- abriera (el watch sólo actualiza a partir de ese momento).
	local datos = noctalia.state.get(EVENTS_KEY)
	if type(datos) ~= "table" or type(datos.rows) ~= "table" or #datos.rows == 0 then
		datos = state.table(EVENTS_KEY)
	end
	return type(datos.rows) == "table" and datos.rows or {}
end

local function diskRows(): { any }
	-- El estado directo es la fuente de verdad: la caché del módulo puede
	-- seguir con el valor viejo si el service publicó antes de que el panel
	-- abriera (el watch sólo actualiza a partir de ese momento).
	local datos = noctalia.state.get(DISK_KEY)
	if type(datos) ~= "table" or type(datos.rows) ~= "table" or #datos.rows == 0 then
		datos = state.table(DISK_KEY)
	end
	return type(datos.rows) == "table" and datos.rows or {}
end

-- Busca por id O por nombre: el panel recibe el id corto por clic, pero el
-- service también puede abrir el detalle por nombre (`{"tab":"detail",
-- "id":"prueba"}`). Buscar sólo por id dejaba el detalle sin puertos ni
-- stats cuando llegaba el nombre.
local function findContainer(id: string): any
	for _, container in ipairs(list("containers")) do
		if tostring(container.id) == id or tostring(container.name) == id then
			return container
		end
	end
	return nil
end

local function runningContainers(): { any }
	local salida: { any } = {}
	for _, container in ipairs(list("containers")) do
		if container.state == "running" then
			table.insert(salida, container)
		end
	end
	return salida
end

-- ── piezas ────────────────────────────────────────────────────────────

local function stateColor(estado: string): string
	if estado == "running" then
		return theme.ok()
	elseif estado == "paused" then
		return theme.warn()
	end
	return theme.dim()
end

local function chip(texto: string, color: string): any
	return ui.row({
		fill = theme.chip(),
		radius = 6,
		paddingH = 6,
		paddingV = 2,
		align = "stretch",
	}, {
		ui.label({ text = texto, fontSize = 11, color = color }),
	})
end

local function iconButton(glyph: string, tooltip: string, enabled: boolean, onClick: () -> ()): any
	return ui.button({
		glyph = glyph,
		controlSize = "sm",
		variant = "ghost",
		tooltip = tooltip,
		enabled = enabled,
		onClick = onClick,
	})
end

-- Una tarjeta de métrica: el ancho lo reparte el flexGrow del padre.
-- `detalle` acepta un string o una lista de líneas. El desglose del disco
-- son 4 valores (Images, Containers, Volumes, Build cache): concatenados en
-- una sola línea se cortaban ("Images 1.017MB · Co…") y no se leía nada.
local function metricCard(etiqueta: string, valor: string, detalle: any, color: string): any
	local lineas: { any } = {}
	local partes = if type(detalle) == "table" then detalle else { detalle }
	for _, parte in ipairs(partes) do
		table.insert(lineas, ui.label(layout.text(tostring(parte), { fontSize = 10, color = theme.muted() })))
	end
	local hijos: { any } = {
		ui.label(layout.text(valor, { fontSize = 22, fontWeight = "bold", color = color })),
		ui.label(layout.text(etiqueta, { fontSize = 12, color = theme.muted() })),
	}
	for _, linea in ipairs(lineas) do
		table.insert(hijos, linea)
	end
	return ui.column({
		flexGrow = 1,
		minWidth = 0,
		gap = 1,
		padding = 12,
		radius = 10,
		fill = theme.raised(),
	}, hijos)
end

-- Una barra con su porcentaje (uso de disco, CPU, memoria).
local function usageBar(etiqueta: string, valor: number, detalle: string, color: string): any
	return ui.column({ gap = 2, flexGrow = 1, minWidth = 0 }, {
		ui.row({ gap = 6, align = "stretch", justify = "space_between" }, {
			ui.label(layout.text(etiqueta, { fontSize = 11, color = theme.muted() })),
			ui.label(layout.text(detalle, { fontSize = 11, color = color })),
		}),
		ui.progress({ progress = math.min(1, math.max(0, valor)), height = 6, radius = 3, fill = color }),
	})
end

local function emptyState(texto: string): any
	return ui.column({ padding = 20, align = "stretch", gap = 4 }, {
		ui.label({ text = texto, fontSize = 13, color = theme.muted() }),
	})
end

local function sectionTitle(titulo: string): any
	return ui.row({ gap = 10, align = "stretch" }, {
		ui.label({ text = titulo, fontSize = 15, fontWeight = "semibold" }),
	})
end

-- El alto del viewport de la lista: el cromo de la vista se lo come. Sin un
-- número, el scroll mide lo que el contenido y la rueda nunca scrollea.
local function listViewport(): number
	return math.max(160, PANEL_H - layout.chrome({ TOPBAR_H, TOOLBAR_H, FOOTER_H }) - 40)
end

-- El alto completo cuando la vista no tiene barra de herramientas ni pie.
local function fullViewport(): number
	return listViewport() + TOOLBAR_H + FOOTER_H
end

-- Cuántas filas de `rowH` entran en el panel. Descuenta el topbar, el
-- padding del contenido y el pie de página. Cada vista tiene su alto de
-- fila: una entrada de Events mide ~24 px, la de un contenedor 64.
local function pageSizeFor(rowH: number): number
	-- Se descuenta el topbar, el padding del contenido (12 arriba y abajo),
	-- el gap del column y el pie. El -2 es un margen: el alto real de las
	-- filas varía con el texto y sin él el pie quedaba cortado abajo
	-- (medido: 35 filas de evento dejaban el pie 50 px fuera del panel).
	local disponible = PANEL_H - TOPBAR_H - 12 - 12 - 34
	return math.max(3, math.floor(disponible / (rowH + 2)) - 5)
end

local function pageSize(): number
	return pageSizeFor(ROW_H)
end

local function pageFooter(total: number, pages: number): any
	local page = math.max(1, math.min(S.page, pages))
	-- `width = "fill"` + flexGrow en la etiqueta: con `space_between` y sin
	-- ancho propio, las flechas se dibujaban FUERA del row y no se veían
	-- (mismo bug que tenía el bloque Engine del dashboard).
	return ui.row({ width = "fill", gap = 8, padding = 2, align = "center" }, {
		ui.label({
			text = T("desktop.page_of", { page = tostring(page), pages = tostring(pages), total = tostring(total) }),
			flexGrow = 1,
			fontSize = 11,
			color = theme.dim(),
		}),
		ui.row({ gap = 8, align = "stretch" }, {
			ui.button({
				glyph = "chevron-left",
				controlSize = "sm",
				variant = "ghost",
				enabled = page > 1,
				onClick = function()
					S.page = math.max(1, page - 1)
					render()
				end,
			}),
			ui.button({
				glyph = "chevron-right",
				controlSize = "sm",
				variant = "ghost",
				enabled = page < pages,
				onClick = function()
					S.page = math.min(pages, page + 1)
					render()
				end,
			}),
		}),
	})
end

-- El filtro de texto: sólo el panel filtra, el service no sabe de esto.
local function matches(texto: string): boolean
	local q = string.lower(noctalia.string.trim(S.query or ""))
	if q == "" then
		return true
	end
	return string.find(string.lower(texto), q, 1, true) ~= nil
end

local function filtered(tab: string): { any }
	local salida: { any } = {}
	for _, item in ipairs(list(tab)) do
		local texto = tostring(item.name or item.repository or "")
		local estado = item.state
		local pasaFiltro = S.filter == "all" or estado == S.filter
		if not pasaFiltro then
			pasaFiltro = estado == nil
		end
		if pasaFiltro and matches(texto) then
			table.insert(salida, item)
		end
	end
	return salida
end

-- ── barra lateral ──────────────────────────────────────────────────────

local function sidebar(): any
	local hijos: { any } = {}
	for _, seccion in ipairs(SECTIONS) do
		local activa = S.section == seccion.value
		table.insert(hijos, ui.row({
			key = "nav-" .. seccion.value,
			gap = 10,
			align = "stretch",
			padding = 6,
			radius = 8,
			fill = if activa then theme.raised() else nil,
			onClick = function()
				if S.section == seccion.value then
					return
				end
				S.section = seccion.value
				S.page = 1
				S.confirm = nil
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}, {
			ui.glyph({ name = seccion.glyph, size = 16, color = if activa then theme.accent() else theme.muted() }),
			ui.label({
				text = T(seccion.key),
				fontSize = 13,
				fontWeight = if activa then "semibold" else "normal",
				color = if activa then theme.text() else theme.muted(),
			}),
		}))
	end
	-- OJO: NO poner `height = "fill"` acá. Igual que `width = "fill"` en la
	-- raíz, toma el alto de la SUPERFICIE (con el bleed de la sombra del
	-- marco) y la sidebar sobresale ~20 px por debajo del panel. Con
	-- `align = "stretch"` el row padre ya la estira al alto correcto.
	return ui.column({
		width = SIDEBAR_W,
		align = "stretch",
		gap = 2,
		padding = 8,
		fill = theme.raised(),
	}, hijos)
end

-- ── cabecera ───────────────────────────────────────────────────────────

local function topbar(): any
	local st = status()
	return ui.row({
		height = TOPBAR_H,
		gap = 10,
		paddingH = 14,
		align = "stretch",
		fill = theme.raised(),
	}, {
		ui.glyph({ name = "brand-docker", size = 20 }),
		ui.label({ text = T("desktop.title"), fontSize = 16, fontWeight = "semibold" }),
		ui.label({
			text = if st.busy == true then T("panel.refreshing") else "",
			fontSize = 11,
			color = theme.warn(),
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			glyph = "refresh",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.refresh"),
			onClick = function()
				send({ action = "refresh" })
				send({ action = "stats" })
				send({ action = "disk" })
				send({ action = "events" })
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
	})
end

-- ── dashboard ──────────────────────────────────────────────────────────

local function topContainerRow(fila: any): any
	local cpu = tonumber(fila.cpuPct) or 0
	local mem = tonumber(fila.memPct) or 0
	return ui.row({
		gap = 12,
		align = "stretch",
		padding = 6,
		radius = 8,
		fill = theme.raised(),
	}, {
		ui.label(layout.text(tostring(fila.name or ""), { fontSize = 13, fontWeight = "semibold", flexGrow = 1 })),
		usageBar(T("panel.detail.cpu"), cpu, string.format("%.1f%%", cpu), theme.info()),
		usageBar(T("panel.detail.memory"), mem, tostring(fila.memUsage or ""), theme.warn()),
	})
end

local function daemonInfo(): any
	-- El estado directo: la caché de `state` puede tener un valor viejo (o
	-- vacío) si el service Todavía no publicó la info del daemon.
	-- Primero el snapshot (viaja con el daemon); INFO_KEY es el respaldo.
	local snap = state.table(SNAP_KEY)
	local info = snap.daemon
	if type(info) ~= "table" or next(info) == nil then
		info = noctalia.state.get(INFO_KEY)
	end
	if type(info) ~= "table" then
		info = {}
	end
	local filas: { any } = {}
	local function par(etiqueta: string, valor: string)
		-- `width = "fill"` + flexGrow en la etiqueta: sin ancho propio el row
		-- medía su contenido y `space_between` empujaba el VALOR fuera de la
		-- columna, así que Engine mostraba las etiquetas y ningún dato.
		table.insert(filas, ui.row({ width = "fill", gap = 8, align = "center" }, {
			ui.label({ text = etiqueta, fontSize = 11, color = theme.muted(), flexGrow = 1 }),
			ui.label({ text = valor, fontSize = 11, color = theme.text(), maxLines = 1 }),
		}))
	end
	par(T("desktop.daemon.version"), tostring(info.serverVersion or "-"))
	par(T("desktop.daemon.driver"), tostring(info.driver or "-"))
	par(T("desktop.daemon.cpu"), tostring(info.ncpu or 0) .. " vCPU")
	par(T("desktop.daemon.memory"), string.format("%.1f GB", (tonumber(info.memTotal) or 0) / 1073741824))
	par(T("desktop.daemon.os"), tostring(info.os or "-") .. " · " .. tostring(info.arch or "-"))
	return ui.column({ gap = 6, padding = 10, radius = 10, fill = theme.surface(), align = "stretch" }, filas)
end

local function eventRow(evento: any): any
	local accion = tostring(evento.action or "")
	-- La hora se recorta a HH:MM:SS: `docker events --json` trae el
	-- timestamp ISO completo (largo y de ancho variable) y, como el `width`
	-- de un label no se aplica, cada fila quedaba desplazada distinto: los
	-- eventos salían escalonados.
	local hora = string.match(tostring(evento.time or ""), "(%d%d:%d%d:%d%d)")
	if hora == nil then
		hora = tostring(evento.time or "")
	end
	local color = if accion == "die" or accion == "destroy" then theme.danger() elseif accion == "start" then theme.ok() else theme.dim()
	-- Las columnas van dentro de un flex con `width`: el host descarta el
	-- `width` de un label, así que con labels sueltos cada fila arrancaba
	-- en una x distinta.
	return ui.row({ gap = 10, align = "stretch", padding = 4 }, {
		celda(hora, 70, { fontSize = 11, color = theme.dim() }),
		celda(accion, 90, { fontSize = 11, color = color }),
		ui.label(layout.text(tostring(evento.name or evento.image or ""), { fontSize = 12, color = theme.text(), flexGrow = 1 })),
	})
end

local function dashboardView(): any
	local st = status()
	-- El estado directo: la caché del módulo puede tener el valor viejo.
	local disco = noctalia.state.get(DISK_KEY)
	if type(disco) ~= "table" or type(disco.rows) ~= "table" or #disco.rows == 0 then
		disco = state.table(DISK_KEY)
	end
	local stats = statsRows()
	local eventos = eventRows()

	local tarjetas: { any } = {}
	table.insert(tarjetas, metricCard(
		T("desktop.metric.containers"),
		tostring(tonumber(st.running) or 0) .. "/" .. tostring(tonumber(st.containers) or 0),
		T("desktop.metric.running"),
		theme.ok()
	))
	table.insert(tarjetas, metricCard(
		T("desktop.metric.images"),
		tostring(#list("images")),
		T("desktop.metric.stored"),
		theme.info()
	))
	table.insert(tarjetas, metricCard(
		T("desktop.metric.volumes"),
		tostring(#list("volumes")),
		T("desktop.metric.stored"),
		theme.info()
	))
	table.insert(tarjetas, metricCard(
		T("desktop.metric.networks"),
		tostring(#list("networks")),
		T("desktop.metric.stored"),
		theme.info()
	))
	-- El `total` del df es la salida de texto multilínea: en una tarjeta se ve
	-- vacío. Va el reclaimable (una línea) y el desglose debajo.
	-- Una línea por tipo: antes iban concatenadas con " · " y la tarjeta
	-- mostraba "Images 1.017MB · Co…" cortado.
	local detalle: { string } = {}
	local totalReclaim = 0
	for _, fila in ipairs(disco.rows or {}) do
		local valor = tostring(fila.reclaimable or "0B")
		totalReclaim = totalReclaim + layout.parseBytes(valor)
		table.insert(detalle, tostring(fila.type or "?") .. ": " .. valor)
	end
	table.insert(tarjetas, metricCard(
		T("desktop.metric.disk"),
		if totalReclaim > 0 then layout.humanBytes(totalReclaim) else "-",
		if #detalle > 0 then detalle else T("desktop.metric.used"),
		theme.warn()
	))

	local top: { any } = {}
	for _, fila in ipairs(stats) do
		table.insert(top, topContainerRow(fila))
	end
	if #top == 0 then
		table.insert(top, emptyState(T("desktop.no_stats")))
	end

	local listaEventos: { any } = {}
	for _, evento in ipairs(eventos) do
		table.insert(listaEventos, eventRow(evento))
	end
	if #listaEventos == 0 then
		table.insert(listaEventos, emptyState(T("desktop.no_events")))
	end

	-- `flexGrow = 1`: el dashboard llena el alto del panel. Sin esto el column
	-- mide su contenido, el `flexGrow` de adentro no tiene contra qué repartir
	-- y la última fila de eventos quedaba cortada contra el borde inferior.
	return ui.column({ gap = 10, padding = 12, flexGrow = 1, align = "stretch" }, {
		ui.row({ gap = 10, align = "stretch" }, tarjetas),
		ui.row({ gap = 10, align = "stretch", flexGrow = 1 }, {
			ui.column({ gap = 8, flexGrow = 2, minWidth = 0, align = "stretch" }, {
				sectionTitle(T("desktop.top_containers")),
				ui.scroll(layout.merge({ key = "dash-stats", align = "stretch", gap = 4 }, layout.scrollExtra(0, true)), top),
			}),
			ui.column({ gap = 8, flexGrow = 1, minWidth = 0, align = "stretch" }, {
				sectionTitle(T("desktop.daemon.title")),
				daemonInfo(),
				sectionTitle(T("desktop.recent_events")),
				ui.scroll(layout.merge({ key = "dash-events", align = "stretch", gap = 2, flexGrow = 1 }), listaEventos),
			}),
		}),
	})
end

-- ── contenedores ───────────────────────────────────────────────────────

local function containerRow(container: any, indice: number, stats: { [string]: any }): any
	local estado = tostring(container.state or "")
	local corriendo = estado == "running"
	local pausado = estado == "paused"
	local fila = stats[tostring(container.name or "")]
	local cpu = tonumber(fila and fila.cpuPct or 0) or 0
	local mem = tonumber(fila and fila.memPct or 0) or 0
	local alpha = if S.anim.t < 1 then anim.stagger(indice, anim.ease_out(S.anim.t), 0.03) else 1
	local id = tostring(container.id or "")
	local confirming = S.confirm == "remove:" .. id

	local puertos: { string } = {}
	for _, puerto in ipairs(type(container.ports) == "table" and container.ports or {}) do
		table.insert(puertos, tostring(puerto.hostPort or 0) .. "→" .. tostring(puerto.containerPort or 0))
		if #puertos >= 2 then
			break
		end
	end

	return ui.row({
		key = "cont-" .. id,
		height = ROW_H,
		gap = 10,
		padding = 8,
		align = "stretch",
		radius = 10,
		fill = theme.raised(),
		opacity = alpha,
	}, {
		ui.box({ width = 4, height = ROW_H - 18, radius = 2, fill = stateColor(estado) }),
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.row({ gap = 8, align = "stretch" }, {
				ui.label(layout.text(tostring(container.name or ""), { fontSize = 14, fontWeight = "semibold" })),
				chip(estado, stateColor(estado)),
			}),
			ui.label(layout.text(layout.ellipsis(tostring(container.image or ""), 42), { fontSize = 11, color = theme.dim() })),
		}),
		ui.column({ width = 160, gap = 2, align = "start" }, {
			ui.label({ text = T("desktop.ports") .. ": " .. (#puertos > 0 and table.concat(puertos, " ") or "-"), fontSize = 11, color = theme.muted() }),
			ui.label({ text = string.format("cpu %.1f%% · mem %.1f%%", cpu, mem), fontSize = 11, color = theme.dim() }),
		}),
		ui.row({ gap = 2, align = "stretch" }, {
			iconButton(
				if corriendo then "player-stop" else "player-play",
				if corriendo then T("desktop.action.stop") else T("desktop.action.start"),
				true,
				function()
					send({ action = if corriendo then "stop" else "start", id = id })
				end
			),
			iconButton("refresh", T("desktop.action.restart"), true, function()
				send({ action = "restart", id = id })
			end),
			iconButton(
				if pausado then "player-play" else "player-pause",
				if pausado then T("desktop.action.unpause") else T("desktop.action.pause"),
				corriendo or pausado,
				function()
					send({ action = if pausado then "unpause" else "pause", id = id })
				end
			),
			iconButton("file-text", T("desktop.action.logs"), true, function()
				S.target = id
				S.detailTab = "logs"
				S.section = "detail"
				send({ action = "detail", id = id })
				send({ action = "logs", id = id })
				render()
			end),
			iconButton("eye", T("desktop.action.inspect"), true, function()
				S.target = id
				S.detailTab = "summary"
				S.section = "detail"
				send({ action = "detail", id = id })
				render()
			end),
			iconButton("list-tree", T("desktop.action.top"), corriendo, function()
				S.target = id
				S.detailTab = "top"
				S.section = "detail"
				send({ action = "top", id = id })
				render()
			end),
			iconButton("git-diff", T("desktop.action.diff"), corriendo, function()
				S.target = id
				S.detailTab = "diff"
				S.section = "detail"
				send({ action = "diff", id = id })
				render()
			end),
			iconButton("terminal-2", T("desktop.action.exec"), corriendo, function()
				S.execId = id
				S.section = "terminal"
				S.page = 1
				send({ action = "detail", id = id })
				render()
			end),
			iconButton("package", T("desktop.action.commit"), true, function()
				S.target = id
				S.form.commitRepo = ""
				S.form.commitTag = "latest"
				S.form.commitMessage = ""
				S.section = "commit"
				render()
			end),
			iconButton("pencil", T("desktop.action.rename"), true, function()
				S.target = id
				S.form.rename = tostring(container.name or "")
				S.section = "rename"
				render()
			end),
			iconButton("file-download", T("desktop.action.copy"), corriendo, function()
				S.target = id
				S.form.copySource = ""
				S.form.copyTarget = ""
				S.section = "copy"
				render()
			end),
			iconButton("trash", T("desktop.action.remove"), true, function()
				if not confirming then
					S.confirm = "remove:" .. id
					render()
					return
				end
				S.confirm = nil
				send({ action = "remove", id = id })
				render()
			end),
		}),
	})
end

local function containersToolbar(): any
	local botones: { any } = {
		ui.input({
			key = "desk-search",
			value = S.query,
			placeholder = T("desktop.search"),
			controlSize = "sm",
			width = 240,
			onChange = function(texto: any)
				S.query = tostring(texto or "")
				S.page = 1
				render()
			end,
		}),
	}
	local filtros = {
		{ value = "all", key = "desktop.filter.all" },
		{ value = "running", key = "desktop.filter.running" },
		{ value = "stopped", key = "desktop.filter.stopped" },
	}
	for _, filtro in ipairs(filtros) do
		local activo = S.filter == filtro.value
		table.insert(botones, ui.button({
			text = T(filtro.key),
			controlSize = "sm",
			variant = if activo then "secondary" else "ghost",
			selected = activo,
			onClick = function()
				if S.filter == filtro.value then
					return
				end
				S.filter = filtro.value
				S.page = 1
				render()
			end,
		}))
	end
	table.insert(botones, ui.spacer({ flexGrow = 1 }))
	table.insert(botones, ui.button({
		glyph = "plus",
		controlSize = "sm",
		variant = "outline",
		tooltip = T("panel.run"),
		onClick = function()
			S.form.runImage = ""
			S.form.runName = ""
			S.form.runPorts = ""
			S.form.runEnv = ""
			S.section = "run"
			render()
		end,
	}))
	return ui.row({ height = TOOLBAR_H, gap = 8, align = "stretch" }, botones)
end

local function containersView(): any
	local items = filtered("containers")
	local stats = statsByName()
	local perPage = pageSize()
	local pages = math.max(1, math.ceil(#items / perPage))
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#items, first + perPage - 1)
	local filas: { any } = {}
	for indice = first, last do
		table.insert(filas, containerRow(items[indice], indice - first + 1, stats))
	end
	if #items == 0 then
		table.insert(filas, emptyState(T("desktop.empty")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		containersToolbar(),
		ui.scroll(layout.merge({ key = "cont-scroll", align = "stretch", gap = 6 }, layout.scrollExtra(listViewport(), true)), filas),
		pageFooter(#items, pages),
	})
end

-- ── imágenes ───────────────────────────────────────────────────────────

local function imageRow(imagen: any, indice: number): any
	local titulo = tostring(imagen.repository or "") .. ":" .. tostring(imagen.tag or "")
	if imagen.dangling == true then
		titulo = T("panel.dangling")
	end
	local id = tostring(imagen.id or "")
	local alpha = if S.anim.t < 1 then anim.stagger(indice, anim.ease_out(S.anim.t), 0.03) else 1
	local confirming = S.confirm == "rmi:" .. id
	return ui.row({
		key = "img-" .. id,
		height = ROW_H,
		gap = 10,
		padding = 8,
		align = "stretch",
		radius = 10,
		fill = theme.raised(),
		opacity = alpha,
	}, {
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label(layout.text(titulo, { fontSize = 14, fontWeight = "semibold" })),
			ui.label(layout.text(id .. " · " .. tostring(imagen.size or ""), { fontSize = 11, color = theme.dim() })),
		}),
		ui.label({ text = tostring(imagen.createdAt or ""), fontSize = 11, color = theme.dim() }),
		ui.row({ gap = 2, align = "stretch" }, {
			iconButton("player-play", T("desktop.action.run"), true, function()
				S.form.runImage = titulo
				S.form.runName = ""
				S.form.runPorts = ""
				S.form.runEnv = ""
				S.section = "run"
				render()
			end),
			iconButton("label", T("desktop.action.tag"), true, function()
				S.target = id
				S.form.tagRepo = tostring(imagen.repository or "")
				S.form.tagTag = "latest"
				S.section = "tag"
				render()
			end),
			iconButton("download", T("desktop.action.pull"), true, function()
				send({ action = "registry", verb = "pull", image = titulo })
				render()
			end),
			iconButton("upload", T("desktop.action.push"), true, function()
				send({ action = "registry", verb = "push", image = titulo })
				render()
			end),
			iconButton("history", T("desktop.action.history"), true, function()
				S.target = id
				send({ action = "history", id = id })
				render()
			end),
			iconButton("trash", T("desktop.action.remove"), true, function()
				if not confirming then
					S.confirm = "rmi:" .. id
					render()
					return
				end
				S.confirm = nil
				send({ action = "rmi", id = id })
				render()
			end),
		}),
	})
end

local function imagesView(): any
	local items = filtered("images")
	local perPage = pageSize()
	local pages = math.max(1, math.ceil(#items / perPage))
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#items, first + perPage - 1)
	local filas: { any } = {}
	for indice = first, last do
		table.insert(filas, imageRow(items[indice], indice - first + 1))
	end
	if #items == 0 then
		table.insert(filas, emptyState(T("desktop.empty")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.row({ height = TOOLBAR_H, gap = 8, align = "stretch" }, {
			ui.input({
				key = "desk-search-img",
				value = S.query,
				placeholder = T("desktop.search"),
				controlSize = "sm",
				width = 240,
				onChange = function(texto: any)
					S.query = tostring(texto or "")
					S.page = 1
					render()
				end,
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.button({
				glyph = "cloud-search",
				controlSize = "sm",
				variant = "outline",
				tooltip = T("desktop.hub_title"),
				onClick = function()
					S.section = "hub"
					render()
				end,
			}),
			ui.button({
				glyph = "hammer",
				controlSize = "sm",
				variant = "outline",
				tooltip = T("desktop.action.build"),
				onClick = function()
					S.section = "build"
					render()
				end,
			}),
		}),
		ui.scroll(layout.merge({ key = "img-scroll", align = "stretch", gap = 6 }, layout.scrollExtra(listViewport(), true)), filas),
		pageFooter(#items, pages),
	})
end

-- ── volúmenes y redes ──────────────────────────────────────────────────

local function resourceRow(tab: string, titulo: string, detalle: string, id: string, indice: number): any
	local alpha = if S.anim.t < 1 then anim.stagger(indice, anim.ease_out(S.anim.t), 0.03) else 1
	local accion = if tab == "volumes" then "volume-rm" else "network-rm"
	local confirming = S.confirm == accion .. ":" .. id

	-- Los hijos se arman en una tabla y se agregan con `table.insert`: un
	-- `if ... else nil end` adentro de un literal de tabla no es válido en
	-- Luau (rompe el conteo de posicionales).
	local hijos: { any } = {
		ui.label(layout.text(titulo, { fontSize = 13, fontWeight = "semibold", flexGrow = 1 })),
		ui.label(layout.text(detalle, { fontSize = 11, color = theme.dim() })),
	}
	-- Detalle: `docker volume inspect` / `network inspect`. El resultado se
	-- publica en su propia clave y se muestra en una vista aparte.
	table.insert(hijos, iconButton("eye", T("desktop.action.inspect"), true, function()
		S.inspectKind = tab
		S.inspectName = id
		S.section = "inspect"
		send({ action = if tab == "volumes" then "volume_inspect" else "network_inspect", name = id })
		render()
	end))
	-- Respaldo: sólo los volúmenes tienen datos que valga la pena guardar.
	if tab == "volumes" then
		table.insert(hijos, iconButton("download", T("desktop.action.backup"), true, function()
			S.section = "volbackup"
			S.form.volBackupName = id
			S.form.volBackupPath = "~/Documents/backups/" .. id .. ".tar.gz"
			render()
		end))
	end
	table.insert(hijos, ui.button({
		text = if confirming then T("panel.confirm") else "",
		glyph = if confirming then nil else "trash",
		controlSize = "sm",
		variant = if confirming then "destructive" else "ghost",
		onClick = function()
			if not confirming then
				S.confirm = accion .. ":" .. id
				render()
				return
			end
			S.confirm = nil
			send({ action = accion, id = id })
			render()
		end,
	}))
	return ui.row({
		key = tab .. "-" .. id,
		height = 52,
		gap = 10,
		padding = 8,
		align = "stretch",
		radius = 10,
		fill = theme.raised(),
		opacity = alpha,
	}, hijos)
end

local function resourcesView(tab: string): any
	local items = filtered(tab)
	local filas: { any } = {}
	for indice, item in ipairs(items) do
		if tab == "volumes" then
			table.insert(filas, resourceRow(tab, tostring(item.name or ""), tostring(item.driver or "") .. " · " .. tostring(item.mountpoint or ""), tostring(item.name or ""), indice))
		else
			table.insert(filas, resourceRow(tab, tostring(item.name or ""), tostring(item.driver or "") .. " · " .. tostring(item.scope or ""), tostring(item.name or ""), indice))
		end
	end
	if #items == 0 then
		table.insert(filas, emptyState(T("desktop.empty")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.scroll(layout.merge({ key = tab .. "-scroll", align = "stretch", gap = 6 }, layout.scrollExtra(fullViewport(), true)), filas),
	})
end

-- ── compose ────────────────────────────────────────────────────────────

local function projectRow(project: any, indice: number): any
	local nombre = tostring(project.name or "")
	local estado = tostring(project.state or "stopped")
	local color = if estado == "running" then theme.ok() elseif estado == "partial" then theme.warn() else theme.dim()
	local servicios: { string } = {}
	for _, servicio in ipairs(type(project.services) == "table" and project.services or {}) do
		table.insert(servicios, tostring(servicio))
	end
	local alpha = if S.anim.t < 1 then anim.stagger(indice, anim.ease_out(S.anim.t), 0.03) else 1
	local hijos: { any } = {
		ui.row({ gap = 10, align = "stretch" }, {
			ui.label(layout.text(nombre, { fontSize = 14, fontWeight = "semibold" })),
			chip(estado, color),
			ui.label({
				text = tostring(tonumber(project.running) or 0) .. "/" .. tostring(tonumber(project.containers) or 0) .. " " .. T("panel.detail.running"),
				fontSize = 11,
				color = theme.muted(),
			}),
			ui.spacer({ flexGrow = 1 }),
			iconButton("player-play", T("desktop.action.up"), (tonumber(project.running) or 0) < (tonumber(project.containers) or 0), function()
				send({ action = "compose", project = nombre, verb = "up" })
			end),
			iconButton("player-stop", T("desktop.action.down"), true, function()
				send({ action = "compose", project = nombre, verb = "down" })
			end),
			iconButton("refresh", T("desktop.action.restart"), true, function()
				send({ action = "compose", project = nombre, verb = "restart" })
			end),
			iconButton("cloud-download", T("desktop.action.pull"), true, function()
				send({ action = "compose", project = nombre, verb = "pull" })
			end),
			iconButton("file-code", T("desktop.action.yaml"), true, function()
				S.composeName = nombre
				S.section = "composefile"
				send({ action = "compose_file", name = nombre })
				render()
			end),
		}),
		ui.label(layout.text(table.concat(servicios, ", "), { fontSize = 11, color = theme.dim() })),
	}
	for _, container in ipairs(list("containers")) do
		if tostring(container.project or "") == nombre then
			local cid = tostring(container.id or "")
			local cestado = tostring(container.state or "")
			table.insert(hijos, ui.row({ gap = 8, align = "stretch" }, {
				ui.box({ width = 4, height = 16, radius = 2, fill = stateColor(cestado) }),
				ui.label(layout.text(tostring(container.name or ""), { fontSize = 12, width = 180 })),
				ui.label(layout.text(tostring(container.service or ""), { fontSize = 11, color = theme.muted(), width = 160 })),
				ui.label(layout.text(tostring(container.image or ""), { fontSize = 11, color = theme.dim(), flexGrow = 1 })),
				chip(cestado, stateColor(cestado)),
				iconButton(
					if cestado == "running" then "player-stop" else "player-play",
					if cestado == "running" then T("desktop.action.stop") else T("desktop.action.start"),
					true,
					function()
						send({ action = if cestado == "running" then "stop" else "start", id = cid })
					end
				),
				iconButton("file-text", T("desktop.action.logs"), true, function()
					S.target = cid
					S.detailTab = "logs"
					S.section = "detail"
					send({ action = "detail", id = cid })
					send({ action = "logs", id = cid })
					render()
				end),
			}))
		end
	end
	return ui.column({
		key = "stack-" .. nombre,
		gap = 6,
		padding = 10,
		radius = 10,
		fill = theme.raised(),
		opacity = alpha,
		align = "stretch",
	}, hijos)
end

-- Crear un volumen o una red nueva. El formulario va inline (y no con
-- `formView`) porque `formView` se declara más abajo en el archivo y Luau
-- no resuelve la referencia adelantada.
local function createView(): any
	local clase = tostring(S.form.createKind or "volume")
	local nombre = tostring(S.form.createName or "")
	return ui.column({ gap = 10, padding = 12, align = "stretch" }, {
		ui.row({ gap = 10, align = "center" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.section = if clase == "volume" then "volumes" else "networks"
					render()
				end,
			}),
			ui.label({
				text = T("desktop.create.title") .. " · " .. T("desktop.section." .. clase),
				fontSize = 16,
				fontWeight = "semibold",
			}),
		}),
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.create.name"), 170, { fontSize = 12, color = theme.muted() }),
			ui.input({
				key = "form-createName",
				value = nombre,
				placeholder = if clase == "volume" then "datos" else "bridge",
				controlSize = "sm",
				width = 320,
				onChange = function(texto: any)
					S.form.createName = tostring(texto or "")
				end,
			}),
		}),
		ui.row({ gap = 10, align = "stretch" }, {
			ui.button({
				text = T("desktop.form_send"),
				controlSize = "sm",
				variant = "primary",
				onClick = function()
					if nombre == "" then
						return
					end
					send({ action = "create", kind = clase, name = nombre })
					S.section = if clase == "volume" then "volumes" else "networks"
					S.form.createName = ""
					render()
				end,
			}),
		}),
	})
end

local function composeView(): any
	local proyectos = list("projects")
	local filas: { any } = {}
	for indice, project in ipairs(proyectos) do
		table.insert(filas, projectRow(project, indice))
	end
	if #proyectos == 0 then
		table.insert(filas, emptyState(T("desktop.no_stacks")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.scroll(layout.merge({ key = "compose-scroll", align = "stretch", gap = 8 }, layout.scrollExtra(fullViewport(), true)), filas),
	})
end

-- ── el YAML del stack ──────────────────────────────────────────────────

-- `docker compose` no tiene un verbo que imprima el archivo, así que el CLI
-- (`b3l0w-docker compose-file`) resuelve la ruta con `compose ls` y lo lee.
local function composefileView(): any
	local datos = state.table(COMPOSEFILE_KEY)
	local nombre = tostring(S.composeName or datos.name or "")
	local texto = tostring(datos.text or "")
	local filas: { any } = {}
	if texto == "" then
		table.insert(filas, emptyState(if datos.error then tostring(datos.error) else T("desktop.compose_loading")))
	else
		for linea in string.gmatch(texto, "[^\n]+") do
			-- El comentario con la ruta que agrega el CLI va destacado.
			local esRuta = linea:sub(1, 2) == "# "
			table.insert(filas, ui.label({
				text = layout.ellipsis(linea, 130),
				fontSize = 11,
				fontFamily = "mono",
				color = if esRuta then theme.dim() else theme.text(),
			}))
		end
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.row({ gap = 10, align = "center" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.section = "compose"
					render()
				end,
			}),
			ui.label({ text = T("desktop.compose_title") .. " · " .. nombre, fontSize = 16, fontWeight = "semibold" }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({ text = tostring(#texto) .. " " .. T("desktop.chars"), fontSize = 10, color = theme.dim() }),
		}),
		ui.scroll(layout.merge({ key = "composefile-scroll", align = "stretch", gap = 1 }, layout.scrollExtra(fullViewport(), true)), filas),
	})
end

-- ── terminal ───────────────────────────────────────────────────────────

-- La terminal ejecuta el comando del campo: la declara antes de la vista
-- (un `local function` usado antes de declararse es un global nil).
local function ejecutarExec(): ()
	if S.execId == "" or S.execCommand == "" then
		return
	end
	table.insert(S.execHistory, S.execCommand)
	if #S.execHistory > 8 then
		table.remove(S.execHistory, 1)
	end
	send({ action = "exec", id = S.execId, command = S.execCommand })
	render()
end

local function terminalView(): any
	local exec = state.table(EXEC_KEY)
	local contenedores = runningContainers()
	local opciones: { string } = {}
	local indice = 0
	for i, container in ipairs(contenedores) do
		table.insert(opciones, tostring(container.name or ""))
		if tostring(container.id or "") == S.execId then
			indice = i - 1
		end
	end

	local salida = ""
	-- El exec puede venir con el id o con el nombre del contenedor (docker
	-- acepta las dos formas): se comparan los dos.
	local elegido = findContainer(S.execId)
	local nombreElegido = tostring(elegido and elegido.name or "")
	if S.execId ~= "" then
		local idExec = tostring(exec.id or "")
		if idExec == S.execId or (nombreElegido ~= "" and idExec == nombreElegido) then
			salida = tostring(exec.output or "")
		end
	end

	local rapidos: { any } = {}
	for _, comando in ipairs({ "ls -la", "ps aux", "cat /etc/os-release", "env" }) do
		table.insert(rapidos, ui.button({
			text = comando,
			controlSize = "sm",
			variant = "ghost",
			onClick = function()
				S.execCommand = comando
				render()
			end,
		}))
	end

	return ui.column({ gap = 10, padding = 12, align = "stretch" }, {
		ui.row({ gap = 10, align = "stretch" }, {
			ui.label({ text = T("desktop.terminal_container"), fontSize = 12, color = theme.muted() }),
			ui.select({
				key = "exec-select",
				options = opciones,
				selectedIndex = indice,
				controlSize = "sm",
				width = 220,
				onChange = function(nuevo: any)
					local i = (tonumber(nuevo) or 0) + 1
					local container = contenedores[i]
					if container ~= nil then
						S.execId = tostring(container.id or "")
					end
					render()
				end,
			}),
			ui.input({
				key = "exec-cmd",
				value = S.execCommand,
				placeholder = T("desktop.terminal_command"),
				controlSize = "sm",
				flexGrow = 1,
				onChange = function(texto: any)
					S.execCommand = tostring(texto or "")
				end,
				onSubmit = function(texto: any)
					S.execCommand = tostring(texto or "")
					ejecutarExec()
				end,
			}),
			ui.button({
				text = T("desktop.terminal_run"),
				controlSize = "sm",
				variant = "primary",
				enabled = S.execId ~= "" and S.execCommand ~= "",
				onClick = function()
					ejecutarExec()
				end,
			}),
			ui.button({
				glyph = "terminal",
				controlSize = "sm",
				variant = "outline",
				tooltip = T("desktop.terminal_open"),
				enabled = S.execId ~= "",
				onClick = function()
					local container = findContainer(S.execId)
					noctalia.runInTerminal("docker exec -it " .. tostring(container and container.name or S.execId) .. " sh")
				end,
			}),
		}),
		ui.row({ gap = 6, align = "stretch" }, {
			ui.label({ text = T("desktop.terminal_quick"), fontSize = 11, color = theme.dim() }),
			ui.spacer({ flexGrow = 1 }),
		}),
		ui.row({ gap = 6, align = "stretch" }, rapidos),
		ui.scroll(layout.merge({ key = "exec-out", align = "stretch", padding = 8, fill = theme.surface() }, layout.scrollExtra(listViewport() - 190, true)), {
			ui.label({
				text = if salida == "" then T("desktop.terminal_empty") else salida,
				fontSize = 12,
				color = if salida == "" then theme.dim() else theme.text(),
			}),
		}),
	})
end

-- ── build ──────────────────────────────────────────────────────────────

local function buildView(): any
	return ui.column({ gap = 10, padding = 12, align = "stretch" }, {
		sectionTitle(T("desktop.build_title")),
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.build_tag"), 150, { fontSize = 12, color = theme.muted() }),
			ui.input({
				key = "build-tag",
				value = S.form.buildTag,
				placeholder = "mi-imagen:latest",
				controlSize = "sm",
				width = 280,
				onChange = function(texto: any)
					S.form.buildTag = tostring(texto or "")
				end,
			}),
		}),
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.build_context"), 150, { fontSize = 12, color = theme.muted() }),
			ui.input({
				key = "build-context",
				value = S.form.buildContext,
				placeholder = ".",
				controlSize = "sm",
				width = 280,
				onChange = function(texto: any)
					S.form.buildContext = tostring(texto or "")
				end,
			}),
		}),
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.build_dockerfile"), 150, { fontSize = 12, color = theme.muted() }),
			ui.input({
				key = "build-dockerfile",
				value = S.form.buildDockerfile,
				placeholder = "Dockerfile",
				controlSize = "sm",
				width = 280,
				onChange = function(texto: any)
					S.form.buildDockerfile = tostring(texto or "")
				end,
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.button({
				text = T("desktop.build_run"),
				controlSize = "sm",
				variant = "primary",
				enabled = S.form.buildTag ~= "",
				onClick = function()
					send({
						action = "build",
						tag = S.form.buildTag,
						context = S.form.buildContext,
						dockerfile = S.form.buildDockerfile,
					})
					render()
				end,
			}),
		}),
		ui.label({ text = T("desktop.build_hint"), fontSize = 11, color = theme.dim() }),
	})
end

-- ── disco ──────────────────────────────────────────────────────────────

local function diskView(): any
	local filas: { any } = {}
	for _, fila in ipairs(diskRows()) do
		table.insert(filas, ui.row({ gap = 12, align = "stretch", padding = 8, radius = 10, fill = theme.surface() }, {
			celda(tostring(fila.type or ""), 150, { fontSize = 13, fontWeight = "semibold" }),
			celda(tostring(fila.total or 0) .. " (" .. tostring(fila.active or 0) .. ")", 120, { fontSize = 11, color = theme.muted() }),
			ui.label({ text = tostring(fila.size or ""), fontSize = 12, color = theme.text(), flexGrow = 1 }),
			celda(T("desktop.disk_reclaimable") .. " " .. tostring(fila.reclaimable or "0B"), 190, { fontSize = 11, color = theme.warn() }),
		}))
	end
	if #filas == 0 then
		table.insert(filas, emptyState(T("desktop.empty")))
	end

	local targets: { any } = {}
	local destinos = { "containers", "images", "volumes", "builder", "system" }
	for _, destino in ipairs(destinos) do
		local confirmando = S.confirm == "prune:" .. destino
		table.insert(targets, ui.button({
			text = if confirmando then T("panel.confirm") else T("desktop.prune_" .. destino),
			controlSize = "sm",
			variant = if confirmando then "destructive" else "outline",
			onClick = function()
				if not confirmando then
					S.confirm = "prune:" .. destino
					render()
					return
				end
				S.confirm = nil
				send({ action = "prune", what = destino })
				render()
			end,
		}))
	end

	return ui.column({ gap = 10, padding = 12, align = "stretch", flexGrow = 1 }, {
		sectionTitle(T("desktop.disk_title")),
		ui.scroll(layout.merge({ key = "disk-scroll", align = "stretch", gap = 6 }, layout.scrollExtra(listViewport() - 110, true)), filas),
		ui.row({ gap = 8, align = "stretch" }, targets),
	})
end

-- ── eventos ────────────────────────────────────────────────────────────

-- Los paneles de Noctalia NO scrollean con la rueda de forma confiable
-- (el árbol crece y el host recorta, ignorando el `height` del scroll), así
-- que las listas largas se paginan: es la única forma de llegar al final.
local function eventsView(): any
	local eventos = eventRows()
	-- Una fila de evento mide ~24 px; con el alto de contenedor sólo
	-- entraban 10 y quedaba media pantalla sin usar.
	local perPage = pageSizeFor(24)
	local pages = math.max(1, math.ceil(#eventos / perPage))
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#eventos, first + perPage - 1)
	local filas: { any } = {}
	for indice = first, last do
		table.insert(filas, eventRow(eventos[indice]))
	end
	if #filas == 0 then
		table.insert(filas, emptyState(T("desktop.no_events")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.scroll(layout.merge({ key = "events-scroll", align = "stretch", gap = 2 }, layout.scrollExtra(fullViewport(), true)), filas),
		pageFooter(#eventos, pages),
	})
end

-- ── detalle (inspect) ──────────────────────────────────────────────────

local DETAIL_TABS = { "summary", "ports", "mounts", "env", "logs", "top", "diff" }

local function detailView(): any
	local id = S.target or ""
	local container = findContainer(id)
	local datos = state.table(DETAIL_KEY)
	local info = type(datos.inspect) == "table" and datos.inspect or {}
	local nombre = tostring((container and container.name) or info.name or id)
	local mapa = type(datos.stats) == "table" and datos.stats or {}
	local stats = mapa[id] or mapa[nombre]
	local tabs: { any } = {}
	for _, tab in ipairs(DETAIL_TABS) do
		local activa = S.detailTab == tab
		table.insert(tabs, ui.button({
			text = T("desktop.detail." .. tab),
			controlSize = "sm",
			variant = if activa then "secondary" else "ghost",
			selected = activa,
			onClick = function()
				S.detailTab = tab
				render()
			end,
		}))
	end

	local cuerpo: { any } = {}
	if S.detailTab == "summary" then
		table.insert(cuerpo, ui.label({ text = tostring(info.image or (container and container.image) or ""), fontSize = 12, color = theme.muted() }))
		table.insert(cuerpo, ui.label({ text = T("panel.detail.started") .. ": " .. tostring(info.startedAt or "-"), fontSize = 11, color = theme.dim() }))
		table.insert(cuerpo, ui.label({ text = T("panel.detail.restarts") .. ": " .. tostring(info.restartCount or 0) .. " · " .. T("panel.detail.policy") .. ": " .. tostring(info.restartPolicy or "-"), fontSize = 11, color = theme.dim() }))
		if type(info.networks) == "table" and #info.networks > 0 then
			table.insert(cuerpo, ui.label({ text = T("panel.detail.networks") .. ": " .. table.concat(info.networks, ", "), fontSize = 11, color = theme.info() }))
		end
		if stats ~= nil then
			table.insert(cuerpo, usageBar(T("panel.detail.cpu"), tonumber(stats.cpuPct) or 0, string.format("%.1f%%", tonumber(stats.cpuPct) or 0), theme.info()))
			table.insert(cuerpo, usageBar(T("panel.detail.memory"), tonumber(stats.memPct) or 0, tostring(stats.memUsage or ""), theme.warn()))
			table.insert(cuerpo, ui.label({ text = "net " .. tostring(stats.netIo or "-") .. " · io " .. tostring(stats.blockIo or "-") .. " · pids " .. tostring(stats.pids or 0), fontSize = 11, color = theme.dim() }))
		else
			table.insert(cuerpo, ui.label({ text = T("panel.detail.no_stats"), fontSize = 11, color = theme.dim() }))
		end
		-- Límites de CPU y memoria: `docker update` los aplica en caliente,
		-- sin recrear el contenedor.
		table.insert(cuerpo, ui.spacer({ flexGrow = 0, height = 6 }))
		table.insert(cuerpo, ui.label({ text = T("desktop.limits_title"), fontSize = 13, fontWeight = "semibold" }))
		table.insert(cuerpo, ui.row({ gap = 8, align = "stretch" }, {
			celda(T("desktop.limits_cpus"), 90, { fontSize = 11, color = theme.muted() }),
			ui.input({
				key = "form-limitCpus",
				value = tostring(S.form.limitCpus or ""),
				placeholder = "0.5",
				controlSize = "sm",
				width = 90,
				onChange = function(texto: any)
					S.form.limitCpus = tostring(texto or "")
				end,
			}),
			celda(T("desktop.limits_memory"), 80, { fontSize = 11, color = theme.muted() }),
			ui.input({
				key = "form-limitMemory",
				value = tostring(S.form.limitMemory or ""),
				placeholder = "512m",
				controlSize = "sm",
				width = 90,
				onChange = function(texto: any)
					S.form.limitMemory = tostring(texto or "")
				end,
			}),
			ui.button({
				text = T("desktop.limits_apply"),
				controlSize = "sm",
				variant = "primary",
				enabled = (tostring(S.form.limitCpus or "") ~= "" or tostring(S.form.limitMemory or "") ~= ""),
				onClick = function()
					if tostring(S.form.limitCpus or "") == "" and tostring(S.form.limitMemory or "") == "" then
						return
					end
					send({
						action = "update_limits",
						id = id,
						cpus = S.form.limitCpus or "",
						memory = S.form.limitMemory or "",
					})
				end,
			}),
		}))
	elseif S.detailTab == "ports" then
		-- Cada puerto publicado se abre en el navegador con un clic: es lo
		-- que hace Docker Desktop y ahorra copiar el puerto a mano.
		for _, puerto in ipairs((container and container.ports) or {}) do
			local hostPort = tostring(puerto.hostPort or 0)
			-- El CLI ya calcula la URL; si no viene, se arma con el puerto.
			local url = tostring(puerto.url or ("http://localhost:" .. hostPort))
			table.insert(cuerpo, ui.row({ gap = 8, align = "stretch" }, {
				ui.label({
					text = tostring(puerto.hostIp or "") .. ":" .. hostPort .. " → " .. tostring(puerto.containerPort or "") .. "/" .. tostring(puerto.protocol or "tcp"),
					fontSize = 12,
					color = theme.info(),
					flexGrow = 1,
				}),
				iconButton("external-link", T("desktop.open_port"), true, function()
					noctalia.runAsync({ "xdg-open", url })
				end),
			}))
		end
		if #cuerpo == 0 then
			table.insert(cuerpo, ui.label({ text = T("panel.no_ports"), fontSize = 12, color = theme.dim() }))
		end
	elseif S.detailTab == "mounts" then
		for _, mount in ipairs(type(info.mounts) == "table" and info.mounts or {}) do
			table.insert(cuerpo, ui.label({ text = tostring(mount.destination or "") .. "  ←  " .. tostring(mount.source or ""), fontSize = 12, color = theme.text() }))
		end
		if #cuerpo == 0 then
			table.insert(cuerpo, ui.label({ text = T("panel.detail.no_mounts"), fontSize = 12, color = theme.dim() }))
		end
	elseif S.detailTab == "env" then
		for _, variable in ipairs(type(info.env) == "table" and info.env or {}) do
			table.insert(cuerpo, ui.label({ text = tostring(variable), fontSize = 11, color = theme.text() }))
		end
		if #cuerpo == 0 then
			table.insert(cuerpo, ui.label({ text = T("panel.detail.no_env"), fontSize = 12, color = theme.dim() }))
		end
	elseif S.detailTab == "top" then
		-- Los procesos que corren dentro del contenedor (docker top).
		local top = state.table(TOP_KEY)
		local filas = type(top.rows) == "table" and top.rows or {}
		if #filas == 0 then
			table.insert(cuerpo, emptyState(T("desktop.detail.no_top")))
		else
			for _, fila in ipairs(filas) do
				local texto = tostring(fila)
				table.insert(cuerpo, ui.label({ text = layout.ellipsis(texto, 90), fontSize = 11, color = theme.muted() }))
			end
		end
	elseif S.detailTab == "diff" then
		-- Los cambios del sistema de archivos del contenedor (docker diff).
		local diff = state.table(DIFF_KEY)
		local filas = type(diff.rows) == "table" and diff.rows or {}
		if #filas == 0 then
			table.insert(cuerpo, emptyState(T("desktop.detail.no_diff")))
		else
			for _, fila in ipairs(filas) do
				local texto = tostring(fila)
				local color = if texto:sub(1, 2) == "A " then theme.ok()
					elseif texto:sub(1, 2) == "D " then theme.danger()
					else theme.warn()
				table.insert(cuerpo, ui.label({ text = layout.ellipsis(texto, 90), fontSize = 11, color = color }))
			end
		end
	else
		-- Logs. Dos fuentes: el snapshot (`--tail 80`, una pasada) y el
		-- seguimiento en vivo. Noctalia no tiene timers, así que el "en vivo"
		-- lo mantiene un proceso externo (`b3l0w-docker logs-stream`) que
		-- escribe a un archivo; acá se lee con `readFile` al refrescar.
		local stream = state.table(LOGSTREAM_KEY)
		local activo = tostring(stream.id or "") == id and stream.active == true
		local vivo = ""
		if activo and tostring(stream.path or "") ~= "" then
			local ok, datos = pcall(noctalia.readFile, tostring(stream.path))
			if ok and type(datos) == "string" then
				vivo = datos
			end
		end
		local logs = state.table(LOGS_KEY)
		local texto = if #vivo > 0 then vivo
			elseif tostring(logs.id or "") == id then tostring(logs.text or "")
			else T("panel.logs_loading")
		-- Sólo las últimas 200 líneas: el archivo del seguimiento crece sin
		-- tope y publicarlo entero quemaría el render.
		-- El contenedor emite logs con colores ANSI: sin limpiarlos se lee
		-- `[0m[90mTRC[0m` en vez del nivel. Se quitan los escapes CSI.
		texto = texto:gsub("\27%[[%d;]*m", "")
		texto = texto:gsub("\27%[[%d;]*[A-Za-z]", "")
		local lineas: { string } = {}
		for linea in string.gmatch(texto, "[^\n]+") do
			table.insert(lineas, linea)
		end
		local desde = math.max(1, #lineas - 199)
		local visibles: { any } = {}
		for indice = desde, #lineas do
			table.insert(visibles, ui.label({
				text = layout.ellipsis(tostring(lineas[indice]), 120),
				fontSize = 10,
				color = theme.muted(),
				fontFamily = "mono",
			}))
		end
		if #visibles == 0 then
			table.insert(visibles, emptyState(T("desktop.detail.no_logs")))
		end
		table.insert(cuerpo, ui.row({ gap = 6, align = "center" }, {
			ui.button({
				text = if activo then T("desktop.logs_stop") else T("desktop.logs_follow"),
				glyph = if activo then "player-stop" else "player-play",
				controlSize = "sm",
				variant = if activo then "destructive" else "outline",
				onClick = function()
					if activo then
						send({ action = "logs_stop", id = id })
					else
						send({ action = "logs_stream", id = id })
					end
				end,
			}),
			ui.button({
				text = T("desktop.logs_refresh"),
				glyph = "refresh",
				controlSize = "sm",
				variant = "ghost",
				onClick = function() render() end,
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = if activo then T("desktop.logs_live_on") else T("desktop.logs_live_off"),
				fontSize = 10,
				color = if activo then theme.ok() else theme.dim(),
			}),
			ui.label({ text = tostring(#lineas) .. " " .. T("desktop.logs_lines"), fontSize = 10, color = theme.dim() }),
		}))
		table.insert(cuerpo, ui.scroll({ key = "logs-scroll", align = "stretch", gap = 1, flexGrow = 1 }, visibles))
	end

	-- `flexGrow = 1`: el scroll del cuerpo crece con `flexGrow` y necesita un
	-- padre con alto; sin esto el contenido se cortaba en "Memory".
	return ui.column({ gap = 10, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.row({ gap = 10, align = "stretch" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("desktop.detail.back"),
				onClick = function()
					S.target = nil
					S.section = "containers"
					render()
				end,
			}),
			ui.label({ text = nombre, fontSize = 16, fontWeight = "semibold" }),
			chip(tostring(info.state or (container and container.state) or ""), stateColor(tostring(info.state or ""))),
			ui.spacer({ flexGrow = 1 }),
		}),
		-- `height` + `align = "center"`: con `stretch` el botón seleccionado
		-- se estiraba al alto del row y la pestaña "Summary" salía como un
		-- bloque enorme.
		ui.row({ gap = 6, align = "center", height = 34 }, tabs),
		ui.scroll(layout.merge({ key = "detail-scroll", align = "stretch", gap = 4 }, layout.scrollExtra(listViewport() - 100, true)), cuerpo),
	})
end

-- ── formularios ────────────────────────────────────────────────────────

-- Los campos escriben en `S.form[clave]`: el valor vive en el estado del
-- panel, no en la tabla de campos (que se reconstruye en cada render).
local function formView(titulo: string, campos: { any }, alEnviar: () -> ()): any
	local hijos: { any } = {
		ui.row({ gap = 10, align = "stretch" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.section = "containers"
					S.target = nil
					render()
				end,
			}),
			ui.label({ text = titulo, fontSize = 16, fontWeight = "semibold" }),
		}),
	}
	for _, campo in ipairs(campos) do
		local clave = tostring(campo.clave)
		table.insert(hijos, ui.row({ gap = 10, align = "stretch" }, {
			celda(campo.etiqueta, 170, { fontSize = 12, color = theme.muted() }),
			ui.input({
				key = "form-" .. clave,
				value = S.form[clave] or "",
				placeholder = campo.placeholder or "",
				controlSize = "sm",
				width = 320,
				onChange = function(texto: any)
					S.form[clave] = tostring(texto or "")
				end,
			}),
		}))
	end
	table.insert(hijos, ui.row({ gap = 10, align = "stretch" }, {
		ui.button({
			text = T("desktop.form_send"),
			controlSize = "sm",
			variant = "primary",
			onClick = function()
				alEnviar()
				render()
			end,
		}),
	}))
	return ui.column({ gap = 10, padding = 12, align = "stretch" }, hijos)
end

local function renameView(): any
	local id = S.target or ""
	return formView(T("desktop.rename_title"), {
		{ etiqueta = T("desktop.rename_name"), clave = "rename", placeholder = "mi-contenedor" },
	}, function()
		send({ action = "rename", id = id, name = S.form.rename })
		S.section = "containers"
		S.target = nil
	end)
end

local function commitView(): any
	local id = S.target or ""
	return formView(T("desktop.commit_title"), {
		{ etiqueta = T("desktop.commit_repo"), clave = "commitRepo", placeholder = "mi-imagen" },
		{ etiqueta = T("desktop.commit_tag"), clave = "commitTag", placeholder = "latest" },
		{ etiqueta = T("desktop.commit_message"), clave = "commitMessage", placeholder = "..." },
	}, function()
		send({
			action = "commit",
			id = id,
			repo = S.form.commitRepo,
			tag = S.form.commitTag,
			message = S.form.commitMessage,
		})
		S.section = "containers"
		S.target = nil
	end)
end

local function copyView(): any
	local id = S.target or ""
	return formView(T("desktop.copy_title"), {
		{ etiqueta = T("desktop.copy_source"), clave = "copySource", placeholder = "/app/log.txt" },
		{ etiqueta = T("desktop.copy_target"), clave = "copyTarget", placeholder = "~/log.txt" },
	}, function()
		send({ action = "cp", id = id, source = S.form.copySource, target = S.form.copyTarget })
		S.section = "containers"
		S.target = nil
	end)
end

local function tagView(): any
	local id = S.target or ""
	return formView(T("desktop.tag_title"), {
		{ etiqueta = T("desktop.tag_repo"), clave = "tagRepo", placeholder = "mi-imagen" },
		{ etiqueta = T("desktop.tag_tag"), clave = "tagTag", placeholder = "latest" },
	}, function()
		send({ action = "tag", id = id, repo = S.form.tagRepo, tag = S.form.tagTag })
		S.section = "images"
		S.target = nil
	end)
end

local function runView(): any
	return formView(T("panel.run_title"), {
		{ etiqueta = T("panel.form.image"), clave = "runImage", placeholder = "nginx:latest" },
		{ etiqueta = T("panel.form.name"), clave = "runName", placeholder = "mi-nginx" },
		{ etiqueta = T("panel.form.ports"), clave = "runPorts", placeholder = "8080:80" },
		{ etiqueta = T("panel.form.env"), clave = "runEnv", placeholder = "KEY=valor" },
	}, function()
		local puertos: { string } = {}
		for puerto in string.gmatch(S.form.runPorts or "", "[^,\n]+") do
			local limpio = string.gsub(puerto, "%s", "")
			if limpio ~= "" then
				table.insert(puertos, limpio)
			end
		end
		local env: { string } = {}
		if S.form.runEnv ~= nil and S.form.runEnv ~= "" then
			table.insert(env, S.form.runEnv)
		end
		send({
			action = "run",
			image = S.form.runImage,
			name = S.form.runName,
			ports = puertos,
			env = env,
		})
		S.section = "containers"
	end)
end

-- ── render ─────────────────────────────────────────────────────────────

-- ── respaldo de volumen y detalle de recurso ───────────────────────────

-- Respaldo de un volumen: el nombre viene de la fila y la ruta la elige el
-- usuario (por defecto ~/Documents/backups/<volumen>.tar.gz).
local function volBackupView(): any
	local nombre = tostring(S.form.volBackupName or "")
	local ruta = tostring(S.form.volBackupPath or "")
	local puede = nombre ~= "" and ruta ~= ""
	return ui.column({ gap = 10, padding = 12, align = "stretch" }, {
		ui.row({ gap = 10, align = "stretch" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.section = "volumes"
					render()
				end,
			}),
			ui.label({ text = T("desktop.backup_title"), fontSize = 16, fontWeight = "semibold" }),
		}),
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.backup_volume"), 170, { fontSize = 12, color = theme.muted() }),
			ui.label({ text = nombre, fontSize = 13 }),
		}),
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.backup_path"), 170, { fontSize = 12, color = theme.muted() }),
			ui.input({
				key = "form-volBackupPath",
				value = ruta,
				placeholder = "~/Documents/backups/volumen.tar.gz",
				controlSize = "sm",
				width = 480,
				onChange = function(texto: any)
					S.form.volBackupPath = tostring(texto or "")
				end,
			}),
		}),
		ui.row({ gap = 8, align = "stretch" }, {
			ui.button({
				text = T("desktop.backup_run"),
				controlSize = "sm",
				variant = "primary",
				enabled = puede,
				onClick = function()
					if not puede then
						return
					end
					send({ action = "volume_export", name = nombre, out = S.form.volBackupPath })
					S.section = "volumes"
					render()
				end,
			}),
			ui.label({ text = T("desktop.backup_hint"), fontSize = 11, color = theme.dim() }),
		}),
		-- Restaurar: el camino inverso. Crea el volumen si no existe y
		-- descomprime el tar.gz adentro.
		ui.row({ gap = 10, align = "stretch" }, {
			celda(T("desktop.restore_title"), 170, { fontSize = 12, color = theme.warn() }),
			ui.input({
				key = "form-volRestorePath",
				value = tostring(S.form.volRestorePath or ""),
				placeholder = "~/Documents/backups/volumen.tar.gz",
				controlSize = "sm",
				width = 480,
				onChange = function(texto: any)
					S.form.volRestorePath = tostring(texto or "")
				end,
			}),
		}),
		ui.row({ gap = 8, align = "stretch" }, {
			ui.button({
				text = T("desktop.restore_run"),
				controlSize = "sm",
				variant = "outline",
				enabled = nombre ~= "" and tostring(S.form.volRestorePath or "") ~= "",
				onClick = function()
					if nombre == "" or tostring(S.form.volRestorePath or "") == "" then
						return
					end
					send({ action = "volume_import", name = nombre, inPath = S.form.volRestorePath })
					S.section = "volumes"
					render()
				end,
			}),
			ui.label({ text = T("desktop.restore_hint"), fontSize = 11, color = theme.dim() }),
		}),
	})
end

-- ── búsqueda en Docker Hub ──────────────────────────────────────────────

-- Los resultados de `docker search` vienen como tabla de texto alineada
-- (NAME / DESCRIPTION / STARS / OFFICIAL). Se parte por columnas fijas:
-- parsear por espacios rompe con las descripciones.
local function hubRows(): { any }
	local datos = state.table(HUB_KEY)
	local filas: { any } = {}
	for _, item in ipairs(datos.rows or {}) do
		local nombre = tostring(item.name or "")
		if nombre ~= "" then
			local hijos: { any } = {
				ui.column({ gap = 1, flexGrow = 1, align = "stretch" }, {
					ui.label(layout.text(nombre, { fontSize = 13, fontWeight = "semibold" })),
					ui.label(layout.text(tostring(item.description or ""), { fontSize = 11, color = theme.muted() })),
				}),
			}
			if item.official == true then
				table.insert(hijos, chip("official", theme.ok()))
			end
			table.insert(hijos, ui.label({ text = "★ " .. tostring(item.stars or 0), fontSize = 11, color = theme.warn() }))
			table.insert(hijos, iconButton("download", T("desktop.action.pull"), true, function()
				send({ action = "registry", verb = "pull", image = nombre })
			end))
			table.insert(filas, ui.row({
				key = "hub-" .. nombre,
				height = 48,
				gap = 10,
				padding = 8,
				align = "stretch",
				radius = 10,
				fill = theme.raised(),
			}, hijos))
		end
	end
	return filas
end

local function hubView(): any
	local datos = state.table(HUB_KEY)
	local todos = hubRows()
	local perPage = pageSizeFor(50)
	local pages = math.max(1, math.ceil(#todos / perPage))
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#todos, first + perPage - 1)
	local filas: { any } = {}
	for indice = first, last do
		table.insert(filas, todos[indice])
	end
	if #filas == 0 then
		table.insert(filas, emptyState(T("desktop.hub_empty")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.row({ height = TOOLBAR_H, gap = 8, align = "stretch" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.section = "images"
					render()
				end,
			}),
			ui.label({ text = T("desktop.hub_title"), fontSize = 15, fontWeight = "semibold" }),
			ui.input({
				key = "form-hubQuery",
				value = tostring(S.form.hubQuery or ""),
				placeholder = T("desktop.hub_placeholder"),
				controlSize = "sm",
				width = 300,
				onChange = function(texto: any)
					S.form.hubQuery = tostring(texto or "")
				end,
			}),
			ui.button({
				text = T("desktop.hub_search"),
				controlSize = "sm",
				variant = "primary",
				enabled = tostring(S.form.hubQuery or "") ~= "",
				onClick = function()
					local termino = tostring(S.form.hubQuery or "")
					if termino == "" then
						return
					end
					send({ action = "hub_search", query = termino })
				end,
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = if datos.query ~= nil then T("desktop.hub_for") .. " " .. tostring(datos.query) else "",
				fontSize = 11,
				color = theme.dim(),
			}),
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("desktop.page_prev"),
				enabled = page > 1,
				onClick = function()
					S.page = math.max(1, page - 1)
					render()
				end,
			}),
			ui.button({
				glyph = "arrow-right",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("desktop.page_next"),
				enabled = page < pages,
				onClick = function()
					S.page = math.min(pages, page + 1)
					render()
				end,
			}),
		}),
		ui.scroll(layout.merge({ key = "hub-scroll", align = "stretch", gap = 6 }, layout.scrollExtra(0, true)), filas),
		pageFooter(#todos, pages),
	})
end

-- Detalle de un volumen o una red: las líneas que devuelve docker. El JSON
-- crudo es ilegible en un panel, así que el service publica líneas.
local function inspectView(): any
	local esVolumen = S.inspectKind == "volumes"
	local datos = state.table(if esVolumen then VOLINFO_KEY else NETINFO_KEY)
	local filas: { any } = {}
	-- El service aplana el JSON en pares clave/valor: una línea por dato, con
	-- el valor truncado a una línea. Así entra todo y nada se sale del ancho.
	for _, item in ipairs(datos.rows or {}) do
		local clave = tostring(item.key or "")
		local valor = tostring(item.value or "")
		table.insert(filas, ui.row({ gap = 8, align = "stretch", height = 18 }, {
			celda(clave, 260, { fontSize = 11, color = theme.muted() }),
			ui.label({
				text = layout.ellipsis(valor, 90),
				fontSize = 11,
				color = theme.text(),
				maxLines = 1,
				flexGrow = 1,
				tooltip = valor,
			}),
		}))
	end
	if #filas == 0 then
		table.insert(filas, emptyState(T("desktop.inspect_empty")))
	end
	return ui.column({ gap = 8, padding = 12, align = "stretch", flexGrow = 1 }, {
		ui.row({ gap = 10, align = "stretch" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.section = if esVolumen then "volumes" else "networks"
					render()
				end,
			}),
			ui.label({
				text = T("desktop.inspect_title") .. " · " .. tostring(S.inspectName or ""),
				fontSize = 16,
				fontWeight = "semibold",
			}),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = tostring(#filas) .. " " .. T("desktop.inspect_fields"),
				fontSize = 11,
				color = theme.dim(),
			}),
		}),
		ui.scroll(layout.merge({ key = "inspect-scroll", align = "stretch", gap = 1 }, layout.scrollExtra(0, true)), filas),
	})
end

local function contentView(): any
	if S.section == "containers" then
		return containersView()
	elseif S.section == "images" then
		return imagesView()
	elseif S.section == "volumes" then
		return resourcesView("volumes")
	elseif S.section == "networks" then
		return resourcesView("networks")
	elseif S.section == "compose" then
		return composeView()
	elseif S.section == "terminal" then
		return terminalView()
	elseif S.section == "build" then
		return buildView()
	elseif S.section == "composefile" then
		return composefileView()
	elseif S.section == "disk" then
		return diskView()
	elseif S.section == "events" then
		return eventsView()
	elseif S.section == "rename" then
		return renameView()
	elseif S.section == "commit" then
		return commitView()
	elseif S.section == "copy" then
		return copyView()
	elseif S.section == "tag" then
		return tagView()
	elseif S.section == "run" then
		return runView()
	elseif S.section == "create" then
		return createView()
	elseif S.section == "volbackup" then
		return volBackupView()
	elseif S.section == "inspect" then
		return inspectView()
	elseif S.section == "hub" then
		return hubView()
	elseif S.section == "detail" then
		-- `detailView` existía pero NADIE la llamaba: los botones del
		-- contenedor seteaban S.target y S.detailTab, pero no cambiaban de
		-- sección, así que el detalle no se abría nunca.
		return detailView()
	end
	return dashboardView()
end

function render(): ()
	local st = status()
	local cuerpo: any
	if st.error ~= nil and st.error ~= "" then
		cuerpo = ui.column({ gap = 8, padding = 12, align = "stretch" }, {
			ui.label({ text = tostring(st.error), fontSize = 12, color = theme.danger() }),
			contentView(),
		})
	else
		cuerpo = contentView()
	end
	-- El alto lo pone el host (`height = "fill"` en el manifest) y los scrolls
	-- de adentro crecen con `flexGrow`. El ANCHO no se declara: `width = "fill"`
	-- toma el ancho de la SUPERFICIE (que incluye el bleed de la sombra del
	-- panel flotante, ~27 px), así que el topbar y las cards se salían del
	-- fondo. Heredando el ancho del panel quedan adentro.
	-- El fondo lo pone la config del usuario: acá NO se pinta uno propio.
	panel.render(ui.column({
		height = "fill",
		gap = 0,
		align = "stretch",
	}, {
		topbar(),
		-- `height = "fill"` además de `flexGrow`: con sólo flexGrow el row
		-- dejaba 20 px sin cubrir al fondo y la sidebar (violeta) no llegaba
		-- al borde inferior del panel.
		ui.row({ flexGrow = 1, align = "stretch", gap = 0 }, {
			sidebar(),
			ui.column({
					-- SIN width: el `flexGrow` reparte el ancho entre las dos
					-- columnas. Con un width explícito (1168 px) la columna
					-- derecha pedía más de lo que tiene el row y las filas
					-- del scroll se dibujaban desplazadas (los eventos
					-- salían en varias columnas).
					flexGrow = 1,
					minWidth = 0,
					align = "stretch",
				}, { cuerpo }),
		}),
	}))
end

-- ── hooks ──────────────────────────────────────────────────────────────

function onOpen(_context: any): ()
	state.store(SNAP_KEY, noctalia.state.get(SNAP_KEY))
	state.store(STATUS_KEY, noctalia.state.get(STATUS_KEY))
	state.store(LOGS_KEY, noctalia.state.get(LOGS_KEY))
	state.store(DETAIL_KEY, noctalia.state.get(DETAIL_KEY))
	state.store(DISK_KEY, noctalia.state.get(DISK_KEY))
	state.store(INFO_KEY, noctalia.state.get(INFO_KEY))
	state.store(STATS_KEY, noctalia.state.get(STATS_KEY))
	state.store(EVENTS_KEY, noctalia.state.get(EVENTS_KEY))
	state.store(EXEC_KEY, noctalia.state.get(EXEC_KEY))
	S.anim.t = if prefs.animations() then 0 else 1
	panel.setNeedsFrameTick(true)
	panel.setWantsSecondTicks(true)
	send({ action = "stats" })
	send({ action = "events" })
	send({ action = "disk" })
	-- La info del daemon (bloque Engine): se pide al abrir porque la caché
	-- de state puede arrancar vacía y el service no la carga solo.
	send({ action = "info" })
	render()
end

function onClose(): ()
	S.target = nil
	S.confirm = nil
end

function onFrameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	S.anim.t = math.min(1, S.anim.t + (tonumber(delta) or 16) / 220)
	render()
end

-- El service refresca el snapshot solo; las métricas y los eventos los pide
-- este panel (tardan: stats ~1 s, events ~2 s).
function update(): ()
	local ahora = noctalia.nowMs()
	if ahora - S.lastStats > 8000 then
		S.lastStats = ahora
		send({ action = "stats" })
	end
	if ahora - S.lastEvents > 60000 then
		S.lastEvents = ahora
		send({ action = "events" })
	end
end

-- El panel se puede abrir en una sección concreta: el IPC permite mandar
-- `{"section":"containers","id":"<id>"}` (lo usa el panel compacto).
function onIpc(event: string, payload: any): ()
	if event ~= "section" then
		return
	end
	-- El payload llega como texto (así lo manda el host): se decodifica.
	local data: any = payload
	if type(payload) == "string" and payload ~= "" then
		data = noctalia.json.decode(payload)
	end
	if type(data) ~= "table" then
		return
	end
	local seccion = tostring(data.section or "")
	for _, item in ipairs(SECTIONS) do
		if item.value == seccion then
			S.section = seccion
		end
	end
	if type(data.id) == "string" and data.id ~= "" then
		S.target = data.id
		send({ action = "detail", id = data.id })
	end
	S.page = 1
	render()
end

function onKey(chord: string, pressed: boolean): ()
	if not pressed then
		return
	end
	local indice = 1
	for i, seccion in ipairs(SECTIONS) do
		if seccion.value == S.section then
			indice = i
		end
	end
	if chord == "Right" then
		S.section = SECTIONS[(indice % #SECTIONS) + 1].value
		S.page = 1
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Left" then
		S.section = SECTIONS[((indice - 2) % #SECTIONS) + 1].value
		S.page = 1
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Prior" or chord == "Next" then
		local total = #filtered(S.section)
		local pages = math.max(1, math.ceil(total / pageSize()))
		if chord == "Next" then
			S.page = math.min(pages, S.page + 1)
		else
			S.page = math.max(1, S.page - 1)
		end
		render()
	end
end

state.watch(SNAP_KEY, function(_value: any)
	render()
end)

state.watch(STATUS_KEY, function(_value: any)
	render()
end)

state.watch(DETAIL_KEY, function(_value: any)
	render()
end)

state.watch(LOGS_KEY, function(_value: any)
	render()
end)

state.watch(DISK_KEY, function(_value: any)
	render()
end)

state.watch(INFO_KEY, function(_value: any)
	render()
end)

state.watch(STATS_KEY, function(_value: any)
	render()
end)

state.watch(EVENTS_KEY, function(_value: any)
	render()
end)

state.watch(EXEC_KEY, function(_value: any)
	render()
end)

state.watch(PORTS_KEY, function(_value: any)
	render()
end)

state.watch(HUB_KEY, function(_value: any)
	render()
end)

state.watch(VOLINFO_KEY, function(_value: any)
	render()
end)

state.watch(NETINFO_KEY, function(_value: any)
	render()
end)

-- Navegación desde el servicio: `{"action":"view","tab":"volumes"}` abre el
-- desktop en esa sección. Sin esto el panel sólo se movía con clics.
state.watch(SCREEN_KEY, function(value: any)
	if type(value) ~= "table" or value.tab == nil then
		return
	end
	local tab = tostring(value.tab)
	S.section = tab
	if value.id ~= nil then
		S.target = tostring(value.id)
	end
	if value.detTab ~= nil then
		S.detailTab = tostring(value.detTab)
	end
	-- Vistas que necesitan contexto: el detalle de un volumen/red y el
	-- formulario de respaldo. Así el service (o el panel compacto) puede
	-- abrirlas ya cargadas en vez de obligar a un clic.
	if tab == "inspect" and value.name ~= nil then
		S.inspectKind = if value.kind ~= nil then tostring(value.kind) else "volumes"
		S.inspectName = tostring(value.name)
	end
	if tab == "volbackup" and value.name ~= nil then
		S.form.volBackupName = tostring(value.name)
		S.form.volBackupPath = "~/Documents/backups/" .. tostring(value.name) .. ".tar.gz"
	end
	render()
end)
