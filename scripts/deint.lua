-- auto_deint.lua
local mp = require("mp")

local auto_scan_sd = true 
local cached_path, cached_text = nil, nil
local osd_visible, is_scanning = false, false
local default_hwdec = mp.get_property("hwdec", "no")
local current_manual_idx = 1
local current_active_vf = ""

local function show(text, dur, silent)
    if silent then return end
    mp.osd_message(text, dur or 3)
    osd_visible = (dur ~= 0)
end

-- Broadcasts state to mpv.conf and applies lavfi
local function apply_cadence(vf_string, st)
    mp.set_property("user-data/cadence", st)
    current_active_vf = vf_string

    if mp.get_property("user-data/battery") == "yes" then return end

    if vf_string ~= "" then
        local current_hwdec = mp.get_property("hwdec", "no")
        if current_hwdec ~= "no" and not current_hwdec:match("-copy$") then
            mp.set_property("hwdec", "auto-copy")
        end
        mp.command_native({"vf", "set", vf_string})
    else
        mp.command_native({"vf", "clr", ""})
        if default_hwdec then mp.set_property("hwdec", default_hwdec) end
    end
end

-- Dynamic Battery Toggle Observer (Now fixes the hwdec battery drain)
mp.observe_property("user-data/battery", "string", function(_, val)
    if val == "yes" then
        mp.command_native({"vf", "clr", ""})
        if default_hwdec then mp.set_property("hwdec", default_hwdec) end
    elseif val == "no" and current_active_vf ~= "" then
        local current_hwdec = mp.get_property("hwdec", "no")
        if current_hwdec ~= "no" and not current_hwdec:match("-copy$") then
            mp.set_property("hwdec", "auto-copy")
        end
        mp.command_native({"vf", "set", current_active_vf})
    end
end)

local function run_cadence_scan(is_auto)
    local p = mp.get_property("path")
    if not p or p == "" then return end
    if p == cached_path and cached_text then 
        show(cached_text, 8, is_auto)
        return 
    end
    if is_scanning then return end
    
    show("Scanning cadence...", 10, is_auto)
    is_scanning = true
    
    local vsdetect_path = mp.command_native({"expand-path", "~~/VapourSynth/bin/vsdetect"})
    
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true, args = {vsdetect_path, p}
    }, function(success, res, err)
        is_scanning = false
        if mp.get_property("path") ~= p then return end
        if not success or res.status ~= 0 then 
            show("Scan failed", 3, is_auto)
            return 
        end
        
        local out = res.stdout and res.stdout:gsub("%s+$", "") or ""
        local f = {}
        for str in string.gmatch(out, "([^|]+)") do table.insert(f, str) end
        if #f < 13 then return end
        
        local st, dfo = f[9], f[10]
        local ir, pr, rr = tonumber(f[11]) or 0, tonumber(f[12]) or 0, tonumber(f[13]) or 0
        local field_order = (dfo == "bff") and "bff" or "tff"
        
        local vf_string, setup_name = "", "Progressive"
        
        if st == "telecine" and ir == 0 and pr == 0 and rr == 0 then st = "soft_telecine"
        elseif st:match("^mix") then st = "mix" end

        if st == "telecine" then
            setup_name, current_manual_idx = "Telecine", 2
            vf_string = string.format("lavfi=[fieldmatch=order=%s:mode=pcn_ub:combmatch=full:cthresh=4,decimate]", field_order)
        elseif st == "interlaced" then
            setup_name, current_manual_idx = "Interlace", 3
            vf_string = string.format("lavfi=[bwdif=mode=1:parity=%s:deint=interlaced]", field_order)
        elseif st == "mix" then 
            setup_name, current_manual_idx = "mix_N_mash", 4
            vf_string = string.format("lavfi=[fieldmatch=order=%s:mode=pcn_ub:combmatch=full:cthresh=4,bwdif=mode=0:parity=%s:deint=interlaced,decimate]", field_order, field_order)
        else
            current_manual_idx = 1
        end

        apply_cadence(vf_string, st)

        cached_path = p
        cached_text = string.format(
            "—— VSPROCESS DYNAMIC DEINT ——\n──────────────────────────────\n● Detected Cadence:  %s\n● Confirmed Order:   %s\n● Applied Setup:     %s\n──────────────────────────────\n[Frame Structure]\n  ├─ Interlaced:  %.1f%%\n  └─ Progressive: %.1f%%\n[Cadence Signature]\n  └─ Repeat Field Ratio: %.1f%%\n──────────────────────────────",
            st, string.upper(field_order) .. " (via idet)", setup_name, ir*100, pr*100, rr*100
        )
        mp.add_timeout(0.5, function() show(cached_text, 8, is_auto) end)
    end)
end

mp.register_event("file-loaded", function()
    apply_cadence("", "progressive") 
    local h = mp.get_property_number("height", 0)
    if auto_scan_sd and h > 0 and h <= 576 then run_cadence_scan(true) end
end)

mp.register_event("end-file", function() 
    show("", 0, false)
    apply_cadence("", "progressive")
    cached_path, cached_text = nil, nil
    current_manual_idx = 1
end)

local manual_modes = {
    { name = "Progressive", st = "progressive", vf = "" },
    { name = "Telecine", st = "telecine", vf = "lavfi=[fieldmatch=order=auto:mode=pcn_ub:combmatch=full:cthresh=4,decimate]" },
    { name = "Interlace", st = "interlaced", vf = "lavfi=[bwdif=mode=1:deint=interlaced]" },
    { name = "mix_N_mash", st = "mix", vf = "lavfi=[fieldmatch=order=auto:mode=pcn_ub:combmatch=full:cthresh=4,bwdif=mode=0:deint=interlaced,decimate]" }
}

mp.add_key_binding("X", "cycle_deint_mode", function()
    current_manual_idx = (current_manual_idx % #manual_modes) + 1
    apply_cadence(manual_modes[current_manual_idx].vf, manual_modes[current_manual_idx].st)
    mp.add_timeout(0.5, function() show("Manual Deint Mode: " .. manual_modes[current_manual_idx].name, 5, false) end)
end)

mp.add_key_binding("x", "probe_cadence", function()
    if osd_visible then show("", 0, false) return end
    run_cadence_scan(false)
end)
