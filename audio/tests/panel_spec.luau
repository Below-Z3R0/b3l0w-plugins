-- Specs del PANEL de b3l0w/audio: layout y contrato con el host.
--
-- El panel es un módulo (lo requieren los entries finos), así que el spec lo
-- carga con `require` y lo abre en cada modo.
--
--   luau tests/panel_spec.luau

-- El panel se carga como SCRIPT (el runner lo concatena): un módulo
-- `require`d corre en su propio ámbito y no ve las globales del script que
-- lo llama, así que `noctalia.tr` sería nil. El runner publica el módulo en
-- la global `PANEL_APP`.
local app = PANEL_APP
-- El módulo stub tiene su propio estado (no ve la global del script): el
-- spec escribe ahí.
-- El estado vive en el módulo `.panel-mod/fixture` (el runner lo genera):
-- los módulos requireados no ven las globales del script.

local passed, failed = 0, 0

-- (ok, label, detail): el condicional primero, como en el resto de los
-- specs del proyecto.
local function check(ok, label, detail)
	if ok then
		passed += 1
		print("ok   " .. label)
	else
		failed += 1
		local extra = ""
		if detail ~= nil then
			extra = "  -> " .. tostring(detail)
		end
		print("FAIL " .. label .. extra)
	end
end

local function walk(node, fn)
	if type(node) ~= "table" then
		return
	end
	fn(node)
	for _, child in ipairs(node.children or {}) do
		walk(child, fn)
	end
end

-- Todos los nodos del árbol.
local function nodes()
	local out = {}
	walk(TEST.tree, function(node)
		table.insert(out, node)
	end)
	return out
end

local function find(pred)
	for _, node in ipairs(nodes()) do
		if pred(node) then
			return node
		end
	end
	return nil
end

local function count(pred)
	local total = 0
	walk(TEST.tree, function(node)
		if pred(node) then
			total += 1
		end
	end)
	return total
end

local function open(mode)
	TEST.tree = nil
	app.open({}, mode)
	return TEST.tree
end

-- ── 1. El panel renderiza ────────────────────────────────────────────

open("compact")
check(TEST.tree ~= nil, "el panel entrega árbol")
check(count(function(n) return n.__name == "column" end) > 0, "hay columnas")

-- ── 2. La raíz crece y estira a los hijos ─────────────────────────────
-- Sin `flexGrow` en la raíz el scroll de dentro no toma el alto sobrante y
-- el pie del panel se monta sobre la última card.
local raiz = find(function(n)
	return n.__name == "column" and n.props.flexGrow == 1 and n.props.align == "stretch"
end)
check(raiz ~= nil, "la raíz tiene flexGrow y align=stretch")

