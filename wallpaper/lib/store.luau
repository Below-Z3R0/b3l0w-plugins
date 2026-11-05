--!strict
-- Estado persistente del plugin (state.json dentro de pluginDataDir).
--
-- Todo lo que vuelve del disco pasa por migrate(): se contrasta contra defaults()
-- y se descarta lo que no encaja, de modo que un state.json viejo o editado a
-- mano nunca rompe un spawn. Las funciones que devuelven un estado devuelven una
-- copia: el service reasigna su propia referencia y nadie más ve la mutación.

local engine = require("./engine.luau")

local M = {}

export type CycleState = { active: boolean, minutes: number, order: string, ids: { string } }
export type LastState = { id: string?, output: string? }
-- Ajustes de una vista. `w`/`h` en 0 significan automático: se derivan del
-- ancho del panel o de la proporción de la tarjeta.
export type LayoutState = {
	layout: string, -- "full" | "minimal"
	w: number,
	h: number,
	progress: boolean, -- sólo tiene efecto en el carrusel
	-- Cuántos wallpapers se ven a la vez en el carrusel (3 o 5). En la
	-- grilla no aplica: siempre vale 5 (el máximo).
	slots: number,
	-- Ancho pedido para el panel de esta vista (0 = automático).
	-- El host no sabe redimensionar un panel abierto, así que el plugin
	-- declara una escalera de entries con anchos fijos (cada 100 px entre
	-- 800 y 1900) y abre la que corresponde; este valor elige el escalón.
	panel_w: number,
}

