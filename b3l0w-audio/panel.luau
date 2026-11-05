--!nonstrict
-- Panel de b3l0w/audio.
--
-- Tres vistas: salidas, entradas y streams por aplicación. Cada dispositivo
-- lleva slider de volumen (0..1.5, que es el 0..150% real de PipeWire), mute,
-- "usar como default", pin del default y —cuando la tarjeta los tiene— selector
-- de PERFIL y de CÓDEC (un códec A2DP es un perfil `a2dp-sink-<codec>`).
--
-- El panel no lanza procesos: publica requests por estado y el service los
-- ejecuta. Lo único local es la pestaña, el draft del slider y el cierre.

local anim = require("./lib/anim.luau")
local prefs = require("./lib/prefs.luau")
local theme = require("./lib/theme.luau")
local layout = require("./lib/layout.luau")

local T = noctalia.tr

local STATE_KEY = "b3l0w_audio_state"
local REQUEST_KEY = "b3l0w_audio_request"

local MAX_VOLUME = 1.5

-- Tabla de exports: los entries finos (`panel_compact.luau` y `float.luau`)
-- la usan para publicar los hooks globales del host. `require` corre el
-- módulo en su propio ámbito: las funciones definidas acá NO salen del
-- módulo como hooks, hay que devolverlas explícitamente.
local M: any = {}

-- El panel existe recién cuando el host llama `onOpen`. Antes de eso el
-- módulo se carga y el watcher de estado puede disparar: sin esta bandera
-- el render llama a `panel.render` sobre un panel inexistente.
local READY = false

-- El host es dueño del tamaño: `panel` (attached) y `float` son dos entries
-- del manifest. El MODO lo pasa el entry (ver `panel_compact.luau` y
-- `float.luau`), no el setting: el setting `panel_mode` elige qué entry
-- abre el WIDGET, pero si el usuario abre el otro entry desde el launcher
-- el código debe tener el ancho real para calcular los anchos.
--
-- Antes se leía `prefs.panel_mode()` y el bug era visible: al abrir
-- `audio:float` (1120 px) el código calculaba todo sobre 560 y la card
-- quedaba pegada a la izquierda con medio panel vacío.
local MODE = "compact"

local function panelWidth()
	return if MODE == "float" then 1120 else 560
end

-- El alto MÁXIMO del panel: el `max_height` del manifiesto (el host recorta
-- el panel a ese alto cuando el contenido no entra). No es el alto real: con
-- `height = "content"` el alto lo pone el contenido y este número sólo acota
-- el scroll.
local function panelMaxHeight()
	return if MODE == "float" then 820 else 680
end

local GAP = 6

-- Alto estimado de una card de stream: padding (16) + dos líneas de texto
-- (13 + 10 + 1) + el slider (24) + un gap (4).
-- El alto de una fila de stream: lo define el contenido, no una constante.
local STREAM_H = 68

-- El estado del panel: la pestaña, los drafts de los sliders y la animación.
-- Va ANTES de las funciones que lo leen: Luau resuelve los upvalues al crear
-- la closure, así que una función que use `S` antes de su declaración ve un
-- global nil en runtime.
local S = {
	tab = "sink",
	page = 1,
	draft = {},
	anim = { t = 1, from = 0, to = 0, ms = 220 },
	requests = 0,
	signature = "",
	-- Draft del balance por dispositivo: el valor va al service en onDragEnd.
	balanceDraft = {},
}

-- `render` se declara ACÁ y no junto a su definición: la declaración de un
-- `local` en Luau sólo existe desde su línea hacia adelante. Con la
-- declaración más abajo, `onFrameTick` (el tick de la animación) y el click
-- de las pestañas capturaban un `render` GLOBAL (nil) y reventaban al
-- llamarlo: "attempt to call a nil value".
--
-- Es el mismo motivo por el que `S` va antes de las funciones que lo leen.
local render: () -> ()

-- El alto del cromo: cabecera + pestañas + pie.
--
-- `CHROME_H` era 190 fijo, pero el cromo cambia: con el panel compacto las
-- pestañas ocupan DOS filas (los tabs arriba, las acciones abajo) y con el
-- flotante una sola. Con 190 fijo el scroll se comía 40 px de más en el
-- compacto (la última card quedaba tapada) y dejaba hueco en el flotante.
--
-- Se estima por partes: cada fila del cromo son ~34 px (control sm + padding)
-- y el pie ~24. No es una medida exacta (el host no expone la medición al
-- script), pero sigue al cromo que se dibuja en vez de ser un número fijo.
--
-- La barra de perfiles suma dos filas más cuando está visible (sólo en las
-- pestañas de dispositivo).
local function chromeHeight(compact: boolean): number
	-- El cromo (cabecera + pestañas + pie) es el único alto estimado: se
	-- calcula POR PARTES y de sobra, con layout.chrome.
	local headerH = 34
	local tabsH = compact and 68 or 34
	local footerH = 24
	local profileH = if S.tab == "sink" or S.tab == "source" then 56 else 0
	-- `layout.chrome` SÓLO suma las partes: no sabe de los `gap = 8` con los
	-- que el root separa cada bloque. Sin contarlos, la lista pide 24-32 px
	-- de más, el árbol supera el `max_height` y el host recorta el pie (el
	-- hint de abajo se veía cortado por la mitad).
	local separaciones = if profileH > 0 then 4 else 3
	return layout.chrome({ headerH, tabsH, profileH, footerH }) + separaciones * 8
end

local SNAP = { state = nil }

local function st(): any
	local cached = SNAP.state
	if type(cached) == "table" then
		return cached
	end
	local value = noctalia.state.get(STATE_KEY)
	return if type(value) == "table" then value else {}
end


-- La animación necesita un tick: sin él `S.anim.t` queda en 0 y las filas
-- se quedan con la opacidad del primer frame. Este hook lo publica el
-- entry (que es el que el host llama).
function onFrameTick(delta: any): ()
	if S.anim.t >= 1 or not prefs.animations() then
		return
	end
	S.anim.t = math.min(1, S.anim.t + (tonumber(delta) or 16) / (S.anim.ms or 220))
	render()
end

-- Anchos reales, no aproximados:
--   - el host recorta 12 px del ancho pedido del panel (contrato de layout);
--   - la columna raíz usa padding 6 a cada lado;
--   - la card usa paddingH 10 a cada lado.
-- Los números fixes (16, 12, 280, 330) salían mal apenas cambiaba la
-- densidad, el tamaño de fuente o el ancho del panel: el texto se salía de
-- la caja o sobraba espacio.
local function inner(): number
	return panelWidth() - 12 - 12
end

local function rowWidth(): number
	return inner() - 20
end

