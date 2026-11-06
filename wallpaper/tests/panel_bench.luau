--!nocheck
-- Bench del panel: costo por render con catálogos reales (40 engine, 2400
-- wallhaven) y con las opciones abiertas. Se ejecuta con tests/run.sh bench.
--
-- El presupuesto del host es 25 ms por callback: si un render se pasa, la
-- acción se aborta a mitad y el panel queda sin publicar. Este número es el que
-- hay que mirar antes de agregar trabajo al árbol.

local repeticiones = 40
local arbol: any = nil
panel.render = function(tree: any)
	arbol = tree
end

-- `despues` fuerza el estado que onOpen no puede dejar (por ejemplo cambiar de
-- pantalla, porque onOpen siempre vuelve a browse).
local function medir(nombre: string, preparar: (() -> ())?, despues: (() -> ())?): ()
	local function vuelta(): ()
		if preparar then
			preparar()
		end
		onOpen({})
		if despues then
			despues()
		end
	end
	vuelta() -- calentamiento: la primera pasada paga la compilación JIT
	local inicio = os.clock()
	for _ = 1, repeticiones do
		vuelta()
	end
	local total = (os.clock() - inicio) * 1000 / repeticiones
	print(string.format("  %-34s %6.2f ms/render", nombre, total))
end

local function items(cantidad: number): { any }
	local lista: { any } = {}
	for i = 1, cantidad do
		lista[i] = {
			id = "w" .. tostring(i),
			title = "Wallpaper con un nombre largo " .. tostring(i),
			kind = (i % 3 == 0) and "images" or "video",
			preview = "/tmp/x.jpg",
			tags = { "4K", "Ambient" },
		}
	end
	return lista
end

local vista = TEST.store.view

TEST.catalog.items = items(40)
vista.mode = "carousel"
medir("carrusel · 40 items", function() end)

TEST.catalog.items = items(2400)
medir("carrusel · 2400 items", function() end)

vista.mode = "grid"
vista.columns = 4
medir("grilla · 2400 items", function() end)

vista.grid = { layout = "minimal", w = 0, h = 0 }
medir("grilla minimal · 2400 items", function() end)

vista.mode = "carousel"
vista.carousel = { layout = "full", w = 335, h = 240, progress = true }
medir("carrusel 335 px · 2400 items", function() end)

-- Opciones: es la pantalla más grande del panel.
TEST.catalog.items = items(40)
medir("opciones · 40 items", nil, function()
	S.screen = "options"
	onKey("right", true) -- render de Opciones (onOpen siempre deja browse)
end)

print("")
print("  presupuesto del host: 25 ms por callback")
