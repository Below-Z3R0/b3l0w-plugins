#!/usr/bin/env python3
"""Embebe panel.luau en un fixture Luau que lo expone como función.

El runner `luau` de esta máquina no expone `io` ni `load`, así que el spec no
puede leer el panel desde disco ni evaluarlo con un entorno propio. Se genera
este fixture (mismo patrón que b3l0w-audio/tests) con el fuente REAL del panel
dentro de una función cuyos parámetros hacen de globals del host:

    return function(noctalia, ui, panel, require, barWidget) ... end

    python3 tests/build_panel_fixture.py && luau tests/panel_spec.luau
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "panel.luau"
OUT = ROOT / "tests" / "fixtures" / "panel_source.luau"

source = SRC.read_text(encoding="utf-8")
if "]====]" in source:
    raise SystemExit("el panel contiene el delimitador del fixture; elegí otro nivel")

# Lo que el spec necesita alcanzar: los locales que deciden qué datos se dibujan.
EXPORTS = "return { S = S, activity_rows = activity_rows, card_matches = card_matches, filter_bar = filter_bar }"

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(
    "-- GENERADO por tests/build_panel_fixture.py — no editar a mano.\n"
    "-- Fuente real embebida: ../panel.luau\n"
    "return function(noctalia, ui, panel, require, barWidget)\n"
    + source
    + "\n"
    + EXPORTS
    + "\nend\n",
    encoding="utf-8",
)
print(f"{OUT} ({len(source)} bytes de panel.luau)")
