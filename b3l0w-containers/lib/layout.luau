-- Layout automático para los plugins b3l0w.
--
-- La API de plugins de Noctalia NO expone medición: no hay `measure()` ni
-- `getSize()`. Un script no puede preguntar "¿cuánto mide esta card?".
-- Por eso el layout automático se PIDE al host, no se calcula:
--
--   - `align = "stretch"` encadenado: los hijos heredan el ancho del padre.
--   - `height = "content"` + `max_height` en el manifest: el host mide el
--     árbol renderizado y ajusta la superficie (sin hueco muerto abajo).
--   - los `ui.scroll` llevan un `height` numérico (el viewport): con
--     `flexGrow = 1` el viewport crece con el contenido y la rueda nunca
--     scrollea.
--
-- Este módulo NO inventa tamaños: decide si un control pide su ancho o lo
-- hereda del padre.

local M: any = {}

-- ── modo ─────────────────────────────────────────────────────────────

-- "auto" (por defecto): el host mide. "fixed": el script pide el ancho.
-- El ajuste del usuario (layout_mode) SÓLO sobrescribe esto: nunca
-- aparecen números calculados a mano en el render.
function M.mode(): string
	local value = tostring(noctalia.getConfig("layout_mode") or "auto")
	if value == "fixed" then
		return "fixed"
	end
	return "auto"
end

function M.is_auto(): boolean
	return M.mode() == "auto"
end

-- ── el alto del cromo ────────────────────────────────────────────────

-- El cromo (cabecera + pestañas + pie) es el único alto estimado que
-- queda: hay que descontarlo del viewport del scroll.
--
-- Se calcula POR PARTES y de sobra: si la estimación se queda corta, la
-- última fila queda tapada y no hay forma de llegar a ella; si sobra, hay
-- un hueco vacío abajo, que es un fallo mucho menos grave.
function M.chrome(parts: { number }): number
	local total = 0
	for _, alto in ipairs(parts) do
		total = total + alto
	end
	return total
end

-- ── el ancho ─────────────────────────────────────────────────────────

-- El ancho de la SUPERFICIE (la raíz del render): SIEMPRE explícito.
-- Sin él la raíz mide por contenido y toda la cadena de anchos se rompe:
-- las columnas miden por lo que miden sus hijos, el `flexGrow` no reparte
-- (el host sólo reparte con ancho conocido) y cada fila queda de un ancho
-- distinto.
function M.width(declarado: number): number
	return declarado
end


-- Un texto que se recorta con elipsis en vez de empujar el ancho.
function M.ellipsis(texto: any, maximo: number): string
	local t = tostring(texto or "")
	if #t <= maximo then
		return t
	end
	return t:sub(1, math.max(1, maximo - 1)) .. "…"
end

-- Un label con elipsis y sin ancho fijo: el host recorta y el padre
-- puede encojerlo (minWidth = 0 en el padre flexible).
function M.text(texto: any, props: any): any
	local p = type(props) == "table" and props or {}
	p.text = tostring(texto or "")
	p.maxLines = p.maxLines or 1
	return p
end

-- ── columnas de ancho fijo ───────────────────────────────────────────
--
-- `ui.label` NO tiene ancho fijo: el host descarta el `width` de un label
-- (`label.h`: "Flex ignores preset setSize()") y el reconciler ni siquiera
-- le aplica `minWidth` (sólo `maxWidth`). Por eso las filas con varias
-- columnas quedaban escalonadas: cada label mide su texto y la columna
-- arrancaba en una x distinta en cada fila.
--
-- La forma que SÍ funciona: un FLEX con `width`. El reconciler traduce
-- `width` de un row/column a `minWidth = maxWidth = width`
-- (`ui_tree_reconciler.cpp:1553`), así que el flex mide EXACTO ese ancho.
function M.colProps(ancho: number): any
	return { width = ancho, align = "stretch", gap = 0 }
end

-- Las props de un label dentro de una celda.
function M.celdaProps(texto: any, props: any): any
	local p = type(props) == "table" and props or {}
	p.text = tostring(texto or "")
	p.maxLines = 1
	return p
