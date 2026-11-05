--!strict
-- Puente a procesos del sistema (`wpctl`, `pactl`, `pw-dump`, `upower`).
--
-- Este plugin NO pasa por el CLI `b3l0w`: el backend de audio es WirePlumber,
-- así que el puente habla shell directo. Por eso vive en `lib/proc.luau` y no
-- en `lib/cli.luau`, que en la familia b3l0w es el puente al binario Go
-- (`b3l0w <extensión> ...`) y lo reescribe `luau-shared/sync.sh`.
--
-- `runAsync(cmd, cb)` es la única forma que captura salida. La forma de un solo
-- argumento desprende el proceso y no avisa nada; un tercer argumento de
-- timeout no existe y hace perder el callback.

local M = {}

-- Nombres de nodo (`bluez_output.31_92_...`) y descripciones traen espacios y
-- comillas: sin citar, el shell parte el comando en pedazos.
local function q(value: string): string
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

M.quote = q

-- Resultado crudo de runAsync normalizado a tabla: siempre devuelve algo.
function M.run(command: string, cb: (any) -> ()): ()
	noctalia.runAsync(command, function(result: any)
		cb(result or {})
	end)
end

-- Código de salida crudo sin interpretarlo: `pactl get-default-sink` sale con 1
-- cuando el servidor no responde y eso no invalida el resto del refresco.
function M.exit_code(command: string, cb: (number, string, string) -> ()): ()
	M.run(command, function(result: any)
		local code = tonumber(result.exitCode) or -1
		local stdout = tostring(result.stdout or "")
		local stderr = tostring(result.stderr or "")
		if result.timedOut then
			code = -1
			stderr = "timeout"
		end
		cb(code, stdout, stderr)
	end)
end

return M
