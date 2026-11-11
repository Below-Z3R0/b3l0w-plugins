#!/usr/bin/env bash
# Corre los tests del panel de b3l0w/audio sin sesión gráfica.
#
# Por qué este archivo es tan específico: el host de Noctalia carga los
# plugins de una forma que Luau CLI no imita.
#
#   1. El host resuelve `require("./lib/anim.luau")` (con extensión); Luau CLI
#      pide el módulo SIN extensión. Las copias de test la quitan.
#   2. Un módulo `require`d corre en su propio ámbito y NO ve las globales
#      del script que lo llama: dentro de `lib/*.luau`, `noctalia` sería nil.
#      Por eso las copias de `lib/` usan `STUB.` (el módulo `.panel-mod/stub`)
#      en lugar de `noctalia.`.
#   3. El panel es un módulo (lo requieren los entries finos) pero el test lo
#      carga como SCRIPT: `return M` se convierte en `PANEL_APP = M`.
#
# El fuente del plugin NO se toca: todo esto vive en copias que el runner
# genera y borra al terminar.
#
#   ./tests/run.sh            # el spec del panel (layout)
#   ./tests/run.sh domain     # los specs del dominio (lib/audio.luau)

set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
caso="${1:-spec}"

if [ "$caso" = "domain" ]; then
	cd "$raiz"
	luau tests/audio_spec.luau
	exit 0
fi

temporal="$raiz/.panel-spec.luau"
modulos="$raiz/.panel-mod"
entrada="$raiz/.panel-entry.luau"
trap 'rm -rf "$temporal" "$modulos" "$entrada"' EXIT

