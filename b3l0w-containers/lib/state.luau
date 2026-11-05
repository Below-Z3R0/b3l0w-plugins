--!strict
-- Estado compartido entre el service y los paneles.
--
-- `noctalia.state.watch` entrega el valor NUEVO, pero en ese instante
-- `noctalia.state.get` todavía devuelve el ANTERIOR: si el render lee del
-- `get`, la UI queda un frame atrás ("cambió el modo y no se refleja").
--
-- El watcher guarda el valor en la caché y el render lee siempre de la caché.
-- Un módulo (y no una copia por entry) para que el panel compacto y el
-- panel grande lean exactamente lo mismo.

local M = {}

local CACHE: { [string]: any } = {}

-- El valor cacheado; si no hay, el del estado (el seed de onOpen).
function M.read(key: string): any
	local cached = CACHE[key]
	if cached ~= nil then
		return cached
	end
	return noctalia.state.get(key)
end

-- Guarda un valor en la caché (el seed de onOpen).
function M.store(key: string, value: any): ()
	CACHE[key] = value
end

-- El valor como tabla (vacía si no hay).
function M.table(key: string): { [string]: any }
	local value = M.read(key)
	return type(value) == "table" and value or {}
end

-- Suscribe y cachea: el callback recibe el valor nuevo.
function M.watch(key: string, cb: (any) -> ()): ()
	noctalia.state.watch(key, function(value: any)
		CACHE[key] = value
		cb(value)
	end)
end

return M
