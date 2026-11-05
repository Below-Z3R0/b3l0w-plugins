--!nonstrict
-- Helpers de datos puros compartidos por el service, el widget y el panel.
--
-- Nada de acá toca el host, el disco ni la red: son transformaciones de texto
-- a tablas. La única dependencia externa es os.time() en age(), que es Luau
-- estándar y existe también sin Noctalia corriendo.

local theme = require("./theme.luau")

local M = {}

-- De peor a mejor. El orden manda el color de la barra, el filtro de severidad
-- y el `max_severity` que pinta el widget.
M.SEVERITIES = { "critical", "high", "medium", "low", "unknown" }

local SEVERITY_RANK = {
	critical = 5,
	high = 4,
	medium = 3,
	low = 2,
	unknown = 1,
}

local SEVERITY_COLOR = {
	critical = theme.danger(),
	high = theme.danger(),
	medium = theme.warn(),
	low = theme.ok(),
	unknown = theme.dim(),
}

-- Arch no soporta actualizaciones parciales: el comando que se copia desde el
-- panel es siempre el upgrade completo, nunca `pacman -S <paquete>`.
local UPGRADE_COMMAND = "sudo pacman -Syu"

function M.severity(value)
	local key = tostring(value or ""):lower()
	if SEVERITY_RANK[key] ~= nil then
		return key
	end
	return "unknown"
end

function M.rank(severity)
	return SEVERITY_RANK[M.severity(severity)] or 1
end

function M.severity_color(severity)
	return SEVERITY_COLOR[M.severity(severity)] or theme.dim()
end

function M.severity_counts()
	local counts = {}
	for _, severity in ipairs(M.SEVERITIES) do
		counts[severity] = 0
	end
	return counts
end

function M.max_severity(counts)
	for _, severity in ipairs(M.SEVERITIES) do
		if (tonumber(counts[severity]) or 0) > 0 then
			return severity
		end
	end
	return nil
end

-- `pacman -Q pkg...` imprime "nombre version" por línea. Un paquete ausente
-- hace que pacman salga con código distinto de cero pero igual imprime los que
-- encontró, así que el caller parsea stdout e ignora el exit code.
function M.parse_installed(stdout)
	local installed = {}
	for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
		local name, version = line:match("^(%S+)%s+(%S+)")
		if name ~= nil and version ~= nil then
			installed[name] = version
		end
	end
	return installed
end

-- `pacman -Qu` imprime "nombre version_vieja -> version_nueva". Con la lista
-- de ignorados agregada por pacman la línea termina en " [ignored]"; el
-- segundo `%S+` corta antes del corchete, así que no molesta.
function M.parse_updates(stdout)
	local rows = {}
	for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
		local name, from, to = line:match("^(%S+)%s+(%S+)%s+%-%>%s+(%S+)")
		if name ~= nil and from ~= nil and to ~= nil then
			table.insert(rows, { name = name, from = from, to = to })
		end
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	return rows
end

-- Filas de `pacman -Qu` que pertenecen a un paquete cuyo nombre contiene
-- `needle` (noctalia, umbriel). Se usa "contiene" y no "empieza con" porque
-- `xdg-desktop-portal-umbriel-git` también es Umbriel.
function M.filter_updates(rows, needle)
	local out = {}
	local want = tostring(needle or ""):lower()
	if want == "" then
		return out
	end
	for _, row in ipairs(rows or {}) do
		if tostring(row.name or ""):lower():find(want, 1, true) ~= nil then
			table.insert(out, row)
		end
	end
	return out
end

-- `noctalia --version` responde "noctalia v5.4.1 (v5.4.1-41-gf2cebd97e016)".
function M.parse_noctalia_version(stdout)
	local text = tostring(stdout or "")
	return {
		version = text:match("v(%d+[%d%.]*)"),
		build = text:match("%(([^%)]+)%)"),
	}
end

-- Salida acordada con el service (una clave por línea):
--   bin=/ruta/al/binario
--   binmtime=<epoch segundos>          (0 = no existe)
--   newest=<epoch> <ruta del .go más nuevo>
-- El binario está viejo cuando existe y hay fuente más nueva que él.
function M.parse_staleness(stdout)
	local out = { bin = nil, binMtime = 0, newestMtime = 0, newestPath = nil, stale = false }
	for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key == "bin" then
			out.bin = value
		elseif key == "binmtime" then
			out.binMtime = tonumber(value) or 0
		elseif key == "newest" then
			local stamp, path = value:match("^(%d+%.?%d*)%s+(.+)$")
			if stamp ~= nil then
				out.newestMtime = math.floor(tonumber(stamp) or 0)
				out.newestPath = path
			end
		end
	end
	out.stale = out.binMtime > 0 and out.newestMtime > out.binMtime
	return out
end

-- Sólo se linkea a IDs que parecen del tracker, así un JSON malformado no
-- puede meter una URL arbitraria en xdg-open.
function M.advisory_url(id)
	local name = tostring(id or "")
	if name:match("^[A-Z][A-Z0-9]*%-%d+$") == nil then
		return nil
	end
	return "https://security.archlinux.org/" .. name
end

local function non_empty_string(value)
	return type(value) == "string" and value ~= ""
end

