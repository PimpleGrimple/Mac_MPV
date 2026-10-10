-- styles.lua: subtitle style picker that reads its styles straight from mpv's own profiles.
--
-- A profile is a style if EITHER
--   * it is defined in ~~/styles.conf (any name; pulled in from mpv.conf with  include=~~/styles.conf), OR
--   * its name starts with "style-" (see style_prefix) wherever it is defined, e.g. directly in mpv.conf.
--
--   [style-clean]
--   profile-desc="Clean (white, bold)"      # "Name (description)" -> shown as name + dim description
--   sub-font="Helvetica Neue"
--   sub-bold=yes
--   sub-color="#FFFFFF"                      # quote values containing '#'
--
-- Styles appear in the menu in file order; the first one is the default. Profiles with profile-cond are fine too
-- (mpv applies them automatically; they also appear in the menu, tagged "auto").
-- The menu look comes from menu.lua: put menu-accent_color=... (etc.) in a style's script-opts-append lines for a
-- shared look, or styles-menu_accent_color=... to change only this script's menu. The menu follows script-opts live,
-- so it recolors itself to match the style being previewed.
-- Styles are applied by this script (plain options + script-opts-append only) and re-checked while a file loads,
-- so slow network files and auto profiles can't leave you with an unstyled player.
-- input.conf:  <key> script-binding styles/toggle_menu | cycle_forward | cycle_backward | reset_default

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")
local msg = require("mp.msg")

-- The menu drawing lives in ~~/script-modules/menu.lua
package.path = mp.command_native({ "expand-path", "~~/script-modules" }) .. "/?.lua;" .. package.path
local Menu = require("menu")

