--!nonstrict
-- iGPU Power panel v4
-- Dropdown con 3 botones: Performance / Balanced / Low-Power
-- Cada botón ejecuta /usr/local/bin/igpu-power-menu.sh <mode>
-- With structured logging via noctalia.log()

local MODES = {
    { id = "performance", label = "Performance", desc = "iGPU al maximo. Reboot requerido.", glyph = "bolt" },
    { id = "balanced",    label = "Balanced",    desc = "Ahorro automatico. Reboot requerido.", glyph = "circle-half" },
    { id = "low-power",   label = "Power Saver", desc = "Maximo ahorro. Reboot requerido.", glyph = "leaf" },
}

local function logEvent(event, data)
    local parts = {}
    for k, v in pairs(data or {}) do
        table.insert(parts, k .. "=" .. tostring(v))
    end
    local msg = "igpu-power panel " .. event
    if #parts > 0 then
        msg = msg .. " " .. table.concat(parts, " ")
    end
    noctalia.log(msg)
end

local function executeMode(mode)
    logEvent("execute_mode", { mode = mode })
    noctalia.runAsync("/usr/local/bin/igpu-power-menu.sh " .. mode)
end

local function modeButton(m)
    return ui.button({
        text = m.label,
        glyph = m.glyph,
        onClick = function()
            logEvent("mode_clicked", { mode = m.id })
            executeMode(m.id)
            panel.close()
        end,
    })
end

local function render()
    panel.render(ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
        ui.label({ text = "iGPU Power Profile", fontSize = 14, fontWeight = "bold", color = "on_surface" }),
        modeButton(MODES[1]),
        modeButton(MODES[2]),
        modeButton(MODES[3]),
    }))
end

function onOpen(_context)
    logEvent("opened", {})
    render()
end

render()
