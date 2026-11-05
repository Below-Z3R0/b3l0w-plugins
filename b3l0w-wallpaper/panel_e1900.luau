-- Entry del panel de b3l0w/wallpaper, escalón de 1900 px.
--
-- El host es dueño del tamaño: el manifest declara este panel con 1900 px y el
-- API de `panel` no tiene `setWidth` (`render`, `close`, `openContextMenu`,
-- `setWantsSecondTicks`, `setNeedsFrameTick` y nada más). Por eso cada
-- escalón de la escalera es un entry propio, y el ancho lo pasa este archivo:
-- el módulo calcula el layout con él.
--
-- `require` ejecuta el módulo en su propio ámbito, así que las funciones de
-- ciclo de vida definidas en `panel.luau` NO salen del módulo: este entry las
-- publica como GLOBALS.

local app = require("./panel.luau")

local ANCHO = 1900
local ENTRY = "panel_w1900"

function onOpen(context: any): ()
	app.open(context, ANCHO, ENTRY)
end

function onClose(): ()
	app.close()
end

function onKey(chord: any, pressed: any)
	app.key(chord, pressed)
end

function onFrameTick(delta: any): ()
	app.frameTick(delta)
end
