--!nonstrict
-- Panel de b3l0w/audit: triage de vulnerabilidades + estado de actualizaciones.
--
-- Dos pestañas:
--   Vulnerabilidades — avisos de arch-audit con severidad, paquete instalado,
--                      versión que lo arregla y CVEs, filtrable y paginado.
--   Actualizaciones  — Noctalia, Umbriel y el CLI b3l0w, cada uno con su
--                      actualización confirmada por ítem.
--
-- El panel no lanza procesos: publica requests por estado y el service los
-- ejecuta. Sólo la copia al portapapeles y el toggle del panel son locales.

local anim = require("./lib/anim.luau")
local audit = require("./lib/audit.luau")
local prefs = require("./lib/prefs.luau")
local layout = require("./lib/layout.luau")
local theme = require("./lib/theme.luau")

local M: any = {}

local T = noctalia.tr

local STATE_KEY = "b3l0w_audit_state"
local UPDATES_KEY = "b3l0w_audit_updates"
local STATUS_KEY = "b3l0w_audit_status"
local REQUEST_KEY = "b3l0w_audit_request"
local SCREEN_KEY = "b3l0w_audit_screen"

local FILTERS = { "all", "critical", "high", "medium", "low", "unknown" }

local TABS = {
	{ value = "vulns", key = "panel.tab.vulns" },
	{ value = "updates", key = "panel.tab.updates" },
}

-- El host es dueño del tamaño: `panel` (attached) y `float` son dos entries
-- distintos del manifest. El MODO lo pasa el entry, no el setting: el
-- setting `panel_mode` elige qué entry abre el WIDGET, pero si el usuario
-- abre el otro desde el launcher, el código calculaba los anchos sobre el
-- panel equivocado y todo se pasaba del borde.
local MODE = "compact"

local function panelWidth()
	-- Los valores salen del manifest (`plugin.toml`): 560x640 y 1200x860.
	-- Antes el código tenía 520 y 1160 (valores viejos) y los anchos
	-- calculados quedaban 40 px más angostos que el panel real.
	return if MODE == "float" then 1200 else 560
end

local function panelHeight()
	return if MODE == "float" then 860 else 640
end

-- El cromo (cabecera + pestañas + pie) por partes: cambia con la vista.
local function chromeH(): number
	return layout.chrome({
		54, -- cabecera: título + resumen
		36, -- pestañas
		34, -- pie
	})
end

local function listHeight()
	return math.max(200, panelHeight() - chromeH())
end

local ROW_H_BY_DENSITY = { compact = 96, cozy = 104, comfortable = 114 }
local UPD_H_BY_DENSITY = { compact = 44, cozy = 50, comfortable = 56 }

local S = {
	tab = "vulns",
	page = 1,
	filter = "all",
	fixOnly = false,
	confirm = nil,
	flash = nil,
	flashAt = 0,
	anim = { t = 1, from = 0, to = 0, ms = 220 },
	requests = 0,
}

local SNAP = { state = nil, updates = nil, status = nil }

local function inner(): number
	return panelWidth() - 16
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

local function rowWidth(): number
	-- el column raíz tiene padding 6 por lado: una fila más ancha se recorta
	return inner() - 12
end

local function rowHeight(): number
	return ROW_H_BY_DENSITY[prefs.density()] or 100
end

local function updRowHeight(): number
	return UPD_H_BY_DENSITY[prefs.density()] or 50
end

-- La fila de filtro y los banners viven dentro de `listHeight`: hay que
-- descontarlos o la última fila de la página se recorta contra el borde.
local function pageSize(): number
	return math.max(2, math.floor((listHeight() - 46) / (rowHeight() + 6)))
end

-- El nonce lleva siempre un contador: dos acciones en el mismo milisegundo
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

local function upd()
	return snapshot("updates", UPDATES_KEY)
end

local function status()
	return snapshot("status", STATUS_KEY)
end

local function glyphName(): string
	local value = noctalia.getConfig("glyph")
	if type(value) == "string" and value ~= "" then
		return value
	end
	return "shield-exclamation"
end

