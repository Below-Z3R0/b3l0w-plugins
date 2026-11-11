#!/usr/bin/env python3
"""Empaqueta los fixtures reales en un literal Luau.

El binario `luau` de Arch es sandboxed (sin `io` ni `os`), así que el spec no
puede leer archivos: este script convierte `tests/fixtures/*` en
`tests/fixtures/data.luau` con la misma salida que capturaron `wpctl`, `pactl` y
`upower`. Los JSON se incrustan como tablas para no necesitar un decoder dentro
del spec.

    python3 tests/build_fixtures.py && luau tests/audio_spec.luau
"""

import json
from pathlib import Path

FIXTURES = Path(__file__).parent / "fixtures"


def lua(value) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        escaped = (
            value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
        )
        return f'"{escaped}"'
    if isinstance(value, list):
        return "{" + ", ".join(lua(item) for item in value) + "}"
    if isinstance(value, dict):
        body = ", ".join(f"[{lua(key)}] = {lua(item)}" for key, item in value.items())
        return "{" + body + "}"
    raise TypeError(f"tipo no soportado: {type(value)}")


def load_json(name: str):
    return json.loads((FIXTURES / name).read_text())


def load_text(name: str) -> str:
    return (FIXTURES / name).read_text()


data = {
    "status": load_text("wpctl_status.txt"),
    "sinks": load_json("sinks.json"),
    "sources": load_json("sources.json"),
    "cards": load_json("cards.json"),
    "inputs": load_json("sink-inputs.json"),
    "pwdump_none": load_text("pwdump_none.txt"),
    "bluez_card": load_json("synthetic_bluez_card.json"),
    "pw_dump": load_text("synthetic_pw_dump.json"),
}

out = FIXTURES / "data.luau"
out.write_text("-- GENERADO por tests/build_fixtures.py — no editar a mano.\nreturn " + lua(data) + "\n")
print(f"{out} {out.stat().st_size} bytes, {len(data)} claves")
