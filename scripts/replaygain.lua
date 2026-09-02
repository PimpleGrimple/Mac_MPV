--[[ replaygain.lua — ReplayGain tag editor for mpv

At rest, playback uses only mpv's native gain (replaygain-preamp for tagged
files, replaygain-fallback for untagged) -- no filter in the chain. The
moment you adjust or scan, a lavfi volume filter carries just the unsaved
delta on top of native, and disappears again once saved/reset/matched.

KEYS
  Meta+↑/↓            adjust ±0.10 dB      Meta+b   hardbake (lossless)
  Shift+Meta+↑/↓       adjust ±0.01 dB      Meta+r   reset to baseline
  Meta+s               EBU R128 scan        Meta+i   show info (4s)
]]

local mp, utils, msg = require 'mp', require 'mp.utils', require 'mp.msg'

-- CONFIG -------------------------------------------------------------
local RG_TARGET_LUFS = -18.0                 -- foobar2000 EBU R128 target
local STEP_DB, MICRO_STEP_DB = 0.10, 0.01
local MAX_DB, MIN_DB, EPS = 20.0, -20.0, 0.005  -- EPS: "no unsaved change" cutoff
local AUTO_BAKE_DEBOUNCE = 10
local FILTER_LABEL = "replaygain"
local AUTO_BAKE = false                      -- automatically bake scanned values
local AUTO_SCAN = true                      -- automatically scan untagged files
local GAIN_KEYS = { 
    "REPLAYGAIN_TRACK_GAIN", "replaygain_track_gain",
    "REPLAYGAIN_ALBUM_GAIN", "replaygain_album_gain",
    "REPLAYGAIN_GAIN", "replaygain_gain" }
local PEAK_KEY_MAP = { 
    REPLAYGAIN_TRACK_GAIN = "REPLAYGAIN_TRACK_PEAK",
    REPLAYGAIN_ALBUM_GAIN = "REPLAYGAIN_ALBUM_PEAK",
    REPLAYGAIN_GAIN = "REPLAYGAIN_PEAK" }

-- STATE ----------------------------------------------------------------
local current_path, last_path, last_track_id, selected_audio_ff_index
local baseline_gain, file_gain, delta = 0.0, 0.0, 0.0
local mpv_native_gain, mpv_has_tags = 0.0, false
local disk_peak, pending_peak
local has_tags_current, baking, scanning = false, false, false
local autobake_timer
local USER_RG_FALLBACK = tonumber(mp.get_property("options/replaygain-fallback")) or 0.0
local file_just_loaded = false

local function effective_gain() return baseline_gain + delta end
-- What mpv already does with zero adjustment: the on-disk tag (tagged) or
-- the configured fallback (untagged).
local function native_reference() return mpv_has_tags and mpv_native_gain or USER_RG_FALLBACK end
local function clamp(v) return math.max(MIN_DB, math.min(MAX_DB, v)) end

local function sync_native()
    if mpv_has_tags then
        mp.set_property_native("file-local-options/replaygain-preamp", 0)
    else
        mp.set_property_native("options/replaygain-fallback", USER_RG_FALLBACK)
    end
end

-- TEST FILTER: remove+re-add with value baked into the creation string.
-- NOT af-command in-place updates -- that was tested three times for real
-- (double precision, float + multi-filter chain, float + single-filter
-- chain) and never actually took audible effect despite `volume` being a
-- genuinely runtime-command-capable AVOption. Remove+re-add is slower per
-- change but is the mechanism actually confirmed to work.
local current_filter_d = 0.0
local function filter_present()
    for _, f in ipairs(mp.get_property_native("af") or {}) do
        if f.label == FILTER_LABEL then return true end
    end
    return false
end
local function remove_filter()
    if filter_present() then mp.commandv("af", "remove", "@" .. FILTER_LABEL) end
    current_filter_d = 0.0
end
local function set_filter_value(db)
    if filter_present() and math.abs(db - current_filter_d) <= EPS then return end
    remove_filter()
    mp.commandv("af", "add", string.format("@%s:lavfi=[volume=%.2fdB:precision=double:eval=once]", FILTER_LABEL, db))
    current_filter_d = db
