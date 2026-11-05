--!strict
-- Traducción de Engine options a la línea de comandos de linux-wallpaperengine.
--
-- FIELDS es la única fuente de verdad sobre nombres, tipos y rangos: el panel
-- dibuja sus controles desde acá y store valida contra is_valid, así no hay dos
-- listas de opciones que se desincronicen.

local M = {}

export type FieldKind = "int" | "number" | "enum" | "bool"
export type Value = number | string | boolean
export type Opts = { [string]: Value }
export type Field = {
	key: string,
	kind: FieldKind,
	flag: string,
	values: { string }?,
	min: number?,
	max: number?,
}

-- Los flags que toman valor van primero, en el orden en que el engine documenta
-- su ayuda, para que dos spawns con las mismas opciones den el mismo argv.
local FIELDS: { Field } = {
	{ key = "fps", kind = "int", flag = "--fps", min = 1, max = 240 },
	{ key = "scaling", kind = "enum", flag = "--scaling", values = { "default", "fill", "fit", "stretch" } },
	{ key = "clamp", kind = "enum", flag = "--clamp", values = { "clamp", "border", "repeat" } },
	{ key = "layer", kind = "enum", flag = "--layer", values = { "default", "background", "bottom", "top", "overlay" } },
	{ key = "volume", kind = "number", flag = "--volume", min = 0, max = 100 },
	{ key = "silent", kind = "bool", flag = "--silent" },
	{ key = "disable_mouse", kind = "bool", flag = "--disable-mouse" },
	{ key = "disable_parallax", kind = "bool", flag = "--disable-parallax" },
	{ key = "disable_particles", kind = "bool", flag = "--disable-particles" },
	{ key = "no_audio_processing", kind = "bool", flag = "--no-audio-processing" },
	{ key = "no_fullscreen_pause", kind = "bool", flag = "--no-fullscreen-pause" },
	{ key = "fullscreen_pause_only_active", kind = "bool", flag = "--fullscreen-pause-only-active" },
	{ key = "noautomute", kind = "bool", flag = "--noautomute" },
}

-- `default` significa "no toques el flag": el engine ya arranca con ese valor en
-- scaling y en layer, y `--clamp`/`--volume` no lo aceptan como texto.
local SKIP_VALUES: { [string]: boolean } = { default = true }

-- Nombres heredados: el plugin viejo llamaba `below` a la capa que el engine
-- llama `bottom`. Se aceptan al leer (state.json o requests viejos) pero al
-- argv siempre va el token que el binario entiende.
local ARG_ALIAS: { [string]: string } = { below = "bottom" }

local BY_KEY: { [string]: Field } = {}
for _, field in ipairs(FIELDS) do
	BY_KEY[field.key] = field
end

M.FIELDS = FIELDS

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Rango cerrado declarado en FIELDS; `min`/`max` ausentes significan sin tope.
local function inRange(field: Field, n: number): boolean
	local lo, hi = field.min, field.max
	if lo ~= nil and n < lo then
		return false
	end
	if hi ~= nil and n > hi then
		return false
	end
	return true
end

function M.is_valid(fieldKey: string, value: any): boolean
	local field = BY_KEY[fieldKey]
	if field == nil then
		return false
	end

	local kind = field.kind
	if kind == "bool" then
		return type(value) == "boolean"
	end

	if kind == "int" or kind == "number" then
		if type(value) ~= "number" then
			return false
		end
		local n = value :: number
		if not isFinite(n) then
			return false
		end
		if kind == "int" and n % 1 ~= 0 then
			return false
		end
		return inRange(field, n)
	end

	if type(value) ~= "string" then
		return false
	end
	for _, allowed in ipairs(field.values or {}) do
		if allowed == value or ARG_ALIAS[value :: string] == allowed then
			return true
		end
	end
	return false
end

-- Texto del argv para un valor ya validado. Los enteros salen sin decimales
-- ("30", no "30.0") porque el engine parsea `--fps` como entero.
local function argv_value(field: Field, value: Value): string
	if field.kind == "int" then
		return string.format("%d", value :: number)
	elseif field.kind == "number" then
		local n = value :: number
		if n % 1 == 0 then
			return string.format("%d", n)
		end
		return tostring(n)
	end
	local text = value :: string
	return ARG_ALIAS[text] or text
end

-- Argumentos para el engine, sin el binario y sin `--screen-root`/`--bg`: el
-- service arma esa parte porque depende del output. Los flags con valor ocupan
-- dos elementos ("--fps", "30"); los bool sólo aparecen cuando son true.
-- Propiedades del proyecto (`--set-property nombre=valor`), lo que en el panel
-- oficial es "Configurar" por wallpaper: sliders, colores y toggles del
-- scene.pkg que el motor acepta por línea de comandos.
function M.properties_argv(props: { [string]: any }?): { string }
	local argv: { string } = {}
	if type(props) ~= "table" then
		return argv
	end
	local names: { string } = {}
	for name in pairs(props) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local value = props[name]
		if type(value) == "boolean" then
			argv[#argv + 1] = "--set-property"
			argv[#argv + 1] = tostring(name) .. "=" .. (value and "1" or "0")
		elseif type(value) == "number" or type(value) == "string" then
			local text = tostring(value)
			if text ~= "" then
				argv[#argv + 1] = "--set-property"
				argv[#argv + 1] = tostring(name) .. "=" .. text
			end
		end
	end
	return argv
end

function M.to_argv(opts: Opts?): { string }
	local argv: { string } = {}
	if type(opts) ~= "table" then
		return argv
	end

	for _, field in ipairs(FIELDS) do
		local value = opts[field.key]
		if value ~= nil then
			if field.kind == "bool" then
				if value == true then
					argv[#argv + 1] = field.flag
				end
			elseif not M.is_valid(field.key, value) then
				noctalia.log("[engine] valor descartado para " .. field.key .. ": " .. tostring(value))
			elseif not (field.kind == "enum" and SKIP_VALUES[value :: string] == true) then
				argv[#argv + 1] = field.flag
				argv[#argv + 1] = argv_value(field, value)
			end
		end
	end

	return argv
end

local function pick(source: Opts?, key: string): Value?
	if type(source) ~= "table" then
		return nil
	end
	return source[key]
end

-- Merge superficial campo por campo: el override gana cuando trae el campo, si
-- no manda el default global, y lo que no pase validación se descarta en vez de
-- llegar al argv.
function M.resolve(defaults: Opts?, override: Opts?): Opts
	local merged: Opts = {}
	for _, field in ipairs(FIELDS) do
		local value = pick(override, field.key)
		if value == nil then
			value = pick(defaults, field.key)
		end
		if value ~= nil and M.is_valid(field.key, value) then
			merged[field.key] = value
		end
	end
	return merged
end

return M