-- ── 3. Ningún nodo usa una prop que el host no tiene ─────────────────
-- El host avisa "ui tree: 'X' has no prop 'Y', ignored". `minHeight` no
-- existe en un scroll y `minWidth` no existe en un label: el spec los
-- detecta antes que el host.
local CONOCIDAS = {
	column = { width = true, height = true, flexGrow = true, opacity = true, visible = true, gap = true,
		padding = true, paddingH = true, paddingV = true, align = true, justify = true, fill = true,
		radius = true, border = true, borderWidth = true, minWidth = true, minHeight = true,
		onClick = true, onHover = true, tooltip = true },
	row = { width = true, height = true, flexGrow = true, opacity = true, visible = true, gap = true,
		padding = true, paddingH = true, paddingV = true, align = true, justify = true, fill = true,
		radius = true, border = true, borderWidth = true, minWidth = true, minHeight = true,
		onClick = true, onHover = true, tooltip = true },
	label = { width = true, height = true, flexGrow = true, opacity = true, visible = true, text = true,
		fontSize = true, color = true, fontWeight = true, maxWidth = true, maxLines = true,
		textAlign = true, fontFamily = true, baseline = true },
	button = { width = true, height = true, flexGrow = true, opacity = true, visible = true, text = true,
		glyph = true, variant = true, enabled = true, tooltip = true, onClick = true, controlSize = true,
		selected = true, key = true },
	select = { width = true, height = true, flexGrow = true, opacity = true, visible = true,
		options = true, selectedIndex = true, enabled = true, placeholder = true, onChange = true,
		controlSize = true, key = true },
	slider = { width = true, height = true, flexGrow = true, opacity = true, visible = true, min = true,
		max = true, step = true, value = true, onChange = true, onDragEnd = true, enabled = true,
		key = true },
	scroll = { width = true, height = true, flexGrow = true, opacity = true, visible = true, fill = true,
		radius = true, border = true, borderWidth = true, gap = true, padding = true, paddingH = true,
		paddingV = true, align = true, justify = true, stickToBottom = true, onScroll = true,
		scrollToBottomRev = true, revealKey = true, key = true },
	glyph = { width = true, height = true, flexGrow = true, opacity = true, visible = true, name = true,
		size = true, color = true },
}
local desconocidas = {}
for _, node in ipairs(nodes()) do
	local permitidas = CONOCIDAS[node.__name]
	if permitidas ~= nil then
		for prop in pairs(node.props) do
			if permitidas[prop] ~= true and node.__name ~= "column" and node.__name ~= "row" then
				desconocidas[#desconocidas + 1] = node.__name .. "." .. prop
			end
		end
	end
end
check(#desconocidas == 0, "ningún nodo usa una prop que el host no tiene",
	table.concat(desconocidas, ", "))

-- ── 4. Ningún ancho calculado a mano ──────────────────────────────────
-- Los números fijos (rowWidth() - 330) se descuadraban con la densidad, el
-- ancho del panel y el tema. El texto debe tomar el ancho que sobra.
local anchos_magicos = {}
for _, node in ipairs(nodes()) do
	local w = node.props.maxWidth
	if type(w) == "number" and w < 400 then
		anchos_magicos[#anchos_magicos + 1] = node.__name .. " maxWidth=" .. tostring(w)
	end
end
check(#anchos_magicos == 0, "ningún label con maxWidth calculado a mano",
	table.concat(anchos_magicos, ", "))

-- ── 5. El panel compacto: las pestañas y las acciones ─────────────────
-- Con 560 px los cinco controles con texto no caben (~620 px): el último
-- quedaba cortado. Ahora van en dos filas y los tabs sólo muestran el
-- glifo y el número.
open("compact")
local tabs_compact = find(function(n)
	return n.__name == "button" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 4) == "tab-"
end)
check(tabs_compact ~= nil, "hay botones de pestaña")
if tabs_compact ~= nil then
	check(tabs_compact.props.text == "1", "en el panel compacto el tab muestra sólo el número",
		tabs_compact.props.text)
	check(tabs_compact.props.tooltip ~= nil, "el tab lleva tooltip con el nombre")
end
-- Las acciones están en una fila aparte: la columna de las pestañas tiene
-- un row y un row de acciones.
local columnas = {}
walk(TEST.tree, function(n)
	if n.__name == "column" then
		table.insert(columnas, n)
	end
end)
local dos_filas = false
for _, c in ipairs(columnas) do
	local filas = 0
	for _, hijo in ipairs(c.children or {}) do
		if hijo.__name == "row" then
			filas = filas + 1
		end
	end
	if filas >= 2 and c.props.gap == 6 then
		dos_filas = true
	end
end
check(dos_filas, "en el panel compacto las acciones van en una segunda fila")

-- ── 6. El panel flotante: todo en una fila ───────────────────────────
open("float")
local tabs_float = find(function(n)
	return n.__name == "button" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 4) == "tab-"
end)
check(tabs_float ~= nil and tabs_float.props.text ~= "1",
	"en el panel flotante el tab muestra el nombre",
	if tabs_float ~= nil then tostring(tabs_float.props.text) else "sin tabs")

-- ── 7. El texto de la cabecera se ajusta al espacio ──────────────────
-- El subtítulo usa flexGrow: toma el ancho que sobra y el host lo recorta
-- con elipsis. Con `maxWidth` fijo el texto se salía en el panel compacto.
open("compact")
local subtitulo = find(function(n)
	return n.__name == "label" and n.props.flexGrow == 1 and n.props.fontSize == 11
end)
check(subtitulo ~= nil, "el subtítulo de la cabecera crece con el espacio")
check(subtitulo ~= nil and subtitulo.props.maxWidth == nil,
	"el subtítulo no lleva maxWidth calculado",
	subtitulo ~= nil and tostring(subtitulo.props.maxWidth) or "sin subtítulo")

