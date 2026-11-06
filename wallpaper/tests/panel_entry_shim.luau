-- Shim de los entries para el runner de tests.
--
-- El host evalúa cada entry como script y resuelve `onOpen`, `onKey`, etc.
-- como GLOBALS. El panel real es un módulo (`panel.luau` devuelve `M`) y son
-- los entries (`panel_e<N>.luau`) los que publican los hooks.
--
-- En el test el módulo va CONCATENADO en un solo archivo, así que sus
-- `local` quedan en el scope del archivo y este shim puede publicarlos
-- igual que haría un entry real.
--
-- El ancho lo pide el propio módulo (`desired`): así el shim siempre simula
-- el escalón correcto y el panel no intenta reabrirse durante el test.

function onOpen(context: any): ()
	local target, ancho = M.desired()
	local entry = string.match(target, ":(.+)$") or "panel"
	open(context, ancho, entry)
end

function onClose(): ()
	close()
end

function onKey(chord: any, pressed: any)
	key(chord, pressed)
end

function onFrameTick(delta: any): ()
	frameTick(delta)
end

-- La geometría viva, para los checks del spec.
function geometry(): any
	return M.geometry()
end
