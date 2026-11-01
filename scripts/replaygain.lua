local mp, utils, msg = require 'mp', require 'mp.utils', require 'mp.msg'
local options = require 'mp.options'

-- CONFIG
local opts = {
    rg_target_lufs = -14.0,
    step_db = 0.10,
    eps = 0.005,
    peak_protect = "true",
    auto_bake_debounce = 10,
    filter_label = "replaygain",
    auto_bake = "false",
    auto_scan = "true",
    stream_cache_mb = 50,
    stream_cache_sec = 30,
    cache_results = "true",
    cache_dir = "~~/cache/scripts/replaygain",
}
options.read_options(opts, "replaygain")

-- PER-DEVICE SLIDER STEP (macOS system volume, 1-16 like the menu bar slider)
-- match = case-insensitive substring of the device's description OR name/id
-- (see `mpv --audio-device=help`). Applied once each time the device appears.
local slider_devices = {
    { match = "earwaxplug", step = 5 },
 -- { match = "coreaudio/AppleUSBAudioEngine", step = 10 },
}

local function parse_bool(v)
    if type(v) == "boolean" then return v end
    if not v then return false end
    local s = tostring(v):lower()
    return s == "true" or s == "yes" or s == "1"
end

-- PATH HELPERS
local function is_url(p) return p ~= nil and p:match("^%a[%w+.-]*://") ~= nil end
local function is_pipe(p) return p == "-" or p == "stdin" or (p ~= nil and p:match("^fd://") ~= nil) end
local function stream_like(p) return is_pipe(p) or is_url(p) end
local function should_cache(p) return p ~= nil and not is_pipe(p) end

-- CACHE
local CACHE_DIR  = mp.command_native({"expand-path", opts.cache_dir})
local CACHE_FILE = utils.join_path(CACHE_DIR, "cache.json")
local cache_dir_ready = false

local function ensure_cache_dir()
    if cache_dir_ready then return end
    if not utils.file_info(CACHE_DIR) then
        if package.config:sub(1,1) == "\\" then
            local p = CACHE_DIR:gsub("/", "\\")
            mp.command_native({name = "subprocess", playback_only = false,
                args = {"cmd", "/c", "if", "not", "exist", "\"" .. p .. "\"", "mkdir", "\"" .. p .. "\""}})
        else
            mp.command_native({name = "subprocess", playback_only = false, args = {"mkdir", "-p", CACHE_DIR}})
        end
    end
    cache_dir_ready = true
end

