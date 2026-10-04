local profile_name   = "battery" -- Profile to apply on battery power
local check_interval = 30        -- Seconds between battery checks
local show_osd       = true      -- Show OSD messages on profile switches
local osd_duration   = 3         -- OSD message display duration in seconds
local toggle_key     = "B"       -- Key binding to toggle manually

local check_cmd = {"pmset", "-g", "batt"}
local battery_match_pattern = "Battery Power"

-- local check_cmd = {"powershell", "-NoProfile", "-Command", "(Get-CimInstance -ClassName Win32_Battery).BatteryStatus"}
-- local battery_match_pattern = "^1"

-- local check_cmd = {"upower", "-i", "/org/freedesktop/UPower/devices/battery_BAT0"}
-- local battery_match_pattern = "state:%s+discharging"

local last_power_state = nil
local enabled = true
local battery_profile_applied = false

local function apply_profile(enable_battery)
    if enable_battery then
        mp.command("apply-profile " .. profile_name)
        battery_profile_applied = true
    elseif battery_profile_applied then
        mp.command("apply-profile " .. profile_name .. " restore")
        battery_profile_applied = false
    end
end

local function check(silent)
    if not enabled then return end
    
    mp.command_native_async({
        name = "subprocess", 
        args = check_cmd, 
        capture_stdout = true, 
        playback_only = false
    }, function(success, result)
        if not success or not result or result.status ~= 0 then return end
        
        local now_on_battery = result.stdout:find(battery_match_pattern) ~= nil
        
        if now_on_battery == last_power_state then return end
        
        last_power_state = now_on_battery
        apply_profile(now_on_battery)
        
        if show_osd and not silent then
            mp.osd_message(now_on_battery and "Battery Saver" or "HQ Profile", osd_duration)
        end
    end)
end

local function toggle()
    enabled = not enabled
    if not enabled then
        if last_power_state then
            apply_profile(false)
            last_power_state = false
        end
        if show_osd then mp.osd_message("HQ Profile", osd_duration) end
    else
        last_power_state = nil
        if show_osd then mp.osd_message("Battery Saver", osd_duration) end
        check(true)
    end
end

mp.register_event("file-loaded", function()
    last_power_state = nil
    battery_profile_applied = false
    check(true)
end)

if check_interval > 0 then
    mp.add_periodic_timer(check_interval, function() check(false) end)
end

if toggle_key and toggle_key ~= "" then
    mp.add_key_binding(toggle_key, "toggle-battery", toggle)
end