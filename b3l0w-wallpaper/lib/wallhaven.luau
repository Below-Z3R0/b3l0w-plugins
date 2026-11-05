--!strict
-- Cliente mínimo de la API pública de Wallhaven (https://wallhaven.cc/help/api).
-- Acá sólo se arma la URL, se parsea la respuesta y se normalizan los items; la
-- descarga y el estado viven en el service.

local M = {}

M.API_BASE = "https://wallhaven.cc/api/v1"

-- Wallhaven codifica los filtros como bits: sfw=100, sketchy=010, nsfw=001.
-- La API toma un código de tres dígitos (sfw, sketchy, nsfw). El oficial usa
-- tres toggles, así que además de los nombres se aceptan los códigos crudos.
local PURITY = {
	sfw = "100",
	sketchy = "010",
	nsfw = "001",
	all = "111",
	["100"] = "100",
	["110"] = "110",
	["101"] = "101",
	["011"] = "011",
	["111"] = "111",
}

-- categories: general=100, anime=010, people=001.
local CATEGORIES = {
	general = "100",
	anime = "010",
	people = "001",
	all = "111",
	-- Las ocho combinaciones de tres dígitos: los chips del panel pueden
	-- dejar una categoría sola ("010") o ninguna marcada.
	["000"] = "111",
	["001"] = "001",
	["010"] = "010",
	["011"] = "011",
	["100"] = "100",
	["101"] = "101",
	["110"] = "110",
	["111"] = "111",
}

-- Proporciones aceptadas por la API (las mismas que expone el oficial).
local RATIOS = {
	landscape = true,
	portrait = true,
	["16x9"] = true,
	["16x10"] = true,
	["21x9"] = true,
	["32x9"] = true,
	["48x9"] = true,
	["9x16"] = true,
	["10x16"] = true,
	["9x18"] = true,
	["1x1"] = true,
	["3x2"] = true,
	["4x3"] = true,
	["5x4"] = true,
}

local SORTING = {
	relevance = "relevance",
	random = "random",
	date_added = "date_added",
	toplist = "toplist",
	views = "views",
	favorites = "favorites",
	hot = "hot",
}

-- M.headers(api_key): cabeceras de la petición. La clave es opcional; sin ella
-- la API sólo devuelve SFW.
function M.headers(api_key: string?): { string }
	local headers = { "Accept: application/json" }
	if type(api_key) == "string" and api_key ~= "" then
		headers[#headers + 1] = "X-API-Key: " .. api_key
	end
	return headers
end

local function pick(table_map: { [string]: string }, value: any, fallback: string): string
	if type(value) == "string" and table_map[value] then
		return table_map[value]
	end
	return table_map[fallback]
end

-- M.build_url(cfg): cfg = { page, query, purity, categories, sorting, api_key }.
function M.build_url(cfg: { [string]: any }): string
	local page = math.max(1, math.floor(tonumber(cfg.page) or 1))
	local parts = {
		"page=" .. tostring(page),
		"purity=" .. pick(PURITY, cfg.purity, "sfw"),
		"categories=" .. pick(CATEGORIES, cfg.categories, "all"),
		"sorting=" .. pick(SORTING, cfg.sorting, "toplist"),
	}
	-- Extras del plugin oficial: orden, resolución mínima y proporción.
	local order = cfg.order
	if order == "asc" or order == "desc" then
		parts[#parts + 1] = "order=" .. order
	end
	-- El oficial expone dos modos: mínimo (`atleast`) o exacta (`resolutions`).
	local resolution = cfg.res
	if type(resolution) ~= "string" then
		resolution = cfg.atleast
	end
	if type(resolution) == "string" then
		local clean = (resolution:gsub("[^%dx]", ""))
		if clean ~= "" then
			local key = (cfg.resmode == "exact") and "resolutions" or "atleast"
			parts[#parts + 1] = key .. "=" .. clean
		end
	end
	local ratios = cfg.ratios
	if type(ratios) == "string" and RATIOS[ratios] then
		parts[#parts + 1] = "ratios=" .. ratios
	end

	local query = cfg.query
	if type(query) == "string" and query ~= "" then
		parts[#parts + 1] = "q=" .. (query:gsub("[^%w%s%-_]", ""):gsub("%s+", "+"))
	end
	return M.API_BASE .. "/search?" .. table.concat(parts, "&")
end

-- M.parse(body) devuelve (data, nil, last_page) o (nil, error, 1).
function M.parse(body: any): (any, string?, number)
	if type(body) ~= "string" or body == "" then
		return nil, "respuesta vacía", 1
	end
	local decoded = noctalia.json.decode(body)
	if type(decoded) ~= "table" then
		return nil, "JSON inválido", 1
	end
	if type(decoded.data) ~= "table" then
		local err = decoded.error
		return nil, type(err) == "string" and err or "la API no devolvió resultados", 1
	end
	local last = 1
	local meta = decoded.meta
	if type(meta) == "table" and type(meta.last_page) == "number" then
		last = math.max(1, math.floor(meta.last_page))
	end
	return decoded.data, nil, last
end

-- M.to_items(data): normaliza a la forma que usa el panel. `id` es el id de
-- Wallhaven; `full` la imagen original y `thumb_url` la miniatura.
function M.to_items(data: any): { any }
	local out: { any } = {}
	if type(data) ~= "table" then
		return out
	end
	for _, entry in ipairs(data) do
		if type(entry) == "table" and type(entry.id) == "string" then
			local thumbs = entry.thumbs
			local thumb_url = type(thumbs) == "table" and thumbs.large or nil
			out[#out + 1] = {
				id = entry.id,
				title = type(entry.resolution) == "string" and entry.resolution or entry.id,
				type = "wallhaven",
				full = type(entry.path) == "string" and entry.path or nil,
				thumb_url = type(thumb_url) == "string" and thumb_url or nil,
				page_url = type(entry.url) == "string" and entry.url or nil,
				bytes = tonumber(entry.file_size) or 0,
				purity = type(entry.purity) == "string" and entry.purity or nil,
			}
		end
	end
	return out
end

-- M.extension(item): extensión del archivo remoto, para guardarlo con el nombre
-- correcto cuando se aplica o se descarga.
function M.extension(item: any): string
	if type(item.full) == "string" then
		local ext = item.full:match("%.(%w+)$")
		if ext then
			return string.lower(ext)
		end
	end
	return "jpg"
end

return M
