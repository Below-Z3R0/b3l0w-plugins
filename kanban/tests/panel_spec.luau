-- Harness de plomería: carga panel.luau con stubs de host y ejercita las
-- funciones que deciden QUÉ datos se dibujan (no cómo).
--
-- El panel no exporta nada: se carga el archivo real y se le agrega un `return`
-- al final para alcanzar los locales. Así el spec corre contra el código que se
-- shipea y no contra una copia.
--
--   luau tests/panel_spec.luau        (desde la raíz del plugin)

local ROOT = "./"

-- ── stubs del host ───────────────────────────────────────────────────

local LOG = {}
local STATE = {}

local CONFIG = {
	appearance_font_scale = 100,
	appearance_density = "standard",
	board_cards_per_column = 25,
	board_stale_days = 7,
	pr_default_filter = "all",
	issue_default_filter = "all",
	default_dashboard = "board",
}

local function cfg(key: string, fallback: any): any
	local value = CONFIG[key]
	return if value == nil then fallback else value
end

-- Cada nodo de UI es una tabla opaca: el spec sólo mira datos.
local UI = {}
setmetatable(UI, {
	__index = function(_, kind)
		return function(_props, children) return { kind = kind, children = children } end
	end,
})

local NOCTALIA = {
	getConfig = cfg,
	tr = function(key: string, args: any)
		if type(args) == "table" then
			for _, value in pairs(args) do
				key = key .. " " .. tostring(value)
			end
		end
		return key
	end,
	log = function(line: string) LOG[#LOG + 1] = line end,
	formatTime = function() return "time" end,
	getColor = function() return "#ffffff" end,
	isDarkMode = function() return true end,
	pluginDataDir = function() return "." end,
	notify = function() end,
	notifyError = function() end,
	openSettings = function() end,
	json = {
		encode = function() return "{}" end,
		decode = function() return {} end,
	},
	state = {
		get = function(key: string) return STATE[key] end,
		set = function(key: string, value: any) STATE[key] = value end,
		watch = function(key: string, fn: any) STATE["watch:" .. key] = fn end,
	},
}

local LIB = {
	["./lib/anim.luau"] = {
		stagger = function() return 1 end,
		ease_out = function() return 1 end,
	},
	["./lib/prefs.luau"] = {
		panel_mode = function() return "compact" end,
		density = function() return "standard" end,
		animations = function() return false end,
	},
	["./lib/theme.luau"] = {
		text = function() return "#ffffff" end,
		muted = function() return "#999999" end,
		dim = function() return "#777777" end,
		surface = function() return "#111111" end,
		chip = function() return "#222222" end,
		ok = function() return "#00ff00" end,
		warn = function() return "#ffaa00" end,
		danger = function() return "#ff0000" end,
		info = function() return "#00aaff" end,
		isDark = function() return true end,
	},
}

local ENV = {
	noctalia = NOCTALIA,
	ui = UI,
	panel = { render = function() end, setNeedsFrameTick = function() end, close = function() end },
	barWidget = {},
	require = function(path: string)
		local mod = LIB[path]
		if mod == nil then
			error("require inesperado en el panel: " .. path)
		end
		return mod
	end,
	assert = assert, error = error, ipairs = ipairs, pairs = pairs, next = next,
	print = print, select = select, tostring = tostring, tonumber = tonumber,
	type = type, unpack = table.unpack, pcall = pcall, rawget = rawget,
	rawset = rawset, setmetatable = setmetatable, getmetatable = getmetatable,
	string = string, table = table, math = math, os = os, utf8 = utf8, coroutine = coroutine,
}

-- ── carga del panel real ─────────────────────────────────────────────

-- El fuente del panel llega embebido como función: el `luau` de esta máquina no
-- tiene `io` ni `load`, y los `require` corren con su propio entorno.
local build = require("./fixtures/panel_source")
local P = build(NOCTALIA, UI, ENV.panel, ENV.require, {})

-- ── utilidades del spec ──────────────────────────────────────────────

local passed, failed = 0, 0

local function check(label: string, ok: boolean, detail: any)
	if ok then
		passed += 1
		print("ok   " .. label)
	else
		failed += 1
		print("FAIL " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
	end
end

local function publish_feed(value: any)
	STATE["b3l0w_kanban_feed"] = value
end

local function publish_status(value: any)
	STATE["b3l0w_kanban_status"] = value
end

local function numbers(rows: any): string
	local out = {}
	for _, row in ipairs(rows) do
		out[#out + 1] = tostring(row.number)
	end
	return table.concat(out, ",")
end

-- El service publica `scope` (created/review/assigned) y `state` (open/closed)
-- por separado; la barra de filtros de actividad escribe ids de `scope`.
publish_feed({
	prs = {
		{ number = 1, scope = "created", state = "open" },
		{ number = 2, scope = "review", state = "open" },
		{ number = 3, scope = "created", state = "closed" },
	},
	issues = {
		{ number = 9, scope = "assigned", state = "open" },
	},
	runs = {
		{ id = "42", name = "CI" },
	},
})
publish_status({ repo = "Below-Z3R0/b3l0w", login = "Below-Z3R0", source = "issues" })

local S = P.S

-- ── actividad: scope vs state ────────────────────────────────────────

S.activityTab = "prs"
S.activityState = "all"
check("actividad/prs: sin filtro devuelve las 3 filas", numbers(P.activity_rows("")) == "1,2,3", numbers(P.activity_rows("")))

S.activityState = "created"
check("actividad/prs: 'creados por mí' filtra por scope, no por state",
	numbers(P.activity_rows("")) == "1,3", numbers(P.activity_rows("")))
check("actividad/prs: elegir 'creados' no vacía la pestaña", #P.activity_rows("") > 0, #P.activity_rows(""))

S.activityState = "review"
check("actividad/prs: 'revisión pedida' devuelve sólo el PR en revisión",
	numbers(P.activity_rows("")) == "2", numbers(P.activity_rows("")))

S.activityTab = "issues"
S.activityState = "assigned"
check("actividad/issues: 'asignados a mí' devuelve el issue asignado",
	numbers(P.activity_rows("")) == "9", numbers(P.activity_rows("")))

S.activityState = "created"
check("actividad/issues: 'creados por mí' no inventa filas asignadas",
	#P.activity_rows("") == 0, numbers(P.activity_rows("")))

-- El filtro por defecto de Ajustes se usa sólo cuando la barra está en "all".
S.activityState = "all"
CONFIG.issue_default_filter = "assigned"
check("actividad/issues: el default de Ajustes se aplica con la barra en 'all'",
	numbers(P.activity_rows("")) == "9", numbers(P.activity_rows("")))
CONFIG.issue_default_filter = "all"
check("actividad/issues: con default 'all' vuelven las filas",
	numbers(P.activity_rows("")) == "9", numbers(P.activity_rows("")))

S.activityTab = "actions"
check("actividad/actions: la pestaña sale de feed.runs",
	#P.activity_rows("") == 1 and tostring(P.activity_rows("")[1].id) == "42", #P.activity_rows(""))

-- ── tarjetas del tablero: filtros contra campos publicados ───────────

S.activityTab = "prs"
STATE["b3l0w_kanban_status"] = { login = "Below-Z3R0" }
STATE["b3l0w_kanban_board"] = { columns = {}, total = 0 }
S.search = ""
S.assignee = "mine"
S.label = "all"
S.staleOnly = false
check("tablero: 'mis issues' compara login sin distinguir mayúsculas",
	P.card_matches({ title = "x", assignees = { "below-z3r0" } }) == true)
check("tablero: 'mis issues' descarta tarjetas de otro",
	P.card_matches({ title = "x", assignees = { "otro" } }) == false)

S.assignee = "unassigned"
check("tablero: 'sin asignar' sólo pasa tarjetas sin assignees",
	P.card_matches({ title = "x", assignees = {} }) == true
		and P.card_matches({ title = "x", assignees = { "otro" } }) == false)

S.assignee = "all"
S.label = "bug"
check("tablero: filtro por label usa labels[].name publicado",
	P.card_matches({ title = "x", labels = { { name = "bug", color = "ff0000" } } }) == true
		and P.card_matches({ title = "x", labels = { { name = "feat", color = "00ff00" } } }) == false)

S.label = "all"
S.search = "12"
check("tablero: el buscador encuentra por número", P.card_matches({ number = 12, title = "otra" }) == true)

S.search = ""
check("tablero: tarjeta sin labels ni assignees no rompe los filtros",
	P.card_matches({ number = 1, title = "sola" }) == true)

-- La traza por pestaña debe ver lo que hay en el estado, no el snapshot viejo.
check("traza: el panel loguea el conteo de datasets",
	#LOG > 0 and string.find(LOG[#LOG], "| notif=") ~= nil, LOG[#LOG])

-- ── barra de filtros: label fantasma tras cambiar de repo ────────────

STATE["b3l0w_kanban_board"] = {
	columns = {
		{
			id = "open", name = "Open", state = "open",
			cards = {
				{ number = 1, title = "x", labels = { { name = "feat", color = "00ff00" } } },
			},
		},
	},
	total = 1,
}
S.search = ""
S.assignee = "all"
-- El watcher de BOARD_KEY invalida el memo de labels; el spec lo imita.
S.cacheStamp = -1
S.label = "bug"
P.filter_bar()
check("tablero: un label que ya no existe se resetea a 'all'", S.label == "all", S.label)
S.label = "feat"
P.filter_bar()
check("tablero: un label que sí existe se conserva", S.label == "feat", S.label)

print("")
print(tostring(passed) .. " ok, " .. tostring(failed) .. " fallidos")
if failed > 0 then
	error(tostring(failed) .. " checks fallidos")
end
