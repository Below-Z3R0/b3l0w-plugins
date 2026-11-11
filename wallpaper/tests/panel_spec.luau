--!nocheck
-- Tests del panel: cada bloque ajusta TEST.store / TEST.catalog, renderiza y
-- mira el árbol que el panel le entrega al host. Se ejecuta con tests/run.sh.
--
-- Regla: un test por comportamiento observable (nodo presente, nodo ausente,
-- ancho calculado). No se testea "que no explote": si algo no está, falla.

local fallos: { string } = {}
local pasos = 0
local arbol: any = nil

function check(cond: any, nombre: string)
	pasos += 1
	if not cond then
		fallos[#fallos + 1] = nombre
	end
end

-- El panel habla con el host por panel.render(tree): se intercepta para mirar.
panel.render = function(tree: any)
	arbol = tree
end

function walk(node: any, fn: (any) -> ())
	if type(node) ~= "table" then
		return
	end
	fn(node)
	for _, child in ipairs(node.children or {}) do
		walk(child, fn)
	end
end

-- Cuenta nodos cuyo texto contiene el fragmento.
function contarTexto(fragmento: string): number
	local total = 0
	walk(arbol, function(node)
		if node.__name == "label" and type(node.props.text) == "string" and string.find(node.props.text, fragmento, 1, true) ~= nil then
			total += 1
		end
	end)
	return total
end

function contar(nombre: string): number
	local total = 0
	walk(arbol, function(node)
		if node.__name == nombre then
			total += 1
		end
	end)
	return total
end

function buscar(nombre: string, predicado: ((any) -> boolean)?): any
	local encontrado: any = nil
	walk(arbol, function(node)
		if encontrado == nil and node.__name == nombre then
			if predicado == nil or predicado(node) then
				encontrado = node
			end
		end
	end)
	return encontrado
end

-- Cuenta los nodos con ese ancho. La CELDA de una tarjeta mide el ancho pedido
-- y la imagen de adentro descuenta el marco (padding + borde): se cuentan las
-- celdas, que son las que definen el ancho del layout.
function conAncho(ancho: number): number
	local total = 0
	walk(arbol, function(node)
		if node.props.width == ancho then
			total += 1
		end
	end)
	return total
end

-- Ancho de la imagen dentro de una tarjeta: el pedido menos el marco.
function conAnchoImagen(ancho: number): number
	local total = 0
	walk(arbol, function(node)
		if node.props.width == ancho and node.__name == "image" then
			total += 1
		end
	end)
	return total
end

-- onOpen resetea el panel y renderiza: es el disparador de cada caso.
function refrescar(): ()
	arbol = nil
	onOpen({})
end

local vista = TEST.store.view

-- ── Ancho del panel ───────────────────────────────────────────────────
-- Va en su propia función porque el script concatenado ya roza el tope de
-- 200 registros de Luau: lo que se declara acá no compite con el resto.
function tests_ancho_panel(): ()
	local function celda(): number
		local ancho = 0
		walk(arbol, function(node)
			if node.__name == "row" and node.props.justify == "space_between" then
				for _, c in ipairs(node.children or {}) do
					if c.__name == "row" then
						local primera = (c.children or {})[1]
						if primera ~= nil then
							ancho = primera.props.width or 0
						end
					end
				end
			end
		end)
		return ancho
	end

	-- 40. El panel se dimensiona al contenido.
	vista.mode = "carousel"
	vista.spacing = 15
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5, panel_w = 0 }
	refrescar()
	local panel5 = geometry().panel_w
	local celda5 = celda()
	check(panel5 == 1500, "ancho: con 5 wallpapers el panel mide 1500 (" .. tostring(panel5) .. ")")

	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3, panel_w = 0 }
	refrescar()
	local panel3 = geometry().panel_w
	local celda3 = celda()
	check(panel3 < panel5, "ancho: con 3 wallpapers el panel es más chico (" .. tostring(panel3) .. " < " .. tostring(panel5) .. ")")
	check(celda3 == celda5, "ancho: la tarjeta no cambia al achicarse el panel (" .. tostring(celda3) .. " vs " .. tostring(celda5) .. ")")

	-- 41. El ancho de tarjeta estira el panel.
	vista.carousel = { layout = "full", w = 120, h = 0, progress = true, slots = 3, panel_w = 0 }
	refrescar()
	local angosto = geometry().panel_w
	vista.carousel = { layout = "full", w = 300, h = 0, progress = true, slots = 3, panel_w = 0 }
	refrescar()
	local ancho = geometry().panel_w
	check(ancho > angosto, "ancho: tarjetas más anchas piden un panel más ancho (" .. tostring(ancho) .. " > " .. tostring(angosto) .. ")")

	-- 42. El escalón siempre existe en la escalera del manifiesto.
	local escalones = geometry().tiers
	local function en_escalera(valor: number): boolean
		for _, t in ipairs(escalones) do
			if t == valor then
				return true
			end
		end
		return false
	end
	check(#escalones == 12, "ancho: la escalera tiene 12 escalones (" .. tostring(#escalones) .. ")")
	check(en_escalera(geometry().panel_w), "ancho: el ancho calculado existe en la escalera (" .. tostring(geometry().panel_w) .. ")")

	-- 43. El control de ancho de panel manda sobre el cálculo automático.
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3, panel_w = 1200 }
	refrescar()
	check(geometry().panel_w == 1200, "ancho: panel_w=1200 se respeta (" .. tostring(geometry().panel_w) .. ")")

	-- 44. La grilla no usa el ancho del carrusel.
	vista.mode = "grid"
	vista.grid = { layout = "full", w = 0, h = 0, panel_w = 0 }
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3, panel_w = 0 }
	refrescar()
	check(geometry().panel_w == 1500, "ancho: la grilla usa el ancho completo (" .. tostring(geometry().panel_w) .. ")")
	vista.grid = { layout = "full", w = 0, h = 0, panel_w = 1000 }
	refrescar()
	check(geometry().panel_w == 1000, "ancho: la grilla respeta su propio panel_w (" .. tostring(geometry().panel_w) .. ")")
	vista.grid = { layout = "full", w = 0, h = 0, panel_w = 0 }

	-- 45. El tope del control de tarjeta crece con menos wallpapers.
	vista.mode = "carousel"
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5, panel_w = 0 }
	refrescar()
	local tope5 = geometry().max_card_w
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3, panel_w = 0 }
	refrescar()
	local tope3 = geometry().max_card_w
	check(tope3 > tope5, "ancho: con 3 wallpapers el tope de tarjeta es mayor (" .. tostring(tope3) .. " > " .. tostring(tope5) .. ")")

	-- Deja el store como estaba para no condicionar el resto de los checks.
	vista.mode = "carousel"
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5, panel_w = 0 }
	refrescar()
