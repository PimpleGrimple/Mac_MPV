local mp = require "mp"
local options = require "mp.options"

local opts = {
    auto_scan_sd = true,
}

local LABEL = "deint"
local DEFAULT_HWDEC = mp.get_property("hwdec", "no")

local active_vf = ""
local osd_visible = false
local osd_serial = 0
local file_epoch = 0
local scanning_path, scanning_epoch
local pending_scan, cached_result

local function show(text, duration, silent)
    if silent then return end

    duration = duration or 3
    osd_serial = osd_serial + 1
    local serial = osd_serial
    mp.osd_message(text, duration)
    osd_visible = text ~= "" and duration ~= 0

    if osd_visible then
        mp.add_timeout(duration, function()
            if osd_serial == serial then osd_visible = false end
        end)
    end
end

local function remove_ours()
    local filters = mp.get_property_native("vf") or {}
    local changed = false

    for i = #filters, 1, -1 do
        if filters[i].label == LABEL then
            table.remove(filters, i)
            changed = true
        end
    end

    if changed then mp.set_property_native("vf", filters) end
end

local function sync_filter()
    remove_ours()

    if active_vf == "" then
        mp.set_property("hwdec", DEFAULT_HWDEC)
        return
    end

    local hwdec = mp.get_property("hwdec", "no")
    if hwdec ~= "no" and not hwdec:match("-copy$") then
        mp.set_property("hwdec", "auto-copy")
    end

    mp.commandv("vf", "add", "@" .. LABEL .. ":" .. active_vf)
end

local function apply_cadence(vf, status)
    active_vf = vf
    mp.set_property("user-data/cadence", status)
    sync_filter()
end

options.read_options(opts, "deint")

local function normalize_order(raw)
    if raw == "bff" or raw == "bb" or raw == "bt" then return "bff" end
    if raw == "tff" or raw == "tt" or raw == "tb" then return "tff" end
    return nil
end