local CONFIG = {
    styles_file = "~~/styles.conf",  -- every profile listed in this file is a style (it must be include'd from mpv.conf)
    style_prefix = "style-",         -- profiles with this name prefix are styles too, wherever they are defined ("" = off)
    default_entry = false,           -- add a first menu entry "Default" = plain mpv.conf values (no style applied)
    override_ass = false,            -- Set to true if you want the script to manage sub-ass-override
    ass_override_mode = "scale",     -- Mode used when override_ass is true ("force", "scale", "strip", "yes")
    show_osc = true,                 -- show the modernx UI whenever a style is previewed or picked (hides again after its hide_timeout)
}
options.read_options(CONFIG, "styles")

local STATE_FILE = mp.command_native({ "expand-path", "~~/cache/scripts/styles.json" })
local MENU_TIMEOUT = 15
local SETTLE_DELAYS = { 0.5, 2, 5 } -- seconds after file-loaded at which the style is re-checked

-- Options that describe the profile itself rather than a setting.
local META_KEYS = { ["profile"] = true, ["profile-desc"] = true, ["profile-cond"] = true, ["profile-restore"] = true }
-- List options (vf-add, ...) are not applied by this script; script-opts-append is handled separately.
local LIST_SUFFIXES = { "-append", "-add", "-pre", "-set", "-clr", "-del", "-remove", "-toggle" }

local function is_list_key(key)
    for _, suffix in ipairs(LIST_SUFFIXES) do
        if key:sub(-#suffix) == suffix then return true end
    end
    return false
end

local styles = {}   -- the style profiles (plus an optional "Default" entry first)
local raw_sample = nil
local problem = nil -- set when styles.conf lists profiles that mpv hasn't loaded
local active = 1
local menu = nil -- the Menu instance, created on first use

---------------------------------------------------------------------------
-- Reading styles from mpv.conf
---------------------------------------------------------------------------

local function to_bool(v)
    v = tostring(v or ""):lower()
    return v == "yes" or v == "true" or v == "on" or v == "1"
end

local function unquote(v)
    return (tostring(v):gsub('^"(.*)"$', "%1"))
end

-- mpv color ("#RRGGBB", "#AARRGGBB" or "r/g/b[/a]" floats) -> "RRGGBB"
local function mpv_color_to_rgb(c)
    c = unquote(c or "")
    local hex = c:match("^#(%x%x%x%x%x%x)$") or c:match("^#%x%x(%x%x%x%x%x%x)$")
    if hex then return hex end
    local r, g, b = c:match("^([%d%.]+)/([%d%.]+)/([%d%.]+)")
    if r then
        local function byte(x) return math.max(0, math.min(255, math.floor((tonumber(x) or 1) * 255 + 0.5))) end
        return string.format("%02X%02X%02X", byte(r), byte(g), byte(b))
    end
    return "FFFFFF"
end

-- A profile's options, following "profile=<other>" includes.
-- Returns an ordered list of {key=, value=} (repeated keys such as script-opts-append all kept, meta keys left out)
-- and a key -> value map (last one wins, meta keys included).
local function flatten_options(by_name, name, list, map, depth)
    list, map, depth = list or {}, map or {}, depth or 0
    local p = by_name[name]
    if not p or depth > 8 then return list, map end
    for _, o in ipairs(p.options or {}) do
        if o.key == "profile" then
            for included in tostring(o.value):gmatch("[^,]+") do
                flatten_options(by_name, included, list, map, depth + 1)
            end
        else
            map[o.key] = o.value
            if not META_KEYS[o.key] then list[#list + 1] = { key = o.key, value = tostring(o.value) } end
        end
    end
    return list, map
end

-- Section names of the styles file, in file order ({} + false when the file does not exist).
local function styles_file_names()
    local f = io.open(mp.command_native({ "expand-path", CONFIG.styles_file }), "r")
    if not f then return {}, false end
    local names = {}
    for line in f:lines() do
        local name = line:match("^%[(.-)%]%s*$")
        if name and name ~= "default" then names[#names + 1] = name end
    end
    f:close()
    return names, true
end

local function collect_styles()
    local list = mp.get_property_native("profile-list") or {}
    local by_name = {}
    for _, p in ipairs(list) do by_name[p.name] = p end

    -- Which profiles are styles: the styles file first (file order), then prefixed ones.
    local ids, wanted = {}, {}
    local function want(name)
        if not wanted[name] then
            wanted[name] = true
            ids[#ids + 1] = name
        end
    end
    local file_names = styles_file_names()
    for _, name in ipairs(file_names) do want(name) end
    local prefix = CONFIG.style_prefix
    if prefix ~= "" then
        for _, p in ipairs(list) do
            if p.name:sub(1, #prefix) == prefix then want(p.name) end
        end
    end

    local found, missing = {}, {}
    for _, id in ipairs(ids) do
        local p = by_name[id]
        if not p then
            missing[#missing + 1] = id
        else
            raw_sample = raw_sample or p
            local entries, opts = flatten_options(by_name, id)
            local desc = tostring(p["profile-desc"] or opts["profile-desc"] or "")

            local name, detail = desc, ""
            local main, sub = desc:match("^(.-)%s*%((.-)%)%s*$")
            if main and main ~= "" then name, detail = main, sub end
            if name == "" then
                local bare = (prefix ~= "" and id:sub(1, #prefix) == prefix) and id:sub(#prefix + 1) or id
                name = bare:gsub("[-_]+", " "):gsub("^%l", string.upper)
            end
            if name == "" then name = id end
            if opts["profile-cond"] then detail = (detail ~= "" and detail .. " · " or "") .. "auto" end

            found[#found + 1] = { id = id, name = name, desc = detail, list = entries, opts = opts }
        end
    end

    if #missing > 0 then
        problem = string.format("%s lists profiles mpv doesn't know - add  include=%s  to mpv.conf", CONFIG.styles_file, CONFIG.styles_file)
        msg.warn(problem .. " (" .. table.concat(missing, ", ") .. ")")
    end

    styles = {}
    if CONFIG.default_entry then styles[1] = { name = "Default", desc = "mpv.conf", list = {}, opts = {} } end
    for _, s in ipairs(found) do styles[#styles + 1] = s end

    -- What the menu previews: the style's own value, else what mpv.conf has (nothing is applied yet).
    for _, s in ipairs(styles) do
        s.font = unquote(s.opts["sub-font"] or mp.get_property("sub-font") or "Helvetica Neue")
        s.bold = to_bool(s.opts["sub-bold"] or mp.get_property("sub-bold"))
        s.italic = to_bool(s.opts["sub-italic"] or mp.get_property("sub-italic"))
        s.color = mpv_color_to_rgb(s.opts["sub-color"] or mp.get_property("sub-color"))
    end
end

---------------------------------------------------------------------------
-- Applying + persistence
---------------------------------------------------------------------------

-- Idempotent: only writes what differs, and merges all script-opts-append lines into one script-opts write,
-- so repeating it while a file loads neither piles up entries nor retriggers anything.
local function apply_style(index)
    local s = styles[index]
    if not s then return end
    local merged, dirty = {}, false
    for k, v in pairs(mp.get_property_native("options/script-opts") or {}) do merged[k] = v end
    for _, e in ipairs(s.list) do
        if e.key == "script-opts-append" then
            local k, v = e.value:match("^([^=]+)=(.*)$")
            if k and merged[k] ~= v then merged[k], dirty = v, true end
        elseif not is_list_key(e.key) and mp.get_property(e.key) ~= e.value then
            mp.set_property(e.key, e.value)
        end
    end
    if dirty then mp.set_property_native("options/script-opts", merged) end
    if CONFIG.override_ass then mp.set_property("sub-ass-override", CONFIG.ass_override_mode) end
end

local function save_state()
    local dir = utils.split_path(STATE_FILE)
    if not utils.file_info(dir) then
        mp.command_native({ name = "subprocess", args = { "mkdir", "-p", dir }, playback_only = false })
    end
    local f = io.open(STATE_FILE, "w")
    if not f then
        msg.warn("Could not save style choice to " .. STATE_FILE)
        return
    end
    f:write(utils.format_json({ style = styles[active].id or "" }))
    f:close()
end

local function load_saved_index()
    local f = io.open(STATE_FILE, "r")
    if not f then return 1 end
    local content = f:read("*a") or ""
    f:close()
    local data = content ~= "" and utils.parse_json(content)
    local id = type(data) == "table" and data.style
    for i, s in ipairs(styles) do
        if s.id and s.id == id then return i end
    end
    return 1
end

-- modernx's own show_osc key binding (only exists when modernx has key_bindings=yes, which is its default)
local function show_ui()
    if CONFIG.show_osc then mp.commandv("script-binding", "modernx/show_osc") end
end

local function select_style(index)
    active = index
    apply_style(index)
    show_ui()
    save_state()
    mp.osd_message("Style: " .. styles[index].name, 2)
end

-- Keep the active style in place while files load (slow mounts, auto profiles, other scripts touching script-opts).
local function settle()
    if menu and menu:is_open() then return end -- don't fight the live preview
    if styles[active] and styles[active].id then apply_style(active) end
end

local timers, debounce = {}, nil
mp.register_event("file-loaded", function()
    for _, t in ipairs(timers) do t:kill() end
    timers = {}
    settle()
    for _, d in ipairs(SETTLE_DELAYS) do timers[#timers + 1] = mp.add_timeout(d, settle) end
end)
mp.observe_property("options/script-opts", "native", function()
    if debounce then debounce:kill() end
    debounce = mp.add_timeout(0.3, settle)
end)

---------------------------------------------------------------------------
-- Menu (menu.lua does the drawing, keys, mouse and timeout; this wires it to the styles)
---------------------------------------------------------------------------

local function has_styles()
    return #styles > (CONFIG.default_entry and 1 or 0)
end

local function toggle_menu()
    if menu and menu:is_open() then
        menu:cancel()
        return
    end
    if not has_styles() then
        mp.osd_message(problem or string.format("No styles found - put profiles in %s, or name them \"%s...\" in mpv.conf",
            CONFIG.styles_file, CONFIG.style_prefix), 5)
        return
    end

    local items = {}
    for i, st in ipairs(styles) do
        -- each row is drawn in the style's own font
        items[i] = { text = st.name, desc = st.desc, font = st.font, bold = st.bold, italic = st.italic, color = st.color }
    end
    local previewed = active

    menu = Menu:new({ items = items, active = active })
    menu.on_move = function(_, index) -- live preview while browsing
        previewed = index
        apply_style(index)
        show_ui()
    end
    menu.on_select = function(_, index) select_style(index) end
    menu.on_cancel = function() -- Esc / q / click outside / timeout: back to the style that was active
        if previewed ~= active then apply_style(active) end
    end
    show_ui()
    menu:open({ selected = active, timeout = MENU_TIMEOUT })
end

---------------------------------------------------------------------------
-- Actions, startup
---------------------------------------------------------------------------

local function cycle(delta)
    if not has_styles() then return toggle_menu() end -- shows the "no styles" hint
    select_style((active - 1 + delta) % #styles + 1)
end

mp.add_key_binding(nil, "toggle_menu", toggle_menu)
mp.add_key_binding(nil, "cycle_forward", function() cycle(1) end)
mp.add_key_binding(nil, "cycle_backward", function() cycle(-1) end)
mp.add_key_binding(nil, "reset_default", function()
    if not has_styles() then return toggle_menu() end
    select_style(1)
end)

-- Troubleshooting: `script-message styles-dump` (console: ` key) lists what was detected.
mp.register_script_message("styles-dump", function()
    for i, s in ipairs(styles) do
        msg.info(string.format("[%d] id=%s name=%q desc=%q font=%q bold=%s italic=%s color=%s options=%d",
            i, tostring(s.id), s.name, s.desc, s.font, tostring(s.bold), tostring(s.italic), s.color, #s.list))
    end
    msg.info("raw profile-list entry: " .. tostring(utils.format_json(raw_sample or {})))
    mp.osd_message(string.format("%d style(s) found - see log", #styles), 3)
end)

collect_styles()
active = load_saved_index()
if styles[active] and styles[active].id then apply_style(active) end