type ViewState = {
	mode: string,
	columns: number,
	-- Separación del carrusel: 0 = tarjetas pegadas, 100 = muy separadas.
	spacing: number,
	-- Selector "Aplicar en" visible en la barra superior.
	apply_on: boolean,
	-- Texto (en vez de sólo el icono) en el selector carrusel/grilla.
	view_label: boolean,
	carousel: LayoutState,
	grid: LayoutState,
}
export type BlockEntry = {
	busy_pct: number?,
	freq_mhz: number?,
	at: number?,
	reason: string,
}
export type State = {
	version: number,
	defaults: engine.Opts,
	overrides: { [string]: engine.Opts },
	-- Propiedades del proyecto por wallpaper (--set-property).
	properties: { [string]: { [string]: any } },
	blocklist: { [string]: BlockEntry },
	cycle: CycleState,
	last: LastState,
	source: string,
	-- El tema sigue la paleta del wallpaper (como los plugins de la casa).
	sync_colors: boolean,
	-- Trazas detalladas en el log. Apagado por defecto: el log del host es uno
	-- solo y el ruido tapa los errores reales.
	debug: boolean,
	-- Orden del catálogo local: name | date | random.
	local_sort: string,
	-- Último color sólido aplicado (#rrggbb).
	color: string?,
	-- Filtros vigentes de Wallhaven (los publica el service al cambiarlos).
	wallhaven_filters: { [string]: any }?,
	-- Tope de resultados de Wallhaven por consulta.
	wallhaven_max: number?,
	view: ViewState,
	-- Marcados por el usuario; sobreviven al reescaneo del catálogo.
	favorites: { [string]: boolean },
}

local STATE_FILE = "state.json"
local VERSION = 1
local DEFAULT_MINUTES = 15
local DEFAULT_COLUMNS = 4
local DEFAULT_SPACING = 15
local MAX_MINUTES = 1440

local function asTable(value: any): { [any]: any }
	if type(value) == "table" then
		return value :: { [any]: any }
	end
	return {}
end

local function asString(value: any): string?
	if type(value) == "string" then
		return value
	end
	return nil
end

local function asNumber(value: any): number?
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

local function clampInt(value: number?, fallback: number, lo: number, hi: number): number
	local n = math.floor(value or fallback)
	if n < lo then
		return lo
	elseif n > hi then
		return hi
	end
	return n
end

-- Disposición de una vista: sólo sobrevive lo que cumple el rango.
local function cleanLayout(value: any, with_progress: boolean): LayoutState
	local raw = asTable(value)
	-- `slots` (cuántos wallpapers se ven en el carrusel) sólo aplica al
	-- carrusel: en la grilla no hay tira. Se normaliza a un impar entre 3 y 5
	-- porque el wallpaper enfocado va en el centro y los demás se reparten a
	-- partes iguales a cada lado.
	local slots = 5
	if with_progress then
		local valor = clampInt(asNumber(raw.slots), 3, 3, 5)
		-- Impar: con 4 no hay reparto equitativo.
		if valor % 2 == 0 then
			valor = valor + 1
		end
		slots = valor
	end
	return {
		layout = (raw.layout == "minimal") and "minimal" or "full",
		w = clampInt(asNumber(raw.w), 0, 0, 1200),
		h = clampInt(asNumber(raw.h), 0, 0, 900),
		progress = with_progress and raw.progress ~= false or false,
		slots = slots,
		panel_w = clampInt(asNumber(raw.panel_w), 0, 0, 1900),
	}
end

local function copyOpts(source: engine.Opts?): engine.Opts
	local out: engine.Opts = {}
	if type(source) == "table" then
		for key, value in pairs(source) do
			out[key] = value
		end
	end
	return out
end

-- Copia estructural explícita: el estado son siete tablas conocidas y así el
-- llamador puede mutar el resultado sin tocar el original.
local function copyState(state: State): State
	local properties: { [string]: { [string]: any } } = {}
	for id, props in pairs(state.properties or {}) do
		local copy: { [string]: any } = {}
		for name, value in pairs(props) do
			copy[name] = value
		end
		properties[id] = copy
	end

	local overrides: { [string]: engine.Opts } = {}
	for id, opts in pairs(state.overrides) do
		overrides[id] = copyOpts(opts)
	end

	local blocklist: { [string]: BlockEntry } = {}
	for id, entry in pairs(state.blocklist) do
		blocklist[id] = {
			busy_pct = entry.busy_pct,
			freq_mhz = entry.freq_mhz,
			at = entry.at,
			reason = entry.reason,
		}
	end

	local ids: { string } = {}
	for index, id in ipairs(state.cycle.ids) do
		ids[index] = id
	end

	local favorites: { [string]: boolean } = {}
	for id, flag in pairs(state.favorites or {}) do
		if flag then
			favorites[id] = true
		end
	end

	return {
		version = state.version,
		defaults = copyOpts(state.defaults),
		overrides = overrides,
		properties = properties,
		blocklist = blocklist,
		cycle = {
			active = state.cycle.active,
			minutes = state.cycle.minutes,
			order = state.cycle.order,
			ids = ids,
		},
		last = { id = state.last.id, output = state.last.output },
		source = state.source or "engine",
		sync_colors = state.sync_colors ~= false,
		debug = state.debug,
		local_sort = state.local_sort or "name",
		color = state.color,
		favorites = favorites,
		-- Los filtros de Wallhaven son parte del estado: sin esta copia,
		-- marcar un favorito (que pasa por copyState) los borraba.
		wallhaven_filters = state.wallhaven_filters,
		wallhaven_max = state.wallhaven_max,
		view = {
			mode = state.view.mode,
			columns = state.view.columns,
			spacing = state.view.spacing,
			apply_on = state.view.apply_on ~= false,
			view_label = state.view.view_label ~= false,
			carousel = state.view.carousel,
			grid = state.view.grid,
		},
	}
end

-- Sólo sobreviven las claves que FIELDS declara y cuyo tipo/rango valida el
-- engine; cualquier otra cosa es basura de una versión anterior.
local function cleanOpts(value: any): engine.Opts
	local opts: engine.Opts = {}
	local source = asTable(value)
	for _, field in ipairs(engine.FIELDS) do
		local raw = source[field.key]
		if raw ~= nil and engine.is_valid(field.key, raw) then
			opts[field.key] = raw
		end
	end
	return opts
end

local function cleanIds(value: any): { string }
	local list = asTable(value) :: { any }
	local ids: { string } = {}
	for _, raw in ipairs(list) do
		if type(raw) == "string" then
			ids[#ids + 1] = raw
		end
	end
	return ids
end

-- Propiedades por wallpaper: nombre -> valor (string, número o bool).
local function cleanProperties(value: any): { [string]: { [string]: any } }
	local properties: { [string]: { [string]: any } } = {}
	for id, props in pairs(asTable(value)) do
		if type(id) == "string" and type(props) == "table" then
			local clean: { [string]: any } = {}
			for name, raw_value in pairs(props) do
				if type(name) == "string"
					and (type(raw_value) == "string" or type(raw_value) == "number" or type(raw_value) == "boolean")
				then
					clean[name] = raw_value
				end
			end
			properties[id] = clean
		end
	end
	return properties
end

local function cleanOverrides(value: any): { [string]: engine.Opts }
	local overrides: { [string]: engine.Opts } = {}
	for id, entry in pairs(asTable(value)) do
		if type(id) == "string" and type(entry) == "table" then
			overrides[id] = cleanOpts(entry)
		end
	end
	return overrides
end

local function cleanBlocklist(value: any): { [string]: BlockEntry }
	local blocklist: { [string]: BlockEntry } = {}
	for id, entry in pairs(asTable(value)) do
		if type(id) == "string" and type(entry) == "table" then
			local row = asTable(entry)
			blocklist[id] = {
				busy_pct = asNumber(row.busy_pct),
				freq_mhz = asNumber(row.freq_mhz),
				at = asNumber(row.at),
				reason = (row.reason == "manual") and "manual" or "gpu",
			}
		end
	end
	return blocklist
end

function M.defaults(): State
	return {
		version = VERSION,
		defaults = {},
		overrides = {},
		properties = {},
		blocklist = {},
		cycle = {
			active = false,
			minutes = DEFAULT_MINUTES,
			order = "sequential",
			ids = {},
		},
		last = {},
		source = "engine",
		sync_colors = true,
		debug = nil,
		local_sort = "name",
		color = nil,
		view = {
			mode = "carousel",
			columns = DEFAULT_COLUMNS,
			spacing = DEFAULT_SPACING,
			apply_on = true,
			view_label = true,
			carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5, panel_w = 0 },
			grid = { layout = "full", w = 0, h = 0, progress = false },
		},
		favorites = {},
	}
end

function M.migrate(raw: any): State
	local out = M.defaults()
	local source = asTable(raw)

	out.defaults = cleanOpts(source.defaults)
	out.overrides = cleanOverrides(source.overrides)
	out.properties = cleanProperties(source.properties)
	out.blocklist = cleanBlocklist(source.blocklist)

	local cycle = asTable(source.cycle)
	out.cycle = {
		active = cycle.active == true,
		minutes = clampInt(asNumber(cycle.minutes), DEFAULT_MINUTES, 1, MAX_MINUTES),
		order = (cycle.order == "random") and "random" or "sequential",
		ids = cleanIds(cycle.ids),
	}

	local last = asTable(source.last)
	out.last = { id = asString(last.id), output = asString(last.output) }

	local view = asTable(source.view)
	-- Ojo: acá había un `local source = asString(...)` que redeclaraba la tabla
	-- `source` como string. Todo lo que venía después (`source.wallhaven_filters`,
	-- `source.debug`) leía de un string y se perdía en silencio.
	local source_name = asString(source.source)
	if source_name ~= "images" and source_name ~= "videos" and source_name ~= "wallhaven" then
		source_name = "engine"
	end
	out.source = source_name

	local raw_filters = asTable(source.wallhaven_filters)
	local wallhaven_filters = nil
	if next(raw_filters) ~= nil then
		wallhaven_filters = {}
		for key, raw_value in pairs(raw_filters) do
			if type(key) == "string" and (type(raw_value) == "string" or type(raw_value) == "number") then
				wallhaven_filters[key] = raw_value
			end
		end
	end
	out.wallhaven_filters = wallhaven_filters

	-- Se deja nil si nunca se tocó: el service lo siembra con el ajuste del
	-- manifiesto, y a partir de ahí el toggle del panel manda.
	if type(source.debug) == "boolean" then
		out.debug = source.debug
	end

	local sync_colors = true
	if type(asTable(raw).sync_colors) == "boolean" then
		sync_colors = asTable(raw).sync_colors
	end
	out.sync_colors = sync_colors

	local favorites: { [string]: boolean } = {}
	for id, flag in pairs(asTable(source.favorites)) do
		if type(id) == "string" and flag == true then
			favorites[id] = true
		end
	end
	out.favorites = favorites

	-- El orden del catálogo local y el último color aplicado se guardaban pero
	-- la migración no los leía: se perdían en cada reinicio.
	local sort = asString(source.local_sort)
	if sort == "date" or sort == "random" then
		out.local_sort = sort
	else
		out.local_sort = "name"
	end
	local color = asString(source.color)
	out.color = color

	-- El tope de Wallhaven lo guardaba el service pero la migración no lo
	-- leía: se perdía en cada reinicio y el select mostraba el default.
	local wh_max = asNumber(source.wallhaven_max)
	if wh_max ~= nil then
		out.wallhaven_max = math.max(24, math.min(2400, math.floor(wh_max)))
	end

	out.view = {
		spacing = clampInt(asNumber(view.spacing), DEFAULT_SPACING, 0, 100),
		mode = (view.mode == "grid") and "grid" or "carousel",
		columns = clampInt(asNumber(view.columns), DEFAULT_COLUMNS, 2, 8),
		apply_on = view.apply_on ~= false,
		view_label = view.view_label ~= false,
		carousel = cleanLayout(view.carousel, true),
		grid = cleanLayout(view.grid, false),
	}

	return out
end

-- ¿Ya hay un state.json? Sirve para distinguir un arranque limpio (donde mandan
-- los ajustes del manifiesto) de una instalación en uso (donde manda el store).
function M.has_state(dataDir: string): boolean
	local raw = noctalia.readFile(dataDir .. "/" .. STATE_FILE)
	return type(raw) == "string" and raw ~= ""
end

function M.load(dataDir: string): State
	local path = dataDir .. "/" .. STATE_FILE
	local raw, readErr = noctalia.readFile(path)
	if not raw then
		noctalia.log("[store] sin estado en " .. path .. " (" .. tostring(readErr) .. "): arranco con defaults")
		return M.defaults()
	end

	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		noctalia.log("[store] " .. path .. " ilegible (" .. tostring(decodeErr) .. "): arranco con defaults")
		return M.defaults()
	end

	return M.migrate(decoded)
end

function M.save(dataDir: string, state: State): (boolean, string?)
	local encoded, encodeErr = noctalia.json.encode(state, true)
	if not encoded then
		noctalia.log("[store] no se pudo serializar el estado: " .. tostring(encodeErr))
		return false, encodeErr
	end

	local path = dataDir .. "/" .. STATE_FILE
	local ok, writeErr = noctalia.writeFile(path, encoded)
	if not ok then
		noctalia.log("[store] no se pudo escribir " .. path .. ": " .. tostring(writeErr))
		return false, writeErr
	end

	return true, nil
end

-- Expuesto para que el service valide lo que llega del panel antes de guardar.
M.clean_opts = cleanOpts

-- Reemplazo total: el panel es dueño del formulario, así que borrar un campo
-- allá tiene que borrarlo acá. Con un merge, "quitar" un setting no se guardaba.
function M.replace_override(state: State, id: string, opts: engine.Opts?): State
	local nextState = copyState(state)
	nextState.overrides[id] = cleanOpts(opts)
	return nextState
end

function M.replace_defaults(state: State, opts: engine.Opts?): State
	local nextState = copyState(state)
	nextState.defaults = cleanOpts(opts)
	return nextState
end

-- Borra de cada override solo las claves indicadas (las que cambiaron en los
-- defaults), dejando intacto lo que el usuario tuneó por wallpaper.
function M.drop_override_keys(state: State, keys: { string }): State
	local nextState = copyState(state)
	for _, id in pairs(nextState.overrides) do
		for _, key in ipairs(keys) do
			id[key] = nil
		end
	end
	return nextState
end

-- `profile` es el resultado de gpuprobe.profile(); se guarda el pico medido para
-- mostrarlo en el panel y entender por qué se rechazó.
function M.block(state: State, id: string, profile: any, reason: string?): State
	local measured = asTable(profile)
	local nextState = copyState(state)
	nextState.blocklist[id] = {
		busy_pct = asNumber(measured.busy_pct),
		freq_mhz = asNumber(measured.freq_mhz),
		at = math.floor(noctalia.nowMs() / 1000),
		reason = (reason == "manual") and "manual" or "gpu",
	}
	return nextState
end

function M.unblock(state: State, id: string): State
	local nextState = copyState(state)
	nextState.blocklist[id] = nil
	return nextState
end

-- Favorito por id de item: se guarda en el estado para que no se pierda cuando
-- el catálogo se reescanea (los ids del workshop y las rutas son estables).
function M.toggle_favorite(state: State, id: string): State
	local nextState = copyState(state)
	local favorites = {}
	for key, value in pairs(nextState.favorites or {}) do
		favorites[key] = value
	end
	if favorites[id] then
		favorites[id] = nil
	else
		favorites[id] = true
	end
	nextState.favorites = favorites
	return nextState
end

function M.is_blocked(state: State, id: string): boolean
	return state.blocklist[id] ~= nil
end

return M
