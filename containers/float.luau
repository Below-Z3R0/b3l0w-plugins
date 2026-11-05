-- Entry flotante de b3l0w/containers.
--
-- El host es dueño del tamaño: el manifest declara este panel con 1240 px.
-- El código NO puede deducir el ancho del setting `panel_mode`: si el
-- usuario abre este entry desde el launcher, el cálculo daba sobre 720 y
-- el contenido se quedaba corto.
--
-- `require` ejecuta el módulo en su propio ámbito, así que las funciones
-- de ciclo de vida definidas en `panel.luau` NO salen del módulo: este
-- entry las publica como GLOBALS.

local app = require("./panel.luau")

function onOpen(context: any): ()
	app.setMode("float")
	app.open(context)
end

function onClose(): ()
	app.close()
end

function onFrameTick(delta: number): ()
	app.frameTick(delta)
end