local function checkedAge(): string
	local state = st()
	local stamp = tonumber(state.checkedAtMs)
	if stamp == nil then
		return T("time.never")
	end
	return audit.age_text(stamp, T, noctalia.trp)
end

local function severityLabel(severity: string): string
	return T("severity." .. severity)
end

local function installedText(item: any): string
	local parts = {}
	for _, entry in ipairs(item.installed or {}) do
		if type(entry.version) == "string" and entry.version ~= "" then
			table.insert(parts, entry.name .. " " .. entry.version)
		else
			table.insert(parts, tostring(entry.name))
		end
	end
	if #parts == 0 then
		for _, name in ipairs(item.packages or {}) do
			table.insert(parts, tostring(name))
		end
	end
	if #parts == 0 then
		return tostring(item.id or "")
	end
	return table.concat(parts, ", ")
end

local function cveText(item: any): string
	local issues = item.issues or {}
	if #issues == 0 then
		return T("panel.no_cves")
	end
	local shown = {}
	for index = 1, math.min(#issues, 3) do
		shown[index] = tostring(issues[index])
	end
	local text = table.concat(shown, ", ")
	if #issues > #shown then
		text = text .. " +" .. tostring(#issues - #shown)
	end
	return text
end

local function statusLabel(value: any): string
	local key = tostring(value or ""):lower():gsub("%s+", "_")
	local translationKey = "status." .. key
	local text = T(translationKey)
	if text == translationKey then
		return tostring(value or "")
	end
	return text
end

local function copied(text: string)
	noctalia.copyToClipboard(text, "text/plain")
	S.flash = T("panel.copied")
	S.flashAt = os.time()
	render()
end

local function openAdvisory(item: any)
	if type(item.url) ~= "string" or item.url == "" then
		return
	end
	noctalia.runAsync({ "xdg-open", item.url })
end

-- Una fila con borde y texto (ui.box es hoja: los hijos se dropean).
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

-- ── cabecera y pestañas ──────────────────────────────────────────────

local function header(): any
	local state = st()
	local bus = status()
	local subtitleColor = theme.muted()
	local total = tonumber(state.total) or 0
	if state.binaryMissing == true or (state.err ~= nil and state.phase ~= "checking") then
		subtitleColor = theme.danger()
	end

	local subtitle
	if bus.busy == true then
		subtitle = T("panel.working")
	elseif total > 0 then
		subtitle = noctalia.trp("count.advisory", total)
	elseif state.checkedAtMs ~= nil then
		subtitle = T("panel.clean")
	else
		subtitle = T("panel.never_checked")
	end

	return ui.row({ gap = 8, padding = 6, align = "center" }, {
		ui.glyph({ name = glyphName(), size = 18, color = if total > 0 then audit.severity_color(state.severity) else "on_surface" }),
		ui.label({ text = T("panel.title"), fontSize = 16, fontWeight = "semibold" }),
		ui.label({ text = layout.ellipsis(subtitle, 46), fontSize = 11, color = subtitleColor, maxLines = 1 }),
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

	local state = st()
	local updates = upd()
	local counts = state.counts or {}
	local parts = {}
	for _, severity in ipairs(audit.SEVERITIES) do
		local count = tonumber(counts[severity]) or 0
		if count > 0 then
			table.insert(parts, tostring(count) .. " " .. severityLabel(severity):lower())
		end
	end
	local vulnText = if #parts > 0 then table.concat(parts, " · ") else T("panel.clean")
	table.insert(buttons, ui.label({
		text = vulnText,
		fontSize = 10,
		color = theme.dim(),
		maxLines = 1,
	}))
	table.insert(buttons, chip(noctalia.trp("count.pending", tonumber(updates.total) or 0), theme.muted()))

	return ui.row({ gap = 8, paddingH = 6, align = "center" }, buttons)
end

-- Barra de acción: "Actualizar todo" siempre visible, con el resumen al lado.
local function actionBar(): any
	local updates = upd()
	local pending = tonumber(updates.total) or 0
	local cliStale = type(updates.cli) == "table" and updates.cli.stale == true
	local hint = T("panel.update_all_hint")
	if cliStale then
		hint = T("panel.update_all_hint_stale")
	end
	return ui.row({ gap = 8, paddingH = 6, align = "center" }, {
		ui.button({
			key = "update-all",
			text = T("panel.update_all"),
			glyph = "download",
			controlSize = "sm",
			variant = "primary",
			tooltip = T("panel.update_all_tip"),
			enabled = status().busy ~= true,
			onClick = function()
				send({ action = "update_all" })
			end,
		}),
		ui.label({
			text = layout.ellipsis(hint, 50),
			fontSize = 10,
			color = if pending > 0 or cliStale then theme.warn() else theme.dim(),
			maxLines = 1,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.label({
			text = noctalia.trp("count.pending", pending),
			fontSize = 10,
			color = theme.dim(),
		}),
	})
end

-- ── vulnerabilidades ─────────────────────────────────────────────────

local function vulnRow(item: any, index: number): any
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.04) else 1
	local color = audit.severity_color(item.severity)
	local fixText = if type(item.fixed) == "string"
		then T("panel.fixed", { version = item.fixed })
		else T("panel.no_fix")

	return ui.column({ align = "stretch", 
		key = "adv-" .. tostring(item.id),
		width = layout.row(rowWidth()),
		height = rowHeight(),
		gap = 3,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.box({ width = 6, height = 14, radius = 3, fill = color }),
			ui.label({
				text = installedText(item),
				fontSize = 13,
				fontWeight = "semibold",
				maxLines = 1,
				flexGrow = 1,
			}),
			chip(severityLabel(item.severity), color),
			ui.label({ text = tostring(item.id or ""), fontSize = 10, color = theme.dim() }),
		}),
		ui.label({
			text = statusLabel(item.status) .. " · " .. tostring(item.type or ""),
			fontSize = 11,
			color = theme.muted(),
			maxLines = 1,
		}),
		ui.label({
			text = fixText,
			fontSize = 11,
			color = if type(item.fixed) == "string" then theme.ok() else theme.warn(),
		}),
		ui.row({ gap = 6, align = "center" }, {
			ui.label({
				text = T("panel.cves") .. ": " .. cveText(item),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
				flexGrow = 1,
			}),
			ui.button({
				glyph = "external-link",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.open_advisory"),
				onClick = function()
					openAdvisory(item)
				end,
			}),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.copy_upgrade"),
				onClick = function()
					copied(audit.upgrade_command())
				end,
			}),
		}),
	})
end

local function vulnList(): any
	local state = st()
	local children = {}

	if state.binaryMissing == true then
		table.insert(children, ui.row({
			gap = 8,
			padding = 8,
			align = "center",
			fill = "#3a2a2a",
			radius = 8,
		}, {
			ui.glyph({ name = "alert-triangle", size = 16, color = theme.danger() }),
			ui.label({ text = T("panel.missing"), fontSize = 11, color = theme.danger(), flexGrow = 1, maxLines = 2 }),
			ui.button({
				text = T("panel.copy_install"),
				controlSize = "sm",
				variant = "outline",
				onClick = function()
					copied("sudo pacman -S arch-audit")
				end,
			}),
		}))
	end

	if state.err ~= nil and state.binaryMissing ~= true then
		table.insert(children, ui.row({
			gap = 8,
			padding = 8,
			align = "center",
			fill = "#3a3226",
			radius = 8,
		}, {
			ui.glyph({ name = "alert-triangle", size = 16, color = theme.warn() }),
			ui.label({ text = tostring(state.err), fontSize = 11, color = theme.warn(), flexGrow = 1, maxLines = 2 }),
		}))
	end

	-- filtro por severidad + sólo con versión que lo arregla
	local options = {}
	for _, key in ipairs(FILTERS) do
		local count
		if key == "all" then
			count = tonumber(state.total) or 0
		else
			count = tonumber((state.counts or {})[key]) or 0
		end
		local label = if key == "all" then T("severity.all") else severityLabel(key)
		table.insert(options, label .. " (" .. tostring(count) .. ")")
	end

	local index = 0
	for position, key in ipairs(FILTERS) do
		if key == S.filter then
			index = position - 1
		end
	end

	table.insert(children, ui.row({ gap = 8, paddingH = 6, align = "center" }, {
		ui.select({
			key = "severity-filter",
			options = options,
			selectedIndex = index,
			flexGrow = 1,
			onChange = function(value)
				local position = (tonumber(value) or 0) + 1
				S.filter = FILTERS[position] or "all"
				S.page = 1
				render()
			end,
		}),
		ui.button({
			key = "fix-only",
			text = T("panel.fix_only"),
			glyph = "download",
			controlSize = "sm",
			selected = S.fixOnly,
			variant = if S.fixOnly then "primary" else "ghost",
			tooltip = T("panel.fix_only_tip"),
			onClick = function()
				S.fixOnly = not S.fixOnly
				S.page = 1
				render()
			end,
		}),
	}))

	local filtered = audit.filter(state.items or {}, S.filter, S.fixOnly)
	if #filtered == 0 then
		table.insert(children, ui.column({ height = listHeight(), align = "center", justify = "center", gap = 6 }, {
			ui.glyph({ name = if (tonumber(state.total) or 0) > 0 then "filter" else "shield-check", size = 28, color = theme.dim() }),
			ui.label({
				text = if (tonumber(state.total) or 0) > 0 then T("panel.filter_empty") else T("panel.empty"),
				fontSize = 12,
				color = theme.muted(),
				textAlign = "center",
				maxLines = 2,
			}),
		}))
		return ui.column({ align = "stretch",  gap = 6 }, children)
	end

	local perPage = pageSize()
	if state.binaryMissing == true or state.err ~= nil then
		perPage = math.max(2, perPage - 1)
	end
	local pages = math.max(1, math.ceil(#filtered / perPage))
	-- Acotar SIN mutar S.page: mutarlo durante el render compite con el
	-- reset de página al cambiar de vista y deja la paginación apuntando a
	-- una página inexistente (la lista se vacía sin aviso).
	local page = math.max(1, math.min(S.page, pages))
	local first = (page - 1) * perPage + 1
	local last = math.min(#filtered, first + perPage - 1)

	local rows = {}
	for position = first, last do
		table.insert(rows, vulnRow(filtered[position], position - first + 1))
	end

	table.insert(children, ui.scroll(layout.merge({
			width = layout.row(rowWidth()),
		key = "vuln-scroll",
		gap = 6,
		paddingH = 2,
		align = "center",
		
	}, layout.scrollExtra(math.max(1, #rows) * (rowHeight() + 6) - 6)), rows))

	table.insert(children, ui.row({ gap = 8, paddingH = 6, align = "center", justify = "center" }, {
		ui.button({
			glyph = "chevron-left",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page > 1,
			onClick = function()
				S.page = math.max(1, S.page - 1)
				S.confirm = nil
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
		ui.label({
			text = T("panel.page_of", {
				page = tostring(S.page),
				pages = tostring(pages),
				total = tostring(#filtered),
			}),
			fontSize = 11,
			color = theme.muted(),
		}),
		ui.button({
			glyph = "chevron-right",
			controlSize = "sm",
			variant = "ghost",
			enabled = S.page < pages,
			onClick = function()
				S.page = math.min(pages, S.page + 1)
				S.confirm = nil
				S.anim.t = if prefs.animations() then 0 else 1
				render()
			end,
		}),
	}))

	return ui.column({ align = "stretch",  gap = 6 }, children)
end

-- ── actualizaciones ──────────────────────────────────────────────────

-- Filas de paquete que entran sin recortar: el bloque de CLI, las tres
-- cabeceras de sección y el pie consumen un alto fijo del cuerpo.
local function rowBudget(): number
	local usable = listHeight() - 120 - (updRowHeight() + 30) - 24
	return math.max(2, math.floor(usable / (updRowHeight() + 4)))
end

local function updateRow(row: any, group: string): any
	local id = "pkg:" .. group .. ":" .. tostring(row.name)
	local confirming = S.confirm == id
	local width = rowWidth()
	return ui.row({
		key = id,
		width = width,
		height = updRowHeight(),
		gap = 8,
		paddingH = 10,
		paddingV = 6,
		align = "center",
		fill = theme.surface(),
		radius = 8,
	}, {
		ui.column({ gap = 1, flexGrow = 1, minWidth = 0, align = "start" }, {
			ui.label({ text = layout.ellipsis(tostring(row.name), 44), fontSize = 12, fontWeight = "semibold", maxLines = 1 }),
			ui.label({
				text = tostring(row.from) .. "  →  " .. tostring(row.to),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
			}),
		}),
		ui.button({
			text = if confirming then T("panel.confirm") else T("panel.update_one"),
			controlSize = "sm",
			variant = if confirming then "primary" else "ghost",
			tooltip = T("panel.update_one_tip"),
			onClick = function()
				if S.confirm ~= id then
					S.confirm = id
					render()
					return
				end
				S.confirm = nil
				send({ action = "update_pkg", name = tostring(row.name) })
				render()
			end,
		}),
		ui.button({
			glyph = "copy",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.copy_pkg"),
			onClick = function()
				copied("sudo pacman -S " .. tostring(row.name))
			end,
		}),
	})
end

local function section(title: string, subtitle: string, rows: any, pending: number, limit: number): any
	local children = {
		ui.row({ gap = 8, paddingH = 10, align = "center" }, {
			ui.label({ text = layout.ellipsis(title, 40), fontSize = 13, fontWeight = "semibold" }),
			ui.label({ text = layout.ellipsis(subtitle, 46), fontSize = 10, color = theme.dim(), maxLines = 1, flexGrow = 1 }),
			chip(noctalia.trp("count.pending", pending), if pending > 0 then theme.warn() else theme.ok()),
		}),
	}
	if pending == 0 then
		table.insert(children, ui.label({ text = T("panel.up_to_date"), fontSize = 11, color = theme.ok() }))
		return ui.column({ align = "stretch",  gap = 4 }, children)
	end
	local shown = 0
	for position, row in ipairs(rows) do
		if position > limit then
			break
		end
		shown = position
		table.insert(children, row)
	end
	if shown < pending then
		local rest = pending - shown
		table.insert(children, ui.row({ paddingH = 10, align = "center", gap = 6 }, {
			ui.label({ text = T("panel.more_rows", { count = tostring(rest) }), fontSize = 10, color = theme.dim() }),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.copy_upgrade"),
				onClick = function()
					copied(audit.upgrade_command())
				end,
			}),
		}))
	end
	return ui.column({ align = "stretch",  gap = 4 }, children)
end

local function cliSection(): any
	local updates = upd()
	local cli = type(updates.cli) == "table" and updates.cli or {}
	local stale = cli.stale == true
	local id = "cli"
	local confirming = S.confirm == id
	local width = rowWidth()

	local binAge = T("time.never")
	if (tonumber(cli.binMtime) or 0) > 0 then
		binAge = audit.age_text((tonumber(cli.binMtime) or 0) * 1000, T, noctalia.trp)
	end
	local sourceAge = T("time.never")
	if (tonumber(cli.newestMtime) or 0) > 0 then
		sourceAge = audit.age_text((tonumber(cli.newestMtime) or 0) * 1000, T, noctalia.trp)
	end

	return ui.column({ align = "stretch",  gap = 4 }, {
		ui.row({ gap = 8, paddingH = 10, align = "center" }, {
			ui.label({ text = T("panel.cli.title"), fontSize = 13, fontWeight = "semibold" }),
			ui.label({ text = tostring(cli.bin or ""), fontSize = 10, color = theme.dim(), maxLines = 1, flexGrow = 1 }),
			chip(if stale then T("panel.cli.stale") else T("panel.cli.fresh"), if stale then theme.warn() else theme.ok()),
		}),
		ui.row({
			key = "cli-row",
			width = width,
			height = updRowHeight() + 6,
			gap = 8,
			paddingH = 10,
			paddingV = 6,
			align = "center",
			fill = theme.surface(),
			radius = 8,
		}, {
			ui.column({ gap = 1, flexGrow = 1, minWidth = 0, align = "start" }, {
				ui.label({
					text = T("panel.cli.ages", { binary = binAge, source = sourceAge }),
					fontSize = 11,
					color = theme.muted(),
					maxLines = 1,
				}),
				ui.label({
					text = T("panel.cli.source", { path = tostring(cli.newestPath or "—") }),
					fontSize = 10,
					color = theme.dim(),
					maxLines = 1,
				}),
			}),
			ui.button({
				text = if confirming then T("panel.confirm") else T("panel.cli.rebuild"),
				controlSize = "sm",
				variant = if confirming then "primary" else "ghost",
				enabled = stale,
				tooltip = T("panel.cli.rebuild_tip"),
				onClick = function()
					if not stale then
						return
					end
					if S.confirm ~= id then
						S.confirm = id
						render()
						return
					end
					S.confirm = nil
					send({ action = "update_cli" })
					render()
				end,
			}),
			ui.button({
				glyph = "copy",
				controlSize = "sm",
				variant = "ghost",
				tooltip = T("panel.cli.copy"),
				onClick = function()
					copied("cd ~/Documents/Github/b3l0w && go build -o ~/.local/bin/b3l0w ./cmd/b3l0w")
				end,
			}),
		}),
	})
end

local function updatesView(): any
	local updates = upd()
	local noctaliaInfo = type(updates.noctalia) == "table" and updates.noctalia or {}
	local umbrielInfo = type(updates.umbriel) == "table" and updates.umbriel or {}
	local systemInfo = type(updates.system) == "table" and updates.system or {}

	local pendingN = tonumber(noctaliaInfo.pending) or 0
	local pendingU = tonumber(umbrielInfo.pending) or 0
	local pendingS = tonumber(systemInfo.pending) or 0

	-- Reparte el alto disponible en partes iguales entre las tres secciones:
	-- una lista larga de paquetes del sistema no puede tapar Noctalia/Umbriel
	-- ni el bloque del CLI, y el sobrante se resume en "+N más".
	local alloc = { n = 0, u = 0, s = 0 }
	local remaining = rowBudget()
	local advanced = true
	while remaining > 0 and advanced do
		advanced = false
		if alloc.n < pendingN and remaining > 0 then
			alloc.n = alloc.n + 1
			remaining = remaining - 1
			advanced = true
		end
		if alloc.u < pendingU and remaining > 0 then
			alloc.u = alloc.u + 1
			remaining = remaining - 1
			advanced = true
		end
		if alloc.s < pendingS and remaining > 0 then
			alloc.s = alloc.s + 1
			remaining = remaining - 1
			advanced = true
		end
	end

	local nRows = {}
	for index = 1, math.min(#(noctaliaInfo.rows or {}), alloc.n) do
		table.insert(nRows, updateRow(noctaliaInfo.rows[index], "noctalia"))
	end
	local uRows = {}
	for index = 1, math.min(#(umbrielInfo.rows or {}), alloc.u) do
		table.insert(uRows, updateRow(umbrielInfo.rows[index], "umbriel"))
	end
	local sRows = {}
	for index = 1, math.min(#(systemInfo.rows or {}), alloc.s) do
		table.insert(sRows, updateRow(systemInfo.rows[index], "system"))
	end

	local noctaliaSub = T("panel.noctalia.sub", {
		installed = tostring(noctaliaInfo.installed or "—"),
		version = tostring(noctaliaInfo.version or "—"),
	})
	local umbrielSub = T("panel.umbriel.sub", {
		installed = tostring(umbrielInfo.installed or "—"),
		portal = tostring(umbrielInfo.portal or "—"),
	})
	local systemSub = T("panel.system.sub", { source = tostring(updates.source or "pacman -Qu") })

	local children = {
		section(T("panel.noctalia.title"), noctaliaSub, nRows, pendingN, alloc.n),
		section(T("panel.umbriel.title"), umbrielSub, uRows, pendingU, alloc.u),
		section(T("panel.system.title"), systemSub, sRows, pendingS, alloc.s),
		cliSection(),
	}

	local at = tonumber(updates.at)
	local stampText = if at ~= nil then audit.age_text(at, T, noctalia.trp) else T("time.never")
	table.insert(children, ui.label({
		text = T("panel.updates.at", {
			age = stampText,
			total = tostring(tonumber(updates.total) or 0),
			source = tostring(updates.source or "pacman -Qu"),
		}),
		fontSize = 10,
		color = theme.dim(),
	}))

	return ui.column({ gap = 8, height = listHeight(), align = "stretch" }, children)
end

-- ── pie ──────────────────────────────────────────────────────────────

local function footer(): any
	local state = st()
	local children = {
		ui.label({
			text = T("panel.checked", { age = checkedAge() }),
			fontSize = 10,
			color = theme.dim(),
			flexGrow = 1,
		}),
	}
	local ignored = tonumber(state.ignoredCount) or 0
	if ignored > 0 then
		table.insert(children, ui.label({
			text = noctalia.trp("count.ignored", ignored),
			fontSize = 10,
			color = theme.dim(),
		}))
	end
	if S.flash ~= nil then
		table.insert(children, ui.label({ text = S.flash, fontSize = 10, color = theme.ok() }))
	end
	if status().busy == true then
		table.insert(children, ui.label({ text = T("panel.working"), fontSize = 10, color = theme.warn() }))
	end
	return ui.row({ gap = 8, paddingH = 6, align = "center" }, children)
end

-- ── render ───────────────────────────────────────────────────────────

local lastTrace = ""

function render()
	local state = st()
	local updates = upd()
	local trace = tostring(S.tab)
		.. "/vulns=" .. tostring(tonumber(state.total) or 0)
		.. "/phase=" .. tostring(state.phase)
		.. "/updates=" .. tostring(tonumber(updates.total) or 0)
		.. "/noctalia=" .. tostring(tonumber((updates.noctalia or {}).pending) or 0)
		.. "/umbriel=" .. tostring(tonumber((updates.umbriel or {}).pending) or 0)
		.. "/cli_stale=" .. tostring(type(updates.cli) == "table" and updates.cli.stale == true)
		.. "/page=" .. tostring(S.page)
		.. "/filter=" .. tostring(S.filter)
		.. "/mode=" .. prefs.panel_mode()
		.. "/density=" .. prefs.density()
		-- el texto traducido va en la traza: delata una clave de i18n que no
		-- resuelve (se vería el key crudo) sin necesidad de mirar la pantalla
		.. "/label=" .. noctalia.trp("count.advisory", tonumber(state.total) or 0)
	if trace ~= lastTrace then
		lastTrace = trace
		noctalia.log("[b3l0w-audit] " .. trace)
	end

	local body: any
	if S.tab == "updates" then
		body = updatesView()
	else
		body = vulnList()
	end

	panel.render(ui.column({
		width = layout.width(inner()),
		height = panelHeight(),
		gap = 4,
		padding = 6,
		align = "stretch",
	}, {
		header(),
		tabs(),
		actionBar(),
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
	S.anim.t = math.min(1, S.anim.t + (tonumber(delta) or 16) / (S.anim.ms or 220))
	render()
end

function M.open(_context: any, mode: string?)
	-- El entry dice qué panel es: el host no lo pasa por el contexto.
	if mode == "compact" or mode == "float" then
		MODE = mode
	end
	lastTrace = ""
	SNAP.state = noctalia.state.get(STATE_KEY)
	SNAP.updates = noctalia.state.get(UPDATES_KEY)
	SNAP.status = noctalia.state.get(STATUS_KEY)
	S.confirm = nil
	S.flash = nil

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
	S.tab = "vulns"
	S.page = 1
	S.confirm = nil
	S.flash = nil
end

function onKey(chord: string, pressed: boolean)
	if not pressed then
		return
	end
	if chord == "Prior" or chord == "Next" then
		local total = #audit.filter(st().items or {}, S.filter, S.fixOnly)
		local pages = math.max(1, math.ceil(total / pageSize()))
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

noctalia.state.watch(UPDATES_KEY, function(value: any)
	SNAP.updates = value
	render()
end)

noctalia.state.watch(STATUS_KEY, function(value: any)
	SNAP.status = value
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
SNAP.updates = noctalia.state.get(UPDATES_KEY)
SNAP.status = noctalia.state.get(STATUS_KEY)

-- El host llama a `onConfigChanged` cuando cambia un ajuste: los entries
-- finos lo reenvían acá (si no, `app.configChanged` sería nil).
function M.configChanged(): ()
	render()
end

return M