end

tests_ancho_panel()

-- Fijar el modo y reabrir el panel. Cada test dice en qué vista corre: al
-- reabrir, el panel vuelve al modo del store (el estado pendiente es de la
-- sesión anterior), así que sin esto los tests heredan el modo del anterior.
function enModo(modo: string): ()
	vista.mode = modo
	refrescar()
end

-- 1. Carrusel completo: barra de progreso.
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
vista.grid = { layout = "full", w = 0, h = 0 }
refrescar()
check(contar("progress") == 1, "carrusel completo: una barra de progreso")
check(contar("column") > 0, "carrusel: hay celdas")
check(arbol ~= nil, "carrusel: entrega árbol al host")

-- 2. Carrusel minimal: sin contador ni título (la barra depende de su propio
-- interruptor, no del layout).
vista.carousel.layout = "minimal"
refrescar()
check(contar("progress") == 1, "carrusel minimal: la barra de progreso se respeta igual")
check(contarTexto("/40") == 0, "carrusel minimal: sin contador de posición")

-- 3. Carrusel completo con progreso apagado.
vista.carousel = { layout = "full", w = 0, h = 0, progress = false }
refrescar()
check(contar("progress") == 0, "carrusel con progreso apagado: sin barra")

-- 4. Grilla completa: caption por tarjeta.
vista.mode = "grid"
vista.grid = { layout = "full", w = 0, h = 0 }
refrescar()
local captions_completa = contar("label")
check(captions_completa >= 20, "grilla completa: un label por tarjeta (" .. tostring(captions_completa) .. ")")

-- 5. Grilla minimal: sin captions.
vista.grid = { layout = "minimal", w = 0, h = 0 }
refrescar()
local captions_minimal = contar("label")
check(captions_minimal < captions_completa, "grilla minimal: menos labels (" .. tostring(captions_minimal) .. " vs " .. tostring(captions_completa) .. ")")

-- 6. Tamaños del carrusel, separados de los de la grilla.
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 200, h = 120, progress = true }
vista.grid = { layout = "full", w = 400, h = 220 }
refrescar()
check(conAncho(200) >= 1, "carrusel w=200: la tarjeta enfocada mide 200")
check(conAncho(400) == 0, "carrusel: no usa el ancho de la grilla")

-- 7. La grilla sí usa su propio ancho.
vista.mode = "grid"
vista.columns = 2
refrescar()
check(conAncho(400) >= 2, "grilla w=400 con 2 columnas: celdas de 400")
check(conAncho(200) == 0, "grilla: no usa el ancho del carrusel")

-- 8. Auto en grilla: reparte el ancho del panel.
vista.grid = { layout = "full", w = 0, h = 0 }
refrescar()
-- El esperado sale del propio panel: copiar la fórmula en el test lo haría
-- pasar siempre, incluso si el cálculo cambia.
local auto_grilla = gridCardW()
check(conAncho(auto_grilla) >= 2, "grilla auto: tarjetas de " .. tostring(auto_grilla) .. " px")
check(auto_grilla <= geometry().panel_inner, "grilla auto: no se sale del contenedor")

-- 9. Tope del carrusel.
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 999, h = 240, progress = true }
refrescar()
local MAX_FOCUS_W = geometry().max_card_w
check(conAncho(MAX_FOCUS_W) >= 1, "carrusel: el ancho se topa en " .. tostring(MAX_FOCUS_W))
check(conAncho(999) == 0, "carrusel: no dibuja el ancho imposible")

-- 10. "Aplicar en" presente/ausente.
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
vista.apply_on = true
refrescar()
check(
	buscar("select", function(node)
		return node.props.width == 170
	end) ~= nil,
	"aplicar en: selector visible por defecto"
)
vista.apply_on = false
refrescar()
check(
	buscar("select", function(node)
		return node.props.width == 170
	end) == nil,
	"aplicar en: selector oculto al apagarlo"
)

-- 11. Etiqueta del selector de vista.
vista.apply_on = true
vista.view_label = true
refrescar()
local con_texto = 0
local sin_texto = 0
walk(arbol, function(node)
	if node.__name == "button" and (node.props.glyph == "layout-grid" or node.props.glyph == "layout-list") then
		if node.props.text ~= nil then
			con_texto += 1
		else
			sin_texto += 1
		end
	end
end)
check(con_texto == 1 and sin_texto == 0, "selector de vista: con etiqueta")

vista.view_label = false
refrescar()
con_texto, sin_texto = 0, 0
walk(arbol, function(node)
	if node.__name == "button" and (node.props.glyph == "layout-grid" or node.props.glyph == "layout-list") then
		if node.props.text ~= nil then
			con_texto += 1
		else
			sin_texto += 1
		end
	end
end)
check(sin_texto == 1 and con_texto == 0, "selector de vista: sólo icono")

-- 12. Catálogo vacío: estado vacío sin explotar.
local items_reales = TEST.catalog.items
TEST.catalog.items = {}
refrescar()
check(arbol ~= nil, "catálogo vacío: igual renderiza")
TEST.catalog.items = items_reales

-- 13. Cabecera: el buscador sólo existe en grilla o en Wallhaven.
vista.mode = "carousel"
TEST.store.source = "engine"
refrescar()
check(
	buscar("input", function(node)
		return node.props.key == "search-input"
	end) == nil,
	"cabecera: carrusel local sin buscador"
)

