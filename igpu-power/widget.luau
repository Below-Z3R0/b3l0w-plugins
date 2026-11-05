--!nonstrict
-- iGPU Power button widget v2
-- Click toggle del panel dropdown

local glyph = noctalia.getConfig("glyph") or "bolt"

local function render()
    barWidget.setGlyph(glyph)
    barWidget.setTooltip("iGPU Power Profile")
end

function update()
    render()
end

function onClick()
    noctalia.togglePanel("user/igpu-power:menu")
end

render()