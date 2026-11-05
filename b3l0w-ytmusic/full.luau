-- Entry del panel a pantalla completa de YouTube Music.
--
-- El contexto de `onOpen` no dice qué panel se abrió (viene vacío), así que
-- el modo se lo pasa el entry: "full" = sidebar + vistas + playerbar.

local app = require("./panel.luau")

function onOpen(context: any): ()
	app.open(context, "full")
end

function onClose(): ()
	app.close()
end

function onKey(chord: string, pressed: boolean): ()
	app.key(chord, pressed)
end

function onFrameTick(delta: number): ()
	app.frameTick(delta)
end
