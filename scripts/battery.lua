local on_battery = nil
local enabled = true

local function apply()
    if on_battery == nil then return end
    mp.command(on_battery and "apply-profile battery" or "apply-profile battery restore")
end

local function check()
    if not enabled then return end
    mp.command_native_async({name = "subprocess", args = {"pmset", "-g", "batt"}, capture_stdout = true}, function(success, result)
        if not success or not result or result.status ~= 0 then return end
        local now = result.stdout:find("Battery Power") ~= nil

        if now == on_battery then return end
        
        local is_startup = (on_battery == nil)
        on_battery = now
        apply()
        
        -- Do not show OSD when mpv first launches, only when state actually changes mid-session
        if not is_startup then
            mp.osd_message(now and "battery profile" or "HQ profile", 3)
        end
    end)
end

local function toggle()
    enabled = not enabled
    if not enabled then
        on_battery = nil
        mp.command("apply-profile battery restore")
        mp.osd_message("Auto-Battery: OFF (HQ Profile Active)", 3)
    else
        mp.osd_message("Auto-Battery: ON", 3)
        check()
    end
end

check()
mp.add_periodic_timer(20, check)
mp.register_event("file-loaded", check)
mp.register_event("playback-restart", apply)

mp.add_key_binding("B", "toggle-battery", toggle)
