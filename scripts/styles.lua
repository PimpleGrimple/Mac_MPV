local mp = require("mp")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")
local options = require("mp.options")

local CONFIG = {
    bg_color = "2D0823",         -- Menu Background Color
    bg_alpha = "90",             -- Menu Background Transparency (00=Solid, FF=Invisible)
    accent_color = "FF4D94",     -- Accent Color for Cursor and Active Items
    border_color = "9A3D88",     -- Menu Border Color
    border_alpha = "60",         -- Menu Border Transparency
    bg_blur = 10,                -- Blurs the edges of the window
    bg_shadow = 0,               -- Adds a drop shadow to the window
    override_ass = false,        -- Set to true if you want the script to manage sub-ass-override
    ass_override_mode = "scale", -- Mode used when override_ass is true ("force", "scale", "strip", "yes")
}
options.read_options(CONFIG, "styles")

local STATE_FILE = mp.command_native({"expand-path", "~~/cache/scripts/styles.json"})

local V_WIDTH = 1280
local V_HEIGHT = 720

local profiles = {}

local function mpv_color_to_ass(c)
    if not c then return "&HFFFFFF&" end
    c = c:gsub('"', '')
    if c:match("^#%x%x%x%x%x%x%x%x$") then
        return "&H" .. c:sub(8,9) .. c:sub(6,7) .. c:sub(4,5) .. "&"
    elseif c:match("^#%x%x%x%x%x%x$") then
        return "&H" .. c:sub(6,7) .. c:sub(4,5) .. c:sub(2,3) .. "&"
    end
    return "&HFFFFFF&"
end

local function parse_styles_conf()
    local path = mp.command_native({"expand-path", "~~/styles.conf"})
    local f = io.open(path, "r")
    if not f then return end
    
    profiles = {}
    local current = nil
    
    for line in f:lines() do
        local id = line:match("^%[(.+)%]$")
        if id then
            current = { id = id, name = id, font = "Helvetica Neue", bold = false, italic = false, color = "&HFFFFFF&", border_color = "&H000000&" }
            table.insert(profiles, current)
        elseif current then
            local raw_desc = line:match('^profile%-desc="?(.-)"?$')
            if raw_desc then 
                local main_name, sub_desc = raw_desc:match("^(.-)%s*%((.-)%)%s*$")
                if main_name then
                    current.name = main_name
                    current.desc = sub_desc
                else
                    current.name = raw_desc
                    current.desc = ""
                end
            end
            
            local font = line:match('^sub%-font="?(.-)"?$')
            if font then current.font = font end
            
            local bold = line:match("^sub%-bold=(%w+)")
            if bold then current.bold = (bold == "yes") end
            
            local italic = line:match("^sub%-italic=(%w+)")
            if italic then current.italic = (italic == "yes") end
            
            local color = line:match("^sub%-color=(%S+)")
            if color then current.color = mpv_color_to_ass(color) end
        end
    end
    f:close()
end

parse_styles_conf()

local state = {
    profile_idx = 1
}

local menu_cursor = 1
local menu_active = false
local menu_timer = nil

-- Persistence

local function save_state()
    local save_obj = {
        profile_idx = state.profile_idx
    }
    local json = utils.format_json(save_obj)
    if json then
        local f = io.open(STATE_FILE, "w")
        if f then f:write(json); f:close() end
    end
end

local function load_state()
    local f = io.open(STATE_FILE, "r")
    if not f then return end
    local content = f:read("*all")
    f:close()
    if content and #content > 0 then
        local parsed = utils.parse_json(content)
        if parsed then
            state.profile_idx = parsed.profile_idx or 1
        end
    end
end

-- Application Logic
local function apply_profile(index, show_osd, silent)
    local item = profiles[index]
    if not item then return end
    state.profile_idx = index
    
    -- Apply the selected profile
    mp.command("apply-profile " .. item.id)
    
    -- Only manage sub-ass-override if explicitly enabled in CONFIG
    if CONFIG.override_ass then
        mp.set_property("sub-ass-override", CONFIG.ass_override_mode)
    end
    
    save_state()
    if show_osd and not silent then mp.osd_message(string.format("Style: %s", item.name), 2.0) end
end

