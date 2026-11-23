-- smartcut.lua — mpv keybinding wrapper for smartcut.py
--
-- k   : cycle Mark A → Mark B (launches processing in current mode)
-- K   : cycle through modes (Smart Cut / Compress / Pan Smash / GIF)
--
-- Options (encoder CRF/presets, GIF, pan smash, frame vs timestamp marks, ...) live in
-- ~/.config/mpv/script-opts/smartcut.conf and are read by smartcut.py.
--
-- Processing runs fully detached via nohup: mpv stays responsive, and the
-- encode survives even if you close mpv or switch to a different video.
-- While mpv is open, output is tailed into the console (press ` to view).

local mp    = require("mp")
local utils = require("mp.utils")

local SCRIPT_DIR  = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local SMARTCUT_PY = SCRIPT_DIR .. "smartcut.py"

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- PATH used for every subprocess we start (Homebrew + user bin dirs).
local TOOL_PATH = (os.getenv("HOME") or "") .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

-- Resolve Python binary: the smartcut pipx venv first, then Homebrew python.
-- The first one that can `import av` wins. The probe prints "OK|<dir>" only
-- if the import works; <dir> is PyAV's bundled .dylibs folder (or empty).
local PROBE = "import av, os; d = os.path.join(os.path.dirname(av.__file__), '.dylibs'); "
           .. "print('OK|' + (d if os.path.isdir(d) else ''))"
local resolved_python = nil
local resolved_av_dylibs = nil

local function detect_python()
    if resolved_python then return resolved_python end

    local candidates = {
        (os.getenv("HOME") or "") .. "/.local/pipx/venvs/smartcut/bin/python3",
        "/opt/homebrew/bin/python3",
    }

    local first_existing = nil
    for _, py in ipairs(candidates) do
        if file_exists(py) then
            first_existing = first_existing or py
            local p = io.popen('PATH="' .. TOOL_PATH .. '" ' .. shell_quote(py)
                               .. " -c " .. shell_quote(PROBE) .. " 2>/dev/null")
            local out = p and p:read("*l")
            if p then p:close() end
            if out and out:sub(1, 3) == "OK|" then
                resolved_python = py
                local d = out:sub(4)
                if d ~= "" and file_exists(d) then resolved_av_dylibs = d end
                break
            end
        end
    end

    resolved_python = resolved_python or first_existing or candidates[2]
    return resolved_python
end

local mark_a       = nil
local mark_a_frame = nil
local current_mode = "smartcut"

local MODES = { "smartcut", "compress", "pansmash", "gif" }
local MODE_NAMES = { smartcut = "Smart Cut", compress = "Compress", pansmash = "Pan Smash", gif = "GIF" }

local function toggle_mode()
    local idx = 1
    for i, m in ipairs(MODES) do
        if m == current_mode then idx = i; break end
    end
    current_mode = MODES[(idx % #MODES) + 1]
    mp.osd_message("Mode: " .. MODE_NAMES[current_mode])
end

local function format_time(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%d-%02d-%05.2f", h, m, s)
    else
        return string.format("%02d-%05.2f", m, s)
    end
end

--- Launch a command fully detached (survives mpv close and video changes).
--- stdout/stderr are captured to log_path; a periodic timer tails the log
--- into mpv's console (press `) while mpv is still running.
local function launch_detached(args, log_path, label)
    local parts = {}
    for _, a in ipairs(args) do
        parts[#parts + 1] = shell_quote(a)
    end
    local cache_dir  = SCRIPT_DIR .. "../../cache/.pycache"
    local dyld_extra = "/opt/homebrew/lib:/usr/local/lib"
    if resolved_av_dylibs and resolved_av_dylibs ~= "" then
        dyld_extra = resolved_av_dylibs .. ":" .. dyld_extra
    end
    local cmd = 'DYLD_LIBRARY_PATH="' .. dyld_extra .. ':${DYLD_LIBRARY_PATH}" '
             .. 'PYTHONPYCACHEPREFIX=' .. shell_quote(cache_dir) .. ' '
             .. 'PATH="' .. TOOL_PATH .. '" nohup '
                .. table.concat(parts, " ")
                .. " > " .. shell_quote(log_path) .. " 2>&1 &"
    os.execute(cmd)

    -- Tail the log file for live console output while mpv is open.
    local pos = 0
    local stale_ticks = 0
    local check_warned = false
    local timer
    timer = mp.add_periodic_timer(1.0, function()
        local f = io.open(log_path, "r")
        if not f then return end
        f:seek("set", pos)
        local chunk = f:read("*a")
        pos = f:seek("cur")
        f:close()

        if chunk and #chunk > 0 then
            stale_ticks = 0
            for line in chunk:gmatch("[^\r\n]+") do
                mp.msg.info("[smartcut] " .. line)
            end
            if chunk:find("[check] WARN", 1, true) then check_warned = true end
            if chunk:find("SUCCESS") then
                mp.osd_message(label .. (check_warned and " ✓ Done — check warnings, see console (`)" or " ✓ Done"))
                timer:kill()
                return
            end
            if chunk:find("CRITICAL ERROR") or chunk:find("Traceback") or chunk:find("FAILED") then
                mp.osd_message(label .. " FAILED — see console (`)")
                timer:kill()
                return
            end
        else
            stale_ticks = stale_ticks + 1
            -- Safety net: if the log hasn't updated in 10 minutes, the
            -- process likely died without a completion marker.  Stop
            -- tailing so we don't leak a timer forever.
            if stale_ticks > 600 then
                mp.msg.warn("[smartcut] No log activity for 10 min — stopping monitor "
                            .. "(process may still be running).")
                timer:kill()
                return
            end
        end
    end)
end

local function sanitize_filename(s)
    -- Strip characters that are unsafe in filenames/paths, then trim.
    s = s:gsub('[/\\:*?"<>|]', '_')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function derive_name(input)
    local _, filename = utils.split_path(input)
    local base = filename:match("^(.+)%.[^%.]+") or filename
    return sanitize_filename(base)
end

--- Estimate the current frame number for OSD display only.
--- Never fall back to display-fps (which is monitor refresh rate, e.g. 60/120Hz).
local function current_frame()
    local n = mp.get_property_number("estimated-frame-number")
    if n and n > 0 then return n end
    local pos = mp.get_property_number("time-pos") or 0
    local fps = mp.get_property_number("container-fps")
              or mp.get_property_number("estimated-vf-fps")
    if fps and fps > 0 and fps < 200 then
        return math.floor(pos * fps)
    end
    return nil
end

local function handle_cut_cycle()
    local t = mp.get_property_number("time-pos")
    if not t then return end

    if not mark_a then
        mark_a = t
        mark_a_frame = current_frame()
        local frame_info = (mark_a_frame and mark_a_frame > 0) and (" (frame " .. tostring(mark_a_frame) .. ")") or ""
        mp.osd_message("Mark A: " .. format_time(mark_a) .. frame_info)
        return
    end

    local start_t, end_t = mark_a, t
    local sf, ef = mark_a_frame, current_frame()
    mark_a = nil
    mark_a_frame = nil

    if start_t >= end_t then
        mp.osd_message("Error: Mark A must precede Mark B.")
        return
    end

    local input = mp.get_property("path")
    local name = derive_name(input)

    local home = os.getenv("HOME") or ""
    local is_image_mode = (current_mode == "gif" or current_mode == "pansmash")
    local base_dir = is_image_mode
        and (home .. "/Pictures/mpv/screenshots/")
        or  (home .. "/Pictures/mpv/clips/")
    local out_dir = base_dir .. name .. "/"
    local EXT_SUFFIX = {
        smartcut = "].cut.mkv",
        compress = "].compressed.mkv",
        pansmash = "].panorama.png",
        gif      = "].pan.gif",
    }
    local out_file = out_dir .. name
                     .. "_[" .. format_time(start_t)
                     .. "_"  .. format_time(end_t)
                     .. EXT_SUFFIX[current_mode]
    local log_file = "/tmp/smartcut_" .. os.time() .. "_" .. math.floor(t * 1000) .. ".log"

    -- Ensure output directory exists before the shell redirect creates the log
    os.execute("mkdir -p " .. shell_quote(out_dir))


    local label = MODE_NAMES[current_mode]
    mp.osd_message(label .. " started")
    mp.msg.info("[smartcut] === Mode: " .. label .. " → " .. out_file .. "===")

    -- Pass exact timestamps (start_t, end_t) with millisecond accuracy.
    -- Also pass frame numbers when available: smartcut.py prefers --frames mode
    -- (unambiguous integer indices) over floating-point timestamp snapping.
    local python_bin = detect_python()
    local py_args = { python_bin, "-u", SMARTCUT_PY, input, tostring(start_t), tostring(end_t), out_file }
    if sf and ef and sf >= 0 and ef > sf then
        py_args[#py_args + 1] = "--start-frame"
        py_args[#py_args + 1] = tostring(sf)
        py_args[#py_args + 1] = "--end-frame"
        py_args[#py_args + 1] = tostring(ef)
    end

    launch_detached(py_args, log_file, label)
end

mp.add_key_binding("k", "smartcut_cycle", handle_cut_cycle)
mp.add_key_binding("K", "toggle_cut_mode", toggle_mode)
