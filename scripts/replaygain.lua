--[[ replaygain.lua — ReplayGain tag editor for mpv

At rest, playback uses only mpv's native gain (replaygain-preamp for tagged
files, replaygain-fallback for untagged) -- no filter in the chain. The
moment you adjust or scan, a lavfi volume filter carries just the unsaved
delta on top of native, and disappears again once saved/reset/matched.

NOTE: replaygain-fallback is NOT cached. It is owned by mpv (and by any
profiles that set it conditionally), read lazily, and observed so that a
profile change mid-file is picked up. sync_native() only ever touches the
per-file replaygain-preamp, never the global fallback.
]]

local mp, utils, msg = require 'mp', require 'mp.utils', require 'mp.msg'
local options = require 'mp.options'

-- CONFIG -------------------------------------------------------------
local opts = {
    rg_target_lufs = -18.0,                 -- foobar2000 EBU R128 target
    step_db = 0.10, 
    micro_step_db = 0.01,
    max_db = 20.0, 
    min_db = -20.0, 
    eps = 0.005,
    auto_bake_debounce = 10,
    filter_label = "replaygain",
    auto_bake = "false",                    -- automatically bake scanned values (accepts true/false/yes/no)
    auto_scan = "false",                    -- automatically scan untagged files
    stream_cache_mb = 50,                   -- total cache MB required to trigger stream auto-scan
    cache_results = "true",                 -- cache scan results across mpv sessions
    cache_dir = "~~/cache/scripts/replaygain", -- location for the cache file
}

options.read_options(opts, "replaygain")

local function parse_bool(v)
    if type(v) == "boolean" then return v end
    if not v then return false end
    local s = tostring(v):lower()
    return s == "true" or s == "yes" or s == "1"
end

local GAIN_KEYS = {
    "REPLAYGAIN_TRACK_GAIN", "replaygain_track_gain",
    "REPLAYGAIN_ALBUM_GAIN", "replaygain_album_gain",
    "REPLAYGAIN_GAIN", "replaygain_gain" }
local PEAK_KEY_MAP = {
    REPLAYGAIN_TRACK_GAIN = "REPLAYGAIN_TRACK_PEAK",
    REPLAYGAIN_ALBUM_GAIN = "REPLAYGAIN_ALBUM_PEAK",
    REPLAYGAIN_GAIN = "REPLAYGAIN_PEAK" }

-- STATE ----------------------------------------------------------------
local current_path, last_path, last_ff_index
local baseline_gain, file_gain, delta = 0.0, 0.0, 0.0
local mpv_native_gain, mpv_has_tags = 0.0, false
local disk_peak, pending_peak
local has_tags_current, has_cached_gain, baking, scanning = false, false, false, false
local autobake_timer, stream_scan_timer

-- CACHE ----------------------------------------------------------------
local function get_cache_file()
    local cache_dir = mp.command_native({"expand-path", opts.cache_dir})
    local is_windows = package.config:sub(1,1) == "\\"
    mp.command_native({
        name = "subprocess",
        args = is_windows and {"cmd", "/c", "mkdir", cache_dir} or {"mkdir", "-p", cache_dir},
        playback_only = false
    })
    return utils.join_path(cache_dir, "cache.json")
end

