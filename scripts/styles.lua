-- A profile is a style if EITHER
--   * it is defined in ~~/styles.conf (any name; pulled in from mpv.conf with  include=~~/styles.conf), OR
--   * its name starts with "style-" (see style_prefix) wherever it is defined, e.g. directly in mpv.conf.
--
--   [example]
--   profile-desc="Clean (white, bold)"      # "Name (description)" -> shown as name + dim description
--   sub-font="Helvetica Neue"
--   sub-color="#FFFFFF"                     # quote values containing '#'

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")
local msg = require("mp.msg")

package.path = mp.command_native({ "expand-path", "~~/scripts/autosubsync" }) .. "/?.lua;" .. package.path
local Menu = require("menu_style")

local CONFIG = {
    styles_file = "~~/styles.conf",
    style_prefix = "style-",
    default_entry = false,
    show_osc = true,
}
options.read_options(CONFIG, "styles")

local STATE_FILE = mp.command_native({ "expand-path", "~~/cache/scripts/styles.json" })
local MENU_TIMEOUT = 15

local META_KEYS = { ["profile"] = true, ["profile-desc"] = true, ["profile-cond"] = true, ["profile-restore"] = true }
local LIST_SUFFIXES = { "-append", "-add", "-pre", "-set", "-clr", "-del", "-remove", "-toggle" }

local function is_list_key(key)
    for _, suffix in ipairs(LIST_SUFFIXES) do
        if key:sub(-#suffix) == suffix then return true end
    end
    return false
end

local styles = {}
local problem = nil
local active = 1
local menu = nil

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

local function styles_file_names()
    local f = io.open(mp.command_native({ "expand-path", CONFIG.styles_file }), "r")
    if not f then return {} end
    local names = {}
    for line in f:lines() do
        local name = line:match("^%[(.-)%]%s*$")
        if name and name ~= "default" then names[#names + 1] = name end
    end
    f:close()
    return names
end

local function collect_styles()
    local list = mp.get_property_native("profile-list") or {}
    local by_name = {}
    for _, p in ipairs(list) do by_name[p.name] = p end

    local ids, wanted = {}, {}
    local function want(name)
        if not wanted[name] then wanted[name] = true; ids[#ids + 1] = name end
    end
    for _, name in ipairs(styles_file_names()) do want(name) end
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

-- Idempotent: only writes what differs, and merges all script-opts-append lines into one write.
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
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return 1 end
    local data = utils.parse_json(content)
    local id = type(data) == "table" and data.style
    for i, s in ipairs(styles) do
        if s.id and s.id == id then return i end
    end
    return 1
end

-- modernx's own show_osc key binding (only exists when modernx has key_bindings=yes, its default).
-- If you don't use modernx, set show_osc=false in styles.conf or delete this function + its 3 call sites.
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

-- Re-apply the active style after things that could clobber it: file-loaded, or script-opts being
-- touched by anything. Debounced so a burst of changes costs one apply, not many.
local settle_timer = nil
local function settle()
    if menu and menu:is_open() then return end
    if styles[active] and styles[active].id then apply_style(active) end
end

local function schedule_settle(delay)
    if settle_timer then settle_timer:kill() end
    settle_timer = mp.add_timeout(delay, settle)
end

mp.register_event("file-loaded", function() settle() end)
mp.observe_property("options/script-opts", "native", function() schedule_settle(0.3) end)

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

local function toggle_menu()
    if menu and menu:is_open() then
        menu:cancel()
        return
    end
    if #styles <= (CONFIG.default_entry and 1 or 0) then
        mp.osd_message(problem or string.format("No styles found - put profiles in %s, or name them \"%s...\" in mpv.conf",
            CONFIG.styles_file, CONFIG.style_prefix), 5)
        return
    end

    local items = {}
    for i, st in ipairs(styles) do
        items[i] = { text = st.name, desc = st.desc, font = st.font, bold = st.bold, italic = st.italic, color = st.color }
    end
    local previewed = active

    menu = Menu:new({ items = items, active = active })
    menu.on_move = function(_, index) previewed = index; apply_style(index); show_ui() end
    menu.on_select = function(_, index) select_style(index) end
    menu.on_cancel = function() if previewed ~= active then apply_style(active) end end
    show_ui()
    menu:open({ selected = active, timeout = MENU_TIMEOUT })
end

---------------------------------------------------------------------------
-- Actions, startup
---------------------------------------------------------------------------

local function cycle(delta)
    if #styles <= (CONFIG.default_entry and 1 or 0) then return toggle_menu() end
    select_style((active - 1 + delta) % #styles + 1)
end

mp.add_key_binding("g-u", "toggle_menu", toggle_menu)
mp.add_key_binding("u", "cycle_forward", function() cycle(1) end)
mp.add_key_binding("U", "cycle_backward", function() cycle(-1) end)
mp.add_key_binding("g-U", "reset_default", function()
    if #styles <= (CONFIG.default_entry and 1 or 0) then return toggle_menu() end
    select_style(1)
end)

collect_styles()
active = load_saved_index()
if styles[active] and styles[active].id then apply_style(active) end