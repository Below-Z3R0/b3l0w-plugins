--!noncheck
-- El host de Noctalia como stub del SCRIPT (el `ui.*` y el `panel.*`).
-- El estado del fixture vive en el módulo `.panel-mod/fixture`: los módulos
-- `require`d no ven las globales del script, y el panel se carga como script
-- pero sus `lib/` son módulos.

local function mk(name)
	return function(props, children)
		if props ~= nil and type(props) ~= "table" then
			error("ui." .. name .. ": props no-table")
		end
		return { __name = name, props = props or {}, children = children or {} }
	end
end

ui = setmetatable({}, { __index = function(_, k) return mk(k) end })

panel = {
	render = function(tree)
		TEST.tree = tree
	end,
	close = function() end,
	setNeedsFrameTick = function() end,
}

TEST = { tree = nil, requests = {} }
