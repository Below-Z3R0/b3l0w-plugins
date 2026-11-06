-- GENERADO por tests/build_panel_fixture.py — no editar a mano.
-- Fuente real embebida: ../panel.luau
return function(noctalia, ui, panel, require, barWidget)
--!nonstrict
-- Panel de b3l0w/kanban.
--
-- Tablero GitHub (issues o proyecto v2) con columnas por estado, tarjetas con
-- labels/asignados, movimiento sin drag (select por tarjeta), buscador,
-- contadores por columna, indicador de estancamiento y pestañas de dashboard
-- heredadas del plugin original (overview, notificaciones, actividad, following,
-- repositorios).
--
-- El panel NO lanza procesos: publica pedidos en REQUEST_KEY y dibuja desde
-- `noctalia.state`. Único `runAsync` local: nada (todo va al service).

local anim = require("./lib/anim.luau")
local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")

local T = noctalia.tr

local STATUS_KEY = "b3l0w_kanban_status"
local BOARD_KEY = "b3l0w_kanban_board"
local META_KEY = "b3l0w_kanban_meta"
local REQUEST_KEY = "b3l0w_kanban_request"
local SCREEN_KEY = "b3l0w_kanban_screen"
local FEED_KEY = "b3l0w_kanban_feed"

-- ── geometría ────────────────────────────────────────────────────────

local function panelMode(): string
	local mode = prefs.panel_mode()
	if mode == "float" then
		return "float"
	end
	return "compact"
end

local function panelWidth(): number
	return if panelMode() == "float" then 1300 else 880
end

local function panelHeight(): number
	return if panelMode() == "float" then 860 else 640
end

-- Cabecera + pestañas + fila de filtros + paddings. El resto es tablero.
local CHROME_H = 156
local GAP = 8

local function bodyHeight(): number
	return math.max(220, panelHeight() - CHROME_H)
end

local function innerWidth(): number
	return panelWidth() - 20
end

-- ── preferencias ─────────────────────────────────────────────────────

local function cfg(key: string, fallback: any): any
	local value = noctalia.getConfig(key)
	if value == nil or value == "" then
		return fallback
	end
	return value
end

local function cfgInt(key: string, fallback: number, low: number, high: number): number
	return math.clamp(tonumber(noctalia.getConfig(key)) or fallback, low, high)
end

local function cfgBool(key: string, fallback: boolean): boolean
	local value = noctalia.getConfig(key)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

-- Escala tipográfica del dashboard (el tablero usa tamaños fijos por densidad).
local function font(size: number): number
	return math.floor(size * cfgInt("appearance_font_scale", 100, 80, 130) / 100 + 0.5)
end

local function dashDensity(): string
	local value = cfg("appearance_density", "standard")
	if value == "compact" or value == "comfortable" then
		return value
	end
	return "standard"
end

local function dashPad(): number
	local density = dashDensity()
	if density == "compact" then
		return 7
	elseif density == "comfortable" then
		return 13
	end
	return 10
end

local function dashRadius(): number
	return cfgInt("appearance_card_radius", 9, 0, 24)
end

local function dashSpacing(): number
	return cfgInt("appearance_card_spacing", 8, 4, 20)
end

local function dashAnimations(): boolean
	return cfgBool("appearance_animations", true)
end

local function cardFill(): string
	local mode = cfg("appearance_card_background", "tinted")
	if mode == "transparent" then
		return "transparent"
	elseif mode == "solid" then
		return "surface/0.72"
	end
	return "surface_container/0.45"
end

local function cardBorder(active: boolean, unread: boolean): (string, number)
	local mode = cfg("appearance_card_border", "subtle")
	local hover = cfg("appearance_hover_effect", "background")
	if unread and cfgBool("notification_unread_border", true) then
		return "primary", 2
	end
	if active and hover == "border" then
		return "primary", 2
	end
	if mode == "none" then
		return "outline_variant/0", 0
	elseif mode == "accent" then
		return "primary", 1
	end
	return "outline_variant", 1
end

local function hoverFill(active: boolean, unread: boolean): string
	if active and cfg("appearance_hover_effect", "background") == "background" then
		return "tertiary/0.72"
	end
	if unread then
		return "primary/0.10"
	end
	return cardFill()
end

local function primaryText(active: boolean): string
	if active and cfg("appearance_hover_effect", "background") == "background" then
		return "on_tertiary"
	end
	return "on_surface"
end

local function secondaryText(active: boolean): string
	if active and cfg("appearance_hover_effect", "background") == "background" then
		return "on_tertiary"
	end
	return "on_surface_variant"
end

local function iconColor(active: boolean): string
	if active and cfg("appearance_hover_effect", "background") == "background" then
		return "on_tertiary"
	end
	local style = cfg("appearance_icon_style", "theme")
	if style == "muted" then
		return "on_surface_variant"
	elseif style == "color" then
		return "tertiary"
	end
	return "primary"
end

local function avatarGeometry(base: number): (number, number)
	local mode = cfg("appearance_avatar_size", "medium")
	local size = base
	if mode == "small" then
		size = math.floor(base * 0.78)
	elseif mode == "large" then
		size = math.floor(base * 1.25)
	end
	local radius = if cfg("appearance_avatar_shape", "circle") == "circle" then math.ceil(size / 2) else math.max(4, math.floor(size / 4))
	return size, radius
end

local function secondaryLines(): number
	local mode = cfg("appearance_secondary_text", "truncate")
	if mode == "full" then
		return 4
	end
	return 1
end

local function showSecondary(): boolean
	return cfg("appearance_secondary_text", "truncate") ~= "hidden"
end

local function staleDays(): number
	return cfgInt("board_stale_days", 7, 1, 90)
end

local function cardLimit(): number
	return cfgInt("board_cards_per_column", 25, 5, 100)
end

local function showCounts(): boolean
	return cfgBool("board_show_counts", true)
end

-- ── tiempo ───────────────────────────────────────────────────────────

-- ISO 8601 a epoch. gjd/kim prescinden de os.time para las zonas: la fecha
-- civil se convierte a UTC a mano y recién después se aplica el offset.
local function parse_iso(value: string): number?
	local y, m, d, h, minute, second, suffix = string.match(
		tostring(value or ""),
		"^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
	)
	if not y then
		return nil
	end
	y, m, d, h, minute, second = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute), tonumber(second)
	local zone = string.match(suffix, "^[%.%d]*([Zz])$")
	local sign, offsetHours, offsetMinutes = string.match(suffix, "^[%.%d]*([+-])(%d%d):?(%d%d)$")
	if not zone and not sign then
		return os.time({ year = y, month = m, day = d, hour = h, min = minute, sec = second })
	end
	local adjustedYear = y - (if m <= 2 then 1 else 0)
	local era = math.floor(adjustedYear / 400)
	local yearOfEra = adjustedYear - era * 400
	local adjustedMonth = m + (if m > 2 then -3 else 9)
	local dayOfYear = math.floor((153 * adjustedMonth + 2) / 5) + d - 1
	local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
	local epoch = (era * 146097 + dayOfEra - 719468) * 86400 + h * 3600 + minute * 60 + second
	if sign == "+" or sign == "-" then
		local offset = (tonumber(offsetHours) * 60 + tonumber(offsetMinutes)) * 60
		if sign == "-" then
			offset = -offset
		end
		epoch -= offset
	end
	return epoch
end

local function days_since(value: string): number
	local stamp = parse_iso(value)
	if stamp == nil then
		return 0
	end
	return math.max(0, math.floor((os.time() - stamp) / 86400 + 0.5))
end

local function display_time(value: string): string
	if value == nil or value == "" then
		return ""
	end
	local mode = cfg("appearance_time_format", "relative")
	if mode == "iso" then
		return value
	end
	local stamp = parse_iso(value)
	if stamp == nil then
		return value
	end
	if mode == "local" then
		return noctalia.formatTime("%Y-%m-%d %H:%M", stamp)
	end
	local seconds = math.max(0, os.time() - stamp)
	if seconds < 3600 then
		return T("time.minutes", { count = tostring(math.floor(seconds / 60)) })
	elseif seconds < 86400 then
		return T("time.hours", { count = tostring(math.floor(seconds / 3600)) })
	end
	return T("time.days", { count = tostring(math.floor(seconds / 86400)) })
end

-- ── estado del panel ─────────────────────────────────────────────────

local SNAP = { status = nil, board = nil, meta = nil, feed = nil }

local S = {
	tab = "board",
	screen = "board",
	search = "",
	assignee = "all",
	label = "all",
	staleOnly = false,
	notifFilter = "",
	activityTab = "prs",
	activityState = "all",
	feedFilter = "all",
	page = 1,
	hovered = nil,
	requests = 0,
	renderStamp = 0,
	itemsCache = nil,
	cacheStamp = -1,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
	form = { title = "", body = "", labels = "" },
	followLimit = 0,
}

