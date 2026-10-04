local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

-- Default user-configurable options (can be overridden via styles.conf or playlist_manager.conf)
local opts = {
    cursor_color = "00E5FF", -- Highlight color for selector in OSD menu (hex format: RRGGBB or BBGGRR)
}
options.read_options(opts, "playlist_manager")

-- Ensure script-modules and scripts directories are in package.path
local script_modules_path = mp.command_native({"expand-path", "~~/script-modules/?.lua;"})
local scripts_path = mp.command_native({"expand-path", "~~/scripts/?.lua;"})
if not package.path:find(script_modules_path, 1, true) then
    package.path = script_modules_path .. scripts_path .. package.path
end

local user_input_loaded, user_input = pcall(require, "user-input-module")

local playlists_dir = mp.command_native({"expand-path", "~/Music/playlists"})

-- Helper to ensure ASS color formatting (&HBBGGRR&)
local function format_ass_color(c)
    if not c or c == "" then return "&H00E5FF&" end
    local clean = tostring(c):gsub("^[#&Hh]+", ""):gsub("&$", "")
    return "&H" .. clean .. "&"
end

-- Ensure target directory exists on disk
local function ensure_dir()
    local res = utils.file_info(playlists_dir)
    if not res or not res.is_dir then
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = {"mkdir", "-p", playlists_dir}
        })
    end
end
ensure_dir()

-- Get full filesystem path for a playlist file
local function get_playlist_path(name)
    local clean_name = name:gsub("[/\\?%%*:|\"<>]", "_")
    return utils.join_path(playlists_dir, clean_name .. ".m3u8")
end

-- Check if current path already exists in target playlist
local function is_in_playlist(file_path, target_path)
    local f = io.open(file_path, "r")
    if not f then return false end
    for line in f:lines() do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == target_path then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

-- Remove a specific path from a playlist file
local function remove_from_playlist(name, target_path)
    local file_path = get_playlist_path(name)
    local f = io.open(file_path, "r")
    if not f then return false end
    local lines = {}
    local found = false
    for line in f:lines() do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == target_path then
            found = true
        elseif trimmed ~= "" then
            table.insert(lines, line)
        end
    end
    f:close()
    if found then
        local wf, err = io.open(file_path, "w")
        if wf then
            for _, l in ipairs(lines) do
                wf:write(l .. "\n")
            end
            wf:close()
            return true
        else
            msg.error("Failed to rewrite " .. file_path .. ": " .. tostring(err))
        end
    end
    return false
end

-- Check favorite status for currently playing file
local function check_favorite_status()
    local path = mp.get_property("path")
    if not path or path == "" then
        mp.set_property_native("user-data/is-favorite", false)
        return
    end
    local fav_path = get_playlist_path("favorites")
    local is_fav = is_in_playlist(fav_path, path)
    mp.set_property_native("user-data/is-favorite", is_fav)
end

-- Add current media to specified playlist
local function add_to_playlist(name)
    local path = mp.get_property("path")
    if not path or path == "" then
        mp.osd_message("No media currently playing!")
        return
    end

    ensure_dir()
    local file_path = get_playlist_path(name)

    -- Check for duplicate entry
    if is_in_playlist(file_path, path) then
        if name == "favorites" then
            mp.set_property_native("user-data/is-favorite", true)
        end
        mp.osd_message("Already in " .. name .. "!", 2)
        return
    end

    local file, err = io.open(file_path, "a")
    if file then
        file:write(path .. "\n")
        file:close()
        if name == "favorites" then
            mp.set_property_native("user-data/is-favorite", true)
        end
        mp.osd_message("Added to " .. name, 2)
        msg.info("Added " .. path .. " to " .. name)
    else
        msg.error("Failed to write to " .. file_path .. ": " .. tostring(err))
        mp.osd_message("Failed to write to playlist: " .. tostring(err), 2)
    end
end

