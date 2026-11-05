--!strict
-- Colores por ROL del tema activo, nunca hex fijo.
--
-- `noctalia.getColor(rol)` devuelve nil para los roles que el tema no define.
-- El error anterior era usar fallbacks oscuros (#1f1f28, #e6e6ea) asumiendo
-- siempre modo oscuro: con el tema en modo claro el texto quedaba blanco
-- sobre blanco y las tarjetas seguían negras mientras la shell cambiaba.
--
-- La solución: derivar el fallback MEZCLANDO los roles que sí existen
-- (surface_container, on_surface), así el color cae bien en cualquier tema,
-- claro u oscuro, y con cualquier paleta comunitaria.

local M = {}

-- ── utilidades de color ────────────────────────────────────────────────

local function hexToRgb(value: string): (number?, number?, number?)
	local hex = string.gsub(value, "#", "")
	if #hex == 3 then
		hex = hex:sub(1, 1) .. hex:sub(1, 1)
			.. hex:sub(2, 2) .. hex:sub(2, 2)
			.. hex:sub(3, 3) .. hex:sub(3, 3)
	end
	if #hex ~= 6 then
		return nil, nil, nil
	end
	local r = tonumber(hex:sub(1, 2), 16)
	local g = tonumber(hex:sub(3, 4), 16)
	local b = tonumber(hex:sub(5, 6), 16)
	if r == nil or g == nil or b == nil then
		return nil, nil, nil
	end
	return r, g, b
end

local function rgbToHex(r: number, g: number, b: number): string
	return string.format("#%02X%02X%02X", r, g, b)
end

-- `t` = 0 devuelve `a`, `t` = 1 devuelve `b`.
local function mix(a: string, b: string, t: number): string
	local ar, ag, ab = hexToRgb(a)
	local br, bg, bb = hexToRgb(b)
	if ar == nil or br == nil then
		return a
	end
	return rgbToHex(
		math.floor(ar + (br - ar) * t + 0.5),
		math.floor(ag + (bg - ag) * t + 0.5),
		math.floor(ab + (bb - ab) * t + 0.5)
	)
end

-- ── resolución de roles ────────────────────────────────────────────────

-- Sólo los roles que el tema define; los demás se derivan.
-- Sin caché: el usuario puede cambiar de tema en runtime y un valor
-- congelado devolvería el color del tema anterior.
local function rol(nombre: string): string?
	local ok, valor = pcall(function()
		return noctalia.getColor(nombre)
	end)
	if ok and type(valor) == "string" and valor ~= "" then
		return valor
	end
	return nil
end

-- La superficie base: la que usa el shell para tarjetas y filas.
local function surfaceBase(): string
	return rol("surface_container") or rol("surface_variant") or rol("surface") or "#F2E9E1"
end

-- El color de texto principal del tema.
local function onSurfaceBase(): string
	return rol("on_surface") or "#575279"
end

-- ── API pública ────────────────────────────────────────────────────────

-- Texto principal
function M.text(): string
	return rol("on_surface") or onSurfaceBase()
end

-- Texto secundario
function M.muted(): string
	local base = rol("on_surface_variant")
	if base then
		return base
	end
	return mix(onSurfaceBase(), surfaceBase(), 0.35)
end

-- Texto tenue / bordes
function M.dim(): string
	local base = rol("outline")
	if base then
		return base
	end
	return mix(onSurfaceBase(), surfaceBase(), 0.62)
end

-- Fondo de fila / tarjeta
function M.surface(): string
	return surfaceBase()
end

-- Fondo de chip (ligeramente más elevado que la superficie)
function M.chip(): string
	local base = rol("surface_container_high")
	if base then
		return base
	end
	return mix(surfaceBase(), onSurfaceBase(), 0.07)
end

-- Fondo de la superficie más elevada (cabeceras, player bar)
function M.raised(): string
	local base = rol("surface_container_highest")
	if base then
		return base
	end
	return mix(surfaceBase(), onSurfaceBase(), 0.13)
end

-- Borde sutil
function M.border(): string
	local base = rol("outline_variant")
	if base then
		return base
	end
	return mix(surfaceBase(), onSurfaceBase(), 0.22)
end

-- Acento del tema (lo que el shell usa para "selected")
function M.accent(): string
	return rol("primary") or "#D7827E"
end

-- Semánticos: si el tema no los define, se derivan mezclando el acento con
-- la superficie, así mantienen el significado sin quedar fuera de paleta.
function M.ok(): string
	return rol("primary") or mix(M.accent(), surfaceBase(), 0.05)
end

function M.warn(): string
	return rol("tertiary") or "#286983"
end

function M.danger(): string
	return rol("error") or "#B4637A"
end

function M.info(): string
	return rol("secondary") or "#56949F"
end

function M.isDark(): boolean
	local ok, valor = pcall(function()
		return noctalia.isDarkMode()
	end)
	return ok and valor == true
end

return M
