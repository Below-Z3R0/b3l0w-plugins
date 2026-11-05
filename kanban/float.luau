-- Entry flotante de b3l0w/kanban.
--
-- El host es dueño del tamaño: el manifest declara este panel con 880 px.
-- El código NO puede deducir el ancho del setting `panel_mode` (que elige
-- qué entry abre el widget): si el usuario abre el otro entry desde el
-- launcher, el cálculo de anchos daba en la cara y el contenido se pasaba
-- del borde. Por eso el entry pasa su modo explícitamente.
--
-- `require` ejecuta el módulo en su propio ámbito, así que las funciones
-- de ciclo de vida definidas en `panel.luau` NO salen del módulo: este
-- entry las publica como GLOBALS.

local app = require("./panel.luau")

function onOpen(context: any): ()
	app.open(context, "float")
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
