--!strict
-- Catálogo de Wallpaper Engine: localiza el directorio del Workshop de Steam
-- (431960) y normaliza cada `project.json` al shape Wallpaper de la SPEC.

local util = require("./util.luau")

local M = {}

export type Wallpaper = {
	id: string,
	title: string,
	type: string,
	path: string,
	file: string,
	preview: string?,
	thumb: string?,
	tags: { string },
	props: { [string]: any },
	load: any?,
}

export type ScanResult = { items: { Wallpaper }, errors: { string } }

local APP_ID = "431960"
local WORKSHOP_SUFFIX = "/steamapps/workshop/content/" .. APP_ID
local KNOWN_TYPES: { [string]: boolean } = { scene = true, video = true, web = true }

-- Instalaciones posibles de Steam en Linux, relativo a $HOME.
local STEAM_PREFIXES = {
	"/.steam/steam",
	"/.steam/root",
	"/.local/share/Steam",
	"/.var/app/com.valvesoftware.Steam/.local/share/Steam",
	"/snap/steam/common/.local/share/Steam",
}

function M.workshop_roots(): { string }
	local roots: { string } = {}
	local home: string? = noctalia.expandPath("~")
	if not home then
		return roots
	end
	for _, prefix in ipairs(STEAM_PREFIXES) do
		roots[#roots + 1] = home .. prefix .. WORKSHOP_SUFFIX
	end
	return roots
end

function M.find_root(): string?
	for _, root in ipairs(M.workshop_roots()) do
		if noctalia.fileExists(root) then
			return root
		end
	end
	return nil
end

local function read_project(dir: string): (any?, string?)
	local path = dir .. "/project.json"
	local raw: string? = noctalia.readFile(path)
	if not raw then
		return nil, "project.json ilegible: " .. path
	end

	local data: any = noctalia.json.decode(raw)
	if type(data) ~= "table" then
		return nil, "project.json inválido: " .. path
	end
	return data, nil
end

local function dir_id(dir: string): string
	return string.match(dir, "([^/]+)$") or dir
end

local function normalize_type(raw: any): string
	if type(raw) ~= "string" then
		return "other"
	end
	local kind = string.lower(util.trim(raw))
	if KNOWN_TYPES[kind] then
		return kind
	end
	return "other"
end

local function normalize_tags(raw: any): { string }
	local tags: { string } = {}
	if type(raw) == "string" then
		local tag = util.trim(raw)
		if tag ~= "" then
			tags[1] = tag
		end
		return tags
	end
	if type(raw) ~= "table" then
		return tags
	end
	for _, value in ipairs(raw :: { any }) do
		if type(value) == "string" then
			local tag = util.trim(value)
			if tag ~= "" then
				tags[#tags + 1] = tag
			end
		end
	end
	return tags
end

-- `project.json` guarda rutas relativas al propio item; el panel y el motor
-- necesitan rutas absolutas.
local function resolve_path(dir: string, raw: any): string?
	if type(raw) ~= "string" then
		return nil
	end
	local name = util.trim(raw)
	if name == "" then
		return nil
	end
	if string.sub(name, 1, 1) == "/" then
		return name
	end
	return dir .. "/" .. name
end

local function extract_props(data: any): { [string]: any }
	local general = data.general
	if type(general) == "table" and type(general.properties) == "table" then
		return general.properties :: { [string]: any }
	end
	return {}
end

function M.parse_item(dir: string): (Wallpaper?, string?)
	local data, err = read_project(dir)
	if not data then
		return nil, err
	end

	local id = dir_id(dir)
	local title = data.title
	local file = data.file

	local item: Wallpaper = {
		id = id,
		title = (type(title) == "string" and util.trim(title) ~= "") and util.trim(title) or id,
		type = normalize_type(data.type),
		path = dir,
		file = type(file) == "string" and util.trim(file) or "",
		preview = resolve_path(dir, data.preview),
		tags = normalize_tags(data.tags),
		props = extract_props(data),
	}
	return item, nil
end

function M.scan(root: string): ScanResult
	local items: { Wallpaper } = {}
	local errors: { string } = {}

	local entries: { string }? = noctalia.listDir(root)
	if not entries then
		noctalia.log("[catalog] no se pudo listar " .. root)
		errors[1] = "list_failed: " .. root
		return { items = items, errors = errors }
	end

	for _, name in ipairs(entries) do
		local dir = root .. "/" .. name
		local info = noctalia.fileInfo(dir)
		if info and info.isDir then
			local item, err = M.parse_item(dir)
			if item then
				items[#items + 1] = item
			else
				errors[#errors + 1] = err or ("parse_failed: " .. dir)
			end
		end
	end

	-- Orden estable para que el carrusel no se reacomode entre escaneos.
	table.sort(items, function(a: Wallpaper, b: Wallpaper): boolean
		local left, right = string.lower(a.title), string.lower(b.title)
		if left == right then
			return a.id < b.id
		end
		return left < right
	end)

	return { items = items, errors = errors }
end

-- Reutiliza el catálogo anterior mientras el mtime del root no cambie: evita
-- re-parsear decenas de project.json en cada tick del servicio.
-- Busca un wallpaper puntual por id sin recorrer el workshop completo: es lo
-- que necesita `apply` cuando el panel está en otra fuente.
function M.find_by_id(id: string): Wallpaper?
	local root = M.find_root()
	if root == nil then
		return nil
	end
	local dir = root .. "/" .. id
	if not noctalia.fileExists(dir .. "/scene.pkg") and not noctalia.fileExists(dir .. "/project.json") then
		-- Sin proyecto no hay nada que el motor pueda levantar.
		return nil
	end
	local item, err = M.parse_item(dir)
	if item == nil then
		return nil
	end
	return item
end

return M
