--!strict
-- Detección de carga de GPU por wallpaper.
--
-- Criterio: medición real del tiempo que el GPU pasa fuera de RC6 (estado de bajo
-- consumo) durante una ventana de muestreo. No se clasifica por tipo de wallpaper:
-- un `scene` liviano y un `video` 4K pueden caer en cualquier extremo.

local M = {}

export type Counters = { rc6: number, freq: number }
export type Profile = { idle_pct: number, busy_pct: number, freq_mhz: number }

local DRM_ROOT = "/sys/class/drm"

local rc6Path: string? = nil
local freqPath: string? = nil
local resolved = false

local function firstExisting(candidates: { string }): string?
	for _, path in ipairs(candidates) do
		if noctalia.fileExists(path) then
			return path
		end
	end
	return nil
end

-- Resuelve una sola vez las rutas sysfs del GPU discreto/integrado que expone RC6.
local function resolve(): boolean
	if resolved then
		return rc6Path ~= nil
	end
	resolved = true

	local entries: { string }? = noctalia.listDir(DRM_ROOT)
	if not entries then
		noctalia.log("[gpuprobe] no se pudo listar " .. DRM_ROOT)
		return false
	end

	for _, name in ipairs(entries :: { string }) do
		if string.match(name, "^card%d+$") then
			local base = DRM_ROOT .. "/" .. name
			local rc6 = firstExisting({
				base .. "/power/rc6_residency_ms",
				base .. "/device/power/rc6_residency_ms",
			})
			if rc6 then
				rc6Path = rc6
				freqPath = firstExisting({
					base .. "/gt_cur_freq_mhz",
					base .. "/device/gt_cur_freq_mhz",
					base .. "/gt/gt0/rps_cur_freq_mhz",
				})
				noctalia.log("[gpuprobe] usando " .. rc6)
				return true
			end
		end
	end

	noctalia.log("[gpuprobe] ningún card expone rc6_residency_ms; la detección queda deshabilitada")
	return false
end

local function readNumber(path: string?): number?
	if not path then
		return nil
	end
	local raw: string? = noctalia.readFile(path)
	if not raw then
		return nil
	end
	return tonumber(noctalia.string.trim(raw))
end

function M.available(): boolean
	return resolve()
end

-- Lee los contadores actuales. Devuelve nil cuando el GPU no los expone, para que
-- el service no marque wallpapers por falta de datos.
function M.read(): Counters?
	if not resolve() then
		return nil
	end
	local rc6 = readNumber(rc6Path)
	local freq = readNumber(freqPath) or 0
	if rc6 == nil then
		return nil
	end
	return { rc6 = rc6, freq = freq }
end

-- Convierte dos lecturas en porcentajes de ocupación. `elapsedMs` debe ser el tiempo
-- real transcurrido entre ambas, medido con noctalia.nowMs().
function M.profile(prev: Counters, cur: Counters, elapsedMs: number): Profile?
	if elapsedMs <= 0 then
		return nil
	end
	local delta = cur.rc6 - prev.rc6
	if delta < 0 then
		-- El contador se reinició (suspend/resume): la muestra no sirve.
		return nil
	end
	local idle = (delta / elapsedMs) * 100
	if idle < 0 then
		idle = 0
	elseif idle > 100 then
		idle = 100
	end
	return {
		idle_pct = idle,
		busy_pct = 100 - idle,
		freq_mhz = cur.freq,
	}
end

-- "heavy" cuando el GPU estuvo ocupado por encima del umbral durante la ventana.
function M.classify(profile: Profile, threshold: number): string
	if profile.busy_pct >= threshold then
		return "heavy"
	end
	return "ok"
end

return M
