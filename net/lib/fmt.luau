--!nonstrict
-- Utilidades puras compartidas por el service y el panel: nada de esto toca el
-- host, así que se puede probar con el CLI de luau.

local M = {}

-- Cita un argumento para el shell. Rutas con espacios y comillas se parten sin
-- esto y el comando recibe basura.
function M.quote(value: string): string
	return "'" .. string.gsub(tostring(value or ""), "'", "'\\''") .. "'"
end

function M.trim(value: any): string
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.lines(text: string): { string }
	local out = {}
	for line in string.gmatch(tostring(text or ""), "([^\n]*)\n?") do
		out[#out + 1] = line
	end
	return out
end

-- Bloque `clave=valor` hasta la línea marcador; lo que sigue vuelve aparte. El
-- probe de Sunshine mezcla ambos en una sola corrida para no pagar dos procesos.
function M.kv(text: string, marker: string): (table, { string })
	local map = {}
	local rest = {}
	local tail = {}
	local seen = false
	for _, line in ipairs(M.lines(text)) do
		if seen then
			table.insert(rest, line)
		elseif line == marker then
			seen = true
		else
			local key, value = string.match(line, "^([%w_]+)=(.*)$")
			if key ~= nil then
				map[key] = value
			end
		end
	end
	tail = rest
	return map, tail
end

-- Días desde 1970-01-01 para una fecha civil (algoritmo days_from_civil).
-- No usa `os.time{...}`: en el host esa forma interpreta los campos como UTC,
-- así que con un timestamp LOCAL devolvía la hora corrida. Con esto el cálculo
-- no depende de la zona horaria del proceso.
local function civil_days(year: number, month: number, day: number): number
	local y = year
	if month <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (month + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

-- Segundos del corrimiento local respecto de UTC (EST = 18000). Se deriva de
-- `os.time()` y del reloj de pared local, que sí son confiables.
function M.tz_offset(): number
	local stamp = os.time()
	local wall = os.date("*t", stamp)
	if type(wall) ~= "table" then
		return 0
	end
	local utc_epoch = civil_days(wall.year, wall.month, wall.day) * 86400
		+ wall.hour * 3600 + wall.min * 60 + wall.sec
	return stamp - utc_epoch
end

local function civil_epoch(year: number, month: number, day: number, hour: number, minute: number, second: number): number
	return civil_days(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

-- Timestamp RFC3339 en UTC (`LastSeen` de Tailscale) -> epoch.
function M.iso_epoch(value: any): number?
	if type(value) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, se = string.match(value, "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
	if y == nil then
		return nil
	end
	local year = tonumber(y)
	-- Go serializa "nunca visto" como 0001-01-01.
	if year < 2000 then
		return nil
	end
	return civil_epoch(year, tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se))
end

-- Timestamp local del log de Sunshine: "2026-11-01 13:25:18". Es hora de pared
-- local, así que se le suma el corrimiento para llegar al epoch real.
function M.log_epoch(value: any): number?
	if type(value) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, se = string.match(value, "^(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")
	if y == nil then
		return nil
	end
	local wall = civil_epoch(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se))
	return wall + M.tz_offset()
end

-- Edad legible desde un epoch. `tr` y `trp` se pasan desde el entry: los
-- módulos no tienen acceso a las traducciones por sí solos.
function M.age_text(stamp: any, tr: any, trp: any): string
	local value = tonumber(stamp)
	if value == nil or value <= 0 then
		return tr("time.never")
	end
	local delta = os.time() - value
	if delta < 0 then
		delta = 0
	end
	if delta < 90 then
		return tr("time.just_now")
	end
	if delta < 3600 then
		return trp("time.minutes_ago", math.floor(delta / 60))
	end
	if delta < 86400 then
		return trp("time.hours_ago", math.floor(delta / 3600))
	end
	return trp("time.days_ago", math.floor(delta / 86400))
end

-- "2001:db8::1" -> true. Se usa para separar la IPv4 de la IPv6 sin adivinar
-- por el orden del arreglo.
function M.is_v6(value: any): boolean
	return type(value) == "string" and string.find(value, ":", 1, true) ~= nil
end

return M