-- El alto útil de la lista: el panel menos la cabecera, las pestañas y el
-- pie. CHROME_H era 190 fijo y con el panel float (820) dejaba 630 de hueco
-- muerto abajo; con el compacto (680) recortaba la última card.
-- El alto MÁXIMO de la lista: el panel menos el cromo (cabecera, pestañas,
-- pie). Es un tope, no el alto final: el scroll toma el menor entre este
-- tope y lo que miden las cards.
local function listMaxHeight(): number
	local compact = panelWidth() < 900
	return math.max(200, panelMaxHeight() - chromeHeight(compact))
end

-- Estimación de lo que mide el contenido de la lista.
--
-- El host NO expone la medición al script (no hay `measure` en la API de
-- plugins), así que la altura hay que estimarla. La estimación es
-- DELIBERADAMENTE generosa: si se queda corta, el scroll thinks que ya
-- entró todo y la última card queda tapada sin que haya forma de llegar a
-- ella; si sobra, el scroll tiene un poco de hueco vacío abajo, que es
-- un fallo mucho menos grave.
--
-- Lo que mide una card:
--   - padding vertical: 8 + 8
--   - la fila de la cabecera: el glifo (16) o dos líneas de texto (13 + 10
--     + 2 de gap) -> 30
--   - la fila del slider: el control sm ~24
--   - cada selector (perfil, códec): ~34 (label + select)
--   - gaps: 4 entre hijos
local CARD_BASE_H = 8 + 8 + 30 + 24 + 4
local SELECTOR_H = 34

