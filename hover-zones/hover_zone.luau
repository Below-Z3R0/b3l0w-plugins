--!nonstrict
-- Hover Zone widget v11 - producción con debug controlable vía IPC
--
-- Debug commands:
--   noctalia msg plugin user/hover-zones:hover_zone all enable-debug
--   noctalia msg plugin user/hover-zones:hover_zone all disable-debug
--   noctalia msg plugin user/hover-zones:hover_zone all log-config
--   noctalia msg plugin user/hover-zones:hover_zone all reset-stats
--
-- Auto-debug si env HOVER_ZONES_DEBUG=1 está seteada al cargar

local panel = noctalia.getConfig("panel") or "launcher"
local context = noctalia.getConfig("context") or ""

-- PNG transparente 1x1
local IMG = "/home/b3low-z3r0/.config/noctalia/transparent.png"

-- Debug state: configurable via onIpc
local debug_enabled = false

-- Estado del widget para debugging
local state = {
    update_count = 0,
    hover_count = 0,
    last_hover = "none",
    last_hover_time = 0,
    last_click_time = 0,
}

local function now() return os.time() end
local function fmt_time(t) return t > 0 and os.date("%H:%M:%S", t) or "never" end

local function dbg(level, event, data)
    if not debug_enabled then return end
    local parts = { "[hover-zones v11:" .. level .. "] " .. event }
    if data then
        for k, v in pairs(data) do
            table.insert(parts, k .. "=" .. tostring(v))
        end
    end
    noctalia.log(table.concat(parts, " "))
end

local function logConfig()
    noctalia.log("[hover-zones v11:CONFIG] panel=" .. panel)
    noctalia.log("[hover-zones v11:CONFIG] context=" .. tostring(context))
    noctalia.log("[hover-zones v11:CONFIG] debug=" .. tostring(debug_enabled))
    noctalia.log("[hover-zones v11:CONFIG] update_count=" .. state.update_count)
    noctalia.log("[hover-zones v11:CONFIG] hover_count=" .. state.hover_count)
    noctalia.log("[hover-zones v11:CONFIG] last_hover=" .. state.last_hover)
    noctalia.log("[hover-zones v11:CONFIG] last_hover_time=" .. fmt_time(state.last_hover_time))
    noctalia.log("[hover-zones v11:CONFIG] last_click_time=" .. fmt_time(state.last_click_time))
end

-- El plugin dueño del panel puede publicar `panel_entry`: un mapa de
-- id-base -> id-real. Sirve para paneles que eligen su variante en runtime
-- (por ejemplo, uno que cambia de ancho). Se resuelve en el momento del
-- toggle, no al cargar: el id real cambia con la configuración del otro
-- plugin y este widget no se recarga.
-- El archivo se prefiere sobre `noctalia.state`: el state NO se comparte
-- entre plugins, así que desde acá no se puede leer lo que publica el plugin
-- dueño del panel.
local PANEL_ENTRY_FILE = "~/.local/state/noctalia/panel-entries.json"

local function resolvedPanel()
    local base = noctalia.getConfig("panel") or panel or "launcher"
    local texto = noctalia.readFile(PANEL_ENTRY_FILE)
    if type(texto) == "string" and texto ~= "" then
        local datos = noctalia.json.decode(texto)
        if type(datos) == "table" then
            local real = datos[base]
            if type(real) == "string" and real ~= "" then
                return real
            end
        end
    end
    return base
end

local function togglePanel()
    local t = now()
    local target = resolvedPanel()
    dbg("INFO", "togglePanel called", {
        panel = target,
        context = context,
        time = fmt_time(t),
        hover_count = state.hover_count,
    })
    -- SIEMPRE noctalia.togglePanel() directo: preserva source bar para anchoring.
    -- Abrir con `noctalia msg panel-open` perdería la barra de origen.
    local ok, err = pcall(noctalia.togglePanel, target)
    if not ok then
        dbg("ERROR", "togglePanel failed", { panel = target, error = tostring(err) })
    end
end

function update()
    noctalia.setUpdateInterval(60000)
    state.update_count = state.update_count + 1
    -- Hit area generoso: 60x60 escalado por bar.scale
    -- (para bar.top/bottom/right con scale=4.0 → 240x240 efectivo)
    pcall(barWidget.setImage, IMG, false, 60, 60)
    pcall(barWidget.setText, "")
    pcall(barWidget.setTooltip, "")
    dbg("INFO", "update #" .. state.update_count, { panel = panel })
end

function onClick()
    state.last_click_time = now()
    dbg("INFO", "onClick", {
        panel = panel,
        time = fmt_time(state.last_click_time),
    })
    togglePanel()
end

function onHover(entered)
    state.last_hover = tostring(entered)
    state.last_hover_time = now()
    if entered then
        state.hover_count = state.hover_count + 1
    end
    dbg(entered and "HOVER" or "HOVER-LEAVE", "onHover", {
        entered = tostring(entered),
        panel = panel,
        time = fmt_time(state.last_hover_time),
        hover_count = state.hover_count,
    })
    if entered then
        togglePanel()
    end
end

function onIpc(event, payload)
    dbg("IPC", "onIpc", { event = tostring(event), payload = tostring(payload) })
    if event == "enable-debug" then
        debug_enabled = true
        noctalia.notify("Hover Zones", "Debug ENABLED")
        dbg("INFO", "debug enabled", { panel = panel })
    elseif event == "disable-debug" then
        debug_enabled = false
        noctalia.notify("Hover Zones", "Debug DISABLED")
    elseif event == "log-config" then
        logConfig()
        noctalia.notify("Hover Zones", "Config logged")
    elseif event == "toggle-now" then
        -- Mismo camino que el hover, pero disparable por IPC: sirve para
        -- probar el anclaje (el panel tiene que abrirse en ESTA barra).
        togglePanel()
    elseif event == "reset-stats" then
        state.hover_count = 0
        state.last_hover = "none"
        noctalia.notify("Hover Zones", "Stats reset")
    end
end

-- Init: auto-debug si env var seteada
-- noctalia exposes env via noctalia.getenv (no hay os.getenv en este runtime)
local env_debug = noctalia.getenv and noctalia.getenv("HOVER_ZONES_DEBUG") or nil
if env_debug == "1" or env_debug == "true" or env_debug == "yes" then
    debug_enabled = true
    noctalia.log("[hover-zones v11:INIT] auto-debug enabled via env HOVER_ZONES_DEBUG=" .. env_debug)
end