end

-- ── el scroll: viewport automático vs. declarado ──────────────────────
--
-- El síntoma "la lista no se ve completa y scrollea aunque haya espacio":
-- el scroll llevaba un `height` calculado a mano, más chico que el espacio
-- real. En automático el scroll NO lleva alto: toma el espacio sobrante
-- del padre (`flexGrow`), así que si la lista entra no hay scroll y si no
-- entra scrollea de verdad.
--
-- OJO: `flexGrow` reparte en el eje principal del padre. El padre del
-- scroll tiene que ser una `column` con alto conocido; dentro de un `row`
-- crecería en ancho.
function M.scrollExtra(base: number, alturaFija: boolean?): any
	-- El viewport del scroll, en dos modos:
	--
	-- - Panel "content" (alto automático): el scroll lleva SÓLO `height`, que
	--   ES el viewport. El "automático" del panel no lo da el scroll: lo da el
	--   manifest (`height = "content"` + `max_height`), que hace que la
	--   superficie siga al árbol renderizado.
	-- - Panel de alto FIJO (el flotante): el scroll crece con su columna
	--   (`flexGrow` y SIN `height`) para llenar el espacio. Con un alto
	--   declarado a mano quedaría un bloque vacío abajo del contenido.
	--
	-- NO combinar `height` con `flexGrow`: el host reparte el eje principal
	-- del padre y el scroll termina con un viewport más chico que su
	-- `height` → el contenido se recorta (la última fila del contenedor
	-- salía cortada por la mitad, con los botones de acción mutilados).
	--
	-- `alturaFija` lo decide el panel, no el layout: `lib/layout.luau` es puro.
	if alturaFija == true then
		return { flexGrow = 1 }
	end
	return { height = base }
end

-- Merge de dos tablas de props (Luau no lo trae).
function M.merge(a: any, b: any): any
	local salida: any = {}
	for _, tabla in ipairs({ a, b }) do
		if type(tabla) == "table" then
			for clave, valor in pairs(tabla) do
				salida[clave] = valor
			end
		end
	end
	return salida
end

-- El ancho de un control DENTRO del panel (una fila, una card, un scroll):
-- en auto lo hereda del padre y el host lo estira; en fixed se pide
-- explícito. Devuelve nil en auto: la prop `width = nil` la ignora el host.
function M.row(declarado: number): number?
	if M.is_auto() then
		return nil
	end
	return declarado
end

-- "1.017MB" → 1017000. `docker system df` usa unidades decimales (B, kB,
-- MB, GB, TB), así que la base es 1000 y no 1024.
local UNIDADES = { B = 1, kB = 1000, KB = 1000, MB = 1000 ^ 2, GB = 1000 ^ 3, TB = 1000 ^ 4, PB = 1000 ^ 5 }

function M.parseBytes(texto: string): number
	local limpio = tostring(texto or ""):gsub("%s", "")
	local numero, unidad = limpio:match("^([%d%.]+)([kKMGTP]?[Bb])$")
	if numero == nil then
		return 0
	end
	local factor = UNIDADES[unidad] or UNIDADES[unidad:sub(1, 1):upper() .. "B"] or 1
	return (tonumber(numero) or 0) * factor
end

-- El inverso, con 1 decimal y sin ".0": 1017000 → "1MB", 7400000000 → "7.4GB".
function M.humanBytes(bytes: number): string
	local valor = tonumber(bytes) or 0
	local unidades = { "B", "kB", "MB", "GB", "TB", "PB" }
	local indice = 1
	while valor >= 1000 and indice < #unidades do
		valor = valor / 1000
		indice = indice + 1
	end
	if indice == 1 then
		return string.format("%d%s", math.floor(valor), unidades[indice])
	end
	local redondeado = math.floor(valor * 10 + 0.5) / 10
	if redondeado == math.floor(redondeado) then
		return string.format("%d%s", math.floor(redondeado), unidades[indice])
	end
	return string.format("%.1f%s", redondeado, unidades[indice])
end

return M