local function estimateContentHeight(rows: any): number
	local total = 0
	for _, row in ipairs(rows or {}) do
		local height = CARD_BASE_H
		if type(row.profiles) == "table" and #row.profiles > 1 then
			height = height + SELECTOR_H + 4
		end
		if type(row.codecs) == "table" and #row.codecs > 0 then
			height = height + SELECTOR_H + 4
		end
		-- Una fila por canal (el control sm ~24) y, con dos canales, el
		-- balance: son filas que la card grew sin que el cálculo lo supiera.
		local channels = row.channels or {}
		if #channels > 1 then
			height = height + (#channels * 28)
			if #channels == 2 then
				height = height + 28
			end
		end
		total = total + height + GAP
	end
	return math.max(0, total - GAP)
end

-- El alto del scroll: el menor entre lo que mide el contenido y el tope.
--
-- El patrón es el del grid del plugin de wallpaper: `height = "content"` en
-- el manifiesto hace que el host mida el árbol y ajuste el panel, así que el
-- scroll puede declarar un alto FIJO (el viewport) y el contenido que sobra
-- se scrollea. Si el contenido es más chico que el alto declarado, el host
-- recorta el panel: no queda hueco muerto abajo.
-- El alto de un estado vacío ("sin dispositivos", "sin streams"): no hay
-- contenido que medir, pero la caja del mensaje necesita un alto.
local EMPTY_STATE_H = 160

-- `estimated` puede venir nil a propósito: los estados vacíos llaman
-- `listHeight()` sin argumento. Sin el valor por defecto, `math.min(nil, …)`
-- revienta en el render y el host termina deshabilitando el panel por
-- timeouts repetidos ("disabled after repeated timeouts").
local function listHeight(estimated: number?): number
	return math.max(1, math.min(tonumber(estimated) or EMPTY_STATE_H, listMaxHeight()))
end

local function percent(value: any): string
	return tostring(math.floor((tonumber(value) or 0) + 0.5)) .. "%"
end

-- Slider en unidades de volumen (0..1.5), que es como lo reporta PipeWire.
local function units(row: any): number
	local value = tonumber(row.volume) or 0
	return math.max(0, math.min(MAX_VOLUME, value / 100))
end

-- El nonce lleva un contador: dos acciones en el mismo milisegundo comparten
-- reloj y el service descartaría la segunda como duplicada.
local function send(payload): ()
	S.requests = S.requests + 1
	payload.nonce = tostring(math.floor(os.clock() * 1000)) .. ":" .. tostring(S.requests)
	noctalia.state.set(REQUEST_KEY, payload)
end

local function devices(): any
	local state = st()
	return if S.tab == "source" then (state.sources or {}) else (state.sinks or {})
end

-- Alto MÍNIMO estimado de una card. Es una estimación a propósito: la card
-- real no tiene altura fija, así que el valor real puede ser mayor (título
-- en dos líneas) y la paginación debe sobreestimar para no recortar nada.

local function has_bluetooth(rows: any): boolean
	for _, row in ipairs(rows or {}) do
		if row.bluetooth then
			return true
		end
	end
	return false
end

-- La rueda del mouse no llega a los paneles: lo que no entra en el alto útil se
-- pagina, no se scrollea.

-- Fila con borde y texto: `ui.box` es hoja, así que un chip es un `ui.row`.
local function chip(text: string, color: string): any
	return ui.row({
		fill = theme.chip(),
		radius = 6,
		paddingH = 6,
		paddingV = 2,
		align = "center",
	}, {
		ui.label({ text = layout.ellipsis(text, 50), fontSize = 10, color = color }),
	})
end

local function subtitle(row: any): string
	local state = st()
	local parts = {}
	if row.active then
		table.insert(parts, T("panel.active"))
	elseif row.bluetooth then
		table.insert(parts, T("panel.bluetooth"))
	else
		table.insert(parts, T("panel.available"))
	end
	if type(row.codec) == "string" and row.codec ~= "" then
		table.insert(parts, T("panel.codec_now", { codec = string.upper(row.codec) }))
	end
	-- El sample rate REAL que publica el backend (no el pedido).
	local rate = tonumber(row.rate) or 0
	if rate > 0 then
		table.insert(parts, T("panel.rate", { rate = tostring(rate) }))
	end
	-- La latencia REAL del dispositivo, en microsegundos.
	local latency = type(row.latency) == "table" and (tonumber(row.latency.actual) or 0) or 0
	if latency > 0 then
		table.insert(parts, T("panel.latency", { latency = tostring(latency) }))
	end
	if tonumber(row.battery) ~= nil and noctalia.getConfig("show_battery") ~= false then
		table.insert(parts, T("panel.battery", { percent = percent(row.battery) }))
	end
	if S.tab == "sink" and row.active and tonumber(state.streamCount) ~= nil and state.streamCount > 0 then
		table.insert(parts, T("panel.streams", { count = tostring(state.streamCount) }))
	end
	if row.active and state.pinned == row.name then
		table.insert(parts, T("panel.pinned"))
	end
	return table.concat(parts, "  ·  ")
end

-- ── cabecera ─────────────────────────────────────────────────────────

local function header(): any
	local state = st()
	local muted = state.allMuted == true
	local subtitle
	local subtitleColor = theme.muted()
	if tostring(state.err or "") ~= "" then
		subtitle = tostring(state.err)
		subtitleColor = theme.danger()
	elseif state.phase == "loading" then
		subtitle = T("panel.loading")
	else
		subtitle = T("panel.defaults", {
			output = tostring(state.defaultSinkName or T("panel.no_output")),
			input = tostring(state.defaultSourceName or T("panel.no_input")),
		})
	end

	return ui.row({ gap = 8, padding = 6, align = "center" }, {
		ui.glyph({ name = if muted then "volume-x" else "volume-2", size = 18, color = if muted then theme.warn() else "primary" }),
		ui.label({ text = T("panel.title"), fontSize = 16, fontWeight = "semibold" }),
		-- Sin `maxWidth` calculado: el subtítulo toma el ancho que sobra
		-- (flexGrow) y el host lo recorta a una línea con elipsis. El número
		-- fijo (260) dejaba el subtítulo en 300 px con el panel compacto
		-- (560) y sobraba hueco con el flotante (1120).
		ui.label({
			text = layout.ellipsis(subtitle, 46),
			fontSize = 11,
			color = subtitleColor,
			maxLines = 1,
			flexGrow = 1,
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			glyph = "refresh",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.refresh"),
			onClick = function()
				send({ action = "refresh" })
			end,
		}),
		ui.button({
			glyph = "settings",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "close",
			controlSize = "sm",
			variant = "ghost",
			tooltip = T("panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

-- `compact`: sin texto, sólo el glifo y el número. El tooltip lleva el
-- nombre completo, así que no se pierde información.
local function tabButton(value: string, label: string, glyph: string, count: number, compact: boolean): any
	local active = S.tab == value
	local text = if compact then tostring(count) else (label .. " (" .. tostring(count) .. ")")
	return ui.button({
		key = "tab-" .. value,
		text = text,
		glyph = glyph,
		controlSize = "sm",
		variant = if active then "secondary" else "ghost",
		selected = active,
		tooltip = label .. " (" .. tostring(count) .. ")",
		onClick = function()
			S.tab = value
			S.page = 1
			S.anim.t = if prefs.animations() then 0 else 1
			render()
		end,
	})
end

-- La barra de pestañas y las acciones.
--
-- En el panel compacto (560 px) los cinco controles CON texto no caben: los
-- tres tabs ("Salidas (1)", "Entradas (0)", "Streams (0)") más "Silenciar
-- todo" y "Siguiente" miden unos 620 px y se salían del panel por la derecha
-- (el último botón quedaba cortado).
--
-- La solución no es un número mágico sino dejar que el contenido se ajuste:
-- cuando el panel es estrecho, las acciones pasan a una segunda fila y el
-- texto de los botones es opcional (el glifo + el tooltip ya dicen qué es).
-- En el panel flotante (1120 px) todo entra en una fila y se ve el texto.
local function tabs(): any
	local state = st()
	local muted = state.allMuted == true
	local narrow = panelWidth() < 900

	local tabRow = ui.row({ gap = 8, paddingH = 6, align = "center" }, {
		tabButton("sink", T("panel.outputs"), "volume-2", #(state.sinks or {}), narrow),
		tabButton("source", T("panel.inputs"), "microphone", #(state.sources or {}), narrow),
		tabButton("stream", T("panel.streams_tab"), "music", tonumber(state.streamCount) or 0, narrow),
		tabButton("filters", T("panel.filters"), "filter", #(state.modules or {}), narrow),
		tabButton("bt", T("panel.bt_tab"), "bluetooth", #(state.btList or {}), narrow),
	})

	local muteButton = ui.button({
		key = "mute-all",
		text = if muted then T("panel.unmute_all") else T("panel.mute_all"),
		glyph = if muted then "volume-2" else "volume-x",
		controlSize = "sm",
		variant = if muted then "primary" else "outline",
		tooltip = T("panel.mute_all_tip"),
		-- Los filtros y el bluetooth no son dispositivos: el mute y el ciclo
		-- no aplican ahí.
		visible = S.tab == "sink" or S.tab == "source",
		onClick = function()
			send({ action = "mute_all", muted = not muted })
		end,
	})

	local cycleButton = ui.button({
		key = "cycle",
		text = T("panel.cycle"),
		glyph = "arrows-shuffle",
		controlSize = "sm",
		variant = "ghost",
		tooltip = T("panel.cycle_tip"),
		visible = S.tab == "sink" or S.tab == "source",
		onClick = function()
			send({ action = if S.tab == "source" then "cycle_input" else "cycle_output" })
		end,
	})

	if narrow then
		-- Panel estrecho: los tabs en una fila y las acciones en otra.
		return ui.column({ gap = 6, paddingH = 6 }, {
			tabRow,
			ui.row({ gap = 8, paddingH = 6, align = "center" }, {
				ui.spacer({ flexGrow = 1 }),
				muteButton,
				cycleButton,
			}),
		})
	end

	-- Panel ancho: todo en una fila, con el texto.
	return ui.row({ gap = 8, paddingH = 6, align = "center" }, {
		tabButton("sink", T("panel.outputs"), "volume-2", #(state.sinks or {}), false),
		tabButton("source", T("panel.inputs"), "microphone", #(state.sources or {}), false),
		tabButton("stream", T("panel.streams_tab"), "music", tonumber(state.streamCount) or 0, false),
		tabButton("filters", T("panel.filters"), "filter", #(state.modules or {}), false),
		tabButton("bt", T("panel.bt_tab"), "bluetooth", #(state.btList or {}), false),
		ui.spacer({ flexGrow = 1 }),
		muteButton,
		cycleButton,
	})
end

-- ── selectores de perfil y códec ─────────────────────────────────────

-- Los dos selectores son la misma lista de `pactl list cards` con distinto
-- filtro. El índice elegido se deriva SIEMPRE del activo del estado, nunca de un
-- literal: con un `selectedIndex` fijo el refresco devuelve el selector a la
-- primera opción y el usuario lo reporta como "no me deja cambiar".
local function selectRow(row: any, items: any, title: string, action: string, prefix: string, labeler): any
	local options = {}
	local selected = 0
	for index, profile in ipairs(items) do
		table.insert(options, labeler(profile))
		if profile.active then
			selected = index - 1
		end
	end

	-- El label y el selector van EN LÍNEA, pero el `flexGrow` del select
	-- necesita que la row tenga ancho conocido.
	--
	-- La regla del host (flex.cpp): `flexGrow` se reparte sólo si el
	-- contenedor tiene ancho conocido (`mainKnown`) y `totalGrow > 0`. Una
	-- row dentro de una column con `align = "stretch"` SÍ lo tiene (la column
	-- le da su ancho), así que el select se lleva el espacio que sobra.
	--
	-- El error anterior era al revés: el select estaba dentro de una COLUMN
	-- con `align = "stretch"`, y ahí `flexGrow` crece VERTICALMENTE (el eje
	-- principal de una column es el vertical). El selector quedaba en una
	-- fila aparte, con el label arriba, ocupando el doble de alto.
	return ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = layout.ellipsis(title, 40), fontSize = 10, color = theme.dim() }),
		ui.select({
			key = prefix .. "-" .. tostring(row.name),
			options = options,
			selectedIndex = selected,
			flexGrow = 1,
			enabled = row.cardName ~= "",
			onChange = function(value)
				local index = (math.floor(tonumber(value) or 0)) + 1
				local profile = items[index]
				if profile == nil or profile.active then
					return
				end
				send({ action = action, card = row.cardName, profile = profile.name })
			end,
		}),
	})
end

local function codecLabel(profile: any): string
	local label = tostring(profile.codec or profile.name)
	if profile.telephony then
		label = label .. " (" .. T("panel.codec_voice") .. ")"
	elseif profile.hires then
		label = label .. " (" .. T("panel.codec_hires") .. ")"
	end
	return label
end

local function profileLabel(profile: any): string
	local label = tostring(profile.description or profile.name)
	if profile.available == false then
		label = label .. " · " .. T("panel.codec_unavailable")
	end
	return label
end

-- ── perfiles de audio ───────────────────────────────────────────────

-- Los tres perfiles: música, telephonía y Hi-Res. El que está activo sale
-- del estado publicado por el service (`audioProfile`), nunca de un literal.
local PROFILE_IDS = { "music", "telephony", "hires" }

local function profileButton(profileId: string): any
	local state = st()
	local active = state.audioProfile == profileId
	local label = T("panel.profile_" .. profileId)
	return ui.button({
		key = "profile-" .. profileId,
		text = label,
		controlSize = "sm",
		variant = if active then "secondary" else "ghost",
		selected = active,
		tooltip = label .. " · " .. T("panel.profile_hint"),
		onClick = function()
			send({ action = "apply_profile", profile = profileId })
		end,
	})
end

-- La barra de perfiles: sólo cuando hay un sink (el perfil se aplica al
-- default de salida). Muestra el sample rate REAL que publica el backend.
local function profileBar(): any
	local state = st()
	if #(state.sinks or {}) == 0 then
		return nil
	end

	local rate = tonumber(state.rateActual) or 0
	local buttons = {}
	for _, profileId in ipairs(PROFILE_IDS) do
		table.insert(buttons, profileButton(profileId))
	end

	-- La columna de la barra lleva `flexGrow = 1`: sin ella mide por
	-- contenido y el label de la derecha (el sample rate) se sale del
	-- panel: en el compacto de 560 px se veía "48000" y el " Hz" cortado
	-- contra el borde.
	--
	-- `align = "stretch"` hace que las filas hereden el ancho de la columna,
	-- que es lo que permite que el spacer reparta el espacio sobrante.
	return ui.column({ gap = 4, align = "stretch", flexGrow = 1 }, {
		ui.row({ gap = 6, paddingH = 6, align = "center" }, {
			ui.label({ text = T("panel.audio_profile"), fontSize = 10, color = theme.dim() }),
			ui.spacer({ flexGrow = 1 }),
			ui.label({
				text = if rate > 0 then T("panel.rate", { rate = tostring(rate) }) else "",
				fontSize = 10,
				color = theme.dim(),
				-- `maxLines = 1` recorta el texto con elipsis en vez de
				-- desbordarlo: el label se dibujaba hasta el borde del panel
				-- y el " Hz" del sample rate se perdía.
				--
				-- `flexGrow = 1` le da un ancho CONOCIDO: sin él el host lo
				-- mide por su texto y lo dibuja entero, aunque no entre. Con
				-- el grow el host lo acota al espacio que sobra y el
				-- `maxLines` hace su trabajo.
				flexGrow = 1,
				maxLines = 1,
			}),
		}),
		ui.row({ gap = 6, paddingH = 6, align = "center" }, buttons),
	})
end

-- ── volumen por canal y balance ──────────────────────────────────────

-- Una fila por canal con su propio slider. El canal se identifica por su
-- nombre real (front-left / front-right / surround…).
local function channelRow(row: any, index: number, channel: any): any
	local draftKey = "ch:" .. row.name .. ":" .. tostring(index)
	local draft = S.draft[draftKey]
	local shown = if draft ~= nil then draft else (tonumber(channel.percent) or 0)

	local name = string.lower(tostring(channel.name or ""))
	local short = string.upper(tostring(channel.name or "?"))
	if string.find(name, "left", 1, true) ~= nil then
		short = T("panel.channel_left")
	elseif string.find(name, "right", 1, true) ~= nil then
		short = T("panel.channel_right")
	end

	-- `width = "fill"`: sin ancho el row mide su contenido y el slider con
	-- `flexGrow = 1` empuja el "%" fuera del panel (se veía "100" cortado).
	return ui.row({ width = "fill", gap = 6, align = "center" }, {
		ui.label({ text = short, fontSize = 10, color = theme.dim() }),
		ui.slider({
			key = draftKey,
			min = 0,
			max = MAX_VOLUME,
			step = 0.01,
			value = math.min(MAX_VOLUME, shown / 100),
			flexGrow = 1,
			onChange = function(next)
				S.draft[draftKey] = math.floor((tonumber(next) or 0) * 100 + 0.5)
			end,
			onDragEnd = function()
				local target = S.draft[draftKey]
				S.draft[draftKey] = nil
				if target == nil then
					return
				end
				send({
					action = "set_channel_volume",
					kind = row.kind,
					name = row.name,
					channel = index,
					value = target,
				})
			end,
		}),
		-- `maxLines = 1`: el label está al final de un row y sin un ancho
		-- conocido el host lo dibuja entero, aunque se salga del panel.
		ui.label({ text = percent(shown), fontSize = 10, color = theme.muted(), maxLines = 1 }),
	})
end

-- El balance estéreo: -1 (izquierda) a 1 (derecha).
local function balanceRow(row: any): any
	local draftKey = "bal:" .. row.name
	local draft = S.balanceDraft[draftKey]
	local shown = if draft ~= nil then draft else (tonumber(row.balance) or 0)

	return ui.row({ width = "fill", gap = 6, align = "center" }, {
		ui.label({ text = T("panel.balance"), fontSize = 10, color = theme.dim() }),
		ui.slider({
			key = draftKey,
			min = -1,
			max = 1,
			step = 0.01,
			value = shown,
			flexGrow = 1,
			onChange = function(next)
				S.balanceDraft[draftKey] = tonumber(next) or 0
			end,
			onDragEnd = function()
				local target = S.balanceDraft[draftKey]
				S.balanceDraft[draftKey] = nil
				if target == nil then
					return
				end
				send({ action = "set_balance", kind = row.kind, name = row.name, value = target })
			end,
		}),
		ui.label({ text = tostring(math.floor(shown * 100) / 100), fontSize = 10, color = theme.muted() }),
	})
end

-- ── filtros de WirePlumber ───────────────────────────────────────────

-- Cada módulo de filtro es un setting Boolean de WirePlumber: se habilita o
-- se deshabilita con `wpctl settings <id> true|false`.
local function moduleRow(module: any): any
	local enabled = string.lower(tostring(module.value or "")) == "true"
	return ui.row({
		gap = 8,
		paddingH = 10,
		paddingV = 6,
		align = "center",
		fill = theme.surface(),
		radius = 8,
	}, {
		ui.column({ gap = 1, flexGrow = 1, minWidth = 0, align = "stretch" }, {
			ui.label({
				text = tostring(module.name or module.id or ""),
				fontSize = 11,
				maxLines = 1,
			}),
			ui.label({
				text = layout.ellipsis(tostring(module.id or ""), 44),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
			}),
		}),
		ui.button({
			key = "mod-" .. tostring(module.id or ""),
			text = if enabled then T("panel.module_on") else T("panel.module_off"),
			controlSize = "sm",
			variant = if enabled then "primary" else "outline",
			enabled = tostring(module.type or "") == "Boolean",
			tooltip = tostring(module.desc or ""),
			onClick = function()
				send({ action = "set_module", id = module.id, value = not enabled })
			end,
		}),
	})
end

local function filtersList(): any
	local state = st()
	local modules = state.modules or {}
	local filters = state.filters or {}

	local children = {}

	table.insert(children, ui.row({ gap = 6, paddingH = 6, align = "center" }, {
		ui.glyph({ name = "filter", size = 14, color = theme.dim() }),
		ui.label({ text = T("panel.filters_hint"), fontSize = 10, color = theme.dim() }),
	}))

	if #modules == 0 then
		table.insert(children, ui.column({ height = 120, align = "center", justify = "center", gap = 6 }, {
			ui.label({ text = T("panel.filters_empty"), fontSize = 11, color = theme.muted(), textAlign = "center" }),
		}))
	else
		for _, module in ipairs(modules) do
			table.insert(children, moduleRow(module))
		end
	end

	-- Los filtros VIVOS en el grafo: son los nodos de filtro que WirePlumber
	-- tiene cargados ahora mismo.
	table.insert(children, ui.label({
		text = T("panel.filters_live"),
		fontSize = 10,
		color = theme.dim(),
		paddingH = 6,
	}))
	if #filters == 0 then
		table.insert(children, ui.label({
			text = T("panel.filters_live_empty"),
			fontSize = 10,
			color = theme.dim(),
			paddingH = 6,
		}))
	else
		for _, filter in ipairs(filters) do
			table.insert(children, ui.row({ gap = 6, paddingH = 6, align = "center" }, {
				ui.glyph({ name = "filter", size = 12, color = theme.dim() }),
				ui.label({ text = tostring(filter.name or ""), fontSize = 11, maxLines = 1 }),
				ui.spacer({ flexGrow = 1 }),
				ui.label({ text = tostring(filter.id or ""), fontSize = 10, color = theme.dim() }),
			}))
		end
	end

	return ui.scroll(layout.merge({
		key = "filters",
		gap = GAP,
		paddingH = 2,
		align = "stretch",
	}, layout.scrollExtra(listHeight(#modules * 52 + #filters * 28 + 90))), children)
end

-- ── dispositivos bluetooth ───────────────────────────────────────────

local function btRow(device: any): any
	local connected = device.connected == true
	local tags = {}
	if connected then
		table.insert(tags, T("panel.bt_connected"))
	elseif device.paired == true then
		table.insert(tags, T("panel.bt_paired"))
	else
		table.insert(tags, T("panel.bt_unpaired"))
	end
	if tonumber(device.battery) ~= nil then
		table.insert(tags, T("panel.battery", { percent = percent(device.battery) }))
	end

	return ui.row({
		gap = 8,
		paddingH = 10,
		paddingV = 6,
		align = "center",
		fill = theme.surface(),
		radius = 8,
	}, {
		ui.glyph({ name = if connected then "bluetooth" else "bluetooth-off", size = 14, color = if connected then "primary" else theme.dim() }),
		ui.column({ gap = 1, flexGrow = 1, minWidth = 0, align = "stretch" }, {
			ui.label({ text = tostring(device.name or device.mac or ""), fontSize = 11, maxLines = 1 }),
			ui.label({
				text = layout.ellipsis(table.concat(tags, "  ·  "), 46),
				fontSize = 10,
				color = theme.dim(),
				maxLines = 1,
			}),
		}),
		ui.button({
			key = "bt-" .. tostring(device.mac or ""),
			text = if connected then T("panel.bt_disconnect") else T("panel.bt_connect"),
			controlSize = "sm",
			variant = if connected then "outline" else "primary",
			enabled = device.paired == true,
			onClick = function()
				send({
					action = if connected then "bt_disconnect" else "bt_connect",
					mac = device.mac,
				})
			end,
		}),
	})
end

local function btList(): any
	local state = st()
	local devices = state.btList or {}

	if #devices == 0 then
		return ui.column({ height = listHeight(), align = "center", justify = "center", gap = 6 }, {
			ui.glyph({ name = "bluetooth-off", size = 26, color = theme.dim() }),
			ui.label({ text = T("panel.bt_empty"), fontSize = 12, color = theme.muted(), textAlign = "center" }),
		})
	end

	local children = {}
	for _, device in ipairs(devices) do
		table.insert(children, btRow(device))
	end

	return ui.scroll(layout.merge({
		key = "bt",
		gap = GAP,
		paddingH = 2,
		align = "stretch",
	}, layout.scrollExtra(listHeight(#devices * 46))), children)
end

-- ── fila de dispositivo ──────────────────────────────────────────────

local function deviceCard(row: any, index: number): any
	-- Slider controlado: el draft sólo viaja al service en onDragEnd y lo que se
	-- dibuja sale del estado publicado, así un refresco no queda pisado por un
	-- valor local viejo.
	local draftKey = "v:" .. row.name
	local draft = S.draft[draftKey]
	local shown = if draft ~= nil then draft else tonumber(row.volume) or 0
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.05) else 1

	-- El título NO lleva `maxWidth` calculado a mano. El ancho de los botones
	-- de la cabecera cambia con el texto ("Use" / "Is default"), con el ancho
	-- del panel y con el tema, así que cualquier número fijo (330, 150, 260…)
	-- se queda corto o sobra.
	--
	-- En vez de eso: la columna del texto lleva `flexGrow = 1` y `minWidth = 0`
	-- (column SÍ acepta minWidth: está en el conjunto kFlex del reconciler),
	-- así que toma todo el ancho que sobra y el label se recorta con puntos
	-- suspensivos a una línea (maxLines = 1). El recorte lo hace el host
	-- contra el ancho real, no contra una cuenta.
	-- La fila del título lleva `flexGrow = 1`: sin esto mide por contenido y
	-- el título queda pegado al chip "default" en vez de ocupar el ancho
	-- disponible. Con el grow, el label del título (que también lo lleva)
	-- se lleva el espacio que sobra y se recorta con elipsis si hace falta;
	-- el chip queda al borde.
	local titleRow = {
		ui.label({
			text = tostring(row.description or row.name),
			fontSize = 13,
			fontWeight = "semibold",
			maxLines = 1,
			flexGrow = 1,
		}),
	}
	if row.active then
		table.insert(titleRow, chip(T("panel.active"), theme.ok()))
	end

	local glyph = "volume-2"
	if row.bluetooth then
		glyph = "headphones"
	elseif row.kind == "source" then
		glyph = "microphone"
	elseif row.muted then
		glyph = "volume-x"
	end

	local pinned = row.active and st().pinned == row.name

	local headButtons = {
		ui.label({ text = percent(shown), fontSize = 11, color = theme.muted(), maxLines = 1 }),
		ui.button({
			glyph = if row.muted then "volume-x" else "volume-2",
			controlSize = "sm",
			variant = if row.muted then "primary" else "ghost",
			tooltip = if row.muted then T("panel.unmute") else T("panel.mute"),
			onClick = function()
				send({ action = "toggle_mute", kind = row.kind, name = row.name })
			end,
		}),
		ui.button({
			text = if row.active then T("panel.is_default") else T("panel.use"),
			controlSize = "sm",
			variant = if row.active then "ghost" else "outline",
			enabled = row.active ~= true,
			onClick = function()
				send({ action = "set_default", kind = row.kind, name = row.name })
			end,
		}),
	}

	if row.kind == "sink" then
		table.insert(headButtons, ui.button({
			glyph = if pinned then "pin" else "pinned-off",
			controlSize = "sm",
			variant = if pinned then "primary" else "ghost",
			tooltip = if pinned then T("panel.unpin_tip") else T("panel.pin_tip"),
			visible = row.active == true,
			onClick = function()
				if pinned then
					send({ action = "unpin_default" })
				else
					send({ action = "pin_default", name = row.name })
				end
			end,
		}))
	end

	local head = {
		ui.glyph({ name = glyph, size = 16, color = if row.active then "primary" else theme.dim() }),
		-- `align = "stretch"`: el default del host es `center` (flex.h:
		-- `m_align = FlexAlign::Center`), y con `center` los hijos de una
		-- column NO se estiran: la fila del título mide por contenido y el
		-- título queda pegado al chip "default" en vez de ocupar el ancho.
		-- Con stretch la fila toma el ancho de la columna y el label (que
		-- lleva flexGrow) se lleva el espacio que sobra.
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0, align = "stretch" }, {
			ui.row({ gap = 6, align = "center", flexGrow = 1 }, titleRow),
			ui.label({
				text = subtitle(row),
				fontSize = 10,
				color = if row.active then theme.info() else theme.dim(),
				maxLines = 1,
			}),
		}),
	}
	for _, button in ipairs(headButtons) do
		table.insert(head, button)
	end

	local children = {
		ui.row({ gap = 8, align = "center" }, head),
		ui.row({ gap = 8, align = "center" }, {
			ui.slider({
				key = "vol-" .. row.name,
				min = 0,
				max = MAX_VOLUME,
				step = 0.01,
				value = units(row),
				flexGrow = 1,
				onChange = function(next)
					S.draft[draftKey] = math.floor((tonumber(next) or 0) * 100 + 0.5)
				end,
				onDragEnd = function()
					local target = S.draft[draftKey]
					S.draft[draftKey] = nil
					if target == nil then
						return
					end
					send({ action = "set_volume", kind = row.kind, name = row.name, value = target })
				end,
			}),
			ui.button({
				text = T("panel.move_here"),
				glyph = "corner-down-right",
				controlSize = "sm",
				variant = "ghost",
				visible = S.tab == "sink" and row.active ~= true,
				tooltip = T("panel.move_here_tip"),
				onClick = function()
					send({ action = "move_streams", sink = row.name })
				end,
			}),
		}),
	}

	-- Perfil de la tarjeta y, para bluetooth, el códec (mismo comando, otra
	-- lista: los A2DP son los perfiles `a2dp-sink-<codec>`).
	if type(row.profiles) == "table" and #row.profiles > 1 then
		table.insert(children, selectRow(row, row.profiles, T("panel.profile"), "set_profile", "profile", profileLabel))
	end
	if type(row.codecs) == "table" and #row.codecs > 0 then
		table.insert(children, selectRow(row, row.codecs, T("panel.codec"), "set_codec", "codec", codecLabel))
	end

	-- Volumen POR CANAL: sólo tiene sentido si el backend publica más de un
	-- canal (un sink mono no los tiene). Los controles finos van detrás de
	-- `show_advanced`: con la vista simple el panel es más corto.
	-- Volumen POR CANAL y balance estéreo: se muestran SIEMPRE. Son los
	-- controles finos del dispositivo (izq/der) y el usuario los pidió
	-- explícitamente; esconderlos detrás de un setting hacía que el plugin
	-- pareciera no tenerlos. `show_advanced` sigue controlando el resto.
	local channels = row.channels or {}
	if #channels > 1 then
		for index, channel in ipairs(channels) do
			table.insert(children, channelRow(row, index, channel))
		end
		-- El balance estéreo sólo con dos canales (izq/der).
		if #channels == 2 then
			table.insert(children, balanceRow(row))
		end
	end

	return ui.column({
		key = "dev-" .. row.name,
		-- Sin `width` fijo: la card hereda el ancho del contenedor
		-- (`align = "stretch"`). El host recorta el ancho pedido del panel,
		-- así que un ancho calculado a mano se pasaba del borde.
		align = "stretch",
		-- Sin `height`: la card crece con su contenido. Con altura fija el
		-- texto se salía de la caja cuando el nombre ocupaba dos líneas.
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		-- El relleno es el mismo para todos: el dispositivo activo ya se
		-- distingue por el borde (`primary`) y por el texto. Antes había un
		-- `if/else` con las dos ramas iguales, que no distinguía nada.
		fill = theme.surface(),
		radius = 10,
		border = if row.active then "primary" else theme.chip(),
		borderWidth = 1,
		opacity = alpha,
	}, children)
end

-- ── streams ──────────────────────────────────────────────────────────

local function streamCard(stream: any, index: number, sinks: any): any
	local draftKey = "s:" .. tostring(stream.id)
	local draft = S.draft[draftKey]
	local shown = if draft ~= nil then draft else tonumber(stream.volume) or 0
	local alpha = if S.anim.t < 1 then 0.85 + 0.15 * anim.stagger(index, anim.ease_out(S.anim.t), 0.05) else 1

	local options = {}
	local selected = 0
	for position, sink in ipairs(sinks) do
		table.insert(options, tostring(sink.description or sink.name))
		if sink.index == stream.sink then
			selected = position - 1
		end
	end

	local where = "?"
	for _, sink in ipairs(sinks) do
		if sink.index == stream.sink then
			where = tostring(sink.description or sink.name)
		end
	end

	return ui.column({
		key = "stream-" .. tostring(stream.id),
		-- Sin `width` fijo: la card hereda el ancho del contenedor
		-- (`align = "stretch"`). El host recorta el ancho pedido del panel,
		-- así que un ancho calculado a mano se pasaba del borde.
		align = "stretch",
		-- Sin `height`: igual que la card de dispositivo.
		gap = 4,
		paddingH = 10,
		paddingV = 8,
		fill = theme.surface(),
		radius = 10,
		opacity = alpha,
	}, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "music", size = 15, color = theme.dim() }),
			-- La columna crece en ANCHO (es hijo de un row: ése es su eje
			-- principal). Sus labels no llevan `flexGrow`: dentro de una
			-- column crecerían en vertical, que no es lo que se quiere. El
			-- texto se recorta con elipsis contra el ancho que le da la
			-- column.
			ui.column({ gap = 1, flexGrow = 1, minWidth = 0, align = "stretch" }, {
				ui.label({
					text = tostring(stream.app),
					fontSize = 13,
					fontWeight = "semibold",
					maxLines = 1,
				}),
				ui.label({ text = where, fontSize = 10, color = theme.dim(), maxLines = 1 }),
			}),
			ui.label({ text = percent(shown), fontSize = 11, color = theme.muted() }),
			-- El selector de salida: ancho FIJO proporcional al panel. Un
			-- `flexGrow` no sirve acá: el select quedaría con el ancho
			-- justo del texto más largo, que con nombres de sink largos se
			-- come media card.
			ui.select({
				key = "stream-sink-" .. tostring(stream.id),
				options = options,
				selectedIndex = selected,
				width = math.floor(rowWidth() * 0.22),
				enabled = #sinks > 1,
				onChange = function(next)
					local position = (math.floor(tonumber(next) or 0)) + 1
					local sink = sinks[position]
					if sink == nil then
						return
					end
					send({ action = "move_stream", stream = stream.id, sink = sink.name })
				end,
			}),
		}),
		ui.slider({
			key = "stream-vol-" .. tostring(stream.id),
			min = 0,
			max = MAX_VOLUME,
			step = 0.01,
			value = math.min(MAX_VOLUME, (tonumber(stream.volume) or 0) / 100),
			flexGrow = 1,
			onChange = function(next)
				S.draft[draftKey] = math.floor((tonumber(next) or 0) * 100 + 0.5)
			end,
			onDragEnd = function()
				local target = S.draft[draftKey]
				S.draft[draftKey] = nil
				if target == nil then
					return
				end
				send({ action = "set_stream_volume", stream = stream.id, value = target })
			end,
		}),
	})
end

local function streamList(): any
	local state = st()
	local streams = state.streams or {}
	local sinks = state.sinks or {}

	if #streams == 0 then
		return ui.column({ height = listHeight(), align = "center", justify = "center", gap = 6 }, {
			ui.glyph({ name = "music", size = 26, color = theme.dim() }),
			ui.label({ text = T("panel.no_streams"), fontSize = 12, color = theme.muted(), textAlign = "center", maxLines = 2 }),
			ui.label({ text = T("panel.no_streams_hint"), fontSize = 10, color = theme.dim(), textAlign = "center", maxLines = 2 }),
		})
	end

	local cards = {}
	for index, stream in ipairs(streams) do
		table.insert(cards, streamCard(stream, index, sinks))
	end

	-- Altura fija (el viewport), como el scroll de dispositivos: con
	-- `flexGrow` el viewport crece con el contenido y la rueda no scrollea.
	return ui.scroll(layout.merge({
		key = "streams",
		gap = GAP,
		paddingH = 2,
		align = "stretch",
		
	}, layout.scrollExtra(listHeight(#cards * (STREAM_H + GAP) - GAP))), cards)
end

-- ── lista de dispositivos ────────────────────────────────────────────

local function btNotice(): any
	local state = st()
	local hint = if state.btConnected == true then T("panel.bt_no_codec") else T("panel.bt_none_hint")
	return ui.row({
		gap = 8,
		paddingH = 10,
		paddingV = 6,
		align = "center",
		fill = theme.chip(),
		radius = 8,
	}, {
		ui.glyph({ name = "bluetooth-off", size = 14, color = theme.dim() }),
		ui.column({ gap = 1, flexGrow = 1 }, {
			ui.label({ text = T("panel.bt_none"), fontSize = 11, color = theme.muted() }),
			ui.label({ text = layout.ellipsis(hint, 50), fontSize = 10, color = theme.dim(), maxLines = 1 }),
		}),
	})
end

local function deviceList(): any
	local rows = devices()
	if #rows == 0 then
		return ui.column({ height = listHeight(), align = "center", justify = "center", gap = 6 }, {
			ui.glyph({ name = if S.tab == "source" then "microphone" else "volume-x", size = 26, color = theme.dim() }),
			ui.label({
				text = if S.tab == "source" then T("panel.no_inputs") else T("panel.no_outputs"),
				fontSize = 12,
				color = theme.muted(),
				textAlign = "center",
			}),
		})
	end

	-- Todas las devices, sin paginar: el scroll las recorre (ver el scroll
	-- de más abajo). La paginación manual (`pageSlice`) partía de una altura
	-- ESTIMADA de cada card, así que cuando una card crecía (el nombre en
	-- dos líneas) la última quedaba tapada; y con el scroll nativo ya no
	-- hace falta: la lista entera vive en el scroll.
	local cards = {}
	for index, row in ipairs(rows) do
		table.insert(cards, deviceCard(row, index))
	end

	local children = {}

	-- Sin bluetooth no hay códecs que ofrecer: se dice, en vez de dejar la
	-- sección vacía como si fuera un bug.
	if S.tab == "sink" and not has_bluetooth(rows) then
		table.insert(children, btNotice())
	end

	-- El scroll lleva ALTURA FIJA (el viewport), no `flexGrow`.
	--
	-- El host sólo scrollea si el contenido es más alto que el viewport
	-- (scroll_view.cpp: `m_maxScrollOffset = contentHeight - viewportH`). Con
	-- `flexGrow = 1` el viewport crece con el contenido, nunca hay desborde y
	-- la rueda no hace NADA: la lista se ve entera pero no se puede recorrer.
	-- Con `height` fijo el viewport es el alto útil y el contenido que sobra
	-- se scrollea.
	--
	-- El alto útil es el del panel menos el cromo (cabecera, pestañas, pie):
	-- `CHROME_H` es una estimación, así que se le da un margen. Si la
	-- estimación se queda corta, la última card queda un poco tapada; si
	-- sobra, hay hueco abajo. Es la parte que el host no deja medir.
	table.insert(children, ui.scroll(layout.merge({
		key = "devices-" .. S.tab,
		gap = GAP,
		paddingH = 2,
		align = "stretch",
	}, layout.scrollExtra(listHeight(estimateContentHeight(rows)))), cards))

	-- `align = "stretch"`: los hijos heredan el ancho del panel, que es lo
	-- que permite que el `flexGrow` del scroll reparta el alto sobrante.
	return ui.column({ gap = GAP, align = "stretch" }, children)
end

local function list(): any
	if S.tab == "stream" then
		return streamList()
	end
	if S.tab == "filters" then
		return filtersList()
	end
	if S.tab == "bt" then
		return btList()
	end
	return deviceList()
end

local function footer(): any
	local state = st()
	local text
	if tostring(state.feedback or "") ~= "" then
		text = tostring(state.feedback)
	else
		text = T("panel.hint")
	end
	return ui.row({ gap = 8, paddingH = 8, align = "center" }, {
		ui.glyph({
			name = if state.feedbackError == true then "alert-triangle" else "info",
			size = 12,
			color = if state.feedbackError == true then theme.danger() else theme.dim(),
		}),
		ui.label({
			text = layout.ellipsis(text, 50),
			fontSize = 10,
			color = if state.feedbackError == true then theme.danger() else theme.dim(),
			maxLines = 1,
			flexGrow = 1,
		}),
	})
end

-- ── render ───────────────────────────────────────────────────────────
--
-- La DECLARACIÓN (`local render`) está arriba, con `S`: Luau resuelve los
-- upvalues al crear la closure, así que una función que use `render` antes
-- de su declaración captura un global nil y revienta al llamarla.

render = function(): ()
	-- Guard: el módulo se carga con `require` y el watcher de estado puede
	-- disparar ANTES de que el panel exista. `panel.render` sobre un panel
	-- inexistente revienta ("attempt to index nil").
	if not READY then
		return
	end
	local state = st()

	-- Una firma por cambio real: es la traza que prueba que el panel recibió
	-- dispositivos, códecs y streams sin necesidad de mirar la pantalla.
	local bluetooth = 0
	local codecDevices = 0
	local profileDevices = 0
	for _, row in ipairs(state.sinks or {}) do
		if row.bluetooth then
			bluetooth = bluetooth + 1
		end
		if type(row.codecs) == "table" and #row.codecs > 0 then
			codecDevices = codecDevices + 1
		end
		if type(row.profiles) == "table" and #row.profiles > 1 then
			profileDevices = profileDevices + 1
		end
	end
	local signature = tostring(#(state.sinks or {})) .. "/" .. tostring(#(state.sources or {}))
		.. "/bt=" .. tostring(bluetooth) .. "/codecs=" .. tostring(codecDevices)
		.. "/profiles=" .. tostring(profileDevices)
		.. "/streams=" .. tostring(state.streamCount or 0)
		.. "/pin=" .. tostring(state.pinned)
		.. "/def=" .. tostring(state.defaultSinkName)
		-- El modo y el ancho: la forma de VERIFICAR que el entry pasó el
		-- modo correcto. Antes el ancho se suponía desde el setting y el
		-- panel calculaba sobre 560 px un panel de 1120.
		.. "/mode=" .. MODE .. "/w=" .. tostring(panelWidth())
	if signature ~= S.signature then
		S.signature = signature
		noctalia.log("[b3l0w-audio-panel] " .. signature)
	end

	-- La raíz lleva el ancho de la SUPERFICIE: el manifest declara 560 px
	-- para el panel compacto y 1120 para el flotante. Con un ancho fijo el
	-- contenido del flotante queda pegado a la izquierda.
	local root: any = {
		header(),
		tabs(),
	}
	-- La barra de perfiles va sólo en las pestañas de dispositivo: los
	-- filtros y el bluetooth no tienen perfil de audio.
	if S.tab == "sink" or S.tab == "source" then
		local bar = profileBar()
		if bar ~= nil then
			table.insert(root, bar)
		end
	end
	table.insert(root, list())
	table.insert(root, footer())

	-- El host recorta 12 px del ancho pedido: pedir `panelWidth()` acá dejaba
	-- la columna 12 px más ancha que el panel y todo lo alineado a la derecha
	-- (los "%" de los canales) se cortaba contra el borde.
	panel.render(ui.column({
		width = layout.width(panelWidth() - 12),
		flexGrow = 1,
		gap = 8,
		padding = 6,
		align = "stretch",
	}, root))
end

-- Exportado para que los entries finos (`panel_compact.luau` y
-- `float.luau`) lo invoquen: `require` corre el módulo en su propio
-- ámbito, así que `function onOpen()` definida acá no sale del módulo.
function M.open(_context: any, mode: string?)
	-- El entry dice qué panel es: el host no lo pasa por el contexto.
	if mode == "compact" or mode == "float" then
		MODE = mode
	end
	READY = true
	SNAP.state = noctalia.state.get(STATE_KEY)
	S.page = 1
	S.draft = {}
	S.anim.t = if prefs.animations() then 0 else 1
	S.signature = ""
	-- El tick de frames no se apaga: `setNeedsFrameTick(false)` es una puerta de
	-- una sola dirección y volver a `true` no reinicia el bucle.
	panel.setNeedsFrameTick(prefs.animations())
	send({ action = "refresh" })
	render()
end

function M.close()
	S.draft = {}
	READY = false
end

function M.configChanged()
	render()
end

function M.frameTick(delta)
	if not prefs.animations() then
		return
	end
	local advance = tonumber(delta) or 0
	if advance > 0 and advance < 1 then
		advance = advance * 1000
	end
	if S.anim.t >= 1 then
		return
	end
	S.anim.t = math.min(1, S.anim.t + advance / S.anim.ms)
	render()
end

noctalia.state.watch(STATE_KEY, function(value)
	SNAP.state = value
	-- Un refresco trae volúmenes nuevos: los drafts viejos ya no representan nada.
	S.draft = {}
	render()
end)

-- NO se llama `render()` acá: el módulo se carga con `require` y en ese
-- momento el panel todavía no existe (`panel.render` sobre un panel
-- inexistente revienta). El primer render lo hace `M.open`.
--
-- El watcher de arriba tampoco puede pintar antes de que exista el panel:
-- por eso `render()` es seguro de llamar en cualquier momento.

return M