local function load_cache()
    if not parse_bool(opts.cache_results) then return {} end
    local f = io.open(get_cache_file(), "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local res, dict = pcall(utils.parse_json, content)
    return (res and dict) or {}
end

local function save_cache(dict)
    if not parse_bool(opts.cache_results) then return end
    local f = io.open(get_cache_file(), "w")
    if f then
        f:write(utils.format_json(dict))
        f:close()
    end
end

local function user_rg_fallback()
    return tonumber(mp.get_property("options/replaygain-fallback")) or 0.0
end

local function effective_gain() return baseline_gain + delta end
local function native_reference() return mpv_has_tags and mpv_native_gain or user_rg_fallback() end
local function clamp(v) return math.max(opts.min_db, math.min(opts.max_db, v)) end

local function sync_native()
    if mpv_has_tags then
        mp.set_property_native("file-local-options/replaygain-preamp", 0)
    end
end

local current_filter_d = 0.0
local function filter_present()
    for _, f in ipairs(mp.get_property_native("af") or {}) do
        if f.label == opts.filter_label then return true end
    end
    return false
end
local function remove_filter()
    if filter_present() then mp.commandv("af", "remove", "@" .. opts.filter_label) end
    current_filter_d = 0.0
end
local function set_filter_value(db)
    if filter_present() and math.abs(db - current_filter_d) <= opts.eps then return end
    remove_filter()
    mp.commandv("af", "add", string.format("@%s:lavfi=[volume=%.2fdB:precision=double:eval=once]", opts.filter_label, db))
    current_filter_d = db
end
local function sync_filter()
    local d = effective_gain() - native_reference()
    if math.abs(d) <= opts.eps then remove_filter() else set_filter_value(d) end
end

-- TAG READING ------------------------------------------------------------
local function parse_db(s)
    if not s then return nil end
    return tonumber(tostring(s):match("([+-]?%d+%.?%d*)"))
end

local function read_tags()
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "audio" and t.selected then
            local g = t["replaygain-track-gain"] or t["replaygain-album-gain"]
            local p = t["replaygain-track-peak"] or t["replaygain-album-peak"]
            if g then return tonumber(g) or 0.0, p and tostring(p) or nil, true end
        end
    end
    local meta = mp.get_property_native("metadata") or {}
    local g, p
    for _, k in ipairs(GAIN_KEYS) do g = parse_db(meta[k]); if g then break end end
    for _, k in ipairs({ "REPLAYGAIN_PEAK", "replaygain_peak",
        "REPLAYGAIN_TRACK_PEAK", "replaygain_track_peak",
        "REPLAYGAIN_ALBUM_PEAK", "replaygain_album_peak" }) do
        if meta[k] then p = tostring(meta[k]):match("([%d%.]+)") break end
    end
    if g then return g, p, true end
    return 0.0, nil, false
end

local function get_write_key()
    local meta = mp.get_property_native("metadata") or {}
    for _, k in ipairs(GAIN_KEYS) do if meta[k] then return k:upper() end end
    return "REPLAYGAIN_TRACK_GAIN"
end
local function get_peak_key(k) return PEAK_KEY_MAP[k] or "REPLAYGAIN_TRACK_PEAK" end

local function get_audio_relative_index()
    local n = 0
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "audio" then
            if t.selected then return n end
            n = n + 1
        end
    end
end

local function selected_audio_ff_index()
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "audio" and t.selected then return t["ff-index"] end
    end
end

local function peak_eq(a, b)
    if (a == nil) ~= (b == nil) then return false end
    if a == nil then return true end
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return math.abs(na - nb) <= 1e-6 end
    return tostring(a) == tostring(b)
end

-- OSD ----------------------------------------------------------------
local function fmt_gain(db) return string.format("%+.2f dB", db) end
local function fmt_peak(p)
    if not p then return "none" end
    local n = tonumber(p)
    if not n or n <= 0 then return tostring(p) end
    return string.format("%s (%.2f dBFS)", p, 20 * math.log(n) / math.log(10))
end

local function osd_state(dur, detailed)
    local eff, ddisk = effective_gain(), effective_gain() - file_gain
    local unsaved = math.abs(ddisk) > opts.eps
    local txt
    if detailed then
        txt = string.format("Gain: %s\nFile Tag: %s   %s\nPeak: %s",
            fmt_gain(eff), fmt_gain(file_gain),
            unsaved and ("(Δ " .. fmt_gain(ddisk) .. ")") or "(unchanged)",
            fmt_peak(pending_peak))
    else
        txt = string.format("Gain: %s", fmt_gain(eff))
        if unsaved then txt = txt .. string.format(" (Δ %s)", fmt_gain(ddisk)) end
    end
    mp.osd_message(txt, dur or 2.5)
end

local hardbake, scan_current

local function schedule_autobake()
    if not parse_bool(opts.auto_bake) then return end
    if autobake_timer then autobake_timer:kill() end
    autobake_timer = mp.add_timeout(opts.auto_bake_debounce, function() autobake_timer = nil hardbake() end)
end

local function adjust(step)
    if not current_path then return end
    delta = clamp(effective_gain() + step) - baseline_gain
    sync_filter()
    osd_state(2.5, false)
    schedule_autobake()
end
local function increase_gain()       adjust( opts.step_db)       end
local function decrease_gain()       adjust(-opts.step_db)       end
local function micro_increase_gain() adjust( opts.micro_step_db) end
local function micro_decrease_gain() adjust(-opts.micro_step_db) end

local function reset_gain()
    if not current_path then return end
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    delta = 0.0
    sync_filter()
    mp.osd_message("Reset to baseline: " .. fmt_gain(baseline_gain), 2)
end

local function show_info() osd_state(4, true) end

local function is_stream_or_pipe(path)
    if not path then return true end
    if path == "-" or path == "stdin" or path:match("^fd://") then return true end
    if path:match("^%a[%a%d+%-%.]*://") then return true end
    if mp.get_property_bool("demuxer-via-network") then return true end
    local stream_path = mp.get_property("stream-path")
    if stream_path and (stream_path:match("^%a[%a%d+%-%.]*://") or stream_path == "-" or stream_path:match("^fd://")) then return true end
    local open_filename = mp.get_property("stream-open-filename")
    if open_filename and (open_filename:match("^%a[%a%d+%-%.]*://") or open_filename == "-" or open_filename:match("^fd://")) then return true end
    return false
end

-- SCAN -----------------------------------------------------------------
local scan_handle, scan_path
scan_current = function(is_auto)
    if scanning then
        if scan_path == current_path then
            if not is_auto then mp.osd_message("Scan already in progress…", 2) end
            return
        else
            if scan_handle then mp.abort_async_command(scan_handle) end
            scan_handle, scanning = nil, false
        end
    end
    if not current_path then mp.osd_message("No file loaded", 2) return end

    local orig_path, t0 = current_path, mp.get_time()
    local is_stream = is_stream_or_pipe(orig_path)
    local scanned_ff_index = last_ff_index
    scanning = true
    scan_path = orig_path

    local function run_ffmpeg(target_file, tmp_dump)
        local args = { "ffmpeg", "-nostdin", "-hide_banner", "-vn", "-sn", "-dn", "-i", target_file }
        
        if is_stream then
            table.insert(args, "-map"); table.insert(args, "0:a:0")
        elseif scanned_ff_index then
            table.insert(args, "-map"); table.insert(args, "0:" .. tostring(scanned_ff_index))
        end
        
        for _, a in ipairs({ "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-" }) do
            table.insert(args, a)
        end

        scan_handle = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
            capture_stdout = false, capture_stderr = true },
        function(success, result, err)
            scanning, scan_handle = false, nil
            if tmp_dump then os.remove(tmp_dump) end

            local stderr = result and result.stderr
            if not (success and result and result.status == 0) then
                if current_path == orig_path then
                    mp.osd_message("Scan FAILED — see console", 4)
                    msg.error("replaygain: scan failed: " .. tostring(err) .. (stderr and ("\n" .. stderr:sub(-400)) or ""))
                end
                return
            end
            
            local lufs = stderr and tonumber(stderr:match("I:%s*([%-]?%d+%.?%d*)%s*LUFS"))
            if not lufs then
                if current_path == orig_path then
                    mp.osd_message("Scan: could not parse LUFS", 4)
                    msg.error("replaygain: no LUFS in ffmpeg output" .. (stderr and ("\n" .. stderr:sub(-400)) or ""))
                end
                return
            end
            
            local dbfs = stderr and tonumber(stderr:match("Peak:%s*([%-]?%d+%.?%d*)%s*dBFS"))
            local computed = opts.rg_target_lufs - lufs
            local scanned_peak = dbfs and string.format("%.6f", 10 ^ (dbfs / 20)) or nil

            -- ALWAYS cache the result, even if the user has already switched to the next video
            if parse_bool(opts.cache_results) then
                local cache = load_cache()
                cache[orig_path] = { gain = computed, peak = scanned_peak }
                save_cache(cache)
            end

            -- If the user switched files while scanning, do not apply the volume filter to the NEW video
            if current_path ~= orig_path then
                msg.info(string.format("replaygain: scan finished and cached in background for previous file: %s", orig_path))
                return
            end

            -- Only apply live changes if they are still watching the same video
            baseline_gain = computed
            pending_peak  = scanned_peak
            delta = clamp(effective_gain()) - baseline_gain
            sync_filter()
            has_cached_gain = true

            local scan_delta = computed - file_gain
            local gain_changed = math.abs(scan_delta) > opts.eps
            local peak_changed = not peak_eq(pending_peak, disk_peak)
            local changed = gain_changed or peak_changed
            local delta_str = string.format(" (Δ %s)", fmt_gain(scan_delta))

            msg.info(string.format("replaygain: scan done in %.1fs — I=%.1f LUFS → %s%s",
                mp.get_time() - t0, lufs, fmt_gain(computed), gain_changed and ("  (Δ " .. fmt_gain(scan_delta) .. ")") or "  (unchanged)"))
            mp.osd_message(string.format("Scan Complete: %s%s", fmt_gain(computed), delta_str), 4)

            if parse_bool(opts.auto_bake) and changed and not is_stream then schedule_autobake() end
        end)
    end

    if is_stream then
        local pid = mp.get_property("pid") or "0"
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
        local tmp_dump = utils.join_path(temp_dir, string.format("mpv_cache_dump_%s.mkv", pid))
        
        if not is_auto then mp.osd_message("Dumping cache in background...", 2) end
        
        -- Asynchronous non-blocking cache dump for streams
        mp.command_native_async({"dump-cache", "0", "999999", tmp_dump}, function(success)
            if not success then
                scanning = false
                mp.osd_message("Cache dump failed", 3)
                return
            end
            run_ffmpeg(tmp_dump, tmp_dump)
        end)
    else
        if not is_auto then mp.osd_message("Scanning loudness…", 999) end
        -- Asynchronous non-blocking scan for local files
        run_ffmpeg(orig_path, nil)
    end
