-- smartcut.lua — mpv keybinding wrapper for smartcut.py
--
-- k   : cycle Mark A → Mark B (launches processing in current mode)
-- K   : cycle through modes (Smart Cut / Compress / Pan Smash / GIF)
--
-- Processing runs fully detached via nohup: mpv stays responsive, and the
-- encode survives even if you close mpv or switch to a different video.
-- While mpv is open, output is tailed into the console (press ` to view).

local mp    = require("mp")
local msg   = require("mp.msg")
local utils = require("mp.utils")
local opt   = require("mp.options")

-- Options (override in ~/.config/mpv/script-opts/smartcut.conf)
local options = {
    python_path = "", -- Custom python binary path (optional). Defaults to auto-detect.
}
opt.read_options(options, "smartcut")

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

-- Resolve Python binary: checks custom option, env vars, venvs, and global brew/system python
local resolved_python = nil
local resolved_av_dylibs = nil

local function detect_python()
    if resolved_python then return resolved_python end

    local home = os.getenv("HOME") or ""
    local candidates = {}

    -- 1. Explicit option in script-opts/smartcut.conf
    if options.python_path ~= "" then
        table.insert(candidates, options.python_path)
    end

    -- 2. Environment variables
    local env_py = os.getenv("SMARTCUT_PYTHON")
    if env_py and env_py ~= "" then table.insert(candidates, env_py) end
    local venv_env = os.getenv("VIRTUAL_ENV")
    if venv_env and venv_env ~= "" then table.insert(candidates, venv_env .. "/bin/python3") end

    -- 3. pipx default venv location (~/.local/pipx/venvs/smartcut)
    table.insert(candidates, home .. "/.local/pipx/venvs/smartcut/bin/python3")
    table.insert(candidates, home .. "/.venv/bin/python3")

    -- 4. Global Homebrew and system Python locations
    table.insert(candidates, "/opt/homebrew/bin/python3")
    table.insert(candidates, "/usr/local/bin/python3")
    table.insert(candidates, "python3")

    local first_existing = nil
    for _, py in ipairs(candidates) do
        local is_bare = not py:find("/")
        if is_bare or file_exists(py) then
            if not first_existing then first_existing = py end
            -- Test if PyAV is importable
            local test_cmd = string.format(
                'PATH="%s/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" %s -c "import av" >/dev/null 2>&1',
                home, shell_quote(py)
            )
            local res = os.execute(test_cmd)
            if res == 0 or res == true then
                resolved_python = py
                break
            end
        end
    end

    resolved_python = resolved_python or first_existing or "python3"

    -- Find PyAV bundled dylibs directory if present
    local dylib_cmd = string.format(
        'PATH="%s/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" %s -c "import av, os; d=os.path.join(os.path.dirname(av.__file__), \'.dylibs\'); print(d if os.path.isdir(d) else \'\')" 2>/dev/null',
        home, shell_quote(resolved_python)
    )
    local p = io.popen(dylib_cmd)
    if p then
        local out = p:read("*l")
        p:close()
        if out and out ~= "" and file_exists(out) then
            resolved_av_dylibs = out
        end
    end

    return resolved_python
end

local mark_a       = nil
local mark_a_frame = nil
local mark_b_frame = nil
local current_mode = "smartcut"

local MODES = { "smartcut", "compress", "pansmash", "gif" }
local MODE_LABELS = {
    smartcut = "Mode: Smart Cut",
    compress = "Mode: Compress",
    pansmash = "Mode: Pan Smash",
    gif      = "Mode: GIF",
}
local MODE_SHORT = {
    smartcut = "Smart Cut",
    compress = "Compress",
    pansmash = "Pan Smash",
    gif      = "GIF",
}

local function toggle_mode()
    local idx = 1
    for i, m in ipairs(MODES) do
        if m == current_mode then idx = i; break end
    end
    current_mode = MODES[(idx % #MODES) + 1]
    mp.osd_message(MODE_LABELS[current_mode])
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
    local home = os.getenv("HOME") or ""
    local cache_dir  = SCRIPT_DIR .. "../../cache/.pycache"
    local dyld_extra = "/opt/homebrew/lib:/usr/local/lib"
    if resolved_av_dylibs and resolved_av_dylibs ~= "" then
        dyld_extra = resolved_av_dylibs .. ":" .. dyld_extra
    end
    local cmd = 'DYLD_LIBRARY_PATH="' .. dyld_extra .. ':${DYLD_LIBRARY_PATH}" '
             .. 'PYTHONPYCACHEPREFIX=' .. shell_quote(cache_dir) .. ' '
             .. 'PATH="' .. home .. '/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" nohup '
                .. table.concat(parts, " ")
                .. " > " .. shell_quote(log_path) .. " 2>&1 &"
    os.execute(cmd)

    -- Tail the log file for live console output while mpv is open.
    local pos = 0
    local stale_ticks = 0
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
            if chunk:find("SUCCESS") then
                mp.osd_message(label .. " ✓ Done")
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

-- When mpv plays a disc via bd://, bluray://, dvd:// or dvdnav://, the actual
-- BDMV/VIDEO_TS folder is often NOT part of `path` at all - mpv keeps it in a
-- separate option (--bluray-device / --dvd-device) and `path` can come back
-- as bare as "bluray://" with nothing after it. Recover the real folder: try
-- an embedded path in the URL first (bd://TITLE/PATH), then fall back to the
-- matching device option. Returns nil if `input` isn't a disc protocol URL.
local function resolve_disc_device_path(input)
    local proto, rest = input:match("^(%a[%w+.-]*)://(.*)$")
    if not proto then return nil end
    proto = proto:lower()
    if proto ~= "bd" and proto ~= "bluray" and proto ~= "dvd" and proto ~= "dvdnav" then
        return nil
    end

    -- bd://TITLE/PATH or bd:///PATH - path embedded directly after an
    -- optional title number.
    local embedded = rest:match("^%d*/*(/.+)$")
    if embedded and embedded ~= "" then
        return embedded
    end

    local device_prop = (proto == "dvd" or proto == "dvdnav") and "dvd-device" or "bluray-device"
    local device = mp.get_property(device_prop)
    if device and device ~= "" then
        return device
    end

    return nil
end

-- BD/DVD sources break the plain "filename minus extension" logic in two ways:
--   1. A physical/protocol source (bd://, dvd://, bluray://) has no real
--      filename at all - `path` is just a protocol URL, and the actual folder
--      lives in a separate mpv option (see resolve_disc_device_path above).
--   2. A ripped disc folder's stream files are meaningless numbers
--      (BDMV/STREAM/00001.m2ts) or VOB titles (VIDEO_TS/VTS_01_1.VOB), not
--      the movie/show name.
-- In both cases, prefer mpv's `media-title` (which mpv resolves from the
-- disc's own playlist/IFO metadata), then fall back to the parent folder
-- name (the one actually named after the movie, one level above BDMV/VIDEO_TS).
local function derive_name(input)
    local media_title = mp.get_property("media-title")
    local disc_path = resolve_disc_device_path(input)

    if disc_path then
        if media_title and media_title ~= "" then
            return sanitize_filename(media_title)
        end
        -- No media-title available - fall back to the disc folder's own name.
        local _, folder_name = utils.split_path(disc_path:gsub("[/\\]+$", ""))
        return sanitize_filename((folder_name and folder_name ~= "") and folder_name or "disc")
    end

    local dir, filename = utils.split_path(input)
    local base = filename:match("^(.+)%.[^%.]+") or filename

    local looks_numeric_or_vts = base:match("^%d+$") ~= nil or base:match("^VTS_%d+_%d+$") ~= nil
    if looks_numeric_or_vts then
        if media_title and media_title ~= "" then
            return sanitize_filename(media_title)
        end
        -- .../MOVIE_NAME/BDMV/STREAM/00001.m2ts -> MOVIE_NAME
        -- .../MOVIE_NAME/VIDEO_TS/VTS_01_1.VOB  -> MOVIE_NAME
        -- (search the whole path, not just the immediate dir, since the
        -- stream file sits under BDMV/STREAM or BDMV/PLAYLIST, not BDMV itself)
        local parent = input:match("([^/\\]+)[/\\]BDMV[/\\]") or input:match("([^/\\]+)[/\\]VIDEO_TS[/\\]")
        if parent then
            return sanitize_filename(parent)
        end
    end

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
    mark_b_frame = nil

    if start_t >= end_t then
        mp.osd_message("Error: Mark A must precede Mark B.")
        return
    end

    local input = mp.get_property("path")
    local name = derive_name(input)
    -- For disc protocol sources, hand smartcut.py the real folder (which its
    -- own resolve_disc_input() can then dig into for the main .m2ts/VOB),
    -- not the bare protocol string ffprobe can't do anything with.
    local source_path = resolve_disc_device_path(input) or input

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


    local label = MODE_SHORT[current_mode]
    mp.osd_message(label .. " started")
    mp.msg.info("[smartcut] === " .. MODE_LABELS[current_mode] .. " → " .. out_file .. "===")

    -- Pass exact timestamps (start_t, end_t) with millisecond accuracy.
    -- Also pass frame numbers when available: smartcut.py prefers --frames mode
    -- (unambiguous integer indices) over floating-point timestamp snapping,
    -- which is especially important on disc sources with PTS offsets.
    local python_bin = detect_python()
    local py_args = { python_bin, "-u", SMARTCUT_PY, source_path, tostring(start_t), tostring(end_t), out_file }
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
