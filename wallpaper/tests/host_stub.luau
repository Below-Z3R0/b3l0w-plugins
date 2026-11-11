--!nocheck
-- Stubs mínimos del host de Noctalia para poder ejercitar panel.luau sin abrir
-- una sesión gráfica: `ui.*` devuelve un árbol inspeccionable, `noctalia.*`
-- guarda el estado falso que cada test ajusta desde TESTS.
--
-- Lo concatena tests/run.sh delante de panel.luau y tests/panel_spec.luau.

local function mk(name)
	return function(props, children)
		if props ~= nil and type(props) ~= "table" then
			error("ui." .. name .. ": props no-table")
		end
		return { __name = name, props = props or {}, children = children or {} }
	end
end

ui = setmetatable({}, { __index = function(_, k) return mk(k) end })

-- Estado que los tests pueden reescribir: TEST.store y TEST.catalog.
TEST = {
	store = {
		view = {
			mode = "carousel",
			columns = 4,
			spacing = 15,
			tile = 280,
			apply_on = true,
			view_label = true,
			carousel = { layout = "full", w = 0, h = 0, progress = true },
			grid = { layout = "full", w = 0, h = 0 },
		},
		source = "engine",
		debug = false,
		favorites = {},
		properties = {},
		sync_colors = true,
	},
	catalog = { items = {} },
}
for i = 1, 20 do
	TEST.catalog.items[i] = { id = "w" .. i, title = "Wallpaper " .. i, kind = "video", preview = "/tmp/x.jpg" }
end

noctalia = {
	state = {
		get = function(key)
			if key == "wes_store" then
				return TEST.store
			elseif key == "wes_catalog" then
				return TEST.catalog
			end
			return nil
		end,
		watch = function() end,
		set = function() end,
	},
	getConfig = function() return nil end,
	tr = function(key) return tostring(key) end,
	log = function() end,
	listDir = function() return {} end,
	expandPath = function(path) return path end,
	outputs = function() return { { name = "eDP-1" }, { name = "HDMI-A-1" } } end,
	focusedOutputName = function() return "eDP-1" end,
	runAsync = function() end,
	http = function() end,
	download = function() end,
	wallpaperPath = function() return nil end,
	nowMs = function() return 1700000000000 end,
	notify = function() end,
}

panel = {
	render = function() end,
	setNeedsFrameTick = function() end,
	openContextMenu = function() end,
	close = function() end,
}