end

-- AUTO SCAN EVALUATOR --------------------------------------------------
local function is_auto_scan_enabled()
    if parse_bool(opts.auto_scan) then return true end
    local so = mp.get_property_native("options/script-opts")
    if type(so) == "table" then
        local check_keys = {"replaygain-auto_scan", "replaygain-AUTO_SCAN", "auto_scan", "AUTO_SCAN"}
        for _, k in ipairs(check_keys) do
            local v = so[k]
            if v ~= nil then
                v = tostring(v):lower()
                return (v == "yes" or v == "true" or v == "1")
            end
        end
    end
    return false
end

local function evaluate_auto_scan()
    if not current_path then return end
    if has_tags_current or has_cached_gain or scanning then return end
    
    if is_auto_scan_enabled() then
        if is_stream_or_pipe(current_path) then
            if not stream_scan_timer then
                stream_scan_timer = mp.add_periodic_timer(3, function()
                    if scanning then return end
                    local fw_bytes = mp.get_property_number("demuxer-cache-state/fw-bytes", 0)
                    local back_bytes = mp.get_property_number("demuxer-cache-state/back-bytes", 0)
                    local cache_idle = mp.get_property_bool("demuxer-cache-idle", false)
                    local cache_sec = mp.get_property_number("demuxer-cache-duration", 0)
                    
                    if (fw_bytes + back_bytes) >= (opts.stream_cache_mb * 1024 * 1024) 
                       or cache_sec >= 30 
                       or cache_idle then
                        if stream_scan_timer then 
                            stream_scan_timer:kill()
                            stream_scan_timer = nil 
                        end
                        scan_current(true)
                    end
                end)
            end
        elseif not scanning then
            scan_current(true)
        end
    else
        if stream_scan_timer then
            stream_scan_timer:kill()
            stream_scan_timer = nil
        end
    end