local function split_pipe(text)
    local fields = {}
    for field in (text .. "|"):gmatch("(.-)|") do
        fields[#fields + 1] = field
    end
    return fields
end

--------------------------------------------------------------------------
-- Disc sources (dvd://, bd://) have no seekable file path of their own, so
-- vsdetect -- which only accepts a regular file -- was being handed the
-- literal "dvd://" and failing every scan. Resolve a disc to the first VOB
-- (or largest M2TS) of its biggest title set before scanning.
--------------------------------------------------------------------------
local has_utils, utils = pcall(require, "mp.utils")

local function is_dir(path)
    if not has_utils or type(utils.file_info) ~= "function" then return false end
    local info = utils.file_info(path)
    return info ~= nil and info.is_dir == true
end

local function first_vob_of_largest_set(video_ts)
    if not has_utils or type(utils.readdir) ~= "function" then return nil end
    local entries = utils.readdir(video_ts)
    if not entries then return nil end

    -- Group VOB sizes per VTS set and keep the biggest set (the main title),
    -- then start at its first part. Per-VOB sizes alone are useless here:
    -- a title is split across VTS_xx_1..N at ~1 GiB boundaries.
    local totals = {}
    for _, name in ipairs(entries) do
        local set = name:match("^[Vv][Tt][Ss]_(%d%d)_%d+%.[Vv][Oo][Bb]$")
        if set then
            local info = utils.file_info(video_ts .. "/" .. name)
            if info and info.is_file then
                totals[set] = (totals[set] or 0) + (info.size or 0)
            end
        end
    end

    local best, best_size = nil, -1
    for set, size in pairs(totals) do
        if size > best_size then best, best_size = set, size end
    end
    if not best then return nil end

    local first = video_ts .. "/VTS_" .. best .. "_1.VOB"
    if utils.file_info(first) then return first end
    return nil
end

local function largest_m2ts(stream_dir)
    if not has_utils or type(utils.readdir) ~= "function" then return nil end
    local best, best_size = nil, -1
    for _, name in ipairs(utils.readdir(stream_dir) or {}) do
        if name:lower():match("%.m2ts$") then
            local info = utils.file_info(stream_dir .. "/" .. name)
            if info and info.is_file and (info.size or 0) > best_size then
                best, best_size = stream_dir .. "/" .. name, info.size
            end
        end
    end
    return best
end

local function resolve_scan_target(path)
    if not path or path == "" then return nil end
    local lower = path:lower()

    if lower:match("^dvd") or lower:match("^bd") then
        local is_bd = lower:match("^bd") ~= nil
        local dev = mp.get_property(is_bd and "bluray-device" or "dvd-device", "")
        if not dev or dev == "" then return nil end
        if dev:sub(1, 1) == "~" then
            dev = mp.command_native({ "expand-path", dev }) or dev
        end
        if is_bd then
            local stream = dev .. "/BDMV/STREAM"
            return is_dir(stream) and largest_m2ts(stream) or nil
        end
        local video_ts = is_dir(dev .. "/VIDEO_TS") and (dev .. "/VIDEO_TS") or dev
        return first_vob_of_largest_set(video_ts)
    end

    -- Opening a VIDEO_TS folder directly hits the same vsdetect limitation.
    if is_dir(path) then
        local video_ts = is_dir(path .. "/VIDEO_TS") and (path .. "/VIDEO_TS") or path
        return first_vob_of_largest_set(video_ts)
    end

    return path
end

local run_cadence_scan
run_cadence_scan = function(is_auto)
    local path = mp.get_property("path")
    if not path or path == "" then return end

    if cached_result and cached_result.path == path then
        if active_vf ~= cached_result.vf
            or mp.get_property("user-data/cadence") ~= cached_result.status then
            apply_cadence(cached_result.vf, cached_result.status)
        end
        show(cached_result.text, 8, is_auto)
        return
    end

    if scanning_path then
        if scanning_path ~= path or scanning_epoch ~= file_epoch then
            pending_scan = { path = path, auto = is_auto, epoch = file_epoch }
        end
        return
    end

    local exe = mp.command_native({ "expand-path", "~~/VapourSynth/bin/vsdetect" })
    if not exe or exe == "" then
        show("Scan failed: vsdetect path unavailable", 3, is_auto)
        return
    end

    local target = resolve_scan_target(path)
    if not target then
        show("Scan failed: cannot resolve disc path", 3, is_auto)
        return
    end

    local args = { exe, target }
    -- Manual scans should be able to inspect HD sources instead of trusting
    -- incomplete or missing stream field-order metadata.
    if not is_auto then args[#args + 1] = "--scan-hd" end

    show("Scanning cadence...", 10, is_auto)
    scanning_path, scanning_epoch = path, file_epoch
    local scan_epoch = file_epoch

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result)
        scanning_path, scanning_epoch = nil, nil

        if scan_epoch == file_epoch and mp.get_property("path") == path then
            if not success or not result or result.status ~= 0 then
                show("Scan failed", 3, is_auto)
            else
                local fields = split_pipe((result.stdout or ""):gsub("%s+$", ""))

                if #fields < 13 or fields[9] == "" then
                    show("Invalid vsdetect output", 3, is_auto)
                else
                    local status, raw_order = fields[9], fields[10]
                    local interlaced = tonumber(fields[11]) or 0
                    local progressive = tonumber(fields[12]) or 0
                    local repeat_ratio = tonumber(fields[13]) or 0
                    local order = normalize_order(raw_order) or "auto"

                    -- vsdetect signals metadata-only soft telecine with all-zero
                    -- ratios. It already accounts for this case explicitly.
                    if status == "telecine" and interlaced == 0
                        and progressive == 0 and repeat_ratio == 0 then
                        status = "soft_telecine"
                    end

                    local vf, setup = "", "Progressive (no filter)"

                    if status == "telecine" then
                        setup = "Telecine: fieldmatch + decimate"
                        vf = string.format(
                            "lavfi=[fieldmatch=order=%s:mode=pcn_ub:combmatch=full:cthresh=4,decimate]",
                            order)
                    elseif status == "interlaced" then
                        setup = "Interlaced: bwdif"
                        vf = string.format(
                            "lavfi=[bwdif=mode=1:parity=%s:deint=interlaced]",
                            order)
                    elseif status == "mix_telecine" then
                        setup = "Mixed telecine: fieldmatch + bwdif + decimate"
                        vf = string.format(
                            "lavfi=[fieldmatch=order=%s:mode=pcn_ub:combmatch=full:cthresh=4,bwdif=mode=0:parity=%s:deint=interlaced,decimate]",
                            order, order)
                    elseif status == "mix_interlaced" then
                        -- No reliable pulldown signature: deinterlace only frames
                        -- marked interlaced; do not decimate genuine unique frames.
                        setup = "Mixed interlace: bwdif only"
                        vf = string.format(
                            "lavfi=[bwdif=mode=0:parity=%s:deint=interlaced]",
                            order)
                    elseif status == "soft_telecine" then
                        setup = "Soft telecine (no filter)"
                    elseif status == "unknown" then
                        setup = "Unknown (no filter)"
                    end

                    local order_text = normalize_order(raw_order)
                    order_text = order_text and string.upper(order_text) or "AUTO / unknown"
                    local report = string.format(
                        "—— VSPROCESS DYNAMIC DEINT ——\n──────────────────────────────\n● Detected Cadence:  %s\n● Field Order:       %s\n● Applied Setup:     %s\n──────────────────────────────\n[Frame Structure]\n  ├─ Interlaced:  %.1f%%\n  └─ Progressive: %.1f%%\n[Cadence Signature]\n  └─ Repeat Field Ratio: %.1f%%\n──────────────────────────────",
                        status, order_text, setup,
                        interlaced * 100, progressive * 100, repeat_ratio * 100)

                    -- Keep the existing mpv.conf contract: both mixed subtypes
                    -- publish "mix", while the OSD retains the precise diagnosis.
                    local state_status = status:match("^mix") and "mix" or status
                    apply_cadence(vf, state_status)
                    cached_result = {
                        path = path, status = state_status, vf = vf, text = report,
                    }
                    show(report, 8, is_auto)
                end
            end
        end

        local pending = pending_scan
        pending_scan = nil
        if pending and pending.epoch == file_epoch
            and mp.get_property("path") == pending.path then
            run_cadence_scan(pending.auto)
        end
    end)
end

mp.register_event("file-loaded", function()
    file_epoch = file_epoch + 1
    apply_cadence("", "progressive")

    local height = mp.get_property_number("height", 0)
    if opts.auto_scan_sd and height > 0 and height <= 576 then
        run_cadence_scan(true)
    end
end)

mp.register_event("end-file", function()
    file_epoch = file_epoch + 1
    pending_scan = nil
    show("", 0)
    apply_cadence("", "progressive")
    cached_result = nil
end)

mp.add_key_binding("x", "probe_cadence", function()
    if osd_visible then
        show("", 0)
    else
        run_cadence_scan(false)
    end
end)