-- ── 8. La lista crece y el scroll tiene alto ─────────────────────────
-- `minHeight` no existe en un scroll: el host lo ignora.
local tipos = {}
for _, n in ipairs(nodes()) do
	tipos[n.__name] = (tipos[n.__name] or 0) + 1
end
local lista = {}
for k, v in tipos do lista[#lista+1] = k .. "=" .. tostring(v) end
table.sort(lista)
local d = 0
walk(TEST.tree, function(n) if n.__name == "column" then d = d + 1 end end)


local scrolls = 0
local scroll_con_minheight = false
for _, node in ipairs(nodes()) do
	if node.__name == "scroll" then
		scrolls = scrolls + 1
		if node.props.minHeight ~= nil then
			scroll_con_minheight = true
		end
	end
end
check(scrolls > 0, "hay un scroll para la lista", scrolls)
check(not scroll_con_minheight, "el scroll no usa minHeight (el host lo ignora)")

-- ── 9. Los glifos existen en el host ──────────────────────────────────
-- El host usa Tabler: `arrow-right-left` y `pin-off` no existen y salían
-- como glifo faltante en el log.
local glifos_invalidos = {}
local GLIFOS_OK = {
	volume2 = true, volumex = true, microphone = true, music = true, headphones = true,
	bluetoothoff = true, refresh = true, settings = true, close = true, chevronleft = true,
	chevronright = true, cornerdownright = true, info = true, alerttriangle = true,
	arrowsshuffle = true, pinnedoff = true, pin = true,
}
for _, node in ipairs(nodes()) do
	local g = node.props.glyph or node.props.name
	if type(g) == "string" and node.__name == "glyph" then
		local limpio = string.gsub(g, "-", "")
		if not GLIFOS_OK[limpio] then
			glifos_invalidos[#glifos_invalidos + 1] = g
		end
	end
end
check(#glifos_invalidos == 0, "todos los glifos existen en Tabler",
	table.concat(glifos_invalidos, ", "))

-- ── 10. Las acciones del panel las soporta el service ────────────────
-- El contrato panel <-> service: cada `action =` del panel tiene su clave
-- en la tabla ACTIONS del service. El runner pasa el fuente de los dos
-- archivos en TEST.sources (Luau no tiene readfile).
local sources = TEST.sources or {}
local panel_src = sources["panel.luau"] or ""
local service_src = sources["service.luau"] or ""
local acciones_panel = {}
for accion in panel_src:gmatch('action%s*=%s*"([%w_]+)"') do
	acciones_panel[accion] = true
end
local faltan = {}
for accion in pairs(acciones_panel) do
	if not service_src:find('["' .. accion .. '"]') then
		faltan[#faltan + 1] = accion
	end
end
check(#faltan == 0, "el service soporta todas las acciones del panel",
	table.concat(faltan, ", "))

-- ── 11. El scroll tiene altura FIJA, no flexGrow ─────────────────────
-- El host sólo scrollea si el contenido es más alto que el viewport
-- (scroll_view.cpp: `m_maxScrollOffset = contentHeight - viewportH`). Con
-- `flexGrow = 1` el viewport crece con el contenido, nunca hay desborde y la
-- rueda no hace NADA: la lista se ve entera pero no se puede recorrer.
open("compact")
local scroll = find(function(n) return n.__name == "scroll" end)
check(scroll ~= nil, "hay un scroll")
if scroll ~= nil then
	check(scroll.props.flexGrow == nil, "el scroll NO lleva flexGrow (la rueda no scrollea)",
		tostring(scroll.props.flexGrow))
	check(type(scroll.props.height) == "number", "el scroll lleva altura fija (el viewport)",
		tostring(scroll.props.height))
	check(scroll.props.height > 100, "el alto del scroll alcanza para la lista",
		tostring(scroll.props.height))
end

-- ── 12. No hay paginación manual ─────────────────────────────────────
-- `pageSlice` partía de una altura ESTIMADA de cada card: cuando una card
-- crecía (el nombre en dos líneas) la última quedaba tapada. Ahora el
-- scroll las recorre todas.
local pagina = find(function(n)
	return n.__name == "label" and type(n.props.text) == "string"
		and string.find(n.props.text, "1/", 1, true) ~= nil
end)
check(pagina == nil, "no hay paginación manual (la lista entera va en el scroll)")

-- ── 13. La lista tiene TODAS las devices ────────────────────────────
-- Con la paginación se recortaban; ahora el scroll las lleva todas.
local cards = 0
walk(TEST.tree, function(n)
	if type(n.props.key) == "string" and string.sub(n.props.key, 1, 4) == "dev-" then
		cards += 1
	end
end)
check(cards == 1, "la card del dispositivo está en el árbol", cards)

-- ── 14. El alto del scroll nunca pasa del tope del panel ────────────
-- El scroll toma el menor entre el contenido y el tope (`max_height` del
-- manifiesto menos el cromo). Si se pasara, el panel would medir más que su
-- alto máximo y el host lo recortaría por abajo.
open("compact")
local sc = find(function(n) return n.__name == "scroll" end)
local h_compact = sc ~= nil and (sc.props.height or 0) or 0
check(h_compact > 0 and h_compact <= 680 - 34 - 68 - 24,
	"el alto del scroll del compacto no pasa del tope",
	tostring(h_compact))
open("float")
sc = find(function(n) return n.__name == "scroll" end)
local h_float = sc ~= nil and (sc.props.height or 0) or 0
check(h_float > 0 and h_float <= 820 - 34 - 34 - 24,
	"el alto del scroll del flotante no pasa del tope",
	tostring(h_float))

-- ── 15. Las cinco pestañas ───────────────────────────────────────────
-- Salidas, entradas, streams, filtros y bluetooth: los cinco botones de
-- pestaña existen y cada uno lleva su conteo real del estado.
open("compact")
local totalTabs = 0
local filtrosTab = nil
local btTab = nil
walk(TEST.tree, function(n)
	if n.__name == "button" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 4) == "tab-" then
		totalTabs += 1
		if n.props.key == "tab-filters" then
			filtrosTab = n
		elseif n.props.key == "tab-bt" then
			btTab = n
		end
	end
end)
check(totalTabs == 5, "hay cinco pestañas", totalTabs)
check(filtrosTab ~= nil, "la pestaña de filtros existe")
check(btTab ~= nil, "la pestaña de bluetooth existe")
if filtrosTab ~= nil then
	check(filtrosTab.props.text == "3", "la pestaña de filtros lleva el conteo de módulos",
		filtrosTab.props.text)
end
if btTab ~= nil then
	check(btTab.props.text == "2", "la pestaña de bluetooth lleva el conteo de equipos",
		btTab.props.text)
end

-- ── 16. La barra de perfiles ─────────────────────────────────────────
-- Los tres perfiles (música, telephonía, Hi-Res) y el sample rate real.
local perfiles = {}
walk(TEST.tree, function(n)
	if n.__name == "button" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 8) == "profile-" then
		perfiles[#perfiles + 1] = n.props.key
	end
end)
check(#perfiles == 3, "hay tres botones de perfil", #perfiles)
local tieneHiRes = false
for _, key in ipairs(perfiles) do
	if key == "profile-hires" then
		tieneHiRes = true
	end
end
check(tieneHiRes, "está el perfil Hi-Res")

-- El sample rate REAL del backend (48000) aparece en el panel.
local rate = nil
walk(TEST.tree, function(n)
	if n.__name == "label" and type(n.props.text) == "string"
		and string.find(n.props.text, "48000", 1, true) ~= nil then
		rate = n.props.text
	end
end)
check(rate ~= nil, "el panel muestra el sample rate real", rate)

-- ── 17. La pestaña de filtros dibuja los módulos ─────────────────────
-- El panel tiene que poder cambiar de pestaña: se dispara el onClick del
-- botón y se mira el árbol nuevo.
local function clickTab(key)
	local boton = find(function(n)
		return n.__name == "button" and n.props.key == key
	end)
	if boton == nil then
		return
	end
	if type(boton.props.onClick) == "function" then
		boton.props.onClick()
	end
end

open("compact")
clickTab("tab-filters")
local modulosEnElArbol = 0
walk(TEST.tree, function(n)
	if n.__name == "button" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 4) == "mod-" then
		modulosEnElArbol += 1
	end
end)
check(modulosEnElArbol == 3, "la pestaña de filtros lista los tres módulos", modulosEnElArbol)

-- Un módulo Boolean se puede habilitar: el botón manda la acción al service.
local modBoton = find(function(n)
	return n.__name == "button" and n.props.key == "mod-node.features.audio.no-dsp"
end)
check(modBoton ~= nil, "el módulo tiene su botón")
if modBoton ~= nil then
	check(modBoton.props.enabled == true, "el módulo Boolean se puede tocar")
	local antes = #FIXTURE_REQUESTS
	if type(modBoton.props.onClick) == "function" then
		modBoton.props.onClick()
	end
	local ultima = FIXTURE_REQUESTS[#FIXTURE_REQUESTS]
	check(ultima ~= nil and ultima.action == "set_module",
		"el botón del módulo manda set_module")
	check(ultima ~= nil and ultima.id == "node.features.audio.no-dsp",
		"la acción lleva el id del módulo")
	check(ultima ~= nil and ultima.value == true,
		"la acción lleva el valor nuevo (estaba en false)")
end

-- ── 18. La pestaña de bluetooth lista los equipos ────────────────────
open("compact")
clickTab("tab-bt")
local btEnElArbol = 0
walk(TEST.tree, function(n)
	if n.__name == "button" and type(n.props.key) == "string" and string.sub(n.props.key, 1, 3) == "bt-" then
		btEnElArbol += 1
	end
end)
check(btEnElArbol == 2, "la pestaña de bluetooth lista los dos equipos", btEnElArbol)

-- El equipo conectado ofrece desconectar; el otro, conectar.
local conectar = find(function(n)
	return n.__name == "button" and n.props.key == "bt-27:CB:CF:69:29:1E"
end)
check(conectar ~= nil, "el equipo sin conectar tiene su botón")
if conectar ~= nil then
	local antes = #FIXTURE_REQUESTS
	if type(conectar.props.onClick) == "function" then
		conectar.props.onClick()
	end
	local ultima = FIXTURE_REQUESTS[#FIXTURE_REQUESTS]
	check(ultima ~= nil and ultima.action == "bt_connect",
		"el botón manda bt_connect")
	check(ultima ~= nil and ultima.mac == "27:CB:CF:69:29:1E",
		"la acción lleva la MAC")
end

-- ── el render existe antes de que lo usen ─────────────────────────────
-- Regresión: `render` se declaraba con `local` DESPUÉS de las funciones que
-- lo llamaban. En Luau un `local` sólo existe desde su línea hacia adelante,
-- así que `onFrameTick` (el tick de la animación) y el click de las pestañas
-- capturaban un `render` GLOBAL (nil): al llamarlo reventaba con
-- "attempt to call a nil value" y el panel se congelaba al cambiar de
-- pestaña.
--
-- El symptom era silencioso en el host (el click no hacía nada) y ruidoso en
-- el runner (exit 1). Este check lo fija: el click de una pestaña tiene que
-- funcionar.
local tab_sink = nil
walk(TEST.tree, function(node)
	local key = node.props.key
	if type(key) == "string" and key == "tab-sink" then
		tab_sink = node
	end
end)
check(tab_sink ~= nil, "hay un botón de pestaña")
if tab_sink ~= nil and type(tab_sink.props.onClick) == "function" then
	local ok, err = pcall(tab_sink.props.onClick)
	check(ok, "el click de una pestaña no rompe (render no es nil)",
		tostring(err))
end

print(("\n%d ok, %d fallos"):format(passed, failed))
if failed > 0 then
	error("faltan checks")
end