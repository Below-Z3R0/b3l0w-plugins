-- Entry del panel flotante de YouTube Music (1160 px).
--
-- El modo lo declara el entry: el host no lo dice por el contexto de
-- `onOpen`. Antes este panel usaba `panel_compact.luau`, así que un panel
-- de 1160 px se renderizaba con la lógica y los anchos del de 740.

local app = require("./panel.luau")

function onOpen(context: any): ()
	app.open(context, "float")
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
