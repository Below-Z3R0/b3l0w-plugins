--!strict
-- Geometría del ancho del panel.
--
-- Pura a propósito: no lee el store ni toca la UI. La comparten el panel (para
-- dibujar), el service (para publicar qué entrada hay que abrir) y el widget
-- (para abrir la misma), de modo que los tres calculen lo mismo y no haya dos
-- fuentes de verdad.
--
-- Por qué existe: el host es dueño del tamaño del panel y NO se puede cambiar
-- en runtime. El API de `panel` es `render`, `close`, `openContextMenu`,
-- `setWantsSecondTicks` y `setNeedsFrameTick` — no hay `setWidth` — y el
-- manifiesto sólo acepta un entero o `"fill"` (no existe `width = "content"`).
-- Por eso el ancho es una ESCALERA de entradas, una por escalón de 100 px
-- entre 800 y 1900, y hay que elegir la entrada ANTES de abrir el panel:
-- cerrarlo y reabrirlo desde la CLI pierde la barra de origen (`sourceBarName`
-- sólo viaja cuando la apertura viene de un widget) y el panel termina
-- anclado en la barra por defecto.

local M = {}

-- Escalera.
M.MIN_W = 800
M.MAX_W = 1900
M.STEP = 100
-- Cromo del panel.
M.PAD_H = 16
M.CROP = 12
M.EDGE_W = 26
-- Ancho de celda cuando el usuario no fija uno: el que entra con 5 celdas en
-- el panel de 1500. Fijo a propósito: al pasar de 5 a 3 wallpapers las
-- tarjetas conservan su tamaño y lo que cambia es el panel.
M.CELL_AUTO = 268

local TIERS: { number } = {}
for w = M.MIN_W, M.MAX_W, M.STEP do
	TIERS[#TIERS + 1] = w
end

-- La escalera completa, para el manifiesto y la UI.
function M.tiers(): { number }
	local copia: { number } = {}
	for i, w in ipairs(TIERS) do
		copia[i] = w
	end
	return copia
end

-- El escalón más chico que contiene un ancho pedido.
function M.tierFor(ancho: number): number
	if ancho <= M.MIN_W then
		return M.MIN_W
	end
	if ancho >= M.MAX_W then
		return M.MAX_W
	end
	local pasos = math.ceil((ancho - M.MIN_W) / M.STEP)
	return math.min(M.MAX_W, M.MIN_W + pasos * M.STEP)
end

-- El id de la entrada de panel que sirve ese ancho. 1500 es `panel`, la
-- histórica y la única visible en el launcher; el resto son `panel_w<N>`.
function M.entryFor(ancho: number): string
	if ancho == 1500 then
		return "b3l0w/wallpaper:panel"
	end
	return "b3l0w/wallpaper:panel_w" .. tostring(ancho)
end

-- La celda más ancha que entra en un panel de `ancho` px con `slots` celdas.
function M.maxCellIn(ancho: number, slots: number, gap: number): number
	local inner = ancho - 2 * M.PAD_H - M.CROP
	local disponible = inner - 2 * M.EDGE_W - (slots - 1) * gap
	return math.max(80, math.floor(disponible / slots))
end

-- Tope del control de ancho de tarjeta: lo que entra en el panel más ancho.
function M.maxCard(slots: number, gap: number): number
	return M.maxCellIn(M.MAX_W, slots, gap)
end

-- (ancho del panel, ancho de celda) para el carrusel.
--
--   panel = celdas * celda + gaps + zonas de scroll + padding
--
-- El conteo fija el tamaño base (3 pide un panel más chico que 5) y el ancho
-- de tarjeta lo alarga o lo achica. Con `panel_w` fijado manda ése y las
-- tarjetas se reparten.
function M.carousel(slots: number, gap: number, card_w: number, panel_w: number): (number, number)
	if panel_w >= M.MIN_W then
		local ancho = M.tierFor(panel_w)
		local tope = M.maxCellIn(ancho, slots, gap)
		if card_w >= 80 then
			return ancho, math.min(card_w, tope)
		end
		return ancho, tope
	end
	local tope = M.maxCellIn(M.MAX_W, slots, gap)
	local celda = if card_w >= 80 then math.min(card_w, tope) else math.min(M.CELL_AUTO, tope)
	local necesario = slots * celda + (slots - 1) * gap + 2 * M.EDGE_W + 2 * M.PAD_H + M.CROP
	return M.tierFor(necesario), celda
end

-- Ancho del panel de la grilla: la grilla no usa la tira, así que su ancho
-- sale de su propio control (0 = 1500).
function M.grid(panel_w: number): number
	return if panel_w >= M.MIN_W then M.tierFor(panel_w) else 1500
end

return M