end

-- Load options dynamically when profiles apply
options.read_options(opts, "replaygain", function()
    evaluate_auto_scan()
end)

-- LOAD -----------------------------------------------------------------
local function load_replaygain(force)
    local path = mp.get_property("path")
    if not path then return end

    local abs_path = mp.command_native({"expand-path", path}) or path
    local ff_index = selected_audio_ff_index()

    if not force and abs_path == last_path and ff_index == last_ff_index then return end
    last_path, last_ff_index, current_path = abs_path, ff_index, abs_path
    
    delta = 0.0
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    if stream_scan_timer then stream_scan_timer:kill() stream_scan_timer = nil end
    remove_filter()

    local gain, peak, has_tags = read_tags()
    local cached_gain, cached_peak = nil, nil
    has_cached_gain = false

    if not has_tags and parse_bool(opts.cache_results) then
        local cache = load_cache()
        if cache[current_path] then
            cached_gain = cache[current_path].gain
            cached_peak = cache[current_path].peak
            has_cached_gain = true
        end
    end

    has_tags_current = has_tags
    mpv_has_tags = has_tags
    local fb = user_rg_fallback()
    
    if has_cached_gain then
        baseline_gain = cached_gain
        file_gain = 0.0
        disk_peak = nil
        pending_peak = cached_peak
    else
        baseline_gain = has_tags and gain or fb
        file_gain     = has_tags and gain or 0.0
        disk_peak, pending_peak = peak, peak
    end

    mpv_native_gain = file_gain
    sync_native()
    sync_filter()

    msg.info(string.format("replaygain: %s peak=%s has_tags=%s fallback=%.2f path=%s",
        fmt_gain(baseline_gain), fmt_peak(pending_peak), tostring(has_tags), fb, current_path))
end

