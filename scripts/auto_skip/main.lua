--[[
    auto_skip / main.lua

    One script, one config (script-opts/auto_skip.conf), one flow:

      file loaded
        '- sources are tried in order, the first one with something to skip wins:
              YouTube video (sponsorblock=yes)   sponsorblock.lua  (only this one when
                                                 the YouTube ID is certain)
              then the priority list:
              local     localchapters.lua   the file's own chapter titles (offline)
              aniskip   aniskip.lua         AniList -> AniSkip
              introdb   theintrodb.lua      TheIntroDB (TMDB id)
           A source "misses" when it is not applicable, errors, finds nothing, or
           finds nothing in its <source>_categories. The next one is then tried and
           the sources after a hit are never queried.

    Hits are cached for good, misses for a day, so repeat plays and non-anime
    files don't hit the network. Delete ~~/cache/scripts/auto_skip/ to refetch.

    Provider modules (flat files next to this one) return a table:
        online      true for network sources (their markers also become chapters)
        close       online only: { Label = "Fallback chapter title" } for chapter ends
        applicable  optional; false = skip this source silently
        cache_key   optional online: cache file name (default: the filename)
        scan        offline sources: returns intervals
        fetch       online sources: fetch(done, alive) -> done(body) or
                    done(nil, reason, final)   final = a definite "no data" (cacheable)
        parse       online sources: body -> intervals
    sponsorblock.lua also has detect() -> id, strong, asked for every file.
    An interval is { start_time, end_time, label, ending = bool|nil }.
]]
local mp = require("mp")

local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
package.path = dir .. "?.lua;" .. package.path

------------------------------------------------------------------
-- Configuration (script-opts/auto_skip.conf)
--   <option>            applies to every source
--   <source>_<option>   overrides it for one source (local, aniskip, introdb, sponsorblock)
------------------------------------------------------------------
local BEHAVIOUR = { "skip_once", "advance_on_ending", "show_skip_feedback" }
local SOURCES = { "local", "aniskip", "introdb", "sponsorblock" }

local conf = {
    priority            = "local,aniskip,introdb",
    sponsorblock        = true,
    toggle_key          = "alt+s",
    rescan_key          = "Alt+R",
    debug               = false,

    skip_once           = true,
    advance_on_ending   = true,
    show_skip_feedback  = true,

    local_categories        = "Opening,Ending,Misc",
    aniskip_categories      = "Opening,Ending",
    introdb_categories      = "Intro,Credits,Preview",
    sponsorblock_categories = "sponsor,music_offtopic",

    introdb_tmdb_api_key    = "",
    introdb_default_season  = 1,
}
-- Per-source overrides: "" means "not set, use the global value".
for _, src in ipairs(SOURCES) do
    for _, key in ipairs(BEHAVIOUR) do conf[src .. "_" .. key] = "" end
end
require("mp.options").read_options(conf, "auto_skip")

local function coerce(raw, like)
    local kind = type(like)
    if kind == "boolean" then
        local v = raw:lower()
        if v == "yes" or v == "true" then return true end
        if v == "no" or v == "false" then return false end
        return like
    elseif kind == "number" then
        return tonumber(raw) or like
    end
    return raw
end

-- The behaviour options of one source: its own override, else the global value.
local function behaviour(src)
    local out = {}
    for _, key in ipairs(BEHAVIOUR) do
        local raw = conf[src .. "_" .. key]
        if raw ~= nil and raw ~= "" then
            out[key] = coerce(tostring(raw), conf[key])
        else
            out[key] = conf[key]
        end
    end
    return out
end

