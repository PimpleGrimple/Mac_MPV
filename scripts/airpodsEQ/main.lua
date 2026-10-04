local mp = require 'mp'
local utils = require 'mp.utils'

local TARGET_MAC_VOLUME = 50
local DEVICE_KEYWORDS = { "earwaxplug", "airpods" } -- matched against device description + name
local LABEL = "airpods-fir-eq"
local IR = (mp.get_script_directory() or "") .. "/airpods_ir.wav"
local enabled = false

local function airpods_connected()
    for _, d in ipairs(mp.get_property_native("audio-device-list") or {}) do
        local s = ((d.description or "") .. " " .. (d.name or "")):lower()
        for _, kw in ipairs(DEVICE_KEYWORDS) do
            if s:find(kw, 1, true) then return true end
        end
    end
    return false
end

local function set_filter(on)
    local filters = {}
    for _, f in ipairs(mp.get_property_native("af") or {}) do
        if f.label ~= LABEL then filters[#filters + 1] = f end
    end
    if on then
        filters[#filters + 1] = {
            name = "lavfi", label = LABEL,
            params = { graph = string.format("amovie='%s'[ir];[in][ir]afir[out]", IR) },
        }
    end
    return mp.set_property_native("af", filters)
end

local function check()
    local channels = mp.get_property_number("audio-params/channel-count")
    if not channels then return end

    local want = channels == 2 and airpods_connected()
    if want == enabled then return end

    if want then
        local f = io.open(IR, "r")
        if not f then
            print("[AirPods FIR] IR file missing: " .. IR .. " (run ./generate_ir.py)")
            return
        end
        f:close()
    end

    if set_filter(want) then
        enabled = want
        print("[AirPods FIR] " .. (want and "enabled" or "disabled"))
        if want then
            utils.subprocess_detached({
                args = { "osascript", "-e", "set volume output volume " .. TARGET_MAC_VOLUME },
            })
        end
    else
        print("[AirPods FIR] mpv rejected the filter graph")
    end
end

mp.observe_property("audio-device-list", "native", check)
mp.observe_property("audio-device", "string", check)
mp.observe_property("audio-params/channel-count", "number", check)