vista.mode = "grid"
refrescar()
check(
	buscar("input", function(node)
		return node.props.key == "search-input"
	end) ~= nil,
	"cabecera: grilla con buscador"
)

vista.mode = "carousel"
TEST.store.source = "wallhaven"
refrescar()
check(
	buscar("input", function(node)
		return node.props.key == "search-input"
	end) ~= nil,
	"cabecera: Wallhaven con buscador"
)
local boton_buscar = 0
walk(arbol, function(node)
	if node.__name == "button" and node.props.glyph == "search" then
		boton_buscar += 1
	end
end)
check(boton_buscar >= 1, "cabecera: Wallhaven con botón de buscar")
TEST.store.source = "engine"

-- 15. Los controles de Opciones se aplican al instante: `send` publica al
-- service, pero la UI no puede esperar el viaje de ida y vuelta (si lo espera,
-- el slider rebota al valor viejo y parece que la opción no anda).
function sliderConEtiqueta(etiqueta: string): any
	local encontrado: any = nil
	walk(arbol, function(node)
		if encontrado ~= nil or node.__name ~= "row" then
			return
		end
		local hijos = node.children or {}
		local label = hijos[1]
		if label ~= nil and label.__name == "label" and label.props.text == etiqueta then
			local slider = hijos[2]
			if slider ~= nil and slider.__name == "slider" then
				encontrado = slider
			end
		end
	end)
	return encontrado
end

-- onKey("next") en Opciones pagina y renderiza; focusTo() puede salir sin
-- renderizar si el foco ya está en el destino, así que no sirve para forzar uno.
function abrirOpciones(): ()
	refrescar()
	S.screen = "options"
	onKey("next", true)
	S.optPage = 1
	onKey("prior", true)
end

function volverABrowse(): ()
	S.screen = "browse"
	onKey("end", true) -- cambia el foco: fuerza render
end

vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
vista.apply_on = true
TEST.store.source = "engine"

abrirOpciones()
local slider_w = sliderConEtiqueta("settings.layout.carousel_w")
check(slider_w ~= nil, "opciones: existe el slider de ancho del carrusel")
if slider_w ~= nil then
	slider_w.props.onChange(260)
	refrescar()
	S.screen = "options"
	onKey("right", true)
	sliderConEtiqueta("settings.layout.carousel_w").props.onDragEnd()
	-- El store sigue con w=0: el service todavía no contestó.
	check(TEST.store.view.carousel.w == 0, "opciones: el store todavía no cambió (simula latencia)")
	volverABrowse()
	check(conAncho(260) >= 1, "opciones: el ancho nuevo se aplica sin esperar al service")
end

-- El estilo minimal tiene que verse al instante en el carrusel.
abrirOpciones()
local toggle_estilo = nil
walk(arbol, function(node)
	if toggle_estilo == nil and node.__name == "button" and node.props.text == "settings.layout.full" then
		toggle_estilo = node
	end
end)
check(toggle_estilo ~= nil, "opciones: botón de estilo del carrusel")
if toggle_estilo ~= nil then
	toggle_estilo.props.onClick()
	volverABrowse()
	check(contarTexto("/40") == 0, "opciones: minimal se aplica sin esperar al service")
end

-- Y al confirmar el store, el pendiente se limpia.
TEST.store.view.carousel = { layout = "minimal", w = 260, h = 0, progress = true }
onState({})
check(next(S.pendingLayout or {}) == nil, "opciones: el pendiente se limpia cuando el store coincide")

-- 16. Las secciones de Opciones arrancan abiertas y se pueden cerrar.
function cabeceraSeccion(titulo: string): any
	local encontrado: any = nil
	walk(arbol, function(node)
		if encontrado == nil and node.__name == "row" and type(node.props.onClick) == "function" then
			for _, hijo in ipairs(node.children or {}) do
				if hijo.__name == "label" and hijo.props.text == titulo then
					encontrado = node
				end
			end
		end
	end)
	return encontrado
end

abrirOpciones()
check(sliderConEtiqueta("settings.layout.carousel_w") ~= nil, "secciones: el layout arranca abierto")
local cabecera_layout = cabeceraSeccion("panel.options_layout")
check(cabecera_layout ~= nil, "secciones: hay cabecera clickeable en layout")
if cabecera_layout ~= nil then
	cabecera_layout.props.onClick()
	S.screen = "options"
	onKey("next", true)
	check(sliderConEtiqueta("settings.layout.carousel_w") == nil, "secciones: al cerrarla se ocultan los controles")
	-- Se vuelve a abrir para no arrastrar estado al resto de los tests.
	S.sections.layout = nil
end