-- Toggle favorite state for current media
local function toggle_favorite()
    local path = mp.get_property("path")
    if not path or path == "" then
        mp.osd_message("No media currently playing!")
        return
    end

    ensure_dir()
    local fav_path = get_playlist_path("favorites")
    if is_in_playlist(fav_path, path) then
        if remove_from_playlist("favorites", path) then
            mp.set_property_native("user-data/is-favorite", false)
            mp.osd_message("Removed from Favorites", 2)
            msg.info("Removed " .. path .. " from favorites")
        else
            mp.osd_message("Failed to remove from Favorites", 2)
        end
    else
        add_to_playlist("favorites")
    end
end

-- Export active mpv playlist to a timestamped file
local function export_playlist()
    local count = mp.get_property_number("playlist-count", 0)
    if count == 0 then
        mp.osd_message("Current playlist is empty!")
        return
    end

    ensure_dir()
    local time_str = os.date("%Y%m%d_%H%M%S")
    local file_path = utils.join_path(playlists_dir, "exported_" .. time_str .. ".m3u8")
    local file, err = io.open(file_path, "w")
    if not file then
        mp.osd_message("Failed to export playlist!", 2)
        msg.error("Failed to open export file: " .. tostring(err))
        return
    end

    for i = 0, count - 1 do
        local path = mp.get_property("playlist/" .. i .. "/filename")
        if path then
            file:write(path .. "\n")
        end
    end
    file:close()
    mp.osd_message("Exported to exported_" .. time_str .. ".m3u8", 3)
    msg.info("Exported playlist to " .. file_path)
end

-- Retrieve list of existing playlists in folder
local function get_existing_playlists()
    ensure_dir()
    local p = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {"ls", playlists_dir}
    })
    local lists = {}
    if p.status == 0 and p.stdout then
        for file in string.gmatch(p.stdout, "([^\n]+)%.m3u8") do
            table.insert(lists, file)
        end
    end
    return lists
end

-- Interactive OSD Menu
local menu_active = false
local menu_items = {}
local menu_cursor = 1

local function draw_menu()
    if not menu_active then return end

    local cursor_col = format_ass_color(opts.cursor_color)
    local ass = "{\\q2\\fs28\\bord2\\3c&H000000&\\1c&HFFFFFF&}"
    ass = ass .. "{\\b1\\1c" .. cursor_col .. "}Playlist Manager{\\b0\\1c&HFFFFFF&}\n"
    ass = ass .. "{\\fs20\\1c&HAAAAAA&}Add currently playing media to:{\\fs28\\1c&HFFFFFF&}\n\n"

    for i, item in ipairs(menu_items) do
        if i == menu_cursor then
            ass = ass .. "{\\1c" .. cursor_col .. "\\b1} ▸ " .. item .. " {\\b0\\1c&HFFFFFF&}\n"
        else
            ass = ass .. "   " .. item .. "\n"
        end
    end

    ass = ass .. "\n{\\fs18\\1c&H888888&}[▲/▼ / Scroll] Navigate   [Enter] Select   [Esc] Close"
    mp.set_osd_ass(1920, 1080, ass)
end

local function close_menu()
    menu_active = false
    mp.set_osd_ass(1920, 1080, "")
    mp.remove_key_binding("menu-up")
    mp.remove_key_binding("menu-down")
    mp.remove_key_binding("menu-k")
    mp.remove_key_binding("menu-j")
    mp.remove_key_binding("menu-wheel-up")
    mp.remove_key_binding("menu-wheel-down")
    mp.remove_key_binding("menu-enter")
    mp.remove_key_binding("menu-esc")
end

local function submit_new_playlist(text, err)
    if text and text ~= "" then
        add_to_playlist(text)
    end
end

