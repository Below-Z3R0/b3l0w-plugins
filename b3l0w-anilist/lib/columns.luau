-- Las props de una columna de ancho fijo.
--
-- El host descarta el `width` de un `ui.label` (`label.h`: "Flex ignores
-- preset setSize()") y el reconciler ni siquiera le aplica `minWidth`:
-- sólo `maxWidth`. La forma que funciona es un FLEX con `width`: el
-- reconciler lo traduce a `minWidth = maxWidth = width`.
--
-- Este módulo NO construye controles (no depende del global `ui`, que un
-- módulo `require` no tiene por seguro): sólo devuelve props.
local M: any = {}

function M.colProps(ancho: number): any
	return { width = ancho, align = "stretch", gap = 0 }
end

function M.celdaProps(texto: any, props: any): any
	local p = type(props) == "table" and props or {}
	p.text = tostring(texto or "")
	p.maxLines = 1
	return p
end

return M
