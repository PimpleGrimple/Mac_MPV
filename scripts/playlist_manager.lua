local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local input_ok, input = pcall(require, "mp.input") -- built into mpv; select() needs a recent build

local playlists_dir = mp.command_native({"expand-path", "~~/cache/scripts/playlists"})

local function ensure_dir()
    if utils.file_info(playlists_dir) then return end
    if package.config:sub(1, 1) == "\\" then
        local p = playlists_dir:gsub("/", "\\")
        mp.command_native({name = "subprocess", playback_only = false,
            args = {"cmd", "/c", "if", "not", "exist", "\"" .. p .. "\"", "mkdir", "\"" .. p .. "\""}})
    else
        mp.command_native({name = "subprocess", playback_only = false,
            args = {"mkdir", "-p", playlists_dir}})
    end
end

local function absolute_path(p)
    if not p or p == "" then return nil end
    if p:match("^%a[%w+.-]*://") then return p end -- URL: leave it alone
    if p:sub(1, 1) == "/" then return p end
    if p:match("^%a:[/\\]") then return p end -- Windows drive
    return utils.join_path(mp.get_property("working-directory", "."), p)
end

local function get_playlist_path(name)
    return utils.join_path(playlists_dir, name:gsub("[/\\?%%*:|\"<>]", "_") .. ".m3u8")
end

local function is_in_playlist(file_path, target_path)
    local f = io.open(file_path, "r")
    if not f then return false end
    for line in f:lines() do
        if line:gsub("^%s+", ""):gsub("%s+$", "") == target_path then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

local function remove_from_playlist(name, target_path)
    local file_path = get_playlist_path(name)
    local f = io.open(file_path, "r")
    if not f then return false end
    local lines, found = {}, false
    for line in f:lines() do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == target_path then found = true
        elseif trimmed ~= "" then lines[#lines + 1] = line end
    end
    f:close()
    if not found then return false end
    local wf, err = io.open(file_path, "w")
    if not wf then
        msg.error("Failed to rewrite " .. file_path .. ": " .. tostring(err))
        return false
    end
    for _, l in ipairs(lines) do wf:write(l .. "\n") end
    wf:close()
    return true
end

local function check_favorite_status()
    local path = absolute_path(mp.get_property("path"))
    local is_fav = path and is_in_playlist(get_playlist_path("favorites"), path) or false
    mp.set_property_native("user-data/is-favorite", is_fav)
end

local function add_to_playlist(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        mp.osd_message("No playlist name given", 2)
        return
    end
    local path = absolute_path(mp.get_property("path"))
    if not path then
        mp.osd_message("No media currently playing!")
        return
    end
    local file_path = get_playlist_path(name)
    if is_in_playlist(file_path, path) then
        if name == "favorites" then mp.set_property_native("user-data/is-favorite", true) end
        mp.osd_message("Already in " .. name .. "!", 2)
        return
    end
    local f, err = io.open(file_path, "a")
    if not f then
        msg.error("Failed to write to " .. file_path .. ": " .. tostring(err))
        mp.osd_message("Failed to write to playlist: " .. tostring(err), 2)
        return
    end
    f:write(path .. "\n")
    f:close()
    if name == "favorites" then mp.set_property_native("user-data/is-favorite", true) end
    mp.osd_message("Added to " .. name, 2)
    msg.info("Added " .. path .. " to " .. name)
end

local function toggle_favorite()
    local path = absolute_path(mp.get_property("path"))
    if not path then
        mp.osd_message("No media currently playing!")
        return
    end
    if is_in_playlist(get_playlist_path("favorites"), path) then
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

local function export_playlist()
    local count = mp.get_property_number("playlist-count", 0)
    if count == 0 then
        mp.osd_message("Current playlist is empty!")
        return
    end
    local time_str = os.date("%Y%m%d_%H%M%S")
    local file_path = utils.join_path(playlists_dir, "exported_" .. time_str .. ".m3u8")
    local f, err = io.open(file_path, "w")
    if not f then
        mp.osd_message("Failed to export playlist!", 2)
        msg.error("Failed to open export file: " .. tostring(err))
        return
    end
    for i = 0, count - 1 do
        local path = mp.get_property("playlist/" .. i .. "/filename")
        if path then f:write(path .. "\n") end
    end
    f:close()
    mp.osd_message("Exported to exported_" .. time_str .. ".m3u8", 3)
    msg.info("Exported playlist to " .. file_path)
end

local function get_existing_playlists()
    local lists = {}
    for _, f in ipairs(utils.readdir(playlists_dir, "files") or {}) do
        local name = f:match("^(.+)%.m3u8$")
        if name then lists[#lists + 1] = name end
    end
    return lists
end

local NEW_ITEM = "[Create New Playlist]"
local current_menu = nil   -- token of the open selector, nil when closed
local pending_action = nil -- runs once the selector has fully closed

local function run_pending()
    local fn = pending_action
    pending_action = nil
    if fn then fn() end
end

local function prompt_new_playlist()
    input.get({
        prompt = "New playlist name: ",
        id = "playlist-manager",
        submit = function(text)
            input.terminate() -- get() stays open after submit unless closed explicitly
            if text and text ~= "" then add_to_playlist(text) end
        end,
    })
end

local function close_menu()
    if not current_menu then return end
    current_menu = nil
    input.terminate()
end

local function open_playlist_menu()
    if not (input_ok and input.select) then
        mp.osd_message("This mpv build has no mp.input.select(). Can't open menu.", 3)
        return
    end
    if current_menu then close_menu(); return end

    local items = {NEW_ITEM, "favorites", "watchlater"}
    local added = {favorites = true, watchlater = true}
    for _, name in ipairs(get_existing_playlists()) do
        if not added[name] then
            items[#items + 1] = name
            added[name] = true
        end
    end

    local menu = {}
    current_menu = menu
    input.select({
        prompt = "Add to playlist: ",
        items = items,
        submit = function(idx)
            local selected = items[tonumber(idx)]
            if not selected then return end
            if selected == NEW_ITEM then
                -- select() closes itself on Enter; open the text prompt only after it has closed.
                -- 'closed' normally triggers this; the timer is a fallback (run_pending is idempotent).
                pending_action = prompt_new_playlist
                mp.add_timeout(0.2, run_pending)
            elseif selected == "favorites" then
                toggle_favorite()
            else
                add_to_playlist(selected)
            end
        end,
        closed = function()
            if current_menu == menu then current_menu = nil end
            run_pending()
        end,
    })
end

ensure_dir()

mp.register_event("file-loaded", check_favorite_status)
mp.register_event("end-file", function()
    close_menu()
    mp.set_property_native("user-data/is-favorite", false)
end)

-- Script messages: external trigger API (OSC, other scripts, command line)
for _, m in ipairs({
    {"add_to_playlist", add_to_playlist},
    {"toggle_favorite", toggle_favorite},
    {"export_playlist", export_playlist},
    {"open_playlist_menu", open_playlist_menu},
}) do
    mp.register_script_message(m[1], m[2])
end

mp.add_key_binding("meta+f", "favorite", toggle_favorite)
mp.add_key_binding("meta+W", "watchlater", function() add_to_playlist("watchlater") end)
mp.add_key_binding("meta+p", "playlist_menu", open_playlist_menu)
mp.add_key_binding("ctrl+e", "export_playlist", export_playlist)