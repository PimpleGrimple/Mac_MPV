local msg = require "mp.msg"
local options = require "mp.options"
local utils = require "mp.utils"

-- Publishes user-data/deint (boolean): true while one of our filters runs.

-- ── Filter templates ─────────────────────────────────────────────────────────
-- {o} = detected field order (tff / bff / auto), {field} = tf / bf (for NNEDI).
-- Raise cthresh / swap pc_n for cleaner sources.
local FIELDMATCH = "fieldmatch=order={o}:combmatch=full:cthresh=8:mode="
local BWDIF      = "bwdif=mode=1:parity={o}:deint=interlaced"

-- Alternative interlacers, swap in for BWDIF:
--  nnedi   anime line art / text; shimmers on grain (qual=fast is 2x faster)
--          "nnedi=weights=~/.config/mpv/VapourSynth/models/nnedi3/nnedi3_weights.bin:nns=n32:qual=slow:field={field}:deint=interlaced"
--  estdif  very fast edge-directed; plastic on fine detail
--          "estdif=mode=field:parity={o}:deint=interlaced"
--  w3fdif  natural live-action motion; soft on anime
--          "w3fdif=filter=complex"
--  mcdeint smooth slow pans; warps anime / fast cuts
--          "yadif=mode=1:parity={o}:deint=interlaced,mcdeint=mode=medium:parity=-1"

-- One table drives everything: filter template (f), OSD text (label) and the
-- vf label (the id, shown as "@telecine:" in the info panel). No f = no filter.
local CHAINS = {
    auto = { label = "Auto (detected)" },
    off  = { label = "Off" },
    -- clean 3:2 pulldown → 23.976fps
    telecine = { label = "Telecine: fieldmatch + decimate",        f = FIELDMATCH .. "pc_n,decimate" },
    -- genuine interlaced video → field rate
    bob      = { label = "Bob: bwdif field-rate",                  f = BWDIF },
    -- telecine with bad edits/inserts → 23.976fps
    mix      = { label = "Mix: fieldmatch + decimate + bwdif",     f = FIELDMATCH .. "pcn_ub,decimate=mixed=1," .. BWDIF },
    -- fieldmatch + full bob, no decimate → field-rate CFR
    hybrid   = { label = "Hybrid: fieldmatch + bwdif field-rate",  f = FIELDMATCH .. "pcn_ub," .. BWDIF },
}
local CYCLE = { "auto", "telecine", "bob", "mix", "hybrid", "off" }

-- vsdetect cadence -> chain. Anything else runs no filter.
local DETECT = {
    telecine = "telecine", interlaced = "bob",
    mix_telecine = "mix", mix_interlaced = "hybrid",
}
local ORDER = { tff = "tff", tt = "tff", tb = "tff", bff = "bff", bb = "bff", bt = "bff" }

local opts = {
    auto_scan_sd   = true,      -- scan SD (<= 576p) files automatically on load
    auto_scan_osd  = true,      -- one-line OSD when an automatic scan finishes
    chain          = "auto",    -- default chain: auto | telecine | bob | mix | hybrid | off
}
options.read_options(opts, "deint")

local VSDETECT  = mp.command_native({ "expand-path", "~~/VapourSynth/bin/vsdetect" })
local CACHE_DIR = mp.command_native({ "expand-path", "~~/cache/scripts/deint" })

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
local forced = CHAINS[opts.chain] and opts.chain or "auto"  -- manual pick (Shift+X)
local default_forced = forced        -- what "no per-file override" means
local file_id, file_entry = nil, {}  -- persistent cache entry of the current file
local active_vf, published           -- filter installed / user-data/deint published right now
local saved_hwdec                    -- hwdec value we replaced while filtering
local scan_token                     -- in-flight vsdetect, if any
local osd_until = 0                  -- when our OSD message expires

local function show(text, duration, silent)
    if silent then return end
    duration = duration or 3
    mp.osd_message(text, duration)
    osd_until = (text ~= "" and duration > 0) and mp.get_time() + duration or 0
end

