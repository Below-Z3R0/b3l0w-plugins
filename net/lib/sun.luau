--!nonstrict
-- Parseo de Sunshine. Entra la salida del probe de shell, sale el estado que el
-- panel dibuja. Nada acá corre procesos: el service es el único dueño.
--
-- El probe emite un bloque `clave=valor`, la línea `@@LOG` y después las pocas
-- líneas del log que importan (ya filtradas por grep, así el parseo es lineal y
-- no se lee el archivo entero).

local fmt = require("./fmt.luau")

local M = {}

M.UNIT = "app-dev.lizardbyte.app.Sunshine.service"
M.WEB_PORT = 47990

-- Los cuatro puertos TCP del producto. Se cuentan, no se asume: un Sunshine a
-- medio arrancar deja tres y el panel lo tiene que decir.
M.PORTS = { "47984", "47989", "47990", "48010" }

local function as_string(value: any): string
	if type(value) == "string" then
		return value
	end
	return ""
end

-- "h264_vaapi [vaapi]" -> { name = "h264_vaapi", kind = "vaapi" }
local function split_encoder(line: string): (string, string)
	local name, kind = string.match(line, "encoder:%s*([%w_%.%-]+)%s*%[([^%]]+)%]")
	if name == nil then
		name = string.match(line, "encoder:%s*([%w_%.%-]+)")
		kind = ""
	end
	return fmt.trim(name or ""), fmt.trim(kind or "")
end

-- Los puertos que el probe encontró escuchando, en el orden de M.PORTS.
local function port_list(raw: string): { string }
	local found = {}
	for _, port in ipairs(M.PORTS) do
		if string.find(raw, port, 1, true) ~= nil then
			table.insert(found, port)
		end
	end
	return found
end

-- El log mezcla eventos de varias sesiones: se recorre en orden y gana el último
-- `CLIENT CONNECTED`. La sesión terminó si después aparece `Undo Cmd`
-- (post-sesión de apps.json) o `CLIENT DISCONNECTED` (lo que escribe esta build).
local function parse_session(lines: { string }): table
	local session = {
		at = nil,
		stamp = "",
		ended = false,
		ended_by = "",
	}
	for _, line in ipairs(lines) do
		local stamp = string.match(line, "^%[(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)")
		if string.find(line, "CLIENT CONNECTED", 1, true) ~= nil then
			session.at = fmt.log_epoch(stamp)
			session.stamp = as_string(stamp)
			session.ended = false
			session.ended_by = ""
		elseif session.at ~= nil then
			if string.find(line, "Undo Cmd", 1, true) ~= nil then
				session.ended = true
				session.ended_by = "Undo Cmd"
			elseif string.find(line, "CLIENT DISCONNECTED", 1, true) ~= nil then
				session.ended = true
				session.ended_by = "CLIENT DISCONNECTED"
			end
		end
	end
	return session
end

-- Nombres de las salidas. `umbriel outputs` (y `wlr-randr`) listan el nombre al
-- principio de la línea sin sangría; el resto son propiedades indentadas.
local function parse_outputs(raw: string): { string }
	local out = {}
	-- La lista llega separada por COMAS en una sola línea (el `kv` del probe
	-- sólo entiende `clave=valor` en una línea). Antes se separaba con un
	-- espacio y el patrón `^(%S+)%s` devolvía sólo el primer monitor.
	for chunk in string.gmatch(raw, "[^,]+") do
		local name = string.match(chunk, "^%s*(%S+)")
		if name ~= nil and name ~= "" then
			table.insert(out, name)
		end
	end
	return out
end

function M.parse(map: table, log_lines: { string }): table
	local kv = type(map) == "table" and map or {}
	local state = fmt.trim(as_string(kv.active))
	if state == "" then
		state = "unknown"
	end

	local ports = port_list(as_string(kv.ports))
	local http = fmt.trim(as_string(kv.http))

	local h264, h264_kind = "", ""
	local hevc, hevc_kind = "", ""
	for _, line in ipairs(log_lines) do
		if string.find(line, "Found H.264 encoder:", 1, true) ~= nil then
			h264, h264_kind = split_encoder(line)
		elseif string.find(line, "Found HEVC encoder:", 1, true) ~= nil then
			hevc, hevc_kind = split_encoder(line)
		end
	end

	-- En esta máquina (Intel, sin NVIDIA) nvenc falla por cuda y vulkan hace
	-- core-dump: cualquiera de los dos en el log es la causa del crash-loop.
	local bad_encoder = ""
	if h264_kind == "nvenc" or hevc_kind == "nvenc" then
		bad_encoder = "nvenc"
	elseif h264_kind == "vulkan" or hevc_kind == "vulkan" then
		bad_encoder = "vulkan"
	end

	local output_name = fmt.trim(as_string(kv.output))
	local outputs = parse_outputs(as_string(kv.outputs))
	local output_ok = true
	if output_name ~= "" and #outputs > 0 then
		output_ok = false
		for _, name in ipairs(outputs) do
			if name == output_name then
				output_ok = true
			end
		end
	end

	local capture = fmt.trim(as_string(kv.capture))
	local warnings = {}
	if capture ~= "" and capture ~= "wlr" then
		table.insert(warnings, { code = "capture", value = capture })
	end
	if not output_ok then
		table.insert(warnings, { code = "output", value = output_name })
	end
	if bad_encoder ~= "" then
		table.insert(warnings, { code = "encoder", value = bad_encoder })
	end
	if state == "active" and #ports < #M.PORTS then
		table.insert(warnings, { code = "ports", value = tostring(#ports) })
	end
	if state == "active" and http ~= "" and http ~= "401" and http ~= "307" then
		table.insert(warnings, { code = "http", value = http })
	end
	if state == "failed" then
		table.insert(warnings, { code = "state", value = "failed" })
	end

	return {
		ok = true,
		state = state,
		substate = fmt.trim(as_string(kv.substate)),
		nrestarts = tonumber(kv.nrestarts) or 0,
		failed = state == "failed",
		active = state == "active" or state == "activating" or state == "reloading",
		ports = { list = ports, count = #ports, expected = #M.PORTS },
		http = http,
		http_ok = http == "401" or http == "307",
		conf = {
			capture = capture,
			output = output_name,
			encoder = fmt.trim(as_string(kv.encoder)),
		},
		encoder = {
			h264 = h264,
			h264_kind = h264_kind,
			hevc = hevc,
			hevc_kind = hevc_kind,
			kind = if h264_kind ~= "" then h264_kind else hevc_kind,
			bad = bad_encoder,
		},
		session = parse_session(log_lines),
		-- Conexiones ESTABLISHED a los puertos de Sunshine: la verdad de
		-- campo. `parse_session` infiere del log y el log no registra el
		-- cierre abrupto, así que la sesión parecía viva con el cliente
		-- desconectado hace rato.
		established = tonumber(kv.established) or 0,
		outputs = outputs,
		output_ok = output_ok,
		local_ip = fmt.trim(as_string(kv.localip)),
		warnings = warnings,
	}
end

return M
