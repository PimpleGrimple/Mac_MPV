-- limitation can't have shaders outside profiles that revaluate with and not get("user-data/battery", false) or else it won't be restored

local check_interval = 30

-- macOS
local check_cmd = {"pmset", "-g", "batt"}
local battery_match_pattern = "Battery Power"

-- Linux
-- local check_cmd = {"upower", "-i", "/org/freedesktop/UPower/devices/battery_BAT0"}
-- local battery_match_pattern = "state:%s+discharging"

-- Windows
-- local check_cmd = {"powershell", "-NoProfile", "-Command",
--                    "(Get-CimInstance -ClassName Win32_Battery).BatteryStatus"}
-- local battery_match_pattern = "^1"

local on_battery      = nil    -- last successfully reconciled state
local battery_applied = false  -- profile currently applied?
local enabled         = true
local initialized     = false  -- suppress OSD on first successful check
local checking        = false  -- overlap guard for the async subprocess

-- Default to "not on battery" so shader profiles apply normally before
-- the first detection completes.
mp.set_property_bool("user-data/battery", false)

local function reconcile(want_battery)
    if want_battery then
        if battery_applied then return true end
        -- Flip the flag BEFORE applying the profile so any auto-profile
        -- that depends on it (e.g. shader profiles) unapplies first. That
        -- way the battery profile's restore-point backup captures an
        -- already-clean shader list, not the current file's shaders.
        mp.set_property_bool("user-data/battery", true)
        if mp.command("apply-profile battery") then
            battery_applied = true
            return true
        end
        -- Apply failed: leave the flag as true so shaders stay off while
        -- we retry on the next tick (we're physically on battery either way).
    else
        if not battery_applied then return true end
        if mp.command("apply-profile battery restore") then
            battery_applied = false
            -- Restore may bring back stale shaders captured in an older
            -- backup. Clear them, then flip the flag so the shader profile
            -- re-applies with the correct set for the current resolution.
            mp.commandv("change-list", "glsl-shaders", "clr", "")
            mp.set_property_bool("user-data/battery", false)
            return true
        end
    end
    return false
end

local function check()
    if not enabled or checking then return end
    checking = true

    mp.command_native_async({
        name = "subprocess",
        args = check_cmd,
        capture_stdout = true,
    }, function(success, result)
        checking = false
        if not enabled or not success or not result
           or result.status ~= 0 or not result.stdout then
            return
        end

        local now = result.stdout:find(battery_match_pattern) ~= nil

        -- Always reconcile (retries a previous failure); only announce when
        -- the reconciled state actually changes.
        if not reconcile(now) then return end
        if now == on_battery then return end

        local is_startup = not initialized
        initialized = true
        on_battery  = now

        if not is_startup then
            mp.osd_message(now and "Battery profile" or "HQ profile")
        end
    end)
end

local function toggle()
    enabled = not enabled
    if enabled then
        on_battery = nil  -- force the next check to fire an OSD
        check()
    else
        reconcile(false)
        mp.osd_message("HQ profile")
    end
end

local function on_playback_restart()
    if battery_applied and enabled then
        mp.command("apply-profile battery")
    end
    check()
end

mp.register_event("playback-restart", on_playback_restart)

if check_interval > 0 then
    mp.add_periodic_timer(check_interval, check)
end

mp.add_key_binding("B", "toggle-battery", toggle)

check()