local function menu_enter()
    local selected = menu_items[menu_cursor]
    close_menu()

    if selected == "[Create New Playlist]" then
        if not user_input_loaded then
            user_input_loaded, user_input = pcall(require, "user-input-module")
        end
        if user_input_loaded and user_input then
            user_input.get_user_input(submit_new_playlist, {
                request_text = "New Playlist Name:",
                default_input = "",
            })
        else
            mp.osd_message("user-input-module not found. Can't prompt.")
        end
    elseif selected == "favorites" then
        toggle_favorite()
    else
        add_to_playlist(selected)
    end
end

local function open_playlist_menu()
    if menu_active then
        close_menu()
        return
    end

    options.read_options(opts, "playlist_manager")
    local existing = get_existing_playlists()
    menu_items = {"[Create New Playlist]", "favorites", "watchlater"}

    local added = {favorites = true, watchlater = true}
    for _, name in ipairs(existing) do
        if not added[name] then
            table.insert(menu_items, name)
            added[name] = true
        end
    end

    menu_cursor = 1
    menu_active = true

    -- Navigation key bindings
    local move_up = function()
        menu_cursor = math.max(1, menu_cursor - 1)
        draw_menu()
    end
    local move_down = function()
        menu_cursor = math.min(#menu_items, menu_cursor + 1)
        draw_menu()
    end

    mp.add_forced_key_binding("UP", "menu-up", move_up)
    mp.add_forced_key_binding("DOWN", "menu-down", move_down)
    mp.add_forced_key_binding("k", "menu-k", move_up)
    mp.add_forced_key_binding("j", "menu-j", move_down)
    mp.add_forced_key_binding("WHEEL_UP", "menu-wheel-up", move_up)
    mp.add_forced_key_binding("WHEEL_DOWN", "menu-wheel-down", move_down)
    mp.add_forced_key_binding("ENTER", "menu-enter", menu_enter)
    mp.add_forced_key_binding("ESC", "menu-esc", close_menu)

    draw_menu()
end

-- ===========================================================================
-- Script Messages & Key Bindings
-- ===========================================================================

-- Sync favorite state on playback events
mp.register_event("file-loaded", check_favorite_status)
mp.register_event("end-file", function()
    mp.set_property_native("user-data/is-favorite", false)
end)

-- Register script messages for external / OSC triggers
mp.register_script_message("add_to_playlist", add_to_playlist)
mp.register_script_message("toggle_favorite", toggle_favorite)
mp.register_script_message("export_playlist", export_playlist)
mp.register_script_message("open_playlist_menu", open_playlist_menu)

-- Named script bindings (can be rebound in input.conf / mess.conf)
mp.add_key_binding(nil, "add_to_favorites", function() add_to_playlist("favorites") end)
mp.add_key_binding(nil, "toggle_favorite", toggle_favorite)
mp.add_key_binding(nil, "add_to_watchlater", function() add_to_playlist("watchlater") end)
mp.add_key_binding(nil, "open_menu", open_playlist_menu)
mp.add_key_binding(nil, "export_active_playlist", export_playlist)

-- Default keyboard shortcuts
-- Favorites Toggle: Ctrl+F and Cmd+F (meta+f)
mp.add_key_binding("ctrl+f", "quick_add_fav_ctrl", toggle_favorite)
mp.add_key_binding("meta+f", "quick_add_fav_cmd", toggle_favorite)

-- Watch Later: Ctrl+W and Alt+W
mp.add_key_binding("ctrl+w", "quick_add_watchlater_ctrl", function() add_to_playlist("watchlater") end)
mp.add_key_binding("alt+w", "quick_add_watchlater_alt", function() add_to_playlist("watchlater") end)

-- Menu: Ctrl+P and Cmd+P (meta+p)
mp.add_key_binding("ctrl+p", "open_menu_ctrl", open_playlist_menu)
mp.add_key_binding("meta+p", "open_menu_cmd", open_playlist_menu)

-- Export: Shift+E and Ctrl+E
mp.add_key_binding("E", "export_playlist_shift_e", export_playlist)
mp.add_key_binding("ctrl+e", "export_playlist_ctrl_e", export_playlist)