end
-- Filter carries exactly the unsaved amount beyond native; removed when
-- nothing's unsaved so idle playback stays 100% native.
local function sync_filter()
    local d = effective_gain() - native_reference()
    if math.abs(d) <= EPS then remove_filter() else set_filter_value(d) end
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
-- Explicit map, not gsub("GAIN","PEAK") -- "REPLAYGAIN_TRACK_GAIN" contains "GAIN"
-- twice, so a blind substitute corrupts it into "REPLAYPEAK_TRACK_PEAK".
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
    local unsaved = math.abs(ddisk) > EPS
    
    local txt
    if detailed then
        txt = string.format("Gain: %s\nFile Tag: %s   %s\nPeak: %s",
            fmt_gain(eff), fmt_gain(file_gain),
            unsaved and ("(Δ " .. fmt_gain(ddisk) .. ")") or "(unchanged)",
            fmt_peak(pending_peak))
    else
        txt = string.format("Gain: %s", fmt_gain(eff))
        if unsaved then
            txt = txt .. string.format(" (Δ %s)", fmt_gain(ddisk))
        end
    end
    
    mp.osd_message(txt, dur or 2.5)
end

local hardbake, scan_current  -- forward declarations (mutually referenced)

local function schedule_autobake()
    if not AUTO_BAKE then return end
    if autobake_timer then autobake_timer:kill() end
    autobake_timer = mp.add_timeout(AUTO_BAKE_DEBOUNCE, function() autobake_timer = nil hardbake() end)
end

-- KEY HANDLERS ---------------------------------------------------------
local function adjust(step)
    if not current_path then return end
    delta = clamp(effective_gain() + step) - baseline_gain
    sync_filter()
    osd_state(2.5, false)
    schedule_autobake()
end
local function increase_gain()       adjust( STEP_DB)       end
local function decrease_gain()       adjust(-STEP_DB)       end
local function micro_increase_gain() adjust( MICRO_STEP_DB) end
local function micro_decrease_gain() adjust(-MICRO_STEP_DB) end

local function reset_gain()
    if not current_path then return end
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    delta = 0.0
    sync_filter()
    mp.osd_message("Reset to baseline: " .. fmt_gain(baseline_gain), 2)
end

local function show_info() osd_state(4, true) end



-- LOAD -----------------------------------------------------------------
local function load_replaygain(force)
    local path = mp.get_property("path")
    if not path then return end

    local has_audio = false
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "audio" then has_audio = true break end
    end
    if not has_audio then
        if autobake_timer then autobake_timer:kill() autobake_timer = nil end
        remove_filter()
        current_path, last_path, last_track_id, selected_audio_ff_index = nil, nil, nil, nil
        return
    end

    local abs_path = mp.command_native({"expand-path", path}) or path

    local track_id, ff_index
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "audio" and t.selected then track_id, ff_index = t.id, t["ff-index"] break end
    end

    local should_force = force or file_just_loaded
    file_just_loaded = false

    if not should_force and abs_path == last_path and track_id == last_track_id then return end
    last_path, last_track_id, selected_audio_ff_index, current_path = abs_path, track_id, ff_index, abs_path
    delta = 0.0
    if autobake_timer then autobake_timer:kill() autobake_timer = nil end
    remove_filter()  -- new file: start fully native

    local gain, peak, has_tags = read_tags()
    has_tags_current = has_tags
    mpv_has_tags = has_tags
    baseline_gain = has_tags and gain or USER_RG_FALLBACK
    file_gain     = has_tags and gain or 0.0
    mpv_native_gain = file_gain
    disk_peak, pending_peak = peak, peak

    sync_native()
    sync_filter()

    msg.info(string.format("replaygain: %s peak=%s has_tags=%s path=%s",
        fmt_gain(baseline_gain), fmt_peak(pending_peak), tostring(has_tags), current_path))

    if not has_tags and AUTO_SCAN then scan_current(true) end
end

local function is_stream_or_pipe(path)
    if not path then return true end
    if path == "-" or path == "stdin" or path:match("^fd://") then return true end
    if path:match("^%a[%a%d+%-%.]*://") then return true end
    if mp.get_property_bool("demuxer-via-network") then return true end
    local stream_path = mp.get_property("stream-path")
    if stream_path and (stream_path:match("^%a[%a%d+%-%.]*://") or stream_path == "-" or stream_path:match("^fd://")) then
        return true
    end
    local open_filename = mp.get_property("stream-open-filename")
    if open_filename and (open_filename:match("^%a[%a%d+%-%.]*://") or open_filename == "-" or open_filename:match("^fd://")) then
        return true
    end
    return false