-- 17. Lo que el panel le pide al service: se intercepta `wes_request` y se mira
-- el payload. Un control que dibuja bien pero manda otra cosa es un bug mudo.
local peticiones: { any } = {}
noctalia.state.set = function(key: any, value: any)
	if key == "wes_request" then
		peticiones[#peticiones + 1] = value
	end
end
function ultimaPeticion(): any
	return peticiones[#peticiones]
end
function limpiarPeticiones(): ()
	peticiones = {}
end

TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
vista.grid = { layout = "full", w = 0, h = 0 }
vista.apply_on = true
vista.view_label = true
refrescar()

-- Buscar filtra el catálogo. Se mira en grilla: el carrusel sólo dibuja 5
-- celdas y contar ahí mide el viewport, no el filtro.
vista.mode = "grid"
S.search = "Wallpaper 1"
refrescar()
local filtrados = 0
walk(arbol, function(node)
	if node.__name == "column" and type(node.props.key) == "string" and node.props.key:match("^w%d+$") then
		filtrados += 1
	end
end)
check(filtrados == 11, "buscador: filtra el catálogo local (" .. tostring(filtrados) .. " de 20)")
S.search = ""

-- Sólo favoritos: mismo mecanismo, con el store como fuente.
TEST.store.favorites = { ["w3"] = true }
S.onlyFav = true
refrescar()
local solo_fav = 0
walk(arbol, function(node)
	if node.__name == "column" and type(node.props.key) == "string" and node.props.key:match("^w%d+$") then
		solo_fav += 1
	end
end)
check(solo_fav == 1, "sólo favoritos: queda un item (" .. tostring(solo_fav) .. ")")
S.onlyFav = false
TEST.store.favorites = {}

-- "f" marca favorito: el identificador tiene que viajar.
limpiarPeticiones()
refrescar()
onKey("f", true)
local pedido_fav = ultimaPeticion()
check(
	pedido_fav ~= nil and pedido_fav.action == "favorite" and type(pedido_fav.id) == "string",
	"tecla f: pide favorite con id (" .. tostring(pedido_fav and pedido_fav.id) .. ")"
)

-- Selección múltiple: con `selecting` activo, clickear no aplica, acumula.
limpiarPeticiones()
refrescar()
S.selecting = true
S.selected = {}
local primera_celda = nil
walk(arbol, function(node)
	if primera_celda == nil and node.__name == "column" and node.props.key == "w1" then
		local frame = node.children and node.children[1]
		if frame ~= nil and type(frame.props.onClick) == "function" then
			primera_celda = frame
		end
	end
end)
check(primera_celda ~= nil, "selección: hay celda clickeable")
if primera_celda ~= nil then
	primera_celda.props.onClick()
	check(#S.selected == 1 and S.selected[1] == "w1", "selección: un click acumula sin aplicar")
	check(ultimaPeticion() == nil or ultimaPeticion().action ~= "apply", "selección: no manda apply")
end
S.selecting = false
S.selected = {}

-- 18. La selección múltiple arranca APAGADA, aunque el store traiga ids.
-- Regresión: el panel abría con "3 selected" y en modo selección siempre.
TEST.store.cycle = { active = false, ids = { "w1", "w2", "w3" }, minutes = 1, order = "sequential" }
refrescar()
check(S.selecting == false, "selección múltiple: arranca apagada")
check(#S.selected == 0, "selección múltiple: no restaura ids de un ciclo parado")
check(contarTexto("selected") == 0, "selección múltiple: no se dibuja la barra de selección")

-- Con el modo selección prendido, la barra sí aparece. (refrescar() resetea
-- el estado, así que el modo se prende DESPUÉS de abrir.)
refrescar()
S.selecting = true
S.selected = { "w1" }
render()
check(contarTexto("selected") >= 1, "selección múltiple: la barra aparece al activarla")

-- Y un ciclo CORRIENDO sí restaura la lista (hay que poder detenerlo).
TEST.store.cycle = { active = true, ids = { "w1" }, minutes = 1, order = "sequential" }
refrescar()
check(#S.selected == 1, "selección múltiple: un ciclo corriendo restaura sus ids")
check(S.selecting == false, "selección múltiple: sigue apagada aunque haya ciclo")
TEST.store.cycle = { active = false, ids = {}, minutes = 1, order = "sequential" }
S.selecting = false
S.selected = {}

-- 19. Enter: aplica el wallpaper enfocado.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
refrescar()
limpiarPeticiones()
onKey("right", true)
local catalogo = TEST.catalog.items
local id_enfocado = catalogo[focusedIndex() + 1] and catalogo[focusedIndex() + 1].id
onKey("return", true)
local req_enter = ultimaPeticion()
check(
	req_enter ~= nil and req_enter.action == "apply" and req_enter.id == id_enfocado,
	"Enter: aplica el wallpaper enfocado (" .. tostring(req_enter and req_enter.id) .. ")"
)

-- 20. Enter con el buscador de Wallhaven: busca, no aplica.
TEST.store.source = "wallhaven"
S.wh = { purity = "sfw", categories = "all", sorting = "toplist", order = "desc", atleast = "", ratios = "any", page = 1, query = "" }
refrescar()
S.searchDirty = true
S.wh.query = "cyberpunk"
limpiarPeticiones()
onKey("return", true)
local req_busqueda = ultimaPeticion()
check(
	req_busqueda ~= nil and req_busqueda.action == "set_wallhaven" and req_busqueda.query == "cyberpunk",
	"Enter en Wallhaven: lanza la búsqueda"
)
check(S.searchDirty == false, "Enter en Wallhaven: el flag de escritura se limpia")

-- Y ahora Enter aplica (ya no está escribiendo).
limpiarPeticiones()
onKey("return", true)
local req_despues = ultimaPeticion()
check(req_despues ~= nil and req_despues.action == "apply", "Enter en Wallhaven: sin escribir, aplica")

TEST.store.source = "engine"
S.searchDirty = false

-- 21. "Aplicar en": el output elegido tiene que viajar con el apply.
-- Regresión: el selector se guardaba pero nunca se mandaba, así que el
-- wallpaper siempre iba al output enfocado.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
refrescar()
limpiarPeticiones()
S.output = "HDMI-A-1"
onKey("return", true)
local req_output = ultimaPeticion()
check(
	req_output ~= nil and req_output.output == "HDMI-A-1",
	"Aplicar en: el output elegido viaja con el apply (" .. tostring(req_output and req_output.output) .. ")"
)

-- Con "*" (todas) también viaja explícitamente.
S.output = "*"
limpiarPeticiones()
onKey("return", true)
local req_todas = ultimaPeticion()
check(req_todas ~= nil and req_todas.output == "*", "Aplicar en: '*' viaja como todas")

-- Y sin elección no se manda la clave (el service usa el output enfocado).
S.output = nil
limpiarPeticiones()
onKey("return", true)
local req_sin = ultimaPeticion()
check(req_sin ~= nil and req_sin.output == nil, "Aplicar en: sin elección no se manda output")
S.output = "*"

function botonConTexto(texto: string): any
	local encontrado: any = nil
	walk(arbol, function(node)
		if encontrado == nil and node.__name == "button" and node.props.text == texto then
			encontrado = node
		end
	end)
	return encontrado
end

-- 22. Los chips de categoría muestran el estado real.
-- El store guarda "all" (palabra de la API); los chips usan el código de
-- tres dígitos. Sin la traducción los tres chips aparecían apagados.
TEST.store.source = "wallhaven"
TEST.store.wallhaven_filters = { purity = "sfw", categories = "all", sorting = "toplist", order = "desc", ratios = "any", query = "", page = 1 }
refrescar()
local chips_general = botonConTexto("General")
local chips_anime = botonConTexto("Anime")
local chips_people = botonConTexto("People")
check(chips_general ~= nil and chips_anime ~= nil and chips_people ~= nil, "wallhaven: hay chips de categoría")
if chips_general ~= nil and chips_anime ~= nil and chips_people ~= nil then
	check(chips_general.props.variant == "primary", "wallhaven: con 'all' el chip General queda activo")
	check(chips_anime.props.variant == "primary", "wallhaven: con 'all' el chip Anime queda activo")
	check(chips_people.props.variant == "primary", "wallhaven: con 'all' el chip People queda activo")
end

-- Con un código explícito, sólo ese chip queda activo.
TEST.store.wallhaven_filters = { purity = "sfw", categories = "010", sorting = "toplist", order = "desc", ratios = "any", query = "", page = 1 }
refrescar()
chips_anime = botonConTexto("Anime")
chips_general = botonConTexto("General")
check(chips_anime ~= nil and chips_anime.props.variant == "primary", "wallhaven: con '010' el chip Anime queda activo")
check(chips_general ~= nil and chips_general.props.variant ~= "primary", "wallhaven: con '010' el chip General queda apagado")

TEST.store.source = "engine"
TEST.store.wallhaven_filters = {}

-- 23. Los atajos de una letra no secuestran el buscador.
-- Regresión: escribir "g" cambiaba de vista, "f" marcaba favorito.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
refrescar()
S.searchDirty = true
S.search = "gif"
limpiarPeticiones()
onKey("g", true)
local req_g = ultimaPeticion()
check(req_g == nil, "atajos: 'g' no cambia de vista mientras se escribe")
onKey("f", true)
local req_f = ultimaPeticion()
check(req_f == nil, "atajos: 'f' no marca favorito mientras se escribe")
S.searchDirty = false
S.search = ""
limpiarPeticiones()
onKey("g", true)
local req_g2 = ultimaPeticion()
check(req_g2 ~= nil and req_g2.action == "set_view", "atajos: 'g' funciona sin escribir")

-- 24. La tira del carrusel tiene que entrar en el panel.
-- Regresión: la tira medía 1562 px en un panel de 1468 y se salía.
-- El modo se fija en el store y se reabre el panel: reabrir vuelve al modo
-- del store (el estado pendiente es de la sesión anterior).
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
S.search = ""
S.searchDirty = false
limpiarPeticiones()
refrescar()
local celdas = 0
local suma = 0
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and string.sub(key, -2) == "/f" then
		celdas += 1
		suma += node.props.width or 0
	end
end)
-- El carrusel dibuja 5 slots; con 20 items en el catálogo los 5 están
-- ocupados (el foco está en el primero, así que hay dos slots a la izquierda
-- sin item: se dibujan como placeholders).
check(celdas >= 3 and celdas <= 5, "carrusel: hay hasta 5 tarjetas (" .. tostring(celdas) .. ")")
check(suma <= 1468, "carrusel: las tarjetas entran en el panel (" .. tostring(suma) .. " de 1468)")

-- 25. El grid no se desborda: la fila de tarjetas entra en el ancho útil.
enModo("grid")
local n_tiles = 0
local ancho_scroll = 0
walk(arbol, function(node)
	if node.__name == "scroll" and node.props.key == "grid-scroll" then
		ancho_scroll = node.props.height or 0
	end
	if node.__name == "column" and type(node.props.key) == "string" and string.sub(node.props.key, -2) == "/f" then
		n_tiles += 1
	end
end)
-- 20 items en el catálogo: la grilla los muestra todos (el scroll los recorta).
check(n_tiles == 20, "grilla: se dibujan las 20 tarjetas (" .. tostring(n_tiles) .. ")")
check(ancho_scroll > 0, "grilla: el scroll tiene alto (" .. tostring(ancho_scroll) .. ")")

-- 26. Minimal y full tienen que DIFFERIR de verdad, no sólo en un caption.
-- Regresión: el auditor midió que minimal sólo cambiaba un caption y una
-- barra de 2 px: el resto del chrome era idéntico.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "grid"
vista.grid = { layout = "full", w = 0, h = 0 }
refrescar()
local full_labels = contar("label")
local full_inputs = contar("input")
local full_selects = contar("select")
vista.grid = { layout = "minimal", w = 0, h = 0 }
refrescar()
local min_labels = contar("label")
local min_inputs = contar("input")
local min_selects = contar("select")
check(min_labels < full_labels, "minimal: menos etiquetas que full (" .. tostring(min_labels) .. " < " .. tostring(full_labels) .. ")")
-- El buscador NO es decoración: es la única forma de filtrar en la grilla.
-- Minimal quita chrome (selector de salida), no funciones.
check(min_inputs == full_inputs, "minimal: el buscador sigue disponible (" .. tostring(min_inputs) .. ")")
check(min_selects < full_selects, "minimal: sin el selector de salida (" .. tostring(min_selects) .. " < " .. tostring(full_selects) .. ")")
vista.grid = { layout = "full", w = 0, h = 0 }

-- 27. La grilla con ancho fijo llena el panel.
-- Regresión: con w=240 y 5 columnas la fila medía 1216 de 1452 y quedaban
-- 236 px muertos a la derecha.
vista.mode = "grid"
TEST.store.view.columns = 5
vista.grid = { layout = "full", w = 240, h = 0 }
refrescar()
-- Las filas no llevan `width` (el host las mide): se mide la suma de las
-- tarjetas de la primera fila más sus separaciones.
local ancho_fila = 0
local n = 0
local en_primera_fila = false
walk(arbol, function(node)
	if node.__name == "row" and node.props.gap == 4 and not en_primera_fila then
		en_primera_fila = true
		local ancho = 0
		for _, c in ipairs(node.children or {}) do
			local w = c.props.width or 0
			ancho += w
		end
		ancho_fila = ancho + math.max(0, #((node.children or {})) - 1) * 4
		n = #(node.children or {})
	end
end)
check(n >= 1, "grilla: la primera fila tiene tarjetas (" .. tostring(n) .. ")")
-- Con ancho fijo, las columnas se recalculan: la fila tiene que caber.
local ancho_util = 1500 - 2 * 16 - 2 * 8
check(ancho_fila <= ancho_util, "grilla: la fila entra en el ancho útil (" .. tostring(ancho_fila) .. " <= " .. tostring(ancho_util) .. ")")
TEST.store.view.columns = 4
vista.grid = { layout = "full", w = 0, h = 0 }
vista.mode = "carousel"

-- 28. La barra de progreso va DEBAJO de las tarjetas, con separación.
-- Regresión: con gap = 0 la barra quedaba en la misma línea del borde
-- inferior de las tarjetas y se leía como si estuviera encima.
-- El modo cambia por el atajo (como el usuario): el store puede decir una
-- cosa y el cambio optimista otra, y el que manda es el último.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "grid"
limpiarPeticiones()
onKey("g", true)
refrescar()
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
refrescar()
-- La columna del carrusel: la tira (row con gap 0) y debajo la barra.
enModo("carousel")
local col_carrusel = nil
walk(arbol, function(node)
	if node.__name == "column" and node.props.gap == 12 then
		local primera_fila = node.children and node.children[1]
		if primera_fila and primera_fila.__name == "row" and primera_fila.props.gap == 0 then
			col_carrusel = node
		end
	end
end)
check(col_carrusel ~= nil, "carrusel: la columna de la tira tiene gap de separación")
-- La barra (progress) tiene que ser el último hijo, después de la tira.
local tiene_progress = false
if col_carrusel ~= nil then
	for _, hijo in ipairs(col_carrusel.children) do
		walk(hijo, function(node)
			if node.__name == "progress" then
				tiene_progress = true
			end
		end)
	end
	-- Y no puede ser el primer hijo: tiene que ir DEBAJO de la tira.
	local primero_es_barra = false
	walk(col_carrusel.children[1], function(node)
		if node.__name == "progress" then
			primero_es_barra = true
		end
	end)
	check(not primero_es_barra, "carrusel: la barra no está en la primera fila")
end
check(tiene_progress, "carrusel: la barra está después de la tira")
-- La barra ocupa el ancho del panel, no 516 px pegados a la izquierda.
enModo("carousel")
local ancho_barra = 0
walk(arbol, function(node)
	if node.__name == "progress" then
		ancho_barra = node.props.width or 0
	end
end)
check(ancho_barra >= 1400, "carrusel: la barra ocupa todo el ancho (" .. tostring(ancho_barra) .. ")")

-- 29. El marco va DENTRO de la celda: no la desborda.
-- Regresión: el marco (padding 3 + borde) se sumaba por fuera y la tarjeta
-- medía 8 px más que su celda; en el carrusel el marco del wallpaper enfocado
-- se salía por abajo y la barra de progreso lo cruzaba.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 200, h = 120, progress = true }
refrescar()
local ancho_celda = 0
local ancho_imagen = 0
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and string.sub(key, -2) == "/f" then
		ancho_celda = node.props.width or 0
	end
	if node.__name == "image" then
		ancho_imagen = node.props.width or 0
	end
end)
check(ancho_celda == 0 or ancho_imagen <= ancho_celda,
	"carrusel: la imagen cabe dentro del marco")
-- El marco suma padding(3) + borde: la imagen es menor que el marco.
check(ancho_imagen < 200, "carrusel: la imagen descuenta el marco (" .. tostring(ancho_imagen) .. " < 200)")

-- 30. Los placeholders miden el slot completo.
-- Regresión: con el ancho escalado los slots vacíos eran más angostos que los
-- llenos y la tira quedaba asimétrica (el wallpaper enfocado a 47 px del
-- centro) y cambiaba de tamaño al mover el foco.
local anchos: { number } = {}
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and string.sub(key, -3) == "/f" then
		-- el marco no lleva el ancho: lo tiene la celda que lo contiene
	end
end)
local celdas: { number } = {}
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and (string.sub(key, -2) == "/f" or string.sub(key, -3) == "ph-") then
		celdas[#celdas + 1] = node.props.width or 0
	end
end)
-- Todas las celdas de la tira miden lo mismo (el slot).
local distintos = 0
for _, w in ipairs(celdas) do
	if w > 0 and w ~= celdas[1] then
		distintos += 1
	end
end
check(distintos == 0, "carrusel: todas las celdas miden el slot (" .. tostring(#celdas) .. " celdas, " .. tostring(distintos) .. " distintas)")

-- 31. La tira del carrusel entra en el panel, con las zonas dentro.
-- Regresión: había dos fórmulas de reparto (una sin descontar las zonas de
-- flecha) y la tira se salía del panel por 52 px.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
refrescar()
-- La tira: un row con las dos zonas de flecha y la fila de celdas.
local ancho_tira = 0
local n_zonas = 0
local ancho_zonas = 0
walk(arbol, function(node)
	if node.__name == "row" and node.props.justify == "space_between" and node.props.gap == 0 then
		for _, c in ipairs(node.children or {}) do
			local key = c.props.key
			if type(key) == "string" and string.sub(key, 1, 8) == "wh-edge-" then
				n_zonas += 1
				ancho_zonas += c.props.width or 0
			elseif c.__name == "row" then
				-- la fila de celdas: ancho = celdas + gaps
				local ancho = 0
				local n = #(c.children or {})
				for _, celda in ipairs(c.children or {}) do
					ancho += celda.props.width or 0
				end
				ancho_tira = ancho + math.max(0, n - 1) * (c.props.gap or 0)
			end
		end
	end
end)
check(n_zonas == 2, "carrusel: hay dos zonas de flecha (" .. tostring(n_zonas) .. ")")
check(ancho_tira + ancho_zonas <= 1456, "carrusel: la tira entra en el panel ("
	.. tostring(ancho_tira + ancho_zonas) .. " de 1456)")

-- 32. Los buscadores llevan ancho explicito.
-- Regla del host (lib/ui/controls/flex.cpp): `flexGrow` solo se reparte si el
-- contenedor tiene ancho conocido; un row anidado se mide por contenido y el
-- host salta el reparto. En un input, `width` es un minimo (setMinLayoutWidth):
-- sin el, el campo cae a kMinWidth (48 px) y no se ve.
TEST.store.source = "engine"
vista.mode = "grid"
refrescar()
local anchos = {}
walk(arbol, function(node)
	if node.__name == "input" and node.props.placeholder == "panel.search" then
		anchos[#anchos + 1] = node.props.width or 0
	end
end)
check(#anchos == 1, "grid: hay un buscador (" .. tostring(#anchos) .. ")")
check(anchos[1] == 320, "grid: el buscador lleva ancho explicito (" .. tostring(anchos[1]) .. ")")

-- En Wallhaven también.
TEST.store.source = "wallhaven"
refrescar()
anchos = {}
walk(arbol, function(node)
	if node.__name == "input" and node.props.placeholder == "panel.search" then
		anchos[#anchos + 1] = node.props.width or 0
	end
end)
check(#anchos == 1, "wallhaven: hay un buscador (" .. tostring(#anchos) .. ")")
check(anchos[1] == 320, "wallhaven: el buscador lleva ancho explicito (" .. tostring(anchos[1]) .. ")")

-- La raiz del panel usa align = "stretch": sin stretch los rows hijos se miden
-- por contenido y el host no reparte flexGrow.
TEST.store.source = "engine"
refrescar()
local raiz_stretch = false
walk(arbol, function(node)
	if node.__name == "column" and node.props.gap == 12 and node.props.paddingH == 16 then
		raiz_stretch = node.props.align == "stretch"
	end
end)
check(raiz_stretch, "la raiz del panel usa align=stretch (para que flexGrow reparta)")

TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"

-- 33. Barra de Wallhaven: cada chip manda sólo su filtro y sin página (si la
-- mandara, cambiar la pureza no reiniciaría la búsqueda).

TEST.store.source = "wallhaven"
S.wh = { purity = "100", categories_code = "111", page = 1, lastPage = 5, query = "", sorting = "date_added" }
refrescar()

limpiarPeticiones()
local chip_sketchy = botonConTexto("Sketchy")
check(chip_sketchy ~= nil, "wallhaven: existe el chip Sketchy")
if chip_sketchy ~= nil then
	chip_sketchy.props.onClick()
	local req = ultimaPeticion()
	check(req ~= nil and req.action == "set_wallhaven", "wallhaven: el chip pide set_wallhaven")
	check(req ~= nil and req.purity == "110", "wallhaven: purity 100 → 110 (" .. tostring(req and req.purity) .. ")")
	check(req ~= nil and req.page == nil, "wallhaven: el chip no manda page")
end

-- La paginación sí manda página.
limpiarPeticiones()
S.wh.page = 2
refrescar()
local siguiente = nil
walk(arbol, function(node)
	if siguiente == nil and node.__name == "button" and node.props.glyph == "chevron-right" then
		siguiente = node
	end
end)
check(siguiente ~= nil, "wallhaven: hay botón de página siguiente")
if siguiente ~= nil then
	siguiente.props.onClick()
	local req = ultimaPeticion()
	check(req ~= nil and req.action == "set_wallhaven" and req.page == 3, "wallhaven: siguiente → página 3")
end

TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"

-- Paginado de Opciones.
vista.view_label = true
refrescar()
S.screen = "options"
S.optPage = 1
-- Un render previo: `optRows` se llena al construir la pantalla, y sin eso el
-- tope de página es 1 y PgDn no avanza (falso OK).
onKey("right", true)
check((S.optRows or 0) > 4, "opciones: filas contadas (" .. tostring(S.optRows) .. ")")
onKey("next", true)
check(S.optPage == 5, "opciones: PgDn salta 4 filas (optPage=" .. tostring(S.optPage) .. ")")
onKey("prior", true)
check(S.optPage == 1, "opciones: PgUp vuelve al inicio")

-- 33. El carrusel NO tiene flechas dibujadas.
-- Regresión: las zonas de los extremos dibujaban un glifo `chevron-left` /
-- `chevron-right` que competía con las imágenes. Las ZONAS siguen (disparan
-- el scroll por hover), pero sin glifo.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
refrescar()
local glifos_flecha = 0
walk(arbol, function(node)
	if node.__name == "glyph" then
		local name = node.props.name
		if name == "chevron-left" or name == "chevron-right" then
			glifos_flecha += 1
		end
	end
end)
check(glifos_flecha == 0, "carrusel: no hay flechas dibujadas (" .. tostring(glifos_flecha) .. ")")

-- 34. Las zonas de scroll siguen existiendo (sin glifo).
local zonas_vivas = 0
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and string.sub(key, 1, 8) == "wh-edge-" then
		zonas_vivas += 1
	end
end)
check(zonas_vivas == 2, "carrusel: las dos zonas de scroll por hover siguen (" .. tostring(zonas_vivas) .. ")")

-- 35. El marco de las cards es transparente: el fondo donde están las
-- wallpapers tiene que ser el mismo que el del plugin.
-- Regresión: el marco usaba `surface_container/0.30`, un tinte translúcido
-- que se veía como un rectángulo de otro color alrededor de cada imagen.
local marcos_opacos = 0
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and string.sub(key, -2) == "/f" then
		local fill = node.props.fill
		-- Transparente: ausente, hex con alfa 0, o un rol con alfa 0.
		if fill ~= nil and fill ~= "#00000000" then
			if not (type(fill) == "string" and string.find(fill, "/0", 1, true) ~= nil) then
				marcos_opacos += 1
			end
		end
	end
end)
check(marcos_opacos == 0, "carrusel: los marcos de las cards son transparentes (" .. tostring(marcos_opacos) .. " con color)")

-- 36. El conteo de wallpapers visibles es configurable (3 o 5).
-- Con 5 el coverflow completo; con 3, sólo el enfocado y uno a cada lado.
function celdas_del_carrusel(): number
	local n = 0
	walk(arbol, function(node)
		if node.__name == "row" and node.props.justify == "space_between" then
			for _, c in ipairs(node.children or {}) do
				if c.__name == "row" then
					n = #(c.children or {})
				end
			end
		end
	end)
	return n
end
TEST.store.view = vista
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5 }
refrescar()
local con_cinco = celdas_del_carrusel()
check(con_cinco == 5, "carrusel: con slots=5 hay cinco celdas (" .. tostring(con_cinco) .. ")")
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3 }
refrescar()
local con_tres = celdas_del_carrusel()
check(con_tres == 3, "carrusel: con slots=3 hay tres celdas (" .. tostring(con_tres) .. ")")
-- Sin valor: 5 (el default).
vista.carousel = { layout = "full", w = 0, h = 0, progress = true }
refrescar()
check(celdas_del_carrusel() == 5, "carrusel: sin slots quedan cinco (el default)")

-- 37. Con 3 wallpapers la tira es más angosta que con 5.
function ancho_de_tira(): number
	local ancho = 0
	walk(arbol, function(node)
		if node.__name == "row" and node.props.justify == "space_between" then
			for _, c in ipairs(node.children or {}) do
				if c.__name == "row" then
					local total = 0
					local n = #(c.children or {})
					for _, celda in ipairs(c.children or {}) do
						total += celda.props.width or 0
					end
					ancho = total + math.max(0, n - 1) * (c.props.gap or 0)
				end
			end
		end
	end)
	return ancho
end
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5 }
refrescar()
local ancho5 = ancho_de_tira()
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3 }
refrescar()
local ancho3 = ancho_de_tira()
check(ancho3 < ancho5, "carrusel: con 3 la tira es más angosta que con 5 ("
	.. tostring(ancho3) .. " < " .. tostring(ancho5) .. ")")
-- Y el ancho de UNA CELDA es el mismo en los dos casos: la tira se acorta,
-- las imágenes no se estiran. (No se puede dividir el ancho total por la
-- cantidad de celdas: los gaps son una cantidad distinta en cada caso y
-- falsean la cuenta.)
function ancho_de_celda(): number
	local ancho = 0
	walk(arbol, function(node)
		if node.__name == "row" and node.props.justify == "space_between" then
			for _, c in ipairs(node.children or {}) do
				if c.__name == "row" then
					local primera = (c.children or {})[1]
					if primera ~= nil then
						ancho = primera.props.width or 0
					end
				end
			end
		end
	end)
	return ancho
end
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5 }
refrescar()
local celda5 = ancho_de_celda()
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3 }
refrescar()
local celda3 = ancho_de_celda()
check(celda3 == celda5,
	"carrusel: el ancho de la celda no cambia al cambiar el conteo ("
	.. tostring(celda3) .. " vs " .. tostring(celda5) .. ")")