local function preview_profile(index)
    local item = profiles[index]
    if not item then return end
    mp.command("apply-profile " .. item.id)
    
    if CONFIG.override_ass then
        mp.set_property("sub-ass-override", CONFIG.ass_override_mode)
    end
end

local function live_apply_preview()
    preview_profile(menu_cursor)
    options.read_options(CONFIG, "styles")
end

-- UI & Menu System
local function close_menu()
    if not menu_active then return end
    menu_active = false
    if menu_timer then
        menu_timer:kill()
        menu_timer = nil
    end
    mp.set_osd_ass(0, 0, "")
    mp.remove_key_binding("sub_menu_up")
    mp.remove_key_binding("sub_menu_up_k")
    mp.remove_key_binding("sub_menu_down")
    mp.remove_key_binding("sub_menu_down_j")
    mp.remove_key_binding("sub_menu_wheelup")
    mp.remove_key_binding("sub_menu_wheeldown")
    mp.remove_key_binding("sub_menu_enter")
    mp.remove_key_binding("sub_menu_esc")
    mp.remove_key_binding("sub_menu_q")
end

local function reset_menu_timeout()
    if menu_timer then menu_timer:kill() end
    menu_timer = mp.add_timeout(15.0, close_menu)
end

local function render_menu()
    if not menu_active then return end

    local ass = assdraw.ass_new()
    local active_idx = state.profile_idx
    local function get_color(c) return "&H" .. (tostring(c) or ""):gsub("^[#!]", "") .. "&" end
    local accent_color = get_color(CONFIG.accent_color)

    local card_w = 460
    local visible_count = 9
    local row_h = 48
    local pill_h = 40
    local header_space = 15
    local card_h = (header_space * 2) + (visible_count * row_h)
    local card_x = V_WIDTH - card_w - 30
    local card_y = 30

    -- Card Background
    ass:new_event()
    ass:pos(card_x, card_y)
    ass:append(string.format("{\\bord1.5\\3c%s\\3a%s\\1c%s\\1a%s\\shad%d\\blur%d\\4a&HFF&}", get_color(CONFIG.border_color), get_color(CONFIG.border_alpha), get_color(CONFIG.bg_color), get_color(CONFIG.bg_alpha), CONFIG.bg_shadow, CONFIG.bg_blur))
    ass:draw_start()
    ass:round_rect_cw(0, 0, card_w, card_h, 12)
    ass:draw_stop()

    local list_y = card_y + header_space

    -- List
    local half = math.floor(visible_count / 2)
    local start_idx = menu_cursor - half
    if start_idx < 1 then start_idx = 1 end
    if start_idx > (#profiles - visible_count + 1) then start_idx = math.max(1, #profiles - visible_count + 1) end
    local end_idx = math.min(#profiles, start_idx + visible_count - 1)

    local row_w = card_w - 30

    for i = start_idx, end_idx do
        local p = profiles[i]
        local is_cursor = (i == menu_cursor)
        local is_active = (i == active_idx)
        local cy = list_y + ((i - start_idx) * row_h)

        -- Background Pill for Cursor
        if is_cursor then
            ass:new_event()
            ass:pos(card_x + 15, cy)
            ass:append(string.format("{\\bord1\\3c%s\\3a&H40&\\1c%s\\1a&H88&\\shad0\\blur0\\4a&HFF&}", accent_color, get_color(CONFIG.bg_color)))
            ass:draw_start()
            ass:round_rect_cw(0, 0, row_w, pill_h, 8)
            ass:draw_stop()
        end
        
        -- Dark background for Active Item
        if is_active and not is_cursor then
            ass:new_event()
            ass:pos(card_x + 15, cy)
            ass:append("{\\bord0\\1c&H000000&\\1a&HAA&\\shad0\\blur0\\4a&HFF&}")
            ass:draw_start()
            ass:round_rect_cw(0, 0, row_w, pill_h, 8)
            ass:draw_stop()
        end

        -- Vertical Accent Bar for Active Item
        if is_active then
            ass:new_event()
            ass:pos(card_x + 15, cy + math.floor(pill_h / 2) - 12)
            ass:append(string.format("{\\bord0\\1c%s\\1a&H00&\\shad0\\blur2\\4a&HFF&}", accent_color))
            ass:draw_start()
            ass:round_rect_cw(0, 0, 4, 24, 2)
            ass:draw_stop()
        end

        -- Text Content
        ass:new_event()
        ass:pos(card_x + 30, cy + math.floor(pill_h / 2))
        ass:an(4)

        local text_color = p.color or "&HFFFFFF&"
        local f_name = p.font or "Helvetica Neue"
        local f_size = is_cursor and 21 or 19
        
        -- Style Name
        ass:append(string.format("{\\q2\\fn%s\\b%s\\i%s\\fs%d\\1c%s\\bord1.5\\3c&H111111&\\shad0\\blur0}%s",
            f_name, (p.bold and "1" or "0"), (p.italic and "1" or "0"), f_size, text_color, p.name))

        -- Description
        if p.desc and p.desc ~= "" then
            ass:append(string.format(" {\\fnHelvetica Neue\\b0\\i1\\fs14\\1c&HAAAAAA&\\bord1}  %s", p.desc))
        end
    end

    mp.set_osd_ass(V_WIDTH, V_HEIGHT, ass.text)
    reset_menu_timeout()
end

local function menu_up()
    menu_cursor = menu_cursor - 1
    if menu_cursor < 1 then menu_cursor = #profiles end
    live_apply_preview()
    render_menu()
end

local function menu_down()
    menu_cursor = menu_cursor + 1
    if menu_cursor > #profiles then menu_cursor = 1 end
    live_apply_preview()
    render_menu()
end

local function menu_confirm()
    apply_profile(menu_cursor, true, false)
    close_menu()
end

local function toggle_menu()
    if menu_active then
        close_menu()
    else
        options.read_options(CONFIG, "styles")
        menu_active = true
        parse_styles_conf()
        if state.profile_idx > #profiles then state.profile_idx = 1 end
        menu_cursor = state.profile_idx
        
        mp.add_forced_key_binding("UP", "sub_menu_up", menu_up, {repeatable = true})
        mp.add_forced_key_binding("k", "sub_menu_up_k", menu_up, {repeatable = true})
        mp.add_forced_key_binding("DOWN", "sub_menu_down", menu_down, {repeatable = true})
        mp.add_forced_key_binding("j", "sub_menu_down_j", menu_down, {repeatable = true})
        mp.add_forced_key_binding("WHEEL_UP", "sub_menu_wheelup", menu_up)
        mp.add_forced_key_binding("WHEEL_DOWN", "sub_menu_wheeldown", menu_down)
        mp.add_forced_key_binding("ENTER", "sub_menu_enter", menu_confirm)
        mp.add_forced_key_binding("ESC", "sub_menu_esc", menu_confirm)
        mp.add_forced_key_binding("q", "sub_menu_q", menu_confirm)
        
        render_menu()
    end
end

-- Auto-Style Detection & File Load Handler
local function apply_saved_profile()
    -- Ensure styles configuration is parsed before attempting to apply
    if #profiles == 0 then
        parse_styles_conf()
    end

    load_state()

    -- Safety fallback if index out of range
    if state.profile_idx > #profiles or state.profile_idx < 1 then
        state.profile_idx = 1
    end

    local item = profiles[state.profile_idx]
    if item then
        mp.commandv("apply-profile", item.id)
        if CONFIG.override_ass then
            mp.set_property("sub-ass-override", CONFIG.ass_override_mode)
        end
    end
end

local function on_file_loaded()
    -- Slight non-blocking delay (0.05s) to guarantee mpv internal 
    -- property states and profile hooks are fully ready.
    mp.add_timeout(0.05, apply_saved_profile)
end

mp.register_event("file-loaded", on_file_loaded)

-- Keybindings Registration
local function cycle_forward()
    state.profile_idx = state.profile_idx + 1
    if state.profile_idx > #profiles then state.profile_idx = 1 end
    apply_profile(state.profile_idx, true, false)
end

local function cycle_backward()
    state.profile_idx = state.profile_idx - 1
    if state.profile_idx < 1 then state.profile_idx = #profiles end
    apply_profile(state.profile_idx, true, false)
end

local function reset_default()
    apply_profile(1, true, false)
end

mp.add_key_binding(nil, "toggle_menu", toggle_menu)
mp.add_key_binding(nil, "cycle_forward", cycle_forward)
mp.add_key_binding(nil, "cycle_backward", cycle_backward)
mp.add_key_binding(nil, "reset_default", reset_default)