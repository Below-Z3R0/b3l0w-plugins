-- Entry del panel flotante de b3l0w/audio (1120 px).
--
-- El modo se lo pasa el entry: el host no lo dice por el contexto de
-- `onOpen`, y deducirlo del setting `panel_mode` daba anchos incorrectos
-- cuando se abría este entry desde el launcher.

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