local function string_array(value)
	local out = {}
	if type(value) == "table" then
		for _, entry in ipairs(value) do
			if non_empty_string(entry) then
				table.insert(out, entry)
			end
		end
	end
	return out
end

-- Convierte el array de `arch-audit --json` a la forma que usa el plugin. Una
-- entrada inválida se descarta en vez de tirar todo el chequeo: si el tracker
-- cambia un campo, se degrada a menos filas y no a un panel en blanco.
function M.normalize(raw, installed)
	installed = type(installed) == "table" and installed or {}

	local items = {}
	local seen_ids = {}
	local counts = M.severity_counts()

	if type(raw) ~= "table" then
		return { items = items, counts = counts, total = 0 }
	end

	for _, entry in ipairs(raw) do
		if type(entry) == "table" and non_empty_string(entry.name) and not seen_ids[entry.name] then
			local packages = string_array(entry.packages)
			if #packages > 0 then
				local installed_packages = {}
				for _, name in ipairs(packages) do
					local version = installed[name]
					table.insert(installed_packages, {
						name = name,
						version = non_empty_string(version) and version or nil,
					})
				end

				local severity = M.severity(entry.severity)
				local item = {
					id = entry.name,
					packages = packages,
					installed = installed_packages,
					severity = severity,
					status = non_empty_string(entry.status) and entry.status or "Unknown",
					type = non_empty_string(entry.type) and entry.type or "unknown",
					fixed = non_empty_string(entry.fixed) and entry.fixed or nil,
					issues = string_array(entry.issues),
					url = M.advisory_url(entry.name),
				}

				seen_ids[item.id] = true
				table.insert(items, item)
				counts[severity] = counts[severity] + 1
			end
		end
	end

	table.sort(items, function(a, b)
		local rank_a, rank_b = M.rank(a.severity), M.rank(b.severity)
		if rank_a ~= rank_b then
			return rank_a > rank_b
		end
		local name_a = a.packages[1] or a.id
		local name_b = b.packages[1] or b.id
		if name_a ~= name_b then
			return name_a < name_b
		end
		return a.id < b.id
	end)

	return { items = items, counts = counts, total = #items }
end

function M.ignore_set(list)
	local set = {}
	if type(list) == "table" then
		for _, name in ipairs(list) do
			if type(name) == "string" then
				local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
				if trimmed ~= "" then
					set[trimmed] = true
				end
			end
		end
	end
	return set
end

-- Saca los paquetes ignorados de cada aviso. Un aviso sólo desaparece cuando
-- *todos* sus paquetes están ignorados; si queda alguno, la fila sigue.
function M.apply_ignore(items, ignored)
	local kept_items = {}
	local counts = M.severity_counts()
	local dropped = 0

	for _, item in ipairs(items or {}) do
		local packages = {}
		for _, name in ipairs(item.packages or {}) do
			if not ignored[name] then
				table.insert(packages, name)
			end
		end

		if #packages == 0 then
			dropped = dropped + 1
		else
			local installed = {}
			for _, entry in ipairs(item.installed or {}) do
				if not ignored[entry.name] then
					table.insert(installed, entry)
				end
			end
			table.insert(kept_items, {
				id = item.id,
				packages = packages,
				installed = installed,
				severity = item.severity,
				status = item.status,
				type = item.type,
				fixed = item.fixed,
				issues = item.issues,
				url = item.url,
			})
			counts[item.severity] = counts[item.severity] + 1
		end
	end

	return {
		items = kept_items,
		counts = counts,
		total = #kept_items,
		dropped = dropped,
	}
end

function M.ids(items)
	local set = {}
	for _, item in ipairs(items or {}) do
		set[item.id] = true
	end
	return set
end

function M.new_items(items, seen)
	local fresh = {}
	if type(seen) ~= "table" then
		return fresh
	end
	for _, item in ipairs(items or {}) do
		if not seen[item.id] then
			table.insert(fresh, item)
		end
	end
	return fresh
end

function M.filter(items, severity, fix_only)
	local out = {}
	for _, item in ipairs(items or {}) do
		local severity_ok = severity == nil or severity == "all" or item.severity == severity
		local fix_ok = fix_only ~= true or item.fixed ~= nil
		if severity_ok and fix_ok then
			table.insert(out, item)
		end
	end
	return out
end

-- Devuelve clave de traducción y conteo para trp(). Con count 0 el caller usa
-- tr() (\"recién\"), con > 0 la forma plural.
function M.age(checked_at_ms)
	if type(checked_at_ms) ~= "number" or checked_at_ms <= 0 then
		return "time.never", 0
	end

	local seconds = os.time() - math.floor(checked_at_ms / 1000)
	if seconds < 0 then
		seconds = 0
	end

	if seconds < 60 then
		return "time.just_now", 0
	elseif seconds < 3600 then
		return "time.minutes_ago", math.floor(seconds / 60)
	elseif seconds < 86400 then
		return "time.hours_ago", math.floor(seconds / 3600)
	end
	return "time.days_ago", math.floor(seconds / 86400)
end

function M.age_text(checked_at_ms, translate, translate_plural)
	local key, count = M.age(checked_at_ms)
	if count > 0 then
		return translate_plural(key, count)
	end
	return translate(key)
end

function M.upgrade_command()
	return UPGRADE_COMMAND
end

return M
