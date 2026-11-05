--!strict
-- Puente al CLI en Go. Cada widget tiene su propia extensión de b3l0w
-- (b3l0w docker|kanban|audit|audio|anilist|yt ...), así que el nombre de la
-- extensión es un parámetro, no una constante.
--
-- El service es el único que llama al CLI: el panel nunca lanza procesos.

local M = {}

-- Cita un argumento para el shell. Rutas y títulos traen espacios y comillas:
-- sin esto el comando se parte en pedazos y el binario recibe basura.
-- ── lanzador con reintento ────────────────────────────────────────────
--
-- `noctalia.runAsync` NO siempre encola: el host corre los procesos en un
-- pool acotado y, cuando no tiene worker libre, devuelve **false** y el
-- callback no se llama nunca. Sin mirar el valor de retorno la orden se
-- pierde en silencio: el service queda con el estado inicial para siempre
-- sin error, sin log y sin reintento.
--
-- Con varias órdenes por arranque, las últimas se rechazan. Acá se guardan y
-- el service las relanza desde update() con `M.pump()`.
M.pending = {}
M.MAX_PENDING = 24
M.MAX_ATTEMPTS = 20

local function attempt(cmd: string, cb: any): boolean
	return noctalia.runAsync(cmd, cb) ~= false
end

-- Corre ahora o deja la orden en la cola de reintento.
local function launch(cmd: string, cb: any): boolean
	if attempt(cmd, cb) then
		return true
	end
	if #M.pending < M.MAX_PENDING then
		M.pending[#M.pending + 1] = { cmd = cmd, cb = cb, tries = 0 }
	end
	return false
end

-- Relanza lo rechazado. Devuelve cuántos arrancaron. Lo llama update().
function M.pump(): number
	local queue = M.pending
	if #queue == 0 then
		return 0
	end
	M.pending = {}
	local started = 0
	for _, item in ipairs(queue) do
		if attempt(item.cmd, item.cb) then
			started += 1
		else
			item.tries += 1
			if item.tries < M.MAX_ATTEMPTS then
				M.pending[#M.pending + 1] = item
			else
				noctalia.log("[b3l0w-audit] proceso descartado tras "
					.. tostring(item.tries) .. " intentos: " .. item.cmd)
			end
		end
	end
	return started
end

function M.pendingCount(): number
	return #M.pending
end

-- El CLI escribe el motivo en el JSON de stdout también cuando falla: si sólo
-- se lee stderr, el usuario recibe "exit 1: exit status 2" en vez del motivo.
local function motivo(result: any, code: number): string
	local stdout = result and result.stdout or ""
	local decoded = noctalia.json.decode(stdout)
	if type(decoded) == "table" then
		local detalle = decoded.error or decoded.output
		if type(detalle) == "string" and detalle ~= "" then
			return string.sub(detalle, 1, 200)
		end
	end
	local stderr = result and result.stderr or ""
	if stderr ~= "" then
		return string.sub(stderr, 1, 200)
	end
	return "exit " .. tostring(code)
end

local function q(value: string): string
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

M.quote = q

local function build(ext: string, args: { string }): string
	local argv: { string } = { "b3l0w", ext }
	for _, value in ipairs(args) do
		table.insert(argv, q(value))
	end
	return table.concat(argv, " ")
end

-- Corre un subcomando que devuelve JSON y entrega la tabla decodificada.
-- cb(value, err): uno de los dos siempre es nil.
function M.json(ext: string, args: { string }, cb: (any, string?) -> ()): ()
	noctalia.runAsync(build(ext, args), function(result: any)
		local code = result and result.exitCode or -1
		if code ~= 0 then
			local stderr = result and result.stderr or ""
			cb(nil, "exit " .. tostring(code) .. ": " .. string.sub(stderr, 1, 160))
			return
		end
		local decoded = noctalia.json.decode(result and result.stdout or "")
		if type(decoded) ~= "table" then
			cb(nil, "respuesta invalida")
			return
		end
		cb(decoded, nil)
	end)
end

-- Igual pero devuelve el texto crudo (logs, progreso de updates).
function M.text(ext: string, args: { string }, cb: (string?, string?) -> ()): ()
	noctalia.runAsync(build(ext, args), function(result: any)
		local code = result and result.exitCode or -1
		if code ~= 0 then
			local stderr = result and result.stderr or ""
			cb(nil, "exit " .. tostring(code) .. ": " .. string.sub(stderr, 1, 120))
			return
		end
		cb(result and result.stdout or "", nil)
	end)
end

-- ¿Está la extensión instalada? Evita que el widget muestre un error críptico
-- cuando el binario todavía no se compiló.
function M.available(ext: string, cb: (boolean) -> ()): ()
	noctalia.runAsync("b3l0w plugins 2>/dev/null | grep -qx " .. q(ext), function(result: any)
		cb((result and result.exitCode or 1) == 0)
	end)
end

-- Variante para binarios del sistema (gh, pacman...): NO antepone `b3l0w`.
-- Al propagar la capa compartida desde otro plugin se perdió esta función y el
-- service fallaba con "attempt to call a nil value" en cada refresco.
function M.jsonBin(bin: string, args: { string }, cb: (any, string?) -> ()): ()
	local argv: { string } = { bin }
	for _, value in ipairs(args) do
		table.insert(argv, q(value))
	end
	launch(table.concat(argv, " "), function(result: any)
		local code = result and result.exitCode or -1
		if code ~= 0 then
			cb(nil, motivo(result, code))
			return
		end
		local decoded = noctalia.json.decode(result and result.stdout or "")
		if type(decoded) ~= "table" then
			cb(nil, "respuesta invalida")
			return
		end
		cb(decoded, nil)
	end)
end

function M.textBin(bin: string, args: { string }, cb: (string?, string?) -> ()): ()
	local argv: { string } = { bin }
	for _, value in ipairs(args) do
		table.insert(argv, q(value))
	end
	launch(table.concat(argv, " "), function(result: any)
		local code = result and result.exitCode or -1
		if code ~= 0 then
			cb(nil, motivo(result, code))
			return
		end
		cb(result and result.stdout or "", nil)
	end)
end

-- Corre un comando del sistema y entrega (code, stdout, stderr).
-- El service de audit necesita el código de salida y las tres salidas: por eso
-- esta función existe aparte de `M.text` (que sólo entrega stdout).
function M.exit_code(cmd: string, cb: (number, string, string) -> ()): ()
	launch(cmd, function(result: any)
		local code = result and result.exitCode or -1
		cb(code, result and result.stdout or "", result and result.stderr or "")
	end)
end

-- Corre un comando sin mirar la salida.
function M.run(cmd: string, cb: () -> ()): ()
	launch(cmd, function(_result: any)
		cb()
	end)
end

return M