local function snap(field: string, key: string): any
	local cached = SNAP[field]
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(key)
	return if type(value) == "table" then value else {}
end

local function status(): any
	return snap("status", STATUS_KEY)
end

local function meta(): any
	return snap("meta", META_KEY)
end

local function feed(): any
	return snap("feed", FEED_KEY)
end

local function listOf(value: any): { any }
	return if type(value) == "table" then value else {}
end

local function send(payload: any): ()
	S.requests += 1
	payload.nonce = tostring(math.floor(os.clock() * 1000)) .. ":" .. tostring(S.requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

-- ── piezas ───────────────────────────────────────────────────────────

local function chip(text: string, color: string, fill: string?): any
	return ui.row({
		fill = fill or "surface_container/0.70",
		radius = 6,
		paddingH = 6,
		paddingV = 2,
		align = "center",
	}, {
		ui.label({ text = text, fontSize = 10, color = color, maxLines = 1 }),
	})
end

local function dot(color: string, size: number?): any
	local px = size or 6
	return ui.box({ width = px, height = px, radius = math.ceil(px / 2), fill = color })
end

local function labelChips(labels: { any }, maxChips: number): any
	local children = {}
	for index, label in ipairs(labels) do
		if index > maxChips then
			break
		end
		local color = "#" .. tostring(label.color or "")
		if string.len(tostring(label.color or "")) ~= 6 then
			color = theme.dim()
		end
		children[#children + 1] = ui.row({
			fill = "surface_container/0.70",
			radius = 5,
			paddingH = 4,
			paddingV = 1,
			gap = 3,
			align = "center",
		}, {
			dot(color, 5),
			ui.label({ text = tostring(label.name or ""), fontSize = 9, color = "on_surface_variant", maxLines = 1, maxWidth = 88 }),
		})
	end
	if #labels > maxChips then
		children[#children + 1] = ui.label({ text = "+" .. tostring(#labels - maxChips), fontSize = 9, color = "on_surface_variant" })
	end
	return ui.row({ gap = 3, align = "center" }, children)
end

local function empty_state(illustration: boolean): any
	local children = {}
	if illustration and cfgBool("appearance_show_empty_illustration", true) then
		children[#children + 1] = ui.glyph({ name = "inbox", size = 34, color = "on_surface_variant", opacity = 0.7 })
	end
	children[#children + 1] = ui.label({ text = T("panel.empty"), fontSize = 12, color = "on_surface_variant" })
	return ui.column({ flexGrow = 1, gap = 8, align = "center", justify = "center", padding = 18 }, children)
end

-- ── filtros del tablero ──────────────────────────────────────────────

local function card_assignees(card: any): { string }
	return listOf(card.assignees)
end

local function card_labels(card: any): { any }
	return listOf(card.labels)
end

local function login_self(): string
	return tostring(status().login or "")
end

local function has_login(logins: { string }, wanted: string): boolean
	if wanted == "" then
		return false
	end
	for _, login in ipairs(logins) do
		if string.lower(tostring(login)) == string.lower(wanted) then
			return true
		end
	end
	return false
end

local function card_matches(card: any): boolean
	local needle = string.lower(S.search)
	if needle ~= "" then
		local haystack = string.lower(
			tostring(card.title or "") .. " " .. tostring(card.number or "") .. " " .. tostring(card.author or "")
		)
		if not string.find(haystack, needle, 1, true) then
			local hit = false
			for _, label in ipairs(card_labels(card)) do
				if string.find(string.lower(tostring(label.name or "")), needle, 1, true) then
					hit = true
				end
			end
			for _, login in ipairs(card_assignees(card)) do
				if string.find(string.lower(tostring(login)), needle, 1, true) then
					hit = true
				end
			end
			if not hit then
				return false
			end
		end
	end
	local assignees = card_assignees(card)
	if S.assignee == "mine" and not has_login(assignees, login_self()) then
		return false
	elseif S.assignee == "unassigned" and #assignees > 0 then
		return false
	end
	if S.label ~= "all" then
		local hit = false
		for _, label in ipairs(card_labels(card)) do
			if tostring(label.name or "") == S.label then
				hit = true
			end
		end
		if not hit then
			return false
		end
	end
	if S.staleOnly and days_since(tostring(card.updatedAt or "")) < staleDays() then
		return false
	end
	return true
end

-- Se llama varias veces por frame (por columna y por contador): memo por render.
local function filtered_cards(cards: any): { any }
	local out = {}
	for _, card in ipairs(listOf(cards)) do
		if type(card) == "table" and card_matches(card) then
			out[#out + 1] = card
		end
	end
	return out
end

local function all_cards(): { any }
	local out = {}
	for _, column in ipairs(listOf(snap("board", BOARD_KEY).columns)) do
		for _, card in ipairs(listOf(column.cards)) do
			out[#out + 1] = card
		end
	end
	return out
end

local function all_labels(): { string }
	if S.cacheStamp == S.renderStamp and S.itemsCache ~= nil then
		return S.itemsCache
	end
	local seen = {}
	local out = {}
	for _, column in ipairs(listOf(snap("board", BOARD_KEY).columns)) do
		for _, card in ipairs(listOf(column.cards)) do
			for _, label in ipairs(card_labels(card)) do
				local name = tostring(label.name or "")
				if name ~= "" and not seen[name] then
					seen[name] = true
					out[#out + 1] = name
				end
			end
		end
	end
	table.sort(out)
	S.itemsCache = out
	S.cacheStamp = S.renderStamp
	return out
end

-- ── tarjetas del tablero ─────────────────────────────────────────────

local function column_name(column: any): string
	if column.state == "open" then
		return T("board.open")
	elseif column.state == "closed" then
		return T("board.closed")
	end
	return tostring(column.name or "")
end

local function column_names(): { string }
	local out = {}
	for _, column in ipairs(listOf(snap("board", BOARD_KEY).columns)) do
		out[#out + 1] = column_name(column)
	end
	return out
end

local function column_index(column: any): number
	local names = column_names()
	local wanted = column_name(column)
	for index, name in ipairs(names) do
		if name == wanted then
			return index - 1
		end
	end
	return 0
end

local function board_card(card: any, column: any, names: { string }, width: number, index: number): any
	local key = "card-" .. tostring(card.id)
	local active = S.hovered == key
	local days = days_since(tostring(card.updatedAt or ""))
	local stale = days >= staleDays()
	local border, borderWidth = cardBorder(active, false)
	local alpha = if S.anim.t < 1 then anim.stagger(index, anim.ease_out(S.anim.t), 0.05) else 1
	local assignees = card_assignees(card)
	local assigneeText = ""
	if cfgBool("board_show_assignees", true) and #assignees > 0 then
		assigneeText = "@" .. table.concat(assignees, " @")
	end
	local current = column_index(column)
	local meta_row = {
		ui.label({ text = "#" .. tostring(card.number or 0), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
		ui.box({ flexGrow = 1 }),
	}
	-- El chip de estancamiento existe sólo cuando la tarjeta lo está: si no,
	-- una tarjeta de hoy mostraba "0d idle" al lado de "hace 7h".
	if stale then
		meta_row[#meta_row + 1] = chip(T("board.stale", { count = tostring(days) }), "#e0b070", "warning/0.18")
	else
		meta_row[#meta_row + 1] = ui.label({ text = display_time(tostring(card.updatedAt or "")), fontSize = 9, color = "on_surface_variant", maxLines = 1 })
	end
	local children = {
		ui.row({ gap = 5, align = "center" }, meta_row),
		ui.label({
			text = tostring(card.title or ""),
			fontSize = if prefs.density() == "compact" then 11 else 12,
			fontWeight = "semibold",
			maxLines = 2,
			maxWidth = width - 18,
			color = primaryText(active),
		}),
	}
	if #card_labels(card) > 0 and cfgBool("board_show_labels", true) then
		children[#children + 1] = labelChips(card_labels(card), 3)
	end
	if assigneeText ~= "" then
		children[#children + 1] = ui.label({
			text = assigneeText,
			fontSize = 9,
			color = "primary",
			maxLines = 1,
			maxWidth = width - 18,
		})
	end
	children[#children + 1] = ui.row({ gap = 5, align = "center" }, {
		ui.select({
			key = "move-" .. tostring(card.id),
			options = names,
			selectedIndex = current,
			controlSize = "sm",
			width = math.max(96, width - 52),
			onChange = function(index: any)
				local target = names[(tonumber(index) or 0) + 1]
				if target == nil or target == column_name(column) then
					return
				end
				send({ action = "move", id = tostring(card.id), target = target })
			end,
		}),
		ui.button({
			glyph = "external-link",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.open_browser"),
			onClick = function()
				send({ action = "open", url = tostring(card.url or "") })
			end,
		}),
	})
	return ui.column({
		key = key,
		width = width,
		gap = 5,
		padding = 8,
		radius = prefs.density() == "compact" and 8 or 10,
		fill = hoverFill(active, false),
		border = border,
		borderWidth = borderWidth,
		opacity = alpha,
		onHover = function(value: any)
			if not prefs.animations() then
				return
			end
			S.hovered = if value == "true" then key else nil
			render()
		end,
	}, children)
end

local function board_column(column: any, names: { string }, width: number): any
	local cards = filtered_cards(column.cards)
	local limit = cardLimit()
	local children = {
		ui.row({ gap = 6, align = "center", paddingH = 6, paddingV = 5, radius = 8, fill = "surface_container/0.55" }, {
			dot(column.state == "closed" and theme.ok() or theme.info(), 7),
			ui.label({
				text = column_name(column),
				fontSize = 11,
				fontWeight = "semibold",
				maxLines = 1,
				maxWidth = width - 52,
			}),
			ui.box({ flexGrow = 1 }),
			ui.label({
				text = tostring(#cards),
				fontSize = 10,
				color = "on_surface_variant",
				visible = showCounts(),
			}),
		}),
	}
	local rows = {}
	for index, card in ipairs(cards) do
		if index > limit then
			break
		end
		rows[#rows + 1] = board_card(card, column, names, width - 6, index)
	end
	if #rows == 0 then
		rows[1] = ui.column({ padding = 12, align = "center" }, {
			ui.label({ text = T("board.column_empty"), fontSize = 11, color = "on_surface_variant" }),
		})
	end
	if #cards > limit then
		rows[#rows + 1] = ui.label({
			text = T("board.more", { count = tostring(#cards - limit) }),
			fontSize = 10,
			color = "on_surface_variant",
		})
	end
	children[#children + 1] = ui.scroll({
		key = "col-" .. tostring(column.id),
		width = width,
		height = bodyHeight() - 40,
		gap = 6,
		paddingH = 1,
	}, rows)
	return ui.column({ key = "column-" .. tostring(column.id), width = width, gap = 6 }, children)
end

local function board_rows(): any
	local columns = listOf(snap("board", BOARD_KEY).columns)
	if #columns == 0 then
		return empty_state(true)
	end
	local names = column_names()
	local width = math.max(150, math.floor((innerWidth() - GAP * (#columns - 1)) / #columns))
	local nodes = {}
	for _, column in ipairs(columns) do
		nodes[#nodes + 1] = board_column(column, names, width)
	end
	return ui.row({ gap = GAP, align = "start", height = bodyHeight() }, nodes)
end

-- ── barra de filtros ─────────────────────────────────────────────────

local ASSIGNEE_OPTIONS = { "all", "mine", "unassigned" }

local function assignee_index(): number
	for index, value in ipairs(ASSIGNEE_OPTIONS) do
		if value == S.assignee then
			return index - 1
		end
	end
	return 0
end

local function filter_bar(): any
	local labels = all_labels()
	local labelOptions = { T("filter.all") }
	for _, name in ipairs(labels) do
		labelOptions[#labelOptions + 1] = name
	end
	local labelIndex = 0
	for index, name in ipairs(labelOptions) do
		if name == S.label then
			labelIndex = index - 1
		end
	end
	-- Cambiar de repositorio cambia el set de labels. Si el label filtrado ya no
	-- existe el select mostraba "All" mientras el tablero seguía filtrando por
	-- él: columna vacía sin causa visible.
	if labelIndex == 0 and S.label ~= "all" then
		S.label = "all"
	end
	return ui.row({ gap = 6, align = "center", paddingH = 4 }, {
		ui.input({
			key = "kanban-search",
			value = S.search,
			placeholder = T("panel.search"),
			controlSize = "sm",
			width = 210,
			onChange = function(value: any)
				S.search = tostring(value or "")
				S.page = 1
				render()
			end,
		}),
		ui.select({
			key = "kanban-assignee",
			options = { T("filter.all"), T("filter.assigned_to_me"), T("filter.unassigned") },
			selectedIndex = assignee_index(),
			controlSize = "sm",
			width = 150,
			onChange = function(index: any)
				S.assignee = ASSIGNEE_OPTIONS[(tonumber(index) or 0) + 1] or "all"
				render()
			end,
		}),
		ui.select({
			key = "kanban-label",
			options = labelOptions,
			selectedIndex = labelIndex,
			controlSize = "sm",
			width = 150,
			onChange = function(index: any)
				S.label = labelOptions[(tonumber(index) or 0) + 1] or T("filter.all")
				if S.label == T("filter.all") then
					S.label = "all"
				end
				render()
			end,
		}),
		ui.button({
			text = T("filter.stale"),
			controlSize = "sm",
			variant = if S.staleOnly then "secondary" else "ghost",
			selected = S.staleOnly,
			onClick = function()
				S.staleOnly = not S.staleOnly
				render()
			end,
		}),
		ui.box({ flexGrow = 1 }),
		ui.label({
			text = T("panel.visible", {
				shown = tostring(#filtered_cards(all_cards())),
				total = tostring(tonumber(snap("board", BOARD_KEY).total) or 0),
			}),
			fontSize = 10,
			color = "on_surface_variant",
		}),
	})
end

-- ── pantallas ────────────────────────────────────────────────────────

local function row_card(children: { any }, active: boolean, unread: boolean, onClick: any, onHover: any): any
	local border, borderWidth = cardBorder(active, unread)
	return ui.row({
		gap = dashPad(),
		padding = dashPad(),
		radius = dashRadius(),
		fill = hoverFill(active, unread),
		border = border,
		borderWidth = borderWidth,
		align = "center",
		onClick = onClick,
		onHover = onHover,
	}, children)
end

local function card_hover(key: string): any
	return function(value: any)
		if not dashAnimations() then
			return
		end
		S.hovered = if value == "true" then key else nil
		render()
	end
end

local function scroll_list(rows: { any }): any
	if #rows == 0 then
		return empty_state(true)
	end
	return ui.scroll({
		key = "dash-scroll",
		flexGrow = 1,
		gap = dashSpacing(),
		align = "stretch",
	}, rows)
end

-- El service publica un error por dataset (`activityError`, `followingError`,
-- `reposError`) y sólo notificaciones lo leía: las otras pestañas se quedaban
-- vacías sin decir por qué. Devuelve nil cuando no hay error, así el llamador
-- lo inserta condicionalmente.
local function error_banner(message: any): any
	local text = tostring(message or "")
	if text == "" then
		return nil
	end
	return ui.label({
		text = text,
		fontSize = 10,
		color = theme.warn(),
		maxLines = 2,
		maxWidth = innerWidth() - 20,
	})
end

local function repo_row(repo: any, index: number): any
	local key = "repo-" .. tostring(repo.nameWithOwner or index)
	local full = tostring(repo.nameWithOwner or "")
	local current = full == tostring(status().repo or "")
	local alpha = if S.anim.t < 1 then anim.stagger(index, anim.ease_out(S.anim.t), 0.03) else 1
	return ui.row({
		key = key,
		gap = 8,
		padding = 9,
		radius = dashRadius(),
		fill = if current then "primary/0.14" else hoverFill(S.hovered == key, false),
		border = if current then "primary" else "outline_variant/0.6",
		borderWidth = 1,
		align = "center",
		opacity = alpha,
		onClick = function()
			send({ action = "set_repo", repo = full })
			S.screen = "board"
			S.anim.t = if prefs.animations() then 0 else 1
			render()
		end,
		onHover = card_hover(key),
	}, {
		ui.glyph({ name = "folder-code", size = 16, color = iconColor(false) }),
		ui.column({ flexGrow = 1, gap = 1, minWidth = 0 }, {
			ui.label({ text = full, fontSize = 12, fontWeight = "semibold", maxLines = 1, maxWidth = innerWidth() - 180 }),
			ui.label({ text = display_time(tostring(repo.updatedAt or "")), fontSize = 10, color = "on_surface_variant" }),
		}),
		ui.label({ text = T("panel.private"), fontSize = 9, color = "on_surface_variant", visible = repo.isPrivate == true }),
		ui.glyph({ name = if current then "check" else "chevron-right", size = 14, color = "on_surface_variant" }),
	})
end

local function project_row(project: any, index: number): any
	local key = "project-" .. tostring(project.number or index)
	local number = tonumber(project.number) or 0
	local current = number == tonumber(status().project or 0)
	local alpha = if S.anim.t < 1 then anim.stagger(index, anim.ease_out(S.anim.t), 0.03) else 1
	return ui.row({
		key = key,
		gap = 8,
		padding = 9,
		radius = dashRadius(),
		fill = if current then "primary/0.14" else hoverFill(S.hovered == key, false),
		border = if current then "primary" else "outline_variant/0.6",
		borderWidth = 1,
		align = "center",
		opacity = alpha,
		onClick = function()
			send({ action = "set_project", project = number, owner = tostring(project.owner or status().owner or "") })
			S.screen = "board"
			S.tab = "board"
			S.anim.t = if prefs.animations() then 0 else 1
			render()
		end,
		onHover = card_hover(key),
	}, {
		ui.glyph({ name = "layout-kanban", size = 16, color = iconColor(false) }),
		ui.column({ flexGrow = 1, gap = 1, minWidth = 0 }, {
			ui.label({ text = tostring(project.title or ""), fontSize = 12, fontWeight = "semibold", maxLines = 1 }),
			ui.label({
				text = T("panel.project_meta", { number = tostring(number), items = tostring(project.items or 0) }),
				fontSize = 10,
				color = "on_surface_variant",
			}),
		}),
		ui.glyph({ name = if current then "check" else "chevron-right", size = 14, color = "on_surface_variant" }),
	})
end

local function repos_view(): any
	local data = meta()
	local repos = listOf(data.repos)
	local projects = listOf(data.projects)
	local rows = {}
	for index, repo in ipairs(repos) do
		rows[#rows + 1] = repo_row(repo, index)
	end
	local children = {
		ui.row({ gap = 8, align = "center" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.screen = "board"
					render()
				end,
			}),
			ui.label({ text = T("panel.pick_repo"), fontSize = 15, fontWeight = "semibold" }),
			ui.box({ flexGrow = 1 }),
			ui.button({
				glyph = "refresh",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.refresh"),
				onClick = function()
					send({ action = "discover" })
				end,
			}),
		}),
		ui.separator({ color = "outline_variant/0.5" }),
		ui.row({ gap = 6, align = "center" }, {
			ui.label({ text = T("panel.source"), fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
			ui.button({
				text = T("panel.source_issues"),
				controlSize = "sm",
				variant = if status().source == "issues" then "primary" else "ghost",
				selected = status().source == "issues",
				onClick = function()
					send({ action = "set_source", source = "issues" })
					S.screen = "board"
					render()
				end,
			}),
			ui.button({
				text = T("panel.source_project"),
				controlSize = "sm",
				variant = if status().source == "project" then "primary" else "ghost",
				selected = status().source == "project",
				onClick = function()
					send({ action = "set_source", source = "project" })
					S.screen = "board"
					render()
				end,
			}),
		}),
	}
	if #projects > 0 then
		local prows = {}
		for index, project in ipairs(projects) do
			prows[#prows + 1] = project_row(project, index)
		end
		children[#children + 1] = ui.label({ text = T("panel.projects"), fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" })
		children[#children + 1] = ui.column({ gap = 4 }, prows)
	end
	if tostring(data.projectsError or "") ~= "" then
		children[#children + 1] = ui.row({ gap = 6, align = "center", padding = 6, radius = 8, fill = "warning/0.15" }, {
			ui.glyph({ name = "alert-triangle", size = 13, color = theme.warn() }),
			ui.label({
				text = T("status.projects_scope", { error = tostring(data.projectsError) }),
				fontSize = 10,
				color = "on_surface_variant",
				maxLines = 2,
				maxWidth = innerWidth() - 60,
			}),
		})
	end
	children[#children + 1] = ui.label({ text = T("panel.repos"), fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" })
	local reposError = error_banner(data.reposError)
	if reposError ~= nil then
		children[#children + 1] = reposError
	end
	children[#children + 1] = ui.scroll({
		key = "repo-scroll",
		height = bodyHeight() - 210,
		gap = 4,
		align = "stretch",
	}, rows)
	return ui.column({ gap = 8, align = "stretch", height = bodyHeight() }, children)
end

local function create_view(): any
	local form = S.form
	return ui.column({ gap = 10, padding = 4 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.button({
				glyph = "arrow-left",
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					S.screen = "board"
					render()
				end,
			}),
			ui.label({ text = T("panel.create_title"), fontSize = 15, fontWeight = "semibold" }),
			ui.box({ flexGrow = 1 }),
			ui.label({
				text = T("panel.create_repo", { repo = tostring(status().repo or "") }),
				fontSize = 10,
				color = "on_surface_variant",
			}),
		}),
		ui.input({
			key = "create-title",
			value = form.title,
			placeholder = T("panel.create_issue_title"),
			controlSize = "sm",
			width = innerWidth() - 40,
			onChange = function(value: any)
				form.title = tostring(value or "")
			end,
		}),
		ui.input({
			key = "create-body",
			value = form.body,
			placeholder = T("panel.create_issue_body"),
			multiline = true,
			height = 150,
			width = innerWidth() - 40,
			onChange = function(value: any)
				form.body = tostring(value or "")
			end,
		}),
		ui.input({
			key = "create-labels",
			value = form.labels or cfg("create_default_labels", ""),
			placeholder = T("panel.create_labels_hint"),
			controlSize = "sm",
			width = innerWidth() - 40,
			onChange = function(value: any)
				form.labels = tostring(value or "")
			end,
		}),
		ui.row({ gap = 8, align = "center" }, {
			ui.button({
				text = T("panel.create_submit"),
				variant = "primary",
				controlSize = "sm",
				enabled = tostring(form.title or "") ~= "",
				onClick = function()
					send({
						action = "create",
						title = tostring(form.title or ""),
						body = tostring(form.body or ""),
						labels = tostring(form.labels or ""),
					})
					S.form = { title = "", body = "", labels = "" }
					S.screen = "board"
					render()
				end,
			}),
			ui.label({ text = T("panel.create_hint"), fontSize = 10, color = "on_surface_variant", maxLines = 2, maxWidth = innerWidth() - 200 }),
		}),
	})
end

-- ── dashboard: overview ──────────────────────────────────────────────

local HEAT_COLORS = {
	noctalia = { "surface_container/0.55", "primary/0.25", "primary/0.45", "primary/0.70", "primary" },
	github = { "#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39" },
}

local function heat_color(level: number): string
	local mode = cfg("heatmap_color_mode", "noctalia")
	if mode == "custom" then
		local custom = tostring(noctalia.getConfig("heatmap_custom_level_" .. tostring(level)) or "")
		if string.match(custom, "^#%x%x%x%x%x%x$") then
			return custom
		end
		return HEAT_COLORS.noctalia[level + 1]
	end
	local palette = HEAT_COLORS[mode] or HEAT_COLORS.noctalia
	return palette[level + 1]
end

local function heat_level(count: number, maxCount: number, levels: number): number
	if count <= 0 then
		return 0
	end
	local scaled = math.ceil(count * levels / math.max(1, maxCount))
	return math.clamp(scaled, 1, levels - 1)
end

local function heatmap_view(): any
	local calendar = feed().calendar
	if type(calendar) ~= "table" or type(calendar.weeks) ~= "table" then
		return ui.column({ padding = 18, align = "center" }, {
			ui.label({ text = T("status.preparing_calendar"), fontSize = 11, color = "on_surface_variant" }),
		})
	end
	local cell = cfgInt("heatmap_cell_size", 13, 8, 16)
	local gap = cfgInt("heatmap_cell_gap", 1, 1, 4)
	local radius = cfgInt("heatmap_cell_radius", 2, 0, 4)
	local levels = if cfg("heatmap_levels", "5") == "4" then 4 else 5
	local weeks = listOf(calendar.weeks)
	local maxCount = 1
	for _, week in ipairs(weeks) do
		for _, day in ipairs(listOf(week)) do
			maxCount = math.max(maxCount, tonumber(day.count) or 0)
		end
	end
	local gutter = if cfgBool("heatmap_show_weekdays", true) then 30 else 0
	local fit = math.max(8, math.floor((innerWidth() - 40 - gutter) / (cell + gap)))
	local start = math.max(1, #weeks - fit + 1)
	local columns = {}
	local monthLabel = ""
	for index = start, #weeks do
		local week = listOf(weeks[index])
		local cells = {}
		local week_month = ""
		for dayIndex, day in ipairs(week) do
			local count = tonumber(day.count) or 0
			local level = heat_level(count, maxCount, levels)
			if dayIndex == 1 and type(day.date) == "string" then
				week_month = string.sub(day.date, 6, 7)
			end
			cells[#cells + 1] = ui.box({
				width = cell,
				height = cell,
				radius = radius,
				fill = heat_color(level),
				opacity = if level == 0 then 0.40 else 1,
				border = if level == 0 and cfg("heatmap_empty_style", "background") == "outline" then "primary/0.45" else "primary/0.18",
				borderWidth = 1,
				tooltip = tostring(day.date or "") .. " · " .. tostring(count),
			})
		end
		local children = {}
		if cfgBool("heatmap_show_months", true) then
			children[#children + 1] = ui.label({ text = if week_month ~= monthLabel then week_month else "", fontSize = 8, color = "on_surface_variant" })
			monthLabel = week_month
		end
		children[#children + 1] = ui.column({ key = "week-" .. tostring(index), gap = gap }, cells)
		columns[#columns + 1] = ui.column({ gap = 2, align = "start" }, children)
	end
	local legend = { ui.label({ text = T("heatmap.less"), fontSize = 9, color = "on_surface_variant" }) }
	for level = 1, levels do
		legend[#legend + 1] = ui.box({ width = 9, height = 9, radius = radius, fill = heat_color(level - 1), opacity = if level == 1 then 0.40 else 1 })
	end
	legend[#legend + 1] = ui.label({ text = T("heatmap.more"), fontSize = 9, color = "on_surface_variant" })
	local footer = {}
	if cfgBool("heatmap_show_total", true) then
		footer[#footer + 1] = ui.label({
			text = T("heatmap.total", { count = tostring(tonumber(calendar.total) or 0) }),
			fontSize = 10,
			color = "on_surface_variant",
			flexGrow = 1,
		})
	end
	if cfgBool("heatmap_show_legend", true) then
		footer[#footer + 1] = ui.row({ gap = 3, align = "center" }, legend)
	end
	return ui.column({ gap = 6, padding = dashPad(), radius = dashRadius(), fill = "surface/0.20" }, {
		ui.row({ gap = gap, align = "end" }, columns),
		ui.row({ gap = 6, align = "center" }, footer),
	})
end

local function metric(label: string, value: any, glyph: string): any
	return ui.column({
		flexGrow = 1,
		gap = 2,
		padding = dashPad(),
		radius = dashRadius(),
		fill = cardFill(),
		align = "center",
	}, {
		ui.glyph({ name = glyph, size = font(17), color = iconColor(false) }),
		ui.label({ text = tostring(value or 0), fontSize = font(16), fontWeight = "bold" }),
		ui.label({ text = label, fontSize = font(9), color = "on_surface_variant" }),
	})
end

local function stats_row(items: { any }): any
	local mode = cfg("overview_stats_layout", "columns4")
	if mode == "grid" then
		return ui.column({ gap = dashSpacing() }, {
			ui.row({ gap = dashSpacing() }, { items[1], items[2] }),
			ui.row({ gap = dashSpacing() }, { items[3], items[4] }),
		})
	end
	return ui.row({ gap = if mode == "compact" then 3 else dashSpacing() }, items)
end

local function overview_view(): any
	-- `viewer` es un objeto, no una lista: leerlo con listOf() funcionaba por
	-- accidente (devuelve la tabla tal cual) y ocultaba que un {} del service es
	-- "todavía sin respuesta", no "sin sesión".
	local viewerRaw = meta().viewer
	local viewer = if type(viewerRaw) == "table" then viewerRaw else {}
	local calendar = feed().calendar
	local total = type(calendar) == "table" and tonumber(calendar.total) or 0
	local avatarSize, avatarRadius = avatarGeometry(54)
	-- `ui.image` sólo acepta rutas locales; el service descarga el avatar y
	-- publica avatarPath. Si todavía no está, se muestra el glifo.
	local avatarNode = ui.glyph({ name = "user", size = font(26), color = "on_surface_variant" })
	if type(viewer.avatarPath) == "string" and viewer.avatarPath ~= "" then
		avatarNode = ui.image({
			path = viewer.avatarPath,
			width = avatarSize,
			height = avatarSize,
			radius = avatarRadius,
			fit = "cover",
		})
	end
	local profile = ui.row({
		gap = dashPad(),
		padding = dashPad(),
		radius = dashRadius(),
		fill = cardFill(),
		align = "center",
		onClick = function()
			send({ action = "open", url = tostring(viewer.html_url or "") })
		end,
	}, {
		ui.column({
			width = avatarSize,
			height = avatarSize,
			radius = avatarRadius,
			fill = "primary/0.14",
			align = "center",
			justify = "center",
			border = "primary",
			borderWidth = 2,
		}, {
			avatarNode,
		}),
		ui.column({ width = 220, gap = 2 }, {
			ui.label({ text = tostring(viewer.name or viewer.login or T("panel.not_signed")), fontSize = font(16), fontWeight = "bold" }),
			ui.label({ text = if tostring(viewer.login or "") ~= "" then "@" .. tostring(viewer.login) else "", fontSize = font(11), color = "primary" }),
			ui.label({
				text = tostring(viewer.bio or ""),
				fontSize = font(10),
				color = "on_surface_variant",
				maxLines = secondaryLines(),
				visible = showSecondary() and tostring(viewer.bio or "") ~= "",
			}),
		}),
		ui.column({ flexGrow = 1 }, {
			stats_row({
				metric(T("profile.followers"), viewer.followers, "users"),
				metric(T("profile.following"), viewer.following, "user-plus"),
				metric(T("profile.repositories"), viewer.public_repos, "folder-code"),
				metric(T("profile.contributions"), total, "chart-dots"),
			}),
		}),
	})
	return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
		profile,
		ui.label({ text = T("panel.contributions"), fontSize = font(12), fontWeight = "semibold" }),
		heatmap_view(),
	})
end

-- ── dashboard: notificaciones ────────────────────────────────────────

local REASON_GROUP = {
	assign = "assigned",
	author = "assigned",
	review_requested = "attention",
	team_mention = "attention",
	mention = "attention",
}

local function reason_group(reason: string): string
	return REASON_GROUP[reason] or "updates"
end

local function notifications_view(): any
	local data = feed()
	local items = listOf(data.notifications)
	local readFilter = S.notifFilter ~= "" and S.notifFilter or tostring(cfg("notification_default_filter", "unread"))
	local rows = {}
	local unreadVisible = {}
	for index, item in ipairs(items) do
		local unread = item.unread == true
		local matches = readFilter == "all" or (readFilter == "unread" and unread) or (readFilter == "read" and not unread)
		if matches then
			local key = "notif-" .. tostring(item.id)
			local alpha = if S.anim.t < 1 then anim.stagger(index, anim.ease_out(S.anim.t), 0.03) else 1
			local opacity = if unread then 1 else cfgInt("notification_read_opacity", 100, 40, 100) / 100
			rows[#rows + 1] = ui.row({
				key = key,
				gap = 8,
				padding = dashPad(),
				radius = dashRadius(),
				fill = hoverFill(S.hovered == key, unread),
				border = cardBorder(S.hovered == key, unread),
				borderWidth = if unread and cfgBool("notification_unread_border", true) then 2 else 1,
				opacity = alpha * opacity,
				align = "center",
				onClick = function()
					send({ action = "open", url = tostring(item.url or "") })
				end,
				onHover = card_hover(key),
			}, {
				ui.box({
					width = 7,
					height = 7,
					radius = 4,
					fill = "primary",
					visible = unread and cfgBool("notification_unread_dot", true),
				}),
				ui.glyph({ name = "bell", size = font(15), color = iconColor(false) }),
				ui.column({ flexGrow = 1, gap = 1, minWidth = 0 }, {
					ui.label({ text = tostring(item.title or ""), fontSize = font(12), fontWeight = "semibold", maxLines = 2, maxWidth = innerWidth() - 260 }),
					ui.label({
						text = tostring(item.repository or "") .. "  ·  " .. T("notification.reason." .. reason_group(tostring(item.reason or ""))),
						fontSize = font(10),
						color = "on_surface_variant",
						maxLines = 1,
						visible = showSecondary(),
					}),
				}),
				ui.label({ text = display_time(tostring(item.updatedAt or "")), fontSize = font(9), color = "on_surface_variant" }),
				ui.button({
					glyph = if unread then "check" else "chevron-right",
					controlSize = "sm",
					variant = "ghost",
					enabled = unread,
					tooltip = T("panel.mark_read"),
					onClick = function()
						send({ action = "mark_read", id = tostring(item.id or "") })
					end,
				}),
			})
			if unread then
				unreadVisible[#unreadVisible + 1] = item
			end
		end
	end
	local filters = {
		{ id = "all", label = T("filter.all") },
		{ id = "unread", label = T("filter.unread") },
		{ id = "read", label = T("filter.read") },
	}
	local strip = {}
	for _, filter in ipairs(filters) do
		local id = filter.id
		strip[#strip + 1] = ui.button({
			text = filter.label,
			controlSize = "sm",
			variant = if readFilter == id then "primary" else "ghost",
			selected = readFilter == id,
			onClick = function()
				S.notifFilter = id
				S.page = 1
				render()
			end,
		})
	end
	strip[#strip + 1] = ui.box({ flexGrow = 1 })
	strip[#strip + 1] = ui.button({
		text = T("panel.mark_all_read"),
		controlSize = "sm",
		variant = "outline",
		enabled = #unreadVisible > 0,
		onClick = function()
			send({ action = "mark_all_read" })
		end,
	})
	local children = { ui.row({ gap = 4, align = "center" }, strip) }
	local error = tostring(data.notificationsError or "")
	if error ~= "" then
		children[#children + 1] = ui.label({ text = error, fontSize = 10, color = theme.warn(), maxLines = 2, maxWidth = innerWidth() - 20 })
	end
	children[#children + 1] = scroll_list(rows)
	return ui.column({ flexGrow = 1, gap = 6 }, children)
end

-- ── dashboard: actividad ─────────────────────────────────────────────

local function activity_rows(scope: string): { any }
	local data = feed()
	local source = if S.activityTab == "issues" then listOf(data.issues) else listOf(data.prs)
	local prScope = if S.activityTab == "issues" then cfg("issue_default_filter", "all") else cfg("pr_default_filter", "all")
	-- El service publica `scope` en cada fila (created/review/assigned) y `state`
	-- aparte (open/closed). La barra de filtros escribe ids de scope: compararlos
	-- contra `state` dejaba la pestaña vacía al elegir "creados por mí".
	local wanted = if S.activityState ~= "all" then S.activityState elseif scope ~= "" then scope else tostring(prScope)
	if S.activityTab == "actions" then
		return listOf(data.runs)
	end
	local rows = {}
	for _, item in ipairs(source) do
		if wanted == "all" or tostring(item.scope or "") == wanted then
			rows[#rows + 1] = item
		end
	end
	return rows
end

local function activity_view(): any
	local data = feed()
	local tabs = {
		{ id = "prs", label = T("panel.pull_requests") },
		{ id = "issues", label = T("panel.issues") },
		{ id = "actions", label = T("panel.actions") },
	}
	local strip = {}
	for _, tab in ipairs(tabs) do
		local id = tab.id
		strip[#strip + 1] = ui.button({
			text = tab.label,
			controlSize = "sm",
			variant = if S.activityTab == id then "primary" else "ghost",
			selected = S.activityTab == id,
			onClick = function()
				S.activityTab = id
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		})
	end
	strip[#strip + 1] = ui.box({ flexGrow = 1 })
	if S.activityTab ~= "actions" then
		for _, filter in ipairs({
			{ id = "all", label = T("filter.all") },
			{ id = "created", label = T("filter.created_by_me") },
			{ id = "review", label = T("filter.review_requested") },
			{ id = "assigned", label = T("filter.assigned_to_me") },
		}) do
			local id = filter.id
			strip[#strip + 1] = ui.button({
				text = filter.label,
				controlSize = "sm",
				variant = if S.activityState == id then "secondary" else "ghost",
				selected = S.activityState == id,
				onClick = function()
					S.activityState = id
					render()
				end,
			})
		end
	end
	local rows = {}
	local items = activity_rows("")
	for index, item in ipairs(items) do
		local key = "activity-" .. tostring(item.id or item.number or index)
		local alpha = if S.anim.t < 1 then anim.stagger(index, anim.ease_out(S.anim.t), 0.03) else 1
		local title = tostring(item.title or item.name or "")
		if tostring(item.repository or "") ~= "" and cfgBool("activity_repository_emphasis", true) then
			title = tostring(item.repository) .. " · " .. title
		end
		local children = {
			ui.glyph({
				name = if S.activityTab == "actions" then "player-play" else (S.activityTab == "issues" and "circle-dot" or "git-pull-request"),
				size = font(15),
				color = iconColor(false),
				visible = cfgBool("activity_show_type_icons", true),
			}),
			ui.column({ flexGrow = 1, gap = 1, minWidth = 0 }, {
				ui.label({ text = title, fontSize = font(12), fontWeight = "semibold", maxLines = 1, maxWidth = innerWidth() - 220 }),
				ui.label({
					text = tostring(item.branch or item.repository or ""),
					fontSize = font(10),
					color = "on_surface_variant",
					maxLines = 1,
					visible = showSecondary(),
				}),
			}),
		}
		if S.activityTab == "actions" then
			children[#children + 1] = chip(tostring(item.conclusion or item.status or ""), "on_surface_variant")
		else
			children[#children + 1] = chip(string.upper(tostring(item.state or "")), "on_surface_variant", nil)
			if cfgBool("activity_show_status_badges", true) then
				children[#children + 1] = chip(tostring(item.scope or ""), "primary", "primary/0.12")
			end
		end
		children[#children + 1] = ui.label({ text = display_time(tostring(item.updatedAt or item.createdAt or "")), fontSize = font(9), color = "on_surface_variant" })
		rows[#rows + 1] = ui.row({
			key = key,
			gap = 8,
			padding = dashPad(),
			radius = dashRadius(),
			fill = hoverFill(S.hovered == key, false),
			border = cardBorder(S.hovered == key, false),
			borderWidth = 1,
			opacity = alpha,
			align = "center",
			onClick = function()
				send({ action = "open", url = tostring(item.url or "") })
			end,
			onHover = card_hover(key),
		}, children)
	end
	local children = { ui.row({ gap = 4, align = "center" }, strip) }
	local feedError = error_banner(data.activityError)
	if feedError ~= nil then
		children[#children + 1] = feedError
	end
	children[#children + 1] = scroll_list(rows)
	return ui.column({ flexGrow = 1, gap = 6 }, children)
end

-- ── dashboard: following ─────────────────────────────────────────────

local EVENT_KIND = {
	WatchEvent = "stars",
	PushEvent = "pushes",
	IssuesEvent = "issues",
	PullRequestEvent = "pull_requests",
	ReleaseEvent = "releases",
	ForkEvent = "forks",
}

local function ignored(list: any, value: string): boolean
	for _, item in ipairs(listOf(list)) do
		if string.lower(tostring(item)) == string.lower(value) then
			return true
		end
	end
	return false
end

local function event_text(item: any): string
	local eventType = tostring(item.type or "")
	local repo = tostring(item.repo or "")
	if eventType == "WatchEvent" then
		return T("events.starred") .. " · " .. repo
	elseif eventType == "PushEvent" then
		return T("events.pushed") .. " · " .. repo .. " (" .. tostring(item.ref or "") .. ")"
	elseif eventType == "ForkEvent" then
		return T("events.forked") .. " · " .. tostring(item.forkee or repo)
	elseif eventType == "ReleaseEvent" then
		return T("events.release_published") .. " · " .. tostring(item.releaseName or "") .. " · " .. repo
	elseif eventType == "PullRequestEvent" then
		return T("events.pull_request_updated") .. " · " .. tostring(item.prTitle or "") .. " · " .. repo
	elseif eventType == "IssuesEvent" then
		return T("events.issue_updated") .. " · " .. tostring(item.issueTitle or "") .. " · " .. repo
	end
	return eventType .. " · " .. repo
end

local function following_view(): any
	local data = feed()
	local filters = {
		{ id = "all", label = T("filter.all") },
		{ id = "users", label = T("filter.users") },
		{ id = "repositories", label = T("filter.repositories") },
	}
	local strip = {}
	for _, filter in ipairs(filters) do
		local id = filter.id
		strip[#strip + 1] = ui.button({
			text = filter.label,
			controlSize = "sm",
			variant = if S.feedFilter == id then "primary" else "ghost",
			selected = S.feedFilter == id,
			onClick = function()
				S.feedFilter = id
				S.followLimit = 0
				render()
			end,
		})
	end
	strip[#strip + 1] = ui.box({ flexGrow = 1 })
	strip[#strip + 1] = ui.label({ text = T("panel.feed_limited"), fontSize = 9, color = "on_surface_variant" })
	local ignoredUsers = cfg("following_ignored_users", {})
	local ignoredRepos = cfg("following_ignored_repositories", {})
	local hideBots = cfgBool("following_hide_bots", false)
	local includePre = cfgBool("following_include_prereleases", true)
	local rows = {}
	local maxHeight = cfgInt("following_card_max_height", 260, 140, 500)
	local rowHeight = dashPad() * 2 + font(12) + font(10) + cfgInt("following_event_spacing", 5, 2, 12)
	local capacity = math.max(3, math.floor(maxHeight / math.max(1, rowHeight)))
	local limit = math.max(capacity, S.followLimit)
	for index, item in ipairs(listOf(data.events)) do
		local kind = EVENT_KIND[tostring(item.type or "")] or "other"
		local keep = cfgBool("following_show_" .. kind, true) and S.feedFilter ~= "repositories"
		if cfgBool("following_show_other", true) then
			keep = keep or kind == "other"
		end
		if hideBots and tostring(item.actorType or "") == "Bot" then
			keep = false
		end
		if ignored(ignoredUsers, tostring(item.actor or "")) or ignored(ignoredRepos, tostring(item.repo or "")) then
			keep = false
		end
		if keep and #rows < limit then
			local key = "event-" .. tostring(item.id or index)
			local alpha = if S.anim.t < 1 then anim.stagger(index, anim.ease_out(S.anim.t), 0.03) else 1
			rows[#rows + 1] = ui.row({
				key = key,
				gap = 8,
				padding = dashPad(),
				radius = dashRadius(),
				fill = hoverFill(S.hovered == key, false),
				border = cardBorder(S.hovered == key, false),
				borderWidth = 1,
				opacity = alpha,
				align = "center",
				onClick = function()
					send({ action = "open", url = "https://github.com/" .. tostring(item.repo or "") })
				end,
				onHover = card_hover(key),
			}, {
				ui.column({ width = 120, gap = 1 }, {
					ui.label({ text = tostring(item.actor or ""), fontSize = font(11), fontWeight = "semibold", maxLines = 1 }),
					ui.label({ text = tostring(item.type or ""), fontSize = font(9), color = "on_surface_variant", maxLines = 1 }),
				}),
				ui.label({
					text = event_text(item),
					fontSize = font(11),
					maxLines = cfgInt("following_content_lines", 2, 1, 5),
					maxWidth = innerWidth() - 260,
					flexGrow = 1,
					visible = showSecondary(),
				}),
				ui.label({ text = display_time(tostring(item.createdAt or "")), fontSize = font(9), color = "on_surface_variant" }),
			})
		end
	end
	for _, release in ipairs(listOf(data.releases)) do
		if S.feedFilter ~= "users" and (includePre or not release.prerelease) and #rows < limit + 4 then
			local key = "release-" .. tostring(release.url or release.name)
			rows[#rows + 1] = ui.row({
				key = key,
				gap = 8,
				padding = dashPad(),
				radius = dashRadius(),
				fill = hoverFill(S.hovered == key, false),
				border = cardBorder(S.hovered == key, false),
				borderWidth = 1,
				align = "center",
				onClick = function()
					send({ action = "open", url = tostring(release.url or "") })
				end,
				onHover = card_hover(key),
			}, {
				ui.glyph({ name = "tag", size = font(14), color = iconColor(false) }),
				ui.column({ gap = 1, flexGrow = 1, minWidth = 0 }, {
					ui.label({ text = tostring(release.repo or ""), fontSize = font(11), fontWeight = "semibold", maxLines = 1 }),
					ui.label({ text = tostring(release.name or ""), fontSize = font(10), color = "on_surface_variant", maxLines = 1, visible = showSecondary() }),
				}),
				ui.label({ text = display_time(tostring(release.publishedAt or "")), fontSize = font(9), color = "on_surface_variant" }),
			})
		end
	end
	local children = { ui.row({ gap = 4, align = "center" }, strip) }
	local feedError = error_banner(data.followingError)
	if feedError ~= nil then
		children[#children + 1] = feedError
	end
	if #rows >= limit then
		children[#children + 1] = ui.button({
			text = T("panel.show_more"),
			controlSize = "sm",
			variant = "ghost",
			onClick = function()
				S.followLimit = limit + 5
				render()
			end,
		})
	end
	children[#children + 1] = scroll_list(rows)
	return ui.column({ flexGrow = 1, gap = 6 }, children)
end

-- ── dashboard: repositorios ──────────────────────────────────────────

local function repositories_view(): any
	local repos = listOf(meta().repos)
	local rows = {}
	local grid = cfg("repositories_layout", "list") == "grid"
	local reposError = error_banner(meta().reposError)
	local perRow = if grid then 2 else 1
	local width = math.floor((innerWidth() - GAP * (perRow - 1)) / perRow)
	local index = 1
	while index <= #repos do
		local chunk = {}
		for offset = 0, perRow - 1 do
			local repo = repos[index + offset]
			if repo ~= nil then
				local key = "repo-card-" .. tostring(repo.nameWithOwner or index + offset)
				local details = {}
				chunk[#chunk + 1] = ui.column({
					key = key,
					width = width - 8,
					gap = 2,
					padding = dashPad(),
					radius = dashRadius(),
					fill = hoverFill(S.hovered == key, false),
					border = cardBorder(S.hovered == key, false),
					borderWidth = 1,
					onClick = function()
						send({ action = "open", url = "https://github.com/" .. tostring(repo.nameWithOwner or "") })
					end,
					onHover = card_hover(key),
				}, {
					ui.row({ gap = 6, align = "center" }, {
						ui.glyph({ name = "folder-code", size = font(15), color = iconColor(false) }),
						ui.label({ text = tostring(repo.nameWithOwner or ""), fontSize = font(12), fontWeight = "semibold", maxLines = 1, flexGrow = 1 }),
						ui.label({ text = T("panel.private"), fontSize = 9, color = "on_surface_variant", visible = repo.isPrivate == true }),
					}),
					ui.label({
						text = T("panel.updated", { when = display_time(tostring(repo.updatedAt or "")) }),
						fontSize = font(10),
						color = "on_surface_variant",
					}),
					ui.label({ text = table.concat(details, "  ·  "), fontSize = font(9), color = "on_surface_variant", visible = #details > 0 }),
					ui.row({ gap = 4, align = "center" }, {
						ui.button({
							text = T("panel.select"),
							controlSize = "sm",
							variant = if tostring(repo.nameWithOwner or "") == tostring(status().repo or "") then "secondary" else "outline",
							onClick = function()
								send({ action = "set_repo", repo = tostring(repo.nameWithOwner or "") })
								S.tab = "board"
								render()
							end,
						}),
						ui.label({ text = T("panel.private"), fontSize = 9, color = "on_surface_variant", visible = false }),
					}),
				})
			else
				chunk[#chunk + 1] = ui.box({ width = width - 8, opacity = 0 })
			end
		end
		rows[#rows + 1] = ui.row({ key = "repo-row-" .. tostring(index), gap = GAP, align = "stretch" }, chunk)
		index += perRow
	end
	local children = { ui.label({ text = T("panel.repos_hint"), fontSize = font(10), color = "on_surface_variant" }) }
	if reposError ~= nil then
		children[#children + 1] = reposError
	end
	children[#children + 1] = scroll_list(rows)
	return ui.column({ flexGrow = 1, gap = 6 }, children)
end

-- ── cabecera y pestañas ──────────────────────────────────────────────

local TABS = {
	{ id = "board", key = "panel.board", glyph = "layout-kanban", setting = "show_board" },
	{ id = "overview", key = "panel.overview", glyph = "layout-dashboard", setting = "show_overview" },
	{ id = "notifications", key = "panel.notifications", glyph = "bell", setting = "show_notifications" },
	{ id = "activity", key = "panel.activity", glyph = "git-pull-request", setting = "show_activity" },
	{ id = "following", key = "panel.feed", glyph = "rss", setting = "show_following" },
	{ id = "repositories", key = "panel.repositories", glyph = "folder-code", setting = "show_repositories" },
}

local function enabled_tabs(): { any }
	local out = {}
	for _, tab in ipairs(TABS) do
		if cfgBool(tab.setting, true) then
			out[#out + 1] = tab
		end
	end
	return out
end

local function glyph_name(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "brand-github"
end

local function header(): any
	local st = status()
	local busy = st.busy == true
	local repoName = tostring(st.repo or "")
	if repoName == "" then
		repoName = T("panel.pick_repo")
	end
	return ui.row({ gap = 7, align = "center", paddingH = 4 }, {
		ui.glyph({ name = glyph_name(), size = 20, color = "primary" }),
		ui.label({ text = T("panel.title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
		ui.button({
			text = repoName,
			glyph = "folder-code",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.pick_repo"),
			onClick = function()
				S.screen = "repos"
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
		chip(
			if tostring(st.source or "issues") == "project" then T("panel.source_project") else T("panel.source_issues"),
			"on_surface_variant",
			"surface_container/0.55"
		),
		ui.box({ flexGrow = 1 }),
		ui.label({
			text = T("panel.refreshing"),
			fontSize = 9,
			color = theme.warn(),
			visible = busy,
		}),
		ui.row({
			gap = 3,
			align = "center",
			paddingH = 5,
			paddingV = 1,
			radius = 6,
			fill = "primary/0.16",
			visible = (tonumber(st.unread) or 0) > 0,
			tooltip = T("panel.unread"),
		}, {
			dot("primary", 5),
			ui.label({ text = tostring(tonumber(st.unread) or 0), fontSize = 9, color = "primary" }),
		}),
		ui.button({
			glyph = "plus",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.create_title"),
			onClick = function()
				S.screen = "create"
				S.form = { title = "", body = "", labels = tostring(cfg("create_default_labels", "")) }
				render()
			end,
		}),
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
			glyph = "settings",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "close",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

local function tab_bar(): any
	local buttons = {}
	for _, tab in ipairs(enabled_tabs()) do
		local id = tab.id
		local active = S.tab == id and S.screen == "board"
		buttons[#buttons + 1] = ui.button({
			text = T(tab.key),
			glyph = tab.glyph,
			controlSize = "sm",
			variant = if active then "secondary" else "ghost",
			selected = active,
			onClick = function()
				if S.tab == id and S.screen == "board" then
					return
				end
				S.tab = id
				S.screen = "board"
				S.page = 1
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		})
	end
	return ui.row({ gap = 3, align = "center", paddingH = 4 }, buttons)
end

-- ── estado de error / carga ──────────────────────────────────────────

local function status_view(fallback: string?): any
	local st = status()
	local message = fallback or T("status.loading")
	local glyph = "loader"
	if st.auth == "auth_error" then
		message = T("status.auth_error")
		glyph = "alert-triangle"
	elseif tostring(st.error or "") ~= "" then
		message = tostring(st.error)
		glyph = "alert-triangle"
	end
	return ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center", padding = 24 }, {
		ui.glyph({ name = glyph, size = 34, color = "on_surface_variant" }),
		ui.label({ text = message, fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 4, maxWidth = innerWidth() - 80 }),
		ui.row({ gap = 6 }, {
			ui.button({
				text = T("panel.refresh"),
				controlSize = "sm",
				variant = "outline",
				onClick = function()
					send({ action = "refresh" })
				end,
			}),
			ui.button({
				text = T("panel.settings"),
				controlSize = "sm",
				variant = "ghost",
				onClick = function()
					noctalia.openSettings()
				end,
			}),
		}),
	})
end

local function dash_view(): any
	if S.tab == "overview" then
		return overview_view()
	elseif S.tab == "notifications" then
		return notifications_view()
	elseif S.tab == "activity" then
		return activity_view()
	elseif S.tab == "following" then
		return following_view()
	end
	return repositories_view()
end

local function body(): any
	if S.screen == "repos" then
		return repos_view()
	elseif S.screen == "create" then
		return create_view()
	end
	local board = snap("board", BOARD_KEY)
	local st = status()
	-- Con tarjetas en cache el tablero se sigue mostrando: el error de auth va
	-- como banner arriba, no reemplaza el contenido (el original hacía lo mismo
	-- con `stale`).
	if st.auth == "auth_error" and #listOf(board.columns) == 0 then
		return status_view()
	end
	if S.tab == "board" then
		if tostring(board.note or "") == "no_repo" then
			return status_view(T("status.no_repo"))
		end
		if tostring(board.note or "") == "no_project" then
			return status_view(T("status.no_project"))
		end
		if #listOf(board.columns) == 0 and (tonumber(st.cards) or 0) == 0 and st.busy == true then
			return status_view()
		end
		return board_rows()
	end
	return dash_view()
end

-- ── render ───────────────────────────────────────────────────────────

local lastTrace = ""

-- Traza de datos por pestaña. Una línea por cambio de estado: es la prueba de
-- que cada vista recibe su dataset y no un `{}` silencioso. Barato (sólo loguea
-- cuando cambia) y sin efecto en el dibujo.
local function view_stats(): string
	local f = feed()
	local m = meta()
	local calendar = f.calendar
	local weeks = type(calendar) == "table" and #listOf(calendar.weeks) or 0
	local viewer = type(m.viewer) == "table" and m.viewer or {}
	return "notif=" .. tostring(#listOf(f.notifications))
		.. " unread=" .. tostring(tonumber(f.unread) or 0)
		.. " prs=" .. tostring(#listOf(f.prs))
		.. " issues=" .. tostring(#listOf(f.issues))
		.. " runs=" .. tostring(#listOf(f.runs))
		.. " events=" .. tostring(#listOf(f.events))
		.. " releases=" .. tostring(#listOf(f.releases))
		.. " weeks=" .. tostring(weeks)
		.. " contrib=" .. tostring(type(calendar) == "table" and tonumber(calendar.total) or 0)
		.. " repos=" .. tostring(#listOf(m.repos))
		.. " projects=" .. tostring(#listOf(m.projects))
		.. " viewer=" .. tostring(viewer.login or "")
end

function render(): ()
	S.renderStamp += 1
	local st = status()
	local board = snap("board", BOARD_KEY)
	local trace = tostring(#listOf(board.columns)) .. " cols/" .. tostring(board.total or 0) .. " cards/"
		.. S.tab .. "/" .. S.screen .. "/" .. tostring(S.search) .. "/" .. tostring(st.auth)
		.. " repo=" .. tostring(st.repo or "")
		.. " | " .. view_stats()
	if trace ~= lastTrace then
		lastTrace = trace
		noctalia.log("[b3l0w-kanban] " .. trace)
	end
	local children = { header(), tab_bar() }
	local error = tostring(st.error or "")
	if error ~= "" and st.auth == "auth_error" then
		children[#children + 1] = ui.row({ gap = 6, align = "center", padding = 6, radius = 8, fill = "warning/0.15" }, {
			ui.glyph({ name = "alert-triangle", size = 13, color = theme.warn() }),
			ui.label({ text = T("status.auth_banner", { error = error }), fontSize = 10, color = "on_surface_variant", maxLines = 2, maxWidth = innerWidth() - 60 }),
		})
	end
	if S.tab == "board" and S.screen == "board" then
		children[#children + 1] = filter_bar()
	end
	local main = body()
	children[#children + 1] = main
	panel.render(ui.column({
		width = panelWidth(),
		height = panelHeight(),
		gap = 4,
		padding = 6,
	}, children))
end

function onFrameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	S.anim.t = math.min(1, S.anim.t + (tonumber(delta) or 16) / (S.anim.ms or 220))
	render()
end

function onOpen(_context: any): ()
	lastTrace = ""
	SNAP.status = noctalia.state.get(STATUS_KEY)
	SNAP.board = noctalia.state.get(BOARD_KEY)
	SNAP.meta = noctalia.state.get(META_KEY)
	SNAP.feed = noctalia.state.get(FEED_KEY)
	local orden = noctalia.state.get(SCREEN_KEY)
	local ordered = false
	if type(orden) == "table" then
		for _, tab in ipairs(TABS) do
			if orden.tab == tab.id then
				S.tab = tab.id
				ordered = true
			end
		end
	end
	if not ordered then
		local defaultTab = tostring(cfg("default_dashboard", "board"))
		for _, tab in ipairs(enabled_tabs()) do
			if tab.id == defaultTab then
				S.tab = defaultTab
			end
		end
	end
	S.screen = "board"
	S.renderStamp = 0
	S.cacheStamp = -1
	S.anim.t = if prefs.animations() then 0 else 1
	panel.setNeedsFrameTick(true)
	render()
	-- Un panel recién abierto con el estado viejo muestra un tablero vacío:
	-- pedir refresco sólo si el service no está ocupado.
	if status().busy ~= true and (tonumber(snap("board", BOARD_KEY).at) or 0) == 0 then
		send({ action = "refresh" })
	end
end

function onClose(): ()
	S.hovered = nil
	S.screen = "board"
	panel.setNeedsFrameTick(false)
end

function onKey(chord: string, pressed: boolean): ()
	if not pressed then
		return
	end
	local tabs = enabled_tabs()
	if #tabs == 0 then
		return
	end
	local index = 1
	for position, tab in ipairs(tabs) do
		if tab.id == S.tab then
			index = position
		end
	end
	if chord == "Left" or chord == "Right" then
		local delta = if chord == "Right" then 1 else -1
		S.tab = tabs[((index - 1 + delta) % #tabs) + 1].id
		S.screen = "board"
		S.page = 1
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "g" then
		S.tab = tabs[(index % #tabs) + 1].id
		S.screen = "board"
		S.anim.t = if prefs.animations() then 0 else 1
		render()
	elseif chord == "Prior" or chord == "Next" then
		S.page = if chord == "Next" then S.page + 1 else math.max(1, S.page - 1)
		render()
	end
end

-- ── suscripciones ────────────────────────────────────────────────────

noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = if type(value) == "table" then value else {}
	render()
end)

noctalia.state.watch(BOARD_KEY, function(value: any)
	SNAP.board = if type(value) == "table" then value else {}
	S.cacheStamp = -1
	render()
end)

noctalia.state.watch(META_KEY, function(value: any)
	SNAP.meta = if type(value) == "table" then value else {}
	render()
end)

noctalia.state.watch(FEED_KEY, function(value: any)
	SNAP.feed = if type(value) == "table" then value else {}
	render()
end)

noctalia.state.watch(SCREEN_KEY, function(value: any)
	if type(value) ~= "table" then
		return
	end
	if type(value.tab) == "string" and value.tab ~= "" then
		S.tab = value.tab
		S.screen = "board"
	end
	if type(value.url) == "string" and value.url ~= "" then
		noctalia.log("[b3l0w-kanban] issue creada en " .. value.url)
	end
	render()
end)

render()

return { S = S, activity_rows = activity_rows, card_matches = card_matches, filter_bar = filter_bar }
end
