-- Entry del panel compacto de b3l0w/audio.
--
-- El host es dueño del tamaño: el manifest declara este panel con 560 px.
-- El código NO puede deducir el ancho del setting `panel_mode` (que elige
-- qué entry abre el widget): si el usuario abre el otro entry desde el
-- launcher, el cálculo de anchos daba en la cara. Por eso el entry pasa
-- su modo explícitamente.
--
-- `require` ejecuta el módulo en su propio ámbito, así que las funciones
-- de ciclo de vida definidas en `panel.luau` NO salen del módulo: este
-- entry las publica como GLOBALS.

local app = require("./panel.luau")

function onOpen(context: any): ()
	app.open(context, "compact")
end

function onClose(): ()
	app.close()
end

function onConfigChanged(): ()
	app.configChanged()
end

function onFrameTick(delta: number): ()
	app.frameTick(delta)
end