--------------------------------------------------------------------------
-- Applying a chain
--------------------------------------------------------------------------
-- Drop any filter carrying one of our labels (also catches one restored from
-- watch-later or config), leaving everyone else's filters alone.
local function remove_ours()
    local vf = mp.get_property_native("vf") or {}
    local keep = {}
    for _, f in ipairs(vf) do
        local c = CHAINS[f.label or ""]
        if not (c and c.f) then keep[#keep + 1] = f end
    end
    if #keep ~= #vf then mp.set_property_native("vf", keep) end
end

-- Software filters need system-memory frames: switch a hardware decoder to
-- its copy variant while one runs and put back exactly what we replaced.
local function set_hwdec(filtering)
    if filtering then
        if saved_hwdec then return end
        local cur = mp.get_property("hwdec", "no")
        if cur == "no" or cur:find("%-copy$") then return end
        saved_hwdec = cur
        mp.set_property("hwdec", "auto-copy")
    elseif saved_hwdec then
        mp.set_property("hwdec", saved_hwdec)
        saved_hwdec = nil
    end
end

-- id: chain id or nil (nil = no filter).
local function apply(id, order)
    local c = id and CHAINS[id]
    local vf
    if c and c.f then
        local o = order or "auto"
        vf = "lavfi=[" .. c.f:gsub("{o}", o):gsub("{field}", o == "bff" and "bf" or "tf") .. "]"
    end

    -- Native boolean on purpose: a string "no" would be truthy in profile-cond.
    local deint = vf ~= nil
    if deint ~= published then
        published = deint
        mp.set_property_native("user-data/deint", deint)
    end
    if vf == active_vf then return end

    remove_ours()
    active_vf = vf
    set_hwdec(deint)
    if vf then mp.commandv("vf", "add", "@" .. id .. ":" .. vf) end
end

local function apply_scan(s)
    apply(DETECT[s.cadence], s.order)
end

-- The chain forced on this file (manual pick), or nil when the detector's
-- result is what runs.
local function override_name()
    if forced ~= "auto" then return forced end
end

-- What should be running: manual pick > saved scan. False = nothing applies yet.
local function settle()
    local o = override_name()
    if o then
        apply(o)
        return true
    end
    if file_entry.scan then
        apply_scan(file_entry.scan)
        return true
    end
    apply(nil)
    return false
end

--------------------------------------------------------------------------
-- OSD report
--------------------------------------------------------------------------
local function setup_text(s)
    local o = override_name()
    if o then return CHAINS[o].label .. " (manual)" end
    local id = DETECT[s.cadence]
    return id and CHAINS[id].label
        or (s.cadence:gsub("^%l", string.upper):gsub("_", " ")) .. " (no filter)"
end

local function build_report(s)
    return string.format(
        "● Cadence:       %s\n" ..
        "● Field Order:   %s\n" ..
        "● Setup:           %s\n" ..
        "──────────────────────────────\n" ..
        "[Frame Structure]\n" ..
        "  ├─ Interlaced:  %.1f%%\n" ..
        "  └─ Progressive: %.1f%%\n" ..
        "[Cadence Signature]\n" ..
        "  └─ Repeat Field Ratio: %.1f%%",
        s.cadence, s.order and s.order:upper() or "AUTO / unknown", setup_text(s),
        s.interlaced * 100, s.progressive * 100, s.repeat_ratio * 100)
end

--------------------------------------------------------------------------
-- Scan target. vsdetect only takes a regular file, so a disc (dvd://, bd://)
-- or a VIDEO_TS folder is resolved to the main title's first VOB / largest
-- M2TS.
--------------------------------------------------------------------------
local DISC = { dvd = "dvd", dvdnav = "dvd", bd = "bd", bluray = "bd", br = "bd" }

local function is_dir(path)
    local info = utils.file_info(path)
    return info ~= nil and info.is_dir
end

-- First VOB of the biggest title set. A title is split across VTS_xx_1..N at
-- ~1 GiB, so sizes are summed per set, not compared per file.
local function main_vob(dir)
    local sizes, firsts = {}, {}
    for _, name in ipairs(utils.readdir(dir) or {}) do
        local set, part = name:match("^[Vv][Tt][Ss]_(%d%d)_(%d+)%.[Vv][Oo][Bb]$")
        if set then
            local info = utils.file_info(dir .. "/" .. name)
            if info and info.is_file then
                sizes[set] = (sizes[set] or 0) + info.size
                if part == "1" then firsts[set] = name end
            end
        end
    end
    local best
    for set, size in pairs(sizes) do
        if firsts[set] and (not best or size > sizes[best]) then best = set end
    end
    return best and (dir .. "/" .. firsts[best])
end

local function largest_m2ts(dir)
    local best, best_size = nil, -1
    for _, name in ipairs(utils.readdir(dir) or {}) do
        if name:lower():match("%.m2ts$") then
            local info = utils.file_info(dir .. "/" .. name)
            if info and info.is_file and info.size > best_size then
                best, best_size = dir .. "/" .. name, info.size
            end
        end
    end
    return best
end

local function resolve_scan_target(path)
    local kind = DISC[path:match("^(%a[%w+.-]*)://")]
    local root = path
    if kind then
        root = mp.get_property(kind == "bd" and "bluray-device" or "dvd-device", "")
        if root == "" then return nil end
        root = mp.command_native({ "expand-path", root })
    end
    if kind == "bd" then return largest_m2ts(root .. "/BDMV/STREAM") end
    if kind == "dvd" or is_dir(root) then
        local sub = root .. "/VIDEO_TS"
        return main_vob(is_dir(sub) and sub or root)
    end
    return path
end

--------------------------------------------------------------------------
-- Persistent cache: ~~/cache/scripts/deint/<hash>.json, one small file per
-- source holding { id, scan, override }. The id is resolved path + size +
-- mtime, so replacing or re-encoding a file invalidates its entry. Sources
-- that can't be stat'ed (streams) are simply not cached on disk.
--------------------------------------------------------------------------
-- Two independent 32-bit hashes -> 16 hex chars. The full id is re-checked on
-- read, so a collision can only cause a cache miss, never a wrong result.
local function hash_id(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 131 + b) % 4294967291
    end
    return string.format("%08x%08x", h1, h2)
end

local function entry_path(id)
    return CACHE_DIR .. "/" .. hash_id(id) .. ".json"
end

local function identity_for(path)
    local target = resolve_scan_target(path)
    if not target then return nil end
    target = utils.join_path(mp.get_property("working-directory", ""), target)

    local info = utils.file_info(target)
    if not (info and info.is_file) then return nil end
    return string.format("%s|%d|%d", target, info.size, info.mtime)
end

local function valid_scan(s)
    return type(s) == "table" and type(s.cadence) == "string"
        and type(s.interlaced) == "number" and type(s.progressive) == "number"
        and type(s.repeat_ratio) == "number"
end

local function read_entry(id)
    local f = io.open(entry_path(id))
    if not f then return {} end
    local entry = utils.parse_json(f:read("*a"))
    f:close()

    if type(entry) ~= "table" or entry.id ~= id then return {} end
    if not valid_scan(entry.scan) then entry.scan = nil end
    if not (CHAINS[entry.override] and entry.override ~= "auto") then
        entry.override = nil
    end
    return entry
end

local function save_entry()
    if not file_id then return end
    local p = entry_path(file_id)

    -- Nothing worth keeping: remove the file instead of leaving an empty one.
    if not (file_entry.scan or file_entry.override) then
        os.remove(p)
        return
    end

    file_entry.id = file_id
    local json = utils.format_json(file_entry)
    if not json then return end

    local f = io.open(p, "w")
    if not f then  -- first save: the cache dir doesn't exist yet
        mp.command_native({
            name = "subprocess", playback_only = false,
            args = { "mkdir", "-p", CACHE_DIR },
        })
        f = io.open(p, "w")
    end
    if f then f:write(json); f:close() end
end

--------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------
local function parse_scan(out)
    local f = {}
    for field in (out .. "|"):gmatch("(.-)|") do f[#f + 1] = field end
    if #f < 13 or f[9] == "" then return nil end

    local s = {
        cadence = f[9], order = ORDER[f[10]],
        interlaced = tonumber(f[11]) or 0,
        progressive = tonumber(f[12]) or 0,
        repeat_ratio = tonumber(f[13]) or 0,
    }
    -- All-zero ratios are how vsdetect flags metadata-only soft telecine.
    if s.cadence == "telecine" and s.interlaced == 0
        and s.progressive == 0 and s.repeat_ratio == 0 then
        s.cadence = "soft_telecine"
    end
    return s
end

local function run_cadence_scan(auto, force)
    local path = mp.get_property("path")
    if not path then return end

    local cached = file_entry.scan
    if cached and not force then
        if not override_name() then apply_scan(cached) end
        show(build_report(cached), 8, auto)
        return
    end
    if scan_token then return end  -- one at a time; a stale one dies on end-file

    local target = resolve_scan_target(path)
    if not target then
        return show("Scan failed: cannot resolve disc path", 3, auto)
    end

    local args = { VSDETECT, target }
    -- Manual scans may inspect HD sources instead of trusting missing or
    -- incomplete field-order metadata.
    if not auto then args[3] = "--scan-hd" end

    show("Scanning cadence...", 10, auto)

    local token
    token = mp.command_native_async({
        name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true,
        args = args,
    }, function(ok, res)
        if scan_token ~= token then return end  -- file changed, scan was aborted
        scan_token = nil

        if not (ok and res and res.status == 0) then
            msg.warn("vsdetect failed: " .. tostring(res and res.stderr))
            return show("Scan failed", 3, auto)
        end
        local scan = parse_scan(res.stdout or "")
        if not scan then return show("Invalid vsdetect output", 3, auto) end

        if not override_name() then apply_scan(scan) end
        file_entry.scan = scan
        save_entry()

        if not auto then
            show(build_report(scan), 8)
        elseif opts.auto_scan_osd then
            show("Deint: " .. setup_text(scan), 3)
        end
    end)
    scan_token = token
end

--------------------------------------------------------------------------
-- Events and keys
--------------------------------------------------------------------------
mp.register_event("file-loaded", function()
    file_id = identity_for(mp.get_property("path", ""))
    file_entry = file_id and read_entry(file_id) or {}

    -- A per-file manual override wins, so one file's pick never leaks into
    -- the next.
    forced = file_entry.override or default_forced

    active_vf = false  -- unsynced: force one sweep of leftover filters
    if settle() then return end

    -- file_id is nil for anything vsdetect can't read (http streams etc.), so
    -- those never spawn a doomed scan. x still tries one manually.
    local height = mp.get_property_number("height", 0)
    if opts.auto_scan_sd and file_id and height > 0 and height <= 576 then
        run_cadence_scan(true)
    end
end)

mp.register_event("end-file", function(e)
    if scan_token then
        mp.abort_async_command(scan_token)
        scan_token = nil
    end
    if e.reason == "quit" then return end  -- nothing to tidy on the way out
    show("", 0)
    apply(nil)
    file_id, file_entry = nil, {}
end)

mp.add_key_binding("d", "probe_cadence", function()
    if mp.get_time() < osd_until then
        show("", 0)
    else
        run_cadence_scan(false)
    end
end)

mp.add_key_binding("Ctrl+d", "rescan_cadence", function()
    run_cadence_scan(false, true)
end)

mp.add_key_binding("D", "cycle_chain", function()
    local i = 1
    for n, id in ipairs(CYCLE) do
        if id == forced then i = n end
    end
    forced = CYCLE[i % #CYCLE + 1]

    -- Remembered per file ("auto" just clears the override).
    file_entry.override = forced ~= "auto" and forced or nil
    save_entry()

    -- "auto" means what it does at load time: saved scan, else a fresh scan.
    if not settle() then run_cadence_scan(false) end
    show("Deint chain: " .. CHAINS[forced].label, 3)
end)