-- 38. El slot de fuera de catálogo repite el wallpaper del borde.
-- Con el foco en el primer wallpaper, el slot izquierdo queda fuera del
-- catálogo. Antes era un hueco vacío (se veía un rectángulo vacío en la
-- tira); ahora repite el wallpaper del borde, atenuado.
TEST.store.source = "engine"
TEST.store.view = vista
vista.mode = "carousel"
vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 3 }
refrescar()
local placeholders = 0
walk(arbol, function(node)
	local key = node.props.key
	if type(key) == "string" and string.sub(key, 1, 3) == "ph-" then
		placeholders += 1
	end
end)
check(placeholders == 0, "carrusel: no hay huecos vacíos en la tira (" .. tostring(placeholders) .. ")")

-- 39. La tira se queda en el centro del panel.
-- El row de las celdas lleva `flexGrow = 1`: sin él el host lo mide por
-- contenido y, dentro de la tira (`space_between`), quedaba pegado a un
-- borde en vez de centrado.
local fila_con_grow = false
walk(arbol, function(node)
	if node.__name == "row" and node.props.justify == "center" and node.props.gap ~= nil and node.props.height ~= nil then
		fila_con_grow = (node.props.flexGrow or 0) > 0
	end
end)
check(fila_con_grow, "carrusel: la fila de celdas tiene flexGrow (se centra en el panel)")