------------------------------------------------------------------
-- Util
------------------------------------------------------------------
local util = {}
do
    -- filesystem, cache IO, async curl
    local utils = require("mp.utils")

    function util.nonempty(s)
        return (type(s) == "string" and s:match("%S+")) and s or nil
    end

    function util.expand_path(path)
        return mp.command_native({ "expand-path", path })
    end

    function util.mkdir_p(path)
        if not path or path == "" then return false end
        local info = utils.file_info(path)
        if info and info.is_dir then return true end
        local res = mp.command_native({
            name = "subprocess", playback_only = false, args = { "mkdir", "-p", path },
        })
        return res and res.status == 0
    end

    function util.read_file(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local content = f:read("*a")
        f:close()
        return content
    end

    function util.write_file(path, content)
        local f = io.open(path, "w")
        if not f then return false end
        f:write(content)
        f:close()
        return true
    end

    -- Async curl. callback(body, http_code); body is nil on any failure.
    -- log = optional { debug = fn, warn = fn }
    function util.curl(method, url, headers, body, callback, log)
        log = log or {}
        local args = { "curl", "--globoff", "-s", "-w", "\\n%{http_code}", "-X", method, url,
                       "-A", "Mozilla/5.0 (mpv-auto-skip/1.0)",
                       "--connect-timeout", "5", "--max-time", "15",
                       "--retry", "2", "--retry-delay", "1" }
        if headers then
            for k, v in pairs(headers) do
                table.insert(args, "-H"); table.insert(args, k .. ": " .. v)
            end
        end
        if body then table.insert(args, "-d"); table.insert(args, body) end

        if log.debug then log.debug(string.format("HTTP %s %s", method, url)) end
        mp.command_native_async({
            name = "subprocess", playback_only = false,
            capture_stdout = true, capture_stderr = true, args = args
        }, function(_, result)
            if not result then callback(nil, nil); return end
            if log.debug and result.stderr and result.stderr ~= "" then
                log.debug("curl stderr: " .. result.stderr)
            end

            local stdout = result.stdout or ""
            local body_str, http_code = stdout:match("(.*)\n(%d+)$")
            local code = tonumber(http_code)

            if result.status ~= 0 or not code or code < 200 or code >= 300 then
                if log.warn then
                    log.warn(string.format("HTTP %s failed (code=%s, status=%s)",
                        url, tostring(code), tostring(result.status)))
                end
                callback(nil, code)
                return
            end
            callback(body_str, code)
        end)
    end

    function util.trim_lower(text)
        return ((text or ""):lower():gsub("^%s*(.-)%s*$", "%1"))
    end

    -- "Opening, Ending" -> { opening = true, ending = true }
    function util.category_set(list)
        local set = {}
        for name in (list or ""):gmatch("[^,]+") do set[util.trim_lower(name)] = true end
        return set
    end

    -- Logger with a fixed prefix; debug lines print only while is_debug() is true.
    function util.logger(prefix, is_debug)
        return {
            debug = function(msg) if is_debug and is_debug() then mp.msg.info(prefix .. msg) end end,
            info  = function(msg) mp.msg.info(prefix .. msg) end,
            warn  = function(msg) mp.msg.warn(prefix .. msg) end,
        }
    end

    -- Small deterministic key that also works for non-ASCII titles.
    function util.cache_key(s)
        local hash = 5381
        s = s or ""
        for i = 1, #s do
            hash = (hash * 33 + s:byte(i)) % 4294967296
        end
        return string.format("%08x", hash)
    end

    -- True when the file exists and, if ttl_days is given, is younger than that.
    function util.cache_is_fresh(path, ttl_days)
        local info = utils.file_info(path)
        if not info then return false end
        if not ttl_days then return true end
        return (os.time() - (info.mtime or 0)) < (ttl_days * 86400)
    end

    -- Percent-encode a string for use in a URL query. Works byte by byte, so
    -- multibyte UTF-8 is encoded correctly (each byte becomes %XX).
    function util.url_encode(s)
        return (tostring(s):gsub("[^%w%-_%.~]", function(c)
            return string.format("%%%02X", c:byte())
        end))
    end
end

local cache_dirs = {}
-- ~~/cache/scripts/auto_skip/<name>/[sub/]  (created on first use)
local function cache_dir(name, sub)
    local key = name .. "/" .. (sub or "")
    if not cache_dirs[key] then
        local p = util.expand_path("~~/cache/scripts/auto_skip/" .. name .. "/" .. (sub and (sub .. "/") or ""))
        util.mkdir_p(p)
        cache_dirs[key] = p
    end
    return cache_dirs[key]
end

local log = util.logger("", function() return conf.debug end)

------------------------------------------------------------------
-- Shared state + chapters
------------------------------------------------------------------
local shared = {
    enabled = true,   -- master switch (toggle_key)
    force = false,    -- rescan in progress: ignore the caches and overwrite them
}

local chapters = {}
do
    -- The file's own chapters are never replaced: reset() snapshots them on file-load
    -- (original()), add() merges extra chapters in and keeps the list sorted.
    local base = {}

    local function copy(list)
        local out = {}
        for i, chapter in ipairs(list or {}) do
            local item = {}
            for k, v in pairs(chapter) do item[k] = v end
            out[i] = item
        end
        return out
    end

    function chapters.reset()
        base = copy(mp.get_property_native("chapter-list", {}))
    end

    function chapters.original()
        return base
    end

    -- Back to the file's own chapters (drops everything add() put in).
    function chapters.restore()
        mp.set_property_native("chapter-list", base)
    end

    function chapters.add(list)
        local merged = copy(mp.get_property_native("chapter-list", {}))
        for _, chapter in ipairs(list) do merged[#merged + 1] = chapter end
        table.sort(merged, function(x, y) return (x.time or 0) < (y.time or 0) end)
        mp.set_property_native("chapter-list", merged)
    end
end

------------------------------------------------------------------
-- Skip engine: seeks past the intervals of the chain's winning source
------------------------------------------------------------------
local skip = {}
do
    -- Driven by time-pos changes (no polling). Intervals that touch each other
    -- (Preview, then Intro) are skipped in one jump instead of two.
    local MERGE_GAP = 1.5   -- seconds
    local sources, source_order, entries = {}, {}, {}
    local skipped = {}      -- interval -> true, for skip_once
    local pending = nil     -- time a skip seek was issued; time-pos is ignored until it lands
    local observing = false

    local function skip_interval(first, o)
        skipped[first] = true
        local target, last, labels = first.end_time, first, { first.label }

        -- follow intervals that start where this one ends (or overlap it)
        local grew = true
        while grew do
            grew = false
            for _, e in ipairs(entries) do
                local iv = e.interval
                if iv.end_time > target and iv.start_time <= target + MERGE_GAP
                   and not (o.skip_once and skipped[iv]) then
                    skipped[iv] = true
                    target, last = iv.end_time, iv
                    labels[#labels + 1] = iv.label
                    grew = true
                    break
                end
            end
        end

        local duration = mp.get_property_number("duration", 0)
        local pl_count = mp.get_property_number("playlist-count", 1)
        local pl_pos   = mp.get_property_number("playlist-pos", 0)

        local is_ending = last.label == "Ending" or last.ending
        local is_near_end = duration > 0 and (duration - target) <= 3.0
        local has_next    = (pl_pos + 1) < pl_count

        if o.advance_on_ending and is_ending and is_near_end and has_next then
            mp.osd_message("Skipping to next episode...", 2)
            mp.commandv("playlist-next")
            return
        end

        pending = mp.get_time()
        mp.commandv("seek", tostring(target), "absolute+exact")
        if o.show_skip_feedback then
            mp.osd_message("Skipped " .. table.concat(labels, ", "), 1.5)
        end
    end

    local function on_time(_, time)
        if not time or not shared.enabled then return end
        if pending then
            if mp.get_time() - pending < 2 then return end
            pending = nil   -- the seek never reported back; stop waiting
        end
        for _, entry in ipairs(entries) do
            local interval, o = entry.interval, entry.src.opts
            if time >= interval.start_time and time < interval.end_time - 0.1
               and not (o.skip_once and skipped[interval]) then
                skip_interval(interval, o)
                return
            end
        end
    end

    mp.register_event("playback-restart", function() pending = nil end)

    -- Only observe time-pos while there is something to skip.
    local function rebuild()
        entries = {}
        for _, name in ipairs(source_order) do
            for _, interval in ipairs(sources[name].intervals) do
                entries[#entries + 1] = { interval = interval, src = sources[name] }
            end
        end
        if #entries > 0 and not observing then
            mp.observe_property("time-pos", "number", on_time)
            observing = true
        elseif #entries == 0 and observing then
            mp.unobserve_property(on_time)
            observing = false
        end
    end

    function skip.register(name, opts)
        if not sources[name] then source_order[#source_order + 1] = name end
        sources[name] = { name = name, opts = opts, intervals = {} }
    end

    function skip.set(name, intervals)
        if not sources[name] then return end
        sources[name].intervals = intervals or {}
        rebuild()
    end

    function skip.reset()
        for _, src in pairs(sources) do src.intervals = {} end
        skipped = {}
        pending = nil
        rebuild()
    end
end

------------------------------------------------------------------
-- Publish the shared API for the provider files
------------------------------------------------------------------
package.loaded["autoskip"] = {
    util = util, chapters = chapters, skip = skip, conf = conf, state = shared,
    behaviour = behaviour, cache_dir = cache_dir,
    logger = function(prefix)
        local l = util.logger(prefix, function() return conf.debug end)
        function l.curl(method, url, headers, body, callback)
            util.curl(method, url, headers, body, callback, { debug = l.debug, warn = l.warn })
        end
        return l
    end,
}

------------------------------------------------------------------
-- Provider chain
------------------------------------------------------------------
local MISS_TTL_DAYS = 1
local END_MERGE_WINDOW = 5       -- no "end" chapter if the next segment starts this close
local CHAPTER_DEDUPE_WINDOW = 2  -- online chapters this close to an existing one are dropped
local FILES = { ["local"] = "localchapters", aniskip = "aniskip", introdb = "theintrodb" }

local order, modules, category_sets = {}, {}, {}
for name in conf.priority:gmatch("[^,%s]+") do
    name = name:lower()
    if not FILES[name] then
        log.warn("unknown source in priority: '" .. name .. "' (use local, aniskip, introdb)")
    elseif not modules[name] then
        local ok, mod = pcall(require, FILES[name])
        if ok and type(mod) == "table" then
            modules[name] = mod
            order[#order + 1] = name
            category_sets[name] = util.category_set(conf[name .. "_categories"])
            skip.register(name, behaviour(name))
        else
            log.warn("could not load " .. FILES[name] .. ".lua: " .. tostring(mod))
        end
    end
end

local sponsorblock
if conf.sponsorblock then
    local ok, mod = pcall(require, "sponsorblock")
    if ok and type(mod) == "table" then
        sponsorblock = mod
        modules.sponsorblock = mod
        -- its labels are the category ids with spaces: music_offtopic -> "Music offtopic"
        category_sets.sponsorblock = util.category_set((conf.sponsorblock_categories:gsub("_", " ")))
        skip.register("sponsorblock", behaviour("sponsorblock"))
    else
        log.warn("could not load sponsorblock.lua: " .. tostring(mod))
    end
end

local function filter(intervals, name)
    local out = {}
    local set = category_sets[name]
    for _, iv in ipairs(intervals or {}) do
        if set[util.trim_lower(iv.label)] then out[#out + 1] = iv end
    end
    return out
end

-- Online sources also get chapter markers; the file's own chapters are never replaced.
-- `close` ({ Intro = "Episode" }) adds a chapter where such a segment ends, unless the
-- next segment starts within END_MERGE_WINDOW seconds. If the file has its own chapters,
-- that chapter keeps the original chapter's name (1, Sponsor, 1, 2) and the `close`
-- title is only the fallback for files without chapter titles.
local function dedupe_against(existing, additions)
    local function near(list, t)
        for _, c in ipairs(list) do
            if math.abs((c.time or 0) - (t or 0)) < CHAPTER_DEDUPE_WINDOW then return true end
        end
        return false
    end
    local out = {}
    for _, chapter in ipairs(additions) do
        if not near(existing, chapter.time) and not near(out, chapter.time) then
            out[#out + 1] = chapter
        end
    end
    return out
end

-- Title of the file's own chapter in effect at time t (nil if none / untitled).
local function original_title_at(t)
    local title
    for _, c in ipairs(chapters.original()) do
        if (tonumber(c.time) or 0) <= t + 0.001 then title = c.title else break end
    end
    return util.nonempty(title)
end

local function build_chapters(intervals, close)
    local list = {}
    for _, interval in ipairs(intervals) do list[#list + 1] = interval end
    table.sort(list, function(a, b) return a.start_time < b.start_time end)

    local out = {}
    for i, interval in ipairs(list) do
        out[#out + 1] = { title = interval.label, time = interval.start_time }

        local fallback = close and close[interval.label]
        if fallback then
            local closing = original_title_at(interval.end_time) or fallback
            local next_interval = list[i + 1]
            local abuts = next_interval
                and math.abs(next_interval.start_time - interval.end_time) < END_MERGE_WINDOW
            if not abuts then
                out[#out + 1] = { title = closing, time = interval.end_time }
            end
        end
    end
    table.sort(out, function(a, b) return a.time < b.time end)
    return out
end

local function apply_chapters(mod, intervals)
    local additions = build_chapters(intervals, mod.close)
    if #additions == 0 then return end
    chapters.add(dedupe_against(chapters.original(), additions))
end

local function parse_body(mod, body)
    local ok, intervals = pcall(mod.parse, body)
    if ok and type(intervals) == "table" then return intervals end
    return {}
end

-- cb(intervals | nil, reason, final)
local function run_provider(name, mod, alive, cb)
    if mod.applicable and not mod.applicable() then return cb(nil) end
    if mod.scan then return cb(mod.scan()) end

    local key = mod.cache_key and mod.cache_key() or mp.get_property("filename", "")
    local fname = (key:gsub("[/\\:*?\"<>|]", "_")):sub(1, 180)
    local dir_ = cache_dir(name)
    local hit_file, miss_file = dir_ .. fname .. ".json", dir_ .. fname .. ".miss"

    if not shared.force and util.cache_is_fresh(hit_file) then
        local intervals = parse_body(mod, util.read_file(hit_file) or "")
        if #intervals > 0 then
            log.debug(name .. ": cache hit")
            return cb(intervals)
        end
    end
    if not shared.force and util.cache_is_fresh(miss_file, MISS_TTL_DAYS) then
        return cb(nil, "cached miss (delete " .. miss_file .. " to retry)")
    end

    mod.fetch(function(body, reason, final)
        if not alive() then return end
        if not body then
            if final then
                os.remove(hit_file)   -- a confirmed "nothing" outranks an older hit
                util.write_file(miss_file, "")
            end
            return cb(nil, reason)
        end
        local intervals = parse_body(mod, body)
        if #intervals == 0 then
            os.remove(hit_file)
            util.write_file(miss_file, "")
            return cb(nil, "no markers in response")
        end
        os.remove(miss_file)
        util.write_file(hit_file, body)
        cb(intervals)
    end, alive)
end

local chain_token = 0

local function run_chain(token, sequence)
    local function alive() return token == chain_token end
    local tried = {}

    local function step(i)
        if not alive() then return end
        local name = sequence[i]
        if not name then
            if #tried > 0 then log.info("no skip markers found (tried " .. table.concat(tried, " > ") .. ")") end
            return
        end
        tried[#tried + 1] = name
        local mod = modules[name]
        local called = false

        local function got(intervals, reason)
            called = true
            if not alive() then return end
            local skippable = filter(intervals, name)
            if #skippable > 0 then
                log.info(string.format("%s: %d markers, %d skippable", name, #intervals, #skippable))
                skip.set(name, skippable)
                if mod.online then apply_chapters(mod, intervals) end
                return
            end
            if reason then
                log.info(name .. ": " .. tostring(reason):gsub("\n", " - "))
            elseif intervals then
                log.debug(name .. ": nothing in " .. conf[name .. "_categories"])
            end
            step(i + 1)
        end

        local ok, err = pcall(run_provider, name, mod, alive, got)
        if not ok then
            log.warn(name .. " failed: " .. tostring(err))
            if not called then step(i + 1) end
        end
    end

    step(1)
end

-- A new file, or a forced rescan of the current one (rescan = true).
local function begin_scan(rescan)
    mp.osd_message("")
    if rescan then chapters.restore() else chapters.reset() end
    skip.reset()
    shared.force = rescan
    chain_token = chain_token + 1

    -- A YouTube video is tried against SponsorBlock first. With a certain ID that is
    -- all; with a weak guess the priority list follows if the server has nothing.
    local sequence = order
    if sponsorblock then
        local id, strong = sponsorblock.detect()
        if id then
            sequence = { "sponsorblock" }
            if not strong then
                for _, name in ipairs(order) do sequence[#sequence + 1] = name end
            end
        end
    end
    run_chain(chain_token, sequence)
end

mp.register_event("file-loaded", function() begin_scan(false) end)

------------------------------------------------------------------
-- Rescan: look the current file up again, ignoring and replacing the caches
------------------------------------------------------------------
local function rescan()
    if not mp.get_property("path") then return end
    mp.osd_message("Auto-skip: rescanning", 1.5)
    begin_scan(true)
end

if conf.rescan_key ~= "" then
    mp.add_key_binding(conf.rescan_key, "auto-skip-rescan", rescan)
end
mp.register_script_message("auto-skip-rescan", rescan)

------------------------------------------------------------------
-- Master switch
------------------------------------------------------------------
local function set_enabled(value)
    if shared.enabled == value then return end
    shared.enabled = value
    mp.osd_message("Auto-skip " .. (value and "enabled" or "disabled"), 1.5)
end

if conf.toggle_key ~= "" then
    mp.add_key_binding(conf.toggle_key, "auto-skip-toggle", function() set_enabled(not shared.enabled) end)
end
mp.register_script_message("auto-skip-toggle", function(val)
    if val == "yes" or val == "true" then set_enabled(true)
    elseif val == "no" or val == "false" then set_enabled(false)
    else set_enabled(not shared.enabled) end
end)