# Las copias de `lib/` con STUB en lugar de noctalia.
mkdir -p "$modulos"
for f in "$raiz"/lib/*.luau; do
	base="$(basename "$f" .luau)"
	sed -e 's|noctalia\.|STUB.|g' "$f" > "$modulos/$base.luau"
done

# El estado del fixture, en su propio módulo: el stub no puede ver la global
# TEST del script (los módulos requireados viven en su propio ámbito).
cat > "$modulos/fixture.luau" <<'FIXTURE'
--!nocheck
return {
	state = {
		phase = "ready",
		allMuted = false,
		defaultSinkName = "alsa_output.pci-0000_00_1f.3.analog-stereo",
		defaultSourceName = nil,
		streamCount = 0,
		pinned = nil,
		err = nil,
		feedback = nil,
		feedbackError = false,
		sinks = {
			{
				id = 55,
				index = 55,
				name = "alsa_output.pci-0000_00_1f.3.analog-stereo",
				description = "Built-in Audio Analog Stereo",
				kind = "sink",
				active = true,
				muted = false,
				volume = 90,
				bluetooth = false,
				cardName = "alsa_card.pci-0000_00_1f.3",
				-- El sample rate REAL que publica el backend (no el pedido) y
				-- la latencia real del dispositivo. Sin estos campos el panel
				-- no dibuja la línea "{rate} Hz" y el check que la verifica
				-- falla: el dato tiene que estar en el fixture.
				rate = 48000,
				latency = { actual = 120, requested = 120 },
				profiles = {
					{ name = "Analog Stereo Output", description = "Analog Stereo Output", active = true, available = true },
					{ name = "pro-output-2", description = "Pro Output 2", active = false, available = true },
				},
				codecs = {},
			},
		},
		sources = {
			{
				id = 56,
				index = 56,
				name = "alsa_input.pci-0000_00_1f.3.analog-stereo",
				description = "Built-in Audio Analog Stereo",
				kind = "source",
				active = true,
				muted = false,
				volume = 100,
				bluetooth = false,
				cardName = "",
				profiles = {},
				codecs = {},
			},
		},
		streams = {
			{ id = 10592, sink = 55, app = "Firefox", media = "", volume = 80, muted = false },
		},
		btConnected = false,
		btList = {
			{ mac = "31:92:D9:51:AF:84", name = "Cubitt Headphones", connected = true, paired = true, trusted = true, icon = "audio-headset", battery = 80 },
			{ mac = "27:CB:CF:69:29:1E", name = "HP H23C Earbuds", connected = false, paired = true, trusted = true, icon = "audio-headset" },
		},
		modules = {
			{ id = "node.features.audio.no-dsp", name = "No DSP", desc = "Disable all DSP", type = "Boolean", value = "false", default = "false" },
			{ id = "node.features.audio.mono", name = "Mono", desc = "Force mono", type = "Boolean", value = "true", default = "false" },
			{ id = "linking.role-based.duck-level", name = "Ducking level", desc = "", type = "Float", value = "0.3", default = "0.3" },
		},
		filters = {
			{ id = 62, name = "filter-chain" },
		},
		audioProfile = "music",
		rateActual = 48000,
		rateRequested = 48000,
	},
	requests = {},
	density = "cozy",
}
FIXTURE

# El stub traduce de verdad: se genera una tabla Luau con translations/en.json
# para que el spec vea el texto final ("48000 Hz") y no la clave.
python3 - "$raiz/translations/en.json" "$modulos/tr.luau" <<'TRGEN'
import json, sys

data = json.load(open(sys.argv[1], encoding="utf-8"))

def leaves(node, prefix=""):
    out = {}
    for key, value in node.items():
        if isinstance(value, dict):
            out.update(leaves(value, f"{prefix}{key}."))
        else:
            out[f"{prefix}{key}"] = value
    return out

with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write("--!nocheck\n-- GENERADO por tests/run.sh: translations/en.json como tabla.\n")
    fh.write("return {\n")
    for key, value in sorted(leaves(data).items()):
        fh.write(f"\t[{json.dumps(key)}] = {json.dumps(value, ensure_ascii=False)},\n")
    fh.write("}\n")
TRGEN

cat >"$modulos/stub.luau" <<'STUB'
--!nocheck
-- El host de Noctalia como módulo.
--
-- Dos trampas del sandbox de Luau CLI, que el host no tiene:
--   1. Un módulo `require`d no ve las globales del script que lo llama: por
--      eso las copias de `lib/` usan `STUB.` en lugar de `noctalia.`.
--   2. `require` precarga el módulo (Luau lo analiza antes de ejecutar el
--      script), así que al construirse el global TEST todavía no existe: el
--      estado se lee en CADA llamada, no al construir.
local FIXTURE = require("./fixture")
local TR = require("./tr")

local M = {
	state = {
		get = function(key)
			if key == "b3l0w_audio_state" then
				return FIXTURE.state
			end
			return nil
		end,
		watch = function() end,
		set = function(key, value)
			if key == "b3l0w_audio_request" then
				table.insert(FIXTURE.requests, value)
			end
		end,
	},
	getConfig = function(key)
		if key == "density" then
			return FIXTURE.density or "cozy"
		end
		if key == "show_battery" then
			return true
		end
		if key == "animations" then
			return false
		end
		if key == "panel_mode" then
			return "compact"
		end
		return nil
	end,
	tr = function(key, subst)
		-- El host traduce de verdad (translations/en.json) e interpola los
		-- {placeholders}: el spec depende de eso para ver el texto final
		-- (por ejemplo "48000 Hz") y no la clave.
		local text = TR[tostring(key)]
		if text == nil then
			text = tostring(key)
		end
		if type(subst) == "table" then
			for name, value in pairs(subst) do
				-- El PATRÓN lleva el `%` como escape: en los patterns de
				-- Lua `%` saca el carácter siguiente de la clase de
				-- caracteres, así que `"%{rate}"` busca la llave literal
				-- `{rate}`. Sin el `%` (`"{rate}"`) el `{` abre una clase
				-- inválida y el gsub revienta con "invalid use of '%' in
				-- replacement string".
				--
				-- El REEMPLAZO va como función: si fuera una cadena, un
				-- `%` del valor se interpretaría como una referencia ("%1"
				-- es el grupo 1).
				text = string.gsub(text, "%{" .. tostring(name) .. "}", function()
					return tostring(value)
				end)
			end
		end
		return text
	end,
	log = function() end,
	notifyError = function() end,
	openSettings = function() end,
	runAsync = function() end,
	runStream = function() end,
	outputs = function()
		return { { name = "eDP-1" }, { name = "HDMI-A-1" } }
	end,
	focusedOutputName = function()
		return "eDP-1"
	end,
}
return M
STUB

# Cada módulo de la copia requiere el stub.
for f in "$modulos"/*.luau; do
	case "$(basename "$f")" in
		stub.luau | fixture.luau | tr.luau) ;;
		*) sed -i '1i local STUB = require("./stub")' "$f" ;;
	esac
done

# El panel como script: `return M` -> `PANEL_APP = M`, y sus require apuntan
# a las copias sin extensión.
sed -e 's|noctalia\.|STUB.|g' \
	-e 's|require("\./lib/\([a-z_]*\)\.luau")|require("./.panel-mod/\1")|g' \
	-e 's|^return M$|PANEL_APP = M|' \
	"$raiz/panel.luau" > "$entrada"
sed -i '1i local STUB = require("./.panel-mod/stub")' "$entrada"
# Sonda temporal: dónde se pierde la lista.

{
	cat "$raiz/tests/host_stub.luau"
	echo 'TEST.sources = {'
	echo '	["panel.luau"] = [==['
	cat "$raiz/panel.luau"
	echo ']==],'
	echo '	["service.luau"] = [==['
	cat "$raiz/service.luau"
	echo ']==],'
	echo '}'
	cat "$entrada"
	# El spec (script) no alcanza el ámbito del módulo `.panel-mod/fixture`,
	# así que las requests que el panel manda al service se le pasan por una
	# global. Se inyecta ACÁ (en el archivo temporal), nunca en el fuente.
	echo 'local FIXTURE_REQUESTS = require("./.panel-mod/fixture").requests'
	cat "$raiz/tests/panel_spec.luau"
} >"$temporal"

if ! luau-compile --binary "$temporal" >/dev/null 2>"$temporal.err"; then
	echo "no compila:"
	cat "$temporal.err"
	rm -f "$temporal.err"
	exit 1
fi
rm -f "$temporal.err"

luau "$temporal"