-- HARDBAKE (lossless -c copy remux) --------------------------------------
hardbake = function()
    if baking then mp.osd_message("Hardbake already in progress…", 2) return end
    if not current_path then mp.osd_message("No file loaded", 2) return end
    if is_stream_or_pipe(current_path) then mp.osd_message("Cannot bake: not a local file", 3) return end

    local path, eff = current_path, effective_gain()
    local write_key = get_write_key()
    local peak_key  = get_peak_key(write_key)

    local gain_changed = math.abs(eff - file_gain) > opts.eps
    local peak_changed = not peak_eq(pending_peak, disk_peak)
    if not gain_changed and not peak_changed then mp.osd_message("No changes to save", 2) return end

    local dir, filename = utils.split_path(path)
    local base, ext = filename:match("^(.*)%.([^%.]+)$")
    local tmp = utils.join_path(dir, "." .. (base or filename) .. ".rgtmp" .. (ext and ("." .. ext) or ""))

    local args = { "ffmpeg", "-nostdin", "-y", "-hide_banner", "-loglevel", "warning", "-i", path, "-map", "0", "-c", "copy" }
    local el = ext and ext:lower() or ""
    if el == "mp4" or el == "m4a" or el == "mov" or el == "m4v" then
        table.insert(args, "-movflags"); table.insert(args, "use_metadata_tags")
    end

    local function add_tags(prefix)
        table.insert(args, prefix); table.insert(args, string.format("%s=%+.2f dB", write_key, eff))
        if pending_peak then
            table.insert(args, prefix); table.insert(args, string.format("%s=%s", peak_key, pending_peak))
        end
    end
    add_tags("-metadata")
    if el == "mkv" or el == "webm" or el == "mka" then
        local n = get_audio_relative_index()
        if n then add_tags("-metadata:s:a:" .. tostring(n)) end
    end
    table.insert(args, tmp)

    local saved_delta = eff - file_gain
    baking = true
    mp.osd_message(string.format("Writing %s = %s…", write_key, fmt_gain(eff)), 999)
    msg.info("replaygain: " .. table.concat(args, " "))

    mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
        capture_stdout = false, capture_stderr = true },
    function(success, result, err)
        baking = false
        local still_current = (current_path == path)

        if success and result and result.status == 0 then
            local ok, rename_err = os.rename(tmp, path)
            if not ok then
                local mv = mp.command_native({ name = "subprocess", args = { "mv", "-f", tmp, path },
                    playback_only = false, capture_stdout = false, capture_stderr = true })
                ok = mv and mv.status == 0
                if not ok then
                    if still_current then mp.osd_message("File replace failed — tmp: " .. tmp, 6) end
                    msg.error("replaygain: mv failed: " .. tostring(mv and mv.stderr))
                    os.remove(tmp)
                    return
                end
            end
            if still_current then
                baseline_gain, file_gain, disk_peak, delta = eff, eff, pending_peak, 0.0
                has_tags_current = true
                sync_native()
                sync_filter()
                mp.osd_message(string.format("Saved ✓  %s = %s  (Δ was %s)",
                    write_key, fmt_gain(eff), fmt_gain(saved_delta)), 3)
            end
            msg.info(string.format("replaygain: wrote %s=%s to %s", write_key, fmt_gain(eff), path))
        else
            os.remove(tmp)
            local tail = result and result.stderr and result.stderr:sub(-400) or ""
            if still_current then mp.osd_message("Hardbake FAILED — see console\n" .. tail, 5) end
            msg.error("replaygain: ffmpeg failed: " .. tostring(err) .. "\n" .. tail)
        end
    end)
end

-- EVENTS & BINDINGS --------------------------------------------------

mp.register_event("playback-restart", function()
    evaluate_auto_scan()
end)

mp.observe_property("options/script-opts", "native", function()
    evaluate_auto_scan()
end)

mp.observe_property("track-list", "native", function() load_replaygain(false) end)
mp.register_event("file-loaded", function() load_replaygain(true) end)

mp.register_event("end-file", function()
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    if stream_scan_timer then stream_scan_timer:kill() stream_scan_timer = nil end
end)

mp.observe_property("options/replaygain-fallback", "native", function(_, v)
    if not current_path then return end
    if mpv_has_tags then return end
    baseline_gain = tonumber(v) or 0.0
    delta = clamp(effective_gain()) - baseline_gain
    sync_filter()
end)

mp.add_key_binding("meta+up",         "replaygain-increase",       increase_gain,       {repeatable=true})
mp.add_key_binding("meta+down",       "replaygain-decrease",       decrease_gain,       {repeatable=true})
mp.add_key_binding("Shift+meta+up",   "replaygain-micro-increase", micro_increase_gain, {repeatable=true})
mp.add_key_binding("Shift+meta+down", "replaygain-micro-decrease", micro_decrease_gain, {repeatable=true})
mp.add_key_binding("meta+b", "replaygain-hardbake",         hardbake)
mp.add_key_binding("meta+r", "replaygain-reset",            reset_gain)
mp.add_key_binding("meta+i", "replaygain-info",             show_info)
mp.add_key_binding("meta+s", "replaygain-scan",             scan_current)
