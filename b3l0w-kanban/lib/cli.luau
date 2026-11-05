--!strict
-- Puente al CLI en Go. Cada widget tiene su propia extensión de b3l0w
-- (b3l0w docker|kanban|audit|audio|anilist|yt ...), así que el nombre de la
-- extensión es un parámetro, no una constante.
--
-- El service es el único que llama al CLI: el panel nunca lanza procesos.

local M = {}

-- ── lanzador con reintento ────────────────────────────────────────────
--
-- `noctalia.runAsync` NO siempre encola: el host corre los procesos en un
-- pool acotado y, cuando no tiene un worker libre, devuelve **false** y el
-- callback no se llama nunca. Sin mirar el valor de retorno la orden se
-- pierde en silencio: el service queda con el estado inicial para siempre
-- (auth="checking", panel diciendo "no iniciaste sesión") sin err, sin log
-- y sin reintento, porque sólo el callback lo habría cambiado.
--
-- Con ~10 órdenes por tick (arranque de la shell, `refresh` completo) las
-- últimas se rechazan. Acá se guardan y el service las relanza desde
-- update() con `M.pump()`.
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
				noctalia.log("[b3l0w-kanban] proceso descartado tras "
					.. tostring(item.tries) .. " intentos: " .. item.cmd)
			end
		end
	end
	return started
end

function M.pendingCount(): number
	return #M.pending
end

-- Cita un argumento para el shell. Rutas y títulos traen espacios y comillas:
-- sin esto el comando se parte en pedazos y el binario recibe basura.
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
	launch(build(ext, args), function(result: any)
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
	launch(build(ext, args), function(result: any)
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
	launch("b3l0w plugins 2>/dev/null | grep -qx " .. q(ext), function(result: any)
		cb((result and result.exitCode or 1) == 0)
	end)
end
-- Variante para binarios del sistema (gh, pacman...): NO antepone `b3l0w`.
-- Al propagar la capa compartida desde otro plugin se perdió esta función y el
-- service fallaba con "attempt to call a nil value" en cada refresco.
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

function M.jsonBin(bin: string, args: { string }, cb: (any, string?) -> ()): ()
	local argv: { string } = { bin }
	for _, value in ipairs(args) do
		table.insert(argv, q(value))
	end
	launch(table.concat(argv, " "), function(result: any)
		local code = result and result.exitCode or -1
		local crudo = result and result.stdout or ""
		-- El host a veces entrega stdout vacío (proceso abortado) con exit=0:
		-- decodificarlo da {} y el dataset se publica como "vacío" sin error,
		-- que es exactamente cómo un tablero lleno se vuelve 0 tarjetas.
		-- No se llama al callback: se conserva el dataset anterior y el pump
		-- reintenta la orden.
		if crudo == "" then
			-- Dos casos distintos que antes se confundían:
			--  · rc ~= 0 → el comando falló y el motivo está en stderr
			--    ("your authentication token is missing required scopes",
			--     "the repository has disabled issues"). Es un error real: hay
			--    que mostrarlo, no reintentar.
			--  · rc == 0 → el proceso se abortó sin salida: sí se reintenta.
			-- En ambos casos el callback se llama: abandonarlo dejaba
			-- `S.busy` en true para siempre y el panel girando sin error.
			if code ~= 0 then
				local stderr = result and result.stderr or ""
				if stderr == "" then
					stderr = "exit " .. tostring(code)
				end
				noctalia.log("[b3l0w-kanban] comando falló: "
					.. string.sub(stderr, 1, 140))
				cb(nil, string.sub(stderr, 1, 200))
				return
			end
			noctalia.log("[b3l0w-kanban] respuesta vacía: reintento en cola: "
				.. string.sub(table.concat(argv, " "), 1, 90))
			cb(nil, "respuesta vacía (se reintenta)")
			return
		end
		if code ~= 0 then
			cb(nil, motivo(result, code))
			return
		end
		local decoded = noctalia.json.decode(crudo)
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


return M