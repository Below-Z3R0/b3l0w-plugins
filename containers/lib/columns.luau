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



return M