end

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
    if is_stream_or_pipe(current_path) then
        if not is_auto then mp.osd_message("Cannot scan: not a local file", 3) end
        return
    end

    local path, t0 = current_path, mp.get_time()
    local args = { "ffmpeg", "-nostdin", "-hide_banner", "-vn", "-sn", "-dn", "-i", path }
    if selected_audio_ff_index then
        table.insert(args, "-map"); table.insert(args, "0:" .. tostring(selected_audio_ff_index))
    end
    for _, a in ipairs({ "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-" }) do
        table.insert(args, a)
    end

    scanning, scan_path = true, path
    if not is_auto then
        mp.osd_message("Scanning loudness… (playback continues)", 999)
    end

    scan_handle = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
        capture_stdout = false, capture_stderr = true },
    function(success, result, err)
        scanning, scan_handle = false, nil
        if current_path ~= path then msg.info("replaygain: scan discarded (file changed)") return end
        local stderr = result and result.stderr
        if not (success and result and result.status == 0) then
            mp.osd_message("Scan FAILED — see console", 4)
            msg.error("replaygain: scan failed: " .. tostring(err) .. (stderr and ("\n" .. stderr:sub(-400)) or ""))
            return
        end
        local lufs = stderr and tonumber(stderr:match("I:%s*([%-]?%d+%.?%d*)%s*LUFS"))
        if not lufs then
            mp.osd_message("Scan: could not parse LUFS", 4)
            msg.error("replaygain: no LUFS in ffmpeg output" .. (stderr and ("\n" .. stderr:sub(-400)) or ""))
            return
        end
        local dbfs = stderr and tonumber(stderr:match("Peak:%s*([%-]?%d+%.?%d*)%s*dBFS"))
        local computed = RG_TARGET_LUFS - lufs

        baseline_gain = computed
        pending_peak  = dbfs and tostring(10 ^ (dbfs / 20)) or nil
        delta = 0.0
        sync_filter()

        local scan_delta = computed - file_gain
        local gain_changed = math.abs(scan_delta) > EPS
        local peak_changed = (pending_peak == nil) ~= (disk_peak == nil)
            or (pending_peak and disk_peak and tostring(pending_peak) ~= tostring(disk_peak))
        local changed = gain_changed or peak_changed

        local delta_str = gain_changed and (" (Δ " .. fmt_gain(scan_delta) .. ")") or ""

        msg.info(string.format("replaygain: scan done in %.1fs — I=%.1f LUFS → %s%s",
            mp.get_time() - t0, lufs, fmt_gain(computed), gain_changed and ("  (Δ " .. fmt_gain(scan_delta) .. ")") or "  (unchanged)"))
        mp.osd_message(string.format("Scan Complete: %s%s",
            fmt_gain(computed), delta_str), 4)

        if AUTO_BAKE and changed then schedule_autobake() end
    end)
end

-- HARDBAKE (lossless -c copy remux) --------------------------------------
hardbake = function()
    if baking then mp.osd_message("Hardbake already in progress…", 2) return end
    if not current_path then mp.osd_message("No file loaded", 2) return end
    if is_stream_or_pipe(current_path) then mp.osd_message("Cannot bake: not a local file", 3) return end

    local path, eff = current_path, effective_gain()
    local write_key = get_write_key()
    local peak_key  = get_peak_key(write_key)

    local gain_changed = math.abs(eff - file_gain) > EPS
    local peak_changed = (pending_peak == nil) ~= (disk_peak == nil)
        or (pending_peak and disk_peak and tostring(pending_peak) ~= tostring(disk_peak))
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
                has_tags_current = true  -- file now genuinely has this tag on disk
                -- Intentionally do NOT update mpv_has_tags or mpv_native_gain.
                -- mpv will not read the new tags until it reloads the file.
                -- Keeping them old ensures sync_filter() maintains the lavfi volume bridge.
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
mp.observe_property("track-list", "native", function() load_replaygain(false) end)
mp.register_event("file-loaded", function() file_just_loaded = true load_replaygain(true) end)

mp.add_key_binding("meta+up",         "replaygain-increase",       increase_gain,       {repeatable=true})
mp.add_key_binding("meta+down",       "replaygain-decrease",       decrease_gain,       {repeatable=true})
mp.add_key_binding("Shift+meta+up",   "replaygain-micro-increase", micro_increase_gain, {repeatable=true})
mp.add_key_binding("Shift+meta+down", "replaygain-micro-decrease", micro_decrease_gain, {repeatable=true})
mp.add_key_binding("meta+b", "replaygain-hardbake",         hardbake)
mp.add_key_binding("meta+r", "replaygain-reset",            reset_gain)
mp.add_key_binding("meta+i", "replaygain-info",             show_info)
mp.add_key_binding("meta+s", "replaygain-scan",             scan_current)