-- En su propia función: el script concatenado está en el tope de 200
-- registros de Luau.
function tests_ancho_opciones(): ()
	-- 46. El ancho del panel se configura desde Opciones, uno por modo.
	-- El slider va de 0 (automático) a 1900; por debajo del escalón mínimo el
	-- valor se toma como automático.
	vista.mode = "carousel"
	vista.carousel = { layout = "full", w = 0, h = 0, progress = true, slots = 5, panel_w = 0 }
	vista.grid = { layout = "full", w = 0, h = 0, panel_w = 0 }
	abrirOpciones()
	check(sliderConEtiqueta("settings.layout.carousel_panel_w") ~= nil, "opciones: slider de ancho del panel del carrusel")
	check(sliderConEtiqueta("settings.layout.grid_panel_w") ~= nil, "opciones: slider de ancho del panel de la grilla")
	local sp = sliderConEtiqueta("settings.layout.carousel_panel_w")
	check(sp ~= nil and sp.props.min == 0 and sp.props.max == 1900,
		"opciones: el slider de panel va de 0 a 1900 ("
			.. tostring(sp and sp.props.min) .. ".." .. tostring(sp and sp.props.max) .. ")")
	volverABrowse()
end

tests_ancho_opciones()

-- ── resultado ───────────────────────────────────────────────────────
print("")
print("  " .. tostring(pasos - #fallos) .. "/" .. tostring(pasos) .. " checks OK")
if #fallos > 0 then
	print("  FALLARON:")
	for i = 1, #fallos do
		print("   - " .. fallos[i])
	end
	error("tests del panel: " .. tostring(#fallos) .. " fallas", 0)
end
print("  OK")

