#!/usr/bin/env bash
# Corre los tests del panel sin sesión gráfica.
#
# El panel es un módulo (`panel.luau`, devuelve `M`) y cada entry del
# manifiesto publica los hooks como globales. El test arma un solo script
# concatenando
#   tests/host_stub.luau + panel.luau (sin el require del motor)
#   + tests/panel_entry_shim.luau + tests/panel_spec.luau
# en un archivo temporal dentro del repo (los `require` son relativos).
#
#   ./tests/run.sh          # spec
#   ./tests/run.sh bench    # benchmark del render
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporal="$raiz/.panel-spec.luau"
trap 'rm -f "$temporal"' EXIT

# El módulo, sin el `return M` (rompería la concatenación) y con el motor
# vacío: en el test sólo hacen falta to_argv/properties_argv.
modulo() {
	sed -e 's|^local engine = require("\./lib/engine\.luau")|local engine = setmetatable({}, { __index = function() return function() return {} end end })|' \
		-e 's|^local panel_size = require("\./lib/panel_size\.luau")|-- panel_size se inlina arriba|' \
		-e 's|^return M$|-- return M (el runner concatena el módulo)|' \
		"$raiz/panel.luau"
}

caso="${1:-spec}"

{
	cat "$raiz/tests/host_stub.luau"
	# El `luau` de los tests no resuelve requires relativos, así que la
	# geometría se inlina como una función que devuelve su módulo.
	printf 'local panel_size = (function()\n'
	cat "$raiz/lib/panel_size.luau"
	printf '\nend)()\n'
	modulo
	cat "$raiz/tests/panel_entry_shim.luau"
	if [ "$caso" = "bench" ]; then
		cat "$raiz/tests/panel_bench.luau"
	else
		cat "$raiz/tests/panel_spec.luau"
	fi
} >"$temporal"

if ! luau-compile --binary "$temporal" >/dev/null 2>"$temporal.err"; then
	echo "no compila:"
	cat "$temporal.err"
	rm -f "$temporal.err"
	exit 1
fi
rm -f "$temporal.err"

echo "── panel ($caso) ──"
luau "$temporal"
