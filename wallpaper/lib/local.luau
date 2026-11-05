--!strict
-- Carpetas locales de imágenes y videos. El panel no sabe de dónde viene cada
-- item, así que estos se devuelven con la misma forma que el catálogo del
-- workshop: id = ruta absoluta, thumb = la propia imagen.

local M = {}

M.IMAGE_EXT = {
	jpg = true,
	jpeg = true,
	png = true,
	webp = true,
	gif = true,
	bmp = true,
	avif = true,
}

M.VIDEO_EXT = {
	mp4 = true,
	webm = true,
	mkv = true,
	mov = true,
	m4v = true,
	avi = true,
}

local function extension(name: string): string
	local ext = string.match(name, "%.([%w]+)$")
	return ext and string.lower(ext) or ""
end

local function label(name: string): string
	local clean = string.gsub(name, "%.[%w]+$", "")
	return (string.gsub(clean, "[_%-]+", " "))
end

-- Recorre la carpeta y, si depth > 0, sus subcarpetas. Un directorio ilegible
-- se salta: el panel tiene que abrirse igual.
local function walk(dir: string, kind: string, allowed: { [string]: boolean }, depth: number, out: { any }, limit: number?): boolean
	local entries = noctalia.listDir(dir)
	if type(entries) ~= "table" then
		return false
	end
	for _, name in ipairs(entries) do
		if type(name) == "string" then
			local path = dir .. "/" .. name
			local info = noctalia.fileInfo(path)
			local is_dir = type(info) == "table" and info.isDir == true
			if is_dir then
				if depth > 0 and walk(path, kind, allowed, depth - 1, out, limit) then
					return true
				end
			elseif allowed[extension(name)] then
				out[#out + 1] = {
					id = path,
					title = label(name),
					type = if kind == "videos" then "video" else "image",
					file = path,
					thumb = if kind == "images" then path else nil,
				}
				if limit and #out >= limit then
					return true
				end
			end
		end
	end
	return false
end

-- scan(dir, kind, limit, depth): kind es "images" o "videos"; depth cuenta
-- subcarpetas (0 = sólo el primer nivel).
function M.scan(dir: string?, kind: string, limit: number?, depth: number?): { any }
	if type(dir) ~= "string" or dir == "" then
		return {}
	end
	local out: { any } = {}
	walk(dir, kind, if kind == "videos" then M.VIDEO_EXT else M.IMAGE_EXT, math.max(0, math.floor(depth or 0)), out, limit)

	table.sort(out, function(a, b)
		return string.lower(a.title) < string.lower(b.title)
	end)

	if limit and #out > limit then
		local cut: { any } = {}
		for index = 1, limit do
			cut[index] = out[index]
		end
		return cut
	end
	return out
end

return M