local function load_cache()
    if not parse_bool(opts.cache_results) then return {} end
    local f = io.open(CACHE_FILE, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local res, dict = pcall(utils.parse_json, content)
    return (res and dict) or {}
end

local function save_cache(dict)
    if not parse_bool(opts.cache_results) then return end
    ensure_cache_dir()
    local f = io.open(CACHE_FILE, "w")
    if f then f:write(utils.format_json(dict)) f:close() end
end

local function user_rg_fallback()
    return tonumber(mp.get_property("options/replaygain-fallback")) or 0.0
end

local function canonical_path(p)
    if not p or p == "" then return nil end
    if stream_like(p) then return p end
    if p:sub(1,1) == "/" or p:sub(1,1) == "\\" then return p end
    if p:match("^%a:") then return p end
    return utils.join_path(mp.get_property("working-directory", "."), p)
end

-- STATE
local current_path, current_ff_index
local baseline_gain, file_gain, delta = 0.0, 0.0, 0.0
local mpv_native_gain, mpv_has_tags = 0.0, false
local mpv_loaded_peak   -- peak mpv saw at file open; frozen until reload
local disk_peak, pending_peak
local has_tags_current, has_cached_gain, baking, scanning = false, false, false, false
local taking_over = false   -- true once the script drives the audio gain
local autobake_timer, stream_scan_timer
local auto_scan_done = false  -- true once ANY scan (auto or manual) has started for the current load

-- PEAK PROTECTION
local function peak_ceiling(peak)
    if not parse_bool(opts.peak_protect) then return math.huge end
    local n = tonumber(peak)
    if not n or n <= 0 then return math.huge end
    return math.floor(-20 * math.log(n) / math.log(10) * 100) / 100
end
local function clamp(v) return math.min(v, peak_ceiling(pending_peak)) end

local GAIN_KEYS = {
    "REPLAYGAIN_TRACK_GAIN", "replaygain_track_gain",
    "REPLAYGAIN_ALBUM_GAIN", "replaygain_album_gain",
    "REPLAYGAIN_GAIN", "replaygain_gain" }
local PEAK_KEY_MAP = {
    REPLAYGAIN_TRACK_GAIN = "REPLAYGAIN_TRACK_PEAK",
    REPLAYGAIN_ALBUM_GAIN = "REPLAYGAIN_ALBUM_PEAK",
    REPLAYGAIN_GAIN = "REPLAYGAIN_PEAK" }
local READ_PEAK_KEYS = {
    "REPLAYGAIN_PEAK", "replaygain_peak",
    "REPLAYGAIN_TRACK_PEAK", "replaygain_track_peak",
    "REPLAYGAIN_ALBUM_PEAK", "replaygain_album_peak" }

local function effective_gain() return clamp(baseline_gain + delta) end

-- mpv already lowers tagged files to fit their tagged peak (unless replaygain-clip=yes),
-- so the filter starts from that capped value. mpv_loaded_peak is frozen at file
-- open so this stays correct even after hardbake rewrites the tags on disk.
local function native_reference()
    if not mpv_has_tags then return user_rg_fallback() end
    if not parse_bool(opts.peak_protect) or mp.get_property_bool("options/replaygain-clip") then
        return mpv_native_gain
    end
    return math.min(mpv_native_gain, peak_ceiling(mpv_loaded_peak))
end

local function sync_native()
    if mpv_has_tags then mp.set_property_native("file-local-options/replaygain-preamp", 0) end
end

-- FILTER
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
    if not taking_over then remove_filter() return end
    local d = effective_gain() - native_reference()
    if math.abs(d) <= opts.eps then remove_filter() else set_filter_value(d) end
end

-- TAG READING
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
    for _, k in ipairs(READ_PEAK_KEYS) do
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

-- OSD
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
        txt = "Gain: " .. fmt_gain(eff)
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
    taking_over = true
    sync_filter()
    osd_state(2.5, false)
    schedule_autobake()
end
local function increase_gain() adjust( opts.step_db) end
local function decrease_gain() adjust(-opts.step_db) end

local function reset_gain()
    if not current_path then return end
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    delta = 0.0
    taking_over = true
    sync_filter()
    mp.osd_message("Reset to baseline: " .. fmt_gain(baseline_gain), 2)
end

local function show_info()
    if not current_path then return end
    osd_state(4, true)
end

local function has_audio_track()
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "audio" then return true end
    end
    return false
end

local function is_stream_or_pipe(path)
    if not path then return true end
    if stream_like(path) then return true end
    if mp.get_property_bool("demuxer-via-network") then return true end
    return stream_like(mp.get_property("stream-path"))
        or stream_like(mp.get_property("stream-open-filename"))
end

-- SCAN
local scan_handle, scan_path, scan_id = nil, nil, 0
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
    if not has_audio_track() then
        if not is_auto then mp.osd_message("No audio track to scan", 2) end
        return
    end

    -- Any scan (manual or auto) counts as "scanned": stop every auto trigger from firing again.
    auto_scan_done = true
    if stream_scan_timer then stream_scan_timer:kill() stream_scan_timer = nil end
    scan_id = scan_id + 1
    local my_id = scan_id

    local orig_path, t0 = current_path, mp.get_time()
    local is_stream = is_stream_or_pipe(orig_path)
    local scanned_ff_index = current_ff_index
    scanning = true
    scan_path = orig_path

    local function run_ffmpeg(target_file, tmp_dump)
        local args = { "ffmpeg", "-nostdin", "-hide_banner", "-vn", "-sn", "-dn", "-i", target_file }
        if is_stream then
            table.insert(args, "-map"); table.insert(args, "0:a:0")
        elseif scanned_ff_index then
            table.insert(args, "-map"); table.insert(args, "0:" .. scanned_ff_index)
        end
        for _, a in ipairs({ "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-" }) do
            table.insert(args, a)
        end

        scan_handle = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
            capture_stdout = false, capture_stderr = true },
        function(success, result, err)
            if tmp_dump then os.remove(tmp_dump) end
            if my_id ~= scan_id then return end  -- aborted/superseded: don't touch newer scan's state
            scanning, scan_handle = false, nil

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

            if parse_bool(opts.cache_results) and should_cache(orig_path) then
                local cache = load_cache()
                cache[orig_path] = { gain = computed, peak = scanned_peak }
                save_cache(cache)
            end

            if current_path ~= orig_path then
                msg.info("replaygain: scan finished and cached in background for previous file: " .. orig_path)
                return
            end

            baseline_gain, pending_peak, has_cached_gain = computed, scanned_peak, true
            taking_over = true
            sync_filter()

            local applied = effective_gain()
            local limited = applied < computed + delta - opts.eps
            local scan_delta = applied - file_gain
            local gain_changed = math.abs(scan_delta) > opts.eps
            local peak_changed = not peak_eq(pending_peak, disk_peak)
            local changed = gain_changed or peak_changed
            local delta_str = string.format(" (Δ %s)", fmt_gain(scan_delta))

            msg.info(string.format("replaygain: scan done in %.1fs — I=%.1f LUFS → %s%s",
                mp.get_time() - t0, lufs, fmt_gain(applied),
                gain_changed and ("  (Δ " .. fmt_gain(scan_delta) .. ")") or "  (unchanged)")
                .. (limited and "  [peak-limited]" or ""))
            mp.osd_message(string.format("Scan Complete: %s%s%s", fmt_gain(applied), delta_str,
                limited and " [peak-limited]" or ""), 4)

            if parse_bool(opts.auto_bake) and changed and not is_stream then schedule_autobake() end
        end)
    end

    if is_stream then
        local pid = mp.get_property("pid") or "0"
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
        local tmp_dump = utils.join_path(temp_dir, string.format("mpv_cache_dump_%s_%d.mkv", pid, my_id))

        if not is_auto then mp.osd_message("Dumping cache in background...", 2) end
        mp.command_native_async({"dump-cache", "0", "999999", tmp_dump}, function(success)
            if my_id ~= scan_id then os.remove(tmp_dump) return end
            if not success then
                scanning = false
                mp.osd_message("Cache dump failed", 3)
                return
            end
            run_ffmpeg(tmp_dump, tmp_dump)
        end)
    else
        if not is_auto then mp.osd_message("Scanning loudness…", 999) end
        run_ffmpeg(orig_path, nil)
    end
