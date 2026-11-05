-- Entry del panel compacto de YouTube Music.
--
-- La lógica vive en `panel.luau`, que devuelve una tabla con las funciones
-- de ciclo de vida. Este entry las publica como GLOBALS: `require` ejecuta
-- el módulo en su propio ámbito, así que los `function onOpen()` definidos
-- adentro NO salen del módulo.

local app = require("./panel.luau")

function onOpen(context: any): ()
	app.open(context, "compact")
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
