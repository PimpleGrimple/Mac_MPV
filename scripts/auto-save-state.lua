local utils = require 'mp.utils'

local constant_saving = false -- Periodically save position during playback
local save_interval   = 30    -- Seconds between saves
local save_on_pause   = true  -- Save immediately when paused
local reset_at_end    = true  -- Reset resume position when media finishes
local percent_pos     = 90    -- Threshold percentage (0-100) to consider finished
local reset_type      = "strip" -- "strip" (keep tracks/volume) or "delete" (remove file)

-- Force required config for simplified watch-later parsing
mp.set_property_bool("write-filename-in-watch-later-config", true)
mp.set_property_bool("ignore-path-in-watch-later-config", false)

local function get_watch_later_dir()
    local dir = mp.get_property("current-watch-later-dir")
    return (dir and dir ~= "") and dir or nil
end

local function find_watch_later_file(file_path)
    local dir = get_watch_later_dir()
    if not dir or not file_path then return nil end

    local files = utils.readdir(dir, "files")
    if not files then return nil end

    local expected_full = "# " .. file_path
    for _, name in ipairs(files) do
        local candidate = utils.join_path(dir, name)
        local f = io.open(candidate, "r")
        if f then
            local first_line = f:read("*l")
            f:close()
            if first_line == expected_full then
                return candidate
            end
        end
    end

    return nil
end

local function strip_start_from_watch_later(file_path)
    local wl_file = find_watch_later_file(file_path)
    if not wl_file then return false end

    local f = io.open(wl_file, "r")
    if not f then return false end

    local lines = {}
    local has_other_options = false
    for line in f:lines() do
        if not line:match("^start%s*=") then
            lines[#lines + 1] = line
            if not line:match("^%s*#") and line:match("%S") then
                has_other_options = true
            end
        end
    end
    f:close()

    if has_other_options then
        local fw = io.open(wl_file, "w")
        if not fw then return false end
        fw:write(table.concat(lines, "\n"))
        if #lines > 0 then fw:write("\n") end
        fw:close()
        return true
    else
        os.remove(wl_file)
        return true
    end
end

local original_save_position = nil
local can_delete = true
local current_path = nil
local timer = nil

local function save()
    if not current_path or not mp.get_property_bool("save-position-on-quit") then return end
    mp.command("write-watch-later-config")
end

local function handle_pause(_, pause)
    if not constant_saving or not save_on_pause or not current_path then return end
    if pause then
        if timer then timer:stop() end
        save()
    elseif timer then
        timer:resume()
    end
end

local function update_timer()
    if constant_saving and save_interval > 0 and current_path then
        if not timer then
            timer = mp.add_periodic_timer(save_interval, save)
        else
            timer:resume()
        end
    elseif timer then
        timer:kill()
        timer = nil
    end
end

local function init()
    current_path = mp.get_property("path")
    can_delete = true

    if original_save_position == nil then
        original_save_position = mp.get_property_bool("save-position-on-quit")
    else
        mp.set_property_bool("save-position-on-quit", original_save_position)
    end

    update_timer()
end

local function perform_reset(file_path)
    if not file_path then return end

    if reset_type == "delete" then
        mp.command("delete-watch-later-config")
    else
        save()
        if not strip_start_from_watch_later(file_path) then
            mp.command("delete-watch-later-config")
        end
    end

    mp.set_property_bool("save-position-on-quit", false)
end

local function save_or_delete()
    if not current_path then return end

    local eof         = mp.get_property_bool("eof-reached")
    local percent     = mp.get_property_number("percent-pos")
    local finished    = reset_at_end and
                        (eof or (percent and percent >= percent_pos and percent > 0))

    if finished and can_delete then
        perform_reset(current_path)
    elseif constant_saving then
        save()
    end

    if timer then timer:stop() end
    current_path = nil
end

mp.register_script_message("skip-watchlater-delete", function() can_delete = false end)
mp.register_script_message("reset-watchlater", function()
    if current_path then
        perform_reset(current_path)
        mp.osd_message("Watch-later position reset")
    end
end)

mp.observe_property("pause", "bool", handle_pause)
mp.register_event("file-loaded", init)
mp.add_hook("on_unload", 50, save_or_delete)