end

-- AUTO SCAN EVALUATOR
local function evaluate_auto_scan()
    if not current_path then return end
    if has_tags_current or has_cached_gain or scanning or auto_scan_done then return end
    if not has_audio_track() then
        if stream_scan_timer then
            stream_scan_timer:kill()
            stream_scan_timer = nil
        end
        return
    end

    if not parse_bool(opts.auto_scan) then
        if stream_scan_timer then
            stream_scan_timer:kill()
            stream_scan_timer = nil
        end
        return
    end

    if is_stream_or_pipe(current_path) then
        if not stream_scan_timer then
            stream_scan_timer = mp.add_periodic_timer(3, function()
                if auto_scan_done or has_cached_gain or has_tags_current then
                    stream_scan_timer:kill()
                    stream_scan_timer = nil
                    return
                end
                if scanning then return end
                local fw_bytes   = mp.get_property_number("demuxer-cache-state/fw-bytes", 0)
                local back_bytes = math.max(0, mp.get_property_number("demuxer-cache-state/total-bytes", 0) - fw_bytes)
                local cs         = mp.get_property_native("demuxer-cache-state") or {}
                local at_eof     = cs["eof-cached"] or cs.eof or false
                local cache_sec  = mp.get_property_number("demuxer-cache-duration", 0)
                if (fw_bytes + back_bytes) >= (opts.stream_cache_mb * 1024 * 1024)
                   or cache_sec >= opts.stream_cache_sec or at_eof then
                    stream_scan_timer:kill()
                    stream_scan_timer = nil
                    scan_current(true)
                end
            end)
        end
    elseif not scanning then
        scan_current(true)
    end
end

-- DEVICE SLIDER
local slider_applied = {}  -- [rule index] = true while that device stays connected

local function apply_slider(i, rule)
    local step = math.floor(tonumber(rule.step) or 0)
    if step < 1 or step > 16 then return end
    local pct = math.floor(step * 100 / 16 + 0.5)
    slider_applied[i] = true
    mp.command_native_async({ name = "subprocess", playback_only = false,
        args = { "osascript", "-e", string.format("set volume output volume %d", pct) } },
        function(ok, res)
            if ok and res and res.status == 0 then
                msg.info(string.format("slider [%s]: step %d -> %d%%", rule.match, step, pct))
            else
                slider_applied[i] = false
                msg.error("slider [" .. rule.match .. "]: osascript failed")
            end
        end)
end

local function maybe_apply_slider()
    local haystacks = {}
    for _, d in ipairs(mp.get_property_native("audio-device-list") or {}) do
        haystacks[#haystacks + 1] = ((d.description or "") .. " " .. (d.name or "")):lower()
    end
    local applied_one = false
    for i, rule in ipairs(slider_devices) do
        local needle, present = tostring(rule.match or ""):lower(), false
        if needle ~= "" then
            for _, h in ipairs(haystacks) do
                if h:find(needle, 1, true) then present = true break end
            end
        end
        if not present then
            slider_applied[i] = false
        elseif not slider_applied[i] and not applied_one then
            apply_slider(i, rule)
            applied_one = true
        end
    end
end

options.read_options(opts, "replaygain", function()
    evaluate_auto_scan()
    maybe_apply_slider()
end)

-- LOAD
local function load_replaygain(abs_path, ff_index)
    current_path, current_ff_index = abs_path, ff_index

    delta = 0.0
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    if stream_scan_timer then stream_scan_timer:kill() stream_scan_timer = nil end
    auto_scan_done = false
    remove_filter()

    local gain, peak, has_tags = read_tags()
    local cached_gain, cached_peak
    has_cached_gain = false

    if not has_tags and parse_bool(opts.cache_results) and should_cache(current_path) then
        local c = load_cache()[current_path]
        if c then
            cached_gain, cached_peak = c.gain, c.peak
            has_cached_gain = true
        end
    end

    has_tags_current = has_tags
    mpv_has_tags = has_tags
    mpv_loaded_peak = has_tags and peak or nil
    local fb = user_rg_fallback()

    if has_cached_gain then
        baseline_gain, file_gain, disk_peak, pending_peak = cached_gain, 0.0, nil, cached_peak
    elseif has_tags then
        baseline_gain, file_gain, disk_peak, pending_peak = gain, gain, peak, peak
    else
        -- Untagged, no cache: treat the file as 0 dB on disk and stay passive.
        -- mpv still applies replaygain-fallback natively; taking over (via
        -- meta+up/down, reset, or a scan) will cancel it back out.
        baseline_gain, file_gain, disk_peak, pending_peak = 0.0, 0.0, peak, peak
    end

    taking_over = has_tags or has_cached_gain

    mpv_native_gain = file_gain
    sync_native()
    sync_filter()

    msg.info(string.format("replaygain:%s peak=%s fallback=%.2f",
        fmt_gain(baseline_gain), fmt_peak(pending_peak), fb))
end

-- Single decision point: has the effective (path, audio track) actually changed?
local function sync_track()
    local path = mp.get_property("path")
    if not path then return end
    local abs = canonical_path(mp.command_native({"expand-path", path}) or path)
    local ff  = selected_audio_ff_index()
    if abs == current_path and ff == current_ff_index then return end
    load_replaygain(abs, ff)
end

-- HARDBAKE
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
    local el = (ext and ext:lower()) or ""
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
            local ok = os.rename(tmp, path)
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

-- EVENTS & BINDINGS

mp.register_event("playback-restart", function()
    evaluate_auto_scan()
end)

mp.observe_property("audio-device-list", "native", function() maybe_apply_slider() end)

-- track-list fires several times while a file opens; the file-loaded property
-- is false until the file is fully loaded, so this is a safe gate. No shadow flag needed.
mp.observe_property("track-list", "native", function()
    if mp.get_property_bool("file-loaded") then sync_track() end
end)

mp.register_event("file-loaded", sync_track)

mp.register_event("end-file", function()
    current_path, current_ff_index = nil, nil
    taking_over = false
    mpv_loaded_peak = nil
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    if stream_scan_timer then stream_scan_timer:kill() stream_scan_timer = nil end
end)

mp.observe_property("options/replaygain-fallback", "native", function()
    if not current_path then return end
    if mpv_has_tags then return end
    sync_filter()
end)

mp.add_key_binding("meta+up",   "replaygain-increase", increase_gain, {repeatable=true})
mp.add_key_binding("meta+down", "replaygain-decrease", decrease_gain, {repeatable=true})
mp.add_key_binding("meta+b", "replaygain-hardbake", hardbake)
mp.add_key_binding("meta+r", "replaygain-reset",    reset_gain)
mp.add_key_binding("meta+i", "replaygain-info",     show_info)
mp.add_key_binding("meta+s", "replaygain-scan",     function() scan_current(false) end)