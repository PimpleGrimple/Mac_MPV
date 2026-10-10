--[[
    auto-skip/main.lua
    One mpv script that hosts skip providers (one file per site/API).

      main.lua          shared helpers (util, chapters) + lifecycle
      aniskip.lua       AniSkip API (anime OP/ED/recap), online
      theintrodb.lua    TheIntroDB (TV/movie intro/recap/credits/preview), online
      localchapters.lua skips chapters by title (Opening/Ending/Preview/Intro/Misc), offline
      sponsorblock.lua  SponsorBlock (YouTube)
      sponsorblock.py   network helper used by sponsorblock.lua

    A provider is a module returning a table with:
      setup()           optional, called once: register keybinds, timers, observers
      on_file_loaded()  called for every file, after the shared reset

    Providers get the shared helpers with:  local core = require("autoskip")
      core.util      fs / cache / curl helpers
      core.chapters  chapter-list manager (one named layer per provider)
      core.skip      skip button / auto-skip engine (providers just supply intervals)
      core.remote    plumbing for online providers: cache, toggle key, chapters, stale-callback
                     guard. A provider is then just  applicable / fetch / parse  (see the
                     "remote provider plumbing" section; aniskip.lua is the shortest example)

    To add another site (IntroDB, Jellyfin segments, ...): drop a file next to this
    one and add its name to PROVIDERS below. A provider that errors is logged and
    skipped; it can't take the others down.
]]
local mp = require("mp")

local dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = dir .. "?.lua;" .. package.path

------------------------------------------------------------------
-- Shared: util
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

    function util.file_exists(path)
        return utils.file_info(path) ~= nil
    end

    function util.file_mtime(path)
        local info = utils.file_info(path)
        return info and info.mtime
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
                       "-A", "Mozilla/5.0 (mpv-aniskip/1.0)",
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

    -- ttl_days = 0 means "never expires".
    function util.cache_is_fresh(path, ttl_days)
        if ttl_days == 0 then return true end
        local mt = util.file_mtime(path)
        if not mt then return false end
        return (os.time() - mt) < (ttl_days * 86400)
    end

    -- Percent-encode a string for use in a URL query. Works byte by byte, so
    -- multibyte UTF-8 is encoded correctly (each byte becomes %XX).
    function util.url_encode(s)
        return (tostring(s):gsub("[^%w%-_%.~]", function(c)
            return string.format("%%%02X", c:byte())
        end))
    end

    -- Release-name cleanup shared by providers that parse filenames.
    local QUALITY_TAGS = {
        "1080p","720p","2160p","480p","4k","uhd","web%-dl","webrip","web","bluray","bdrip","bd","hdtv",
        "hevc","h%.?264","x264","x265","avc","aac","ac3","flac","eac3","ddp?5%.1","hdr","dv","10bit","8bit",
        "multi","dual","subs?","dub","batch","repack","proper","extended","uncensored",
    }

    function util.strip_quality_tags(s)
        local lower = s:lower()
        for _, tag in ipairs(QUALITY_TAGS) do
            lower = lower:gsub("[%s%._%-%[%]%(%)]" .. tag .. "[%s%._%-%[%]%(%)]", " ")
        end
        lower = lower:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        return lower
    end
end

------------------------------------------------------------------
-- Shared: chapters
-- Providers never write "chapter-list" directly. Each owns a named layer; this
-- composes   the file's own chapters + all layers   and writes the result, so
-- providers can't overwrite each other and a layer can be removed cleanly.
------------------------------------------------------------------
local chapters = {}
do
    --   chapters.reset()                  -- on file-loaded: snapshot the file's own chapters
    --   chapters.refresh()                -- re-snapshot if no layer is applied
    --   chapters.original()               -- copy of that snapshot
    --   chapters.set(name, list, opts)    -- add/replace a layer; opts.replace = true drops the originals
    --   chapters.clear(name)              -- remove a layer

    local EPS = 0.001
    local base = {}      -- the file's own chapters
    local layers = {}    -- name -> { list = {...}, replace = bool }
    local order = {}     -- layer names in insertion order
    local applied = nil  -- last list we wrote
    local ours = {}      -- keys of chapters we wrote

    local function copy(list)
        local out = {}
        for i, chapter in ipairs(list or {}) do
            local item = {}
            for k, v in pairs(chapter) do item[k] = v end
            out[i] = item
        end
        return out
    end

    local function key(c)
        return string.format("%.3f|%s", c.time or 0, c.title or "")
    end

    local function same(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do
            if math.abs((a[i].time or 0) - (b[i].time or 0)) > EPS
               or (a[i].title or "") ~= (b[i].title or "") then
                return false
            end
        end
        return true
    end

    local function is_end(c)
        return (c.title or ""):find("segment end", 1, true) ~= nil
    end

    local function current_list()
        return mp.get_property_native("chapter-list", {}) or {}
    end

    local function recompose()
        -- If something else edited the list since our last write, keep its edits
        -- as the new base (minus our own entries) instead of clobbering them.
        local current = current_list()
        if not applied then
            -- Nothing of ours is applied: whatever is there now is the base.
            base = copy(current)
        elseif not same(current, applied) then
            local rebased = {}
            for _, c in ipairs(current) do
                if not ours[key(c)] then rebased[#rebased + 1] = c end
            end
            base = copy(rebased)
        end

        local replace = false
        for _, name in ipairs(order) do
            if layers[name].replace then replace = true; break end
        end

        local items, seq = {}, 0
        local function push(c) seq = seq + 1; items[#items + 1] = { c = c, seq = seq } end

        if not replace then
            for _, c in ipairs(base) do push(c) end
        end
        ours = {}
        for _, name in ipairs(order) do
            for _, c in ipairs(layers[name].list) do
                push(c)
                ours[key(c)] = true
            end
        end

        table.sort(items, function(a, b)
            local ta, tb = a.c.time or 0, b.c.time or 0
            if ta ~= tb then return ta < tb end
            local ea, eb = is_end(a.c), is_end(b.c)
            if ea ~= eb then return ea end   -- a segment's end sorts before the next start
            return a.seq < b.seq
        end)

        local merged = {}
        for _, it in ipairs(items) do merged[#merged + 1] = it.c end
        mp.set_property_native("chapter-list", merged)
        applied = (#order > 0) and copy(merged) or nil
        if #order == 0 then ours = {} end
    end

    function chapters.reset()
        base = copy(current_list())
        layers, order, applied, ours = {}, {}, nil, {}
    end

    -- Re-read the file's chapters as the new base, but only while no layer is
    -- applied: with a layer on the list, "current" would contain our own entries.
    -- Online providers call this when (re)initialising mid-file, e.g. on toggle,
    -- so a chapter list changed since file-load is picked up.
    function chapters.refresh()
        if not applied then base = copy(current_list()) end
    end

    function chapters.original()
        return copy(base)
    end

    function chapters.set(name, list, opts)
        if not layers[name] then order[#order + 1] = name end
        layers[name] = { list = copy(list), replace = (opts and opts.replace) or false }
        recompose()
    end

    function chapters.clear(name)
        if not layers[name] then return end
        layers[name] = nil
        for i, n in ipairs(order) do
            if n == name then table.remove(order, i); break end
        end
        recompose()
    end
end

------------------------------------------------------------------
-- Shared: skip engine
-- Providers hand over intervals ({start_time, end_time, label}); this owns the
-- on-screen button, auto-skip, "Skipped X" feedback and next-episode logic, so
-- every provider behaves the same. Behaviour options (auto_skip, skip_once,
-- advance_on_ending, show_skip_button, show_skip_feedback, skip_key, timeout,
-- accent_color) are read live from each provider's own options table, so the
-- provider can change them at runtime; values from script-opts/*.conf are
-- applied once, at load.
--
--   skip.register(name, opts)       once, at provider setup
--   skip.set(name, intervals)       replace that provider's skippable intervals
--   skip.clear(name)                drop them
--   skip.reset()                    on file-loaded (main.lua does this)
-- An interval with  ending = true  (or label "Ending") advances the playlist
-- when it runs to the end of the file and advance_on_ending is on.
------------------------------------------------------------------
local skip = {}
do
    local function hex_to_ass_bgr(hex)
        hex = (hex or ""):gsub("^[#!]", "")
        if not hex:match("^%x%x%x%x%x%x$") then return "FA8BA7" end
        return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
    end


    local accent_cache = {}
    local function accent_of(o)
        local hex = o.accent_color
        local c = accent_cache[hex]
        if not c then c = hex_to_ass_bgr(hex); accent_cache[hex] = c end
        return c
    end

    local SCREEN_W, SCREEN_H = 1920, 1080
    local EDGE_MARGIN_Y = 66
    local BTN_H, BTN_R, BTN_FS = 36, 10, 18
    local EDGE_BAR_W = 6
    local PANEL_W = 194
    local BTN_W = PANEL_W + EDGE_BAR_W
    local BTN_X, BTN_Y = 0, EDGE_MARGIN_Y
    local HOVER_PAD_X, HOVER_PAD_Y = 70, 40
    local SLIDE_DURATION = 0.4

    local function clear_osd() mp.set_osd_ass(SCREEN_W, SCREEN_H, "") end

    local function get_mouse_in_ref_space()
        local mx, my = mp.get_mouse_pos()
        if not mx or not my then return nil, nil end
        local osd_w, osd_h = mp.get_osd_size()
        if not osd_w or osd_w == 0 or not osd_h or osd_h == 0 then return nil, nil end
        return mx * (SCREEN_W / osd_w), my * (SCREEN_H / osd_h)
    end


    local function rounded_rect_right(w, h, r)
        return table.concat({
            "m 0 0",
            string.format("l %d 0", w - r),
            string.format("b %d 0 %d 0 %d %d", w, w, w, r),
            string.format("l %d %d", w, h - r),
            string.format("b %d %d %d %d %d %d", w, h, w, h, w - r, h),
            string.format("l 0 %d", h),
            "l 0 0",
        }, " ")
    end

    local function rounded_rect_left(w, h, r)
        return table.concat({
            string.format("m %d 0", r),
            string.format("l %d 0", w),
            string.format("l %d %d", w, h),
            string.format("l %d %d", r, h),
            string.format("b 0 %d 0 %d 0 %d", h, h, h - r),
            string.format("l 0 %d", r),
            string.format("b 0 0 0 0 %d 0", r),
        }, " ")
    end

    local function draw_panel(x, bg_alpha, scale)
        return string.format(
            "{\\an7}{\\pos(%d,%d)}{\\p1}{\\bord0}{\\shad0}{\\fscx%d}{\\fscy%d}{\\1c&H1A1A1A&}{\\1a&H%s&}%s{\\p0}",
            x, BTN_Y, scale, scale, bg_alpha, rounded_rect_left(PANEL_W, BTN_H, BTN_R))
    end

    local function draw_accent(x, scale, accent)
        return string.format(
            "{\\an7}{\\pos(%d,%d)}{\\p1}{\\bord0}{\\shad0}{\\fscx%d}{\\fscy%d}{\\1c&H%s&}{\\1a&H00&}%s{\\p0}",
            x, BTN_Y, scale, scale, accent, rounded_rect_right(EDGE_BAR_W, BTN_H, 3))
    end

    local function ease(t) return t * t * (3 - 2 * t) end

    local function draw_button(label, remaining, is_hovering, progress, accent)
        local slide = -(1 - ease(progress)) * PANEL_W
        local base_x = BTN_X + slide
        local scale = (progress >= 0.999 and is_hovering) and 104 or 100
        local bg_alpha = is_hovering and "20" or "48"

        local parts = {}
        if progress > 0.02 then
            table.insert(parts, draw_panel(base_x, bg_alpha, scale))
        end
        table.insert(parts, draw_accent(base_x + PANEL_W, scale, accent))
        if progress > 0.15 then
            local text = string.format(
                "{\\an4}{\\pos(%d,%d)}{\\fnsans-serif}{\\fs%d}{\\bord0}{\\shad0}{\\1c&HFFFFFF&}Skip %s  {\\1c&H%s&}•  {\\1c&HFFFFFF&}%ds",
                base_x + 16, BTN_Y + BTN_H / 2, BTN_FS, label, accent, remaining)
            table.insert(parts, text)
        end
        mp.set_osd_ass(SCREEN_W, SCREEN_H, table.concat(parts, "\n"))
    end

    local function draw_feedback(label, accent)
        local panel = draw_panel(BTN_X, "48", 100)
        local accent = draw_accent(BTN_X + PANEL_W, 100, accent)
        local text = string.format(
            "{\\an4}{\\pos(%d,%d)}{\\fnsans-serif}{\\fs%d}{\\bord0}{\\shad0}{\\1c&HFFFFFF&}Skipped %s",
            BTN_X + 16, BTN_Y + BTN_H / 2, BTN_FS, label)
        mp.set_osd_ass(SCREEN_W, SCREEN_H, panel .. "\n" .. accent .. "\n" .. text)
    end


    local sources, source_order, entries = {}, {}, {}

    local state = {
        key_bound = false,
        mouse_bound = false,
        active_interval = nil,
        active_src = nil,
        is_skipping = false,
        timer = nil,
        skipped_intervals = {},
        expanded = true,
        shown_since = nil,
        progress = 1,
        last_wall = nil,
        last_visual_x = BTN_X,
    }

    local skip_action  -- forward declaration

    local function unbind_keys()
        if state.key_bound then
            mp.remove_key_binding("skip-action"); state.key_bound = false
        end
        if state.mouse_bound then
            mp.remove_key_binding("skip-mouse-action"); state.mouse_bound = false
        end
    end

    local function kill_skip_timer()
        if state.timer then
            state.timer:kill(); state.timer = nil
        end
    end

    local function is_hovering_near()
        local tx, ty = get_mouse_in_ref_space()
        if not tx then return false end
        return tx < BTN_X + BTN_W + HOVER_PAD_X and ty < BTN_Y + BTN_H + HOVER_PAD_Y
    end

    local function is_over_button()
        local tx, ty = get_mouse_in_ref_space()
        if not tx then return false end
        return tx >= state.last_visual_x
           and tx <= state.last_visual_x + BTN_W
           and ty >= BTN_Y and ty <= BTN_Y + BTN_H
    end

    local function bind_mouse_if_needed(active)
        if active and not state.mouse_bound then
            mp.add_forced_key_binding("MBTN_LEFT", "skip-mouse-action",
                function() if skip_action then skip_action() end end)
            state.mouse_bound = true
        elseif not active and state.mouse_bound then
            mp.remove_key_binding("skip-mouse-action")
            state.mouse_bound = false
        end
    end

    skip_action = function()
        if not state.active_interval or state.is_skipping then return end
        state.is_skipping = true
        state.skipped_intervals[state.active_interval] = true

        local o = state.active_src.opts
        local duration = mp.get_property_number("duration", 0)
        local pl_count = mp.get_property_number("playlist-count", 1)
        local pl_pos   = mp.get_property_number("playlist-pos", 0)

        local is_ending = state.active_interval.label == "Ending" or state.active_interval.ending
        local is_near_end = duration > 0 and (duration - state.active_interval.end_time) <= 3.0
        local has_next    = (pl_pos + 1) < pl_count

        if o.advance_on_ending and is_ending and is_near_end and has_next then
            mp.osd_message("Skipping to next episode...", 2)
            unbind_keys()
            state.is_skipping = false
            clear_osd()
            mp.commandv("playlist-next")
            return
        end

        mp.set_property_number("time-pos", state.active_interval.end_time)
        if o.show_skip_feedback then draw_feedback(state.active_interval.label, accent_of(o)) end
        unbind_keys()
        kill_skip_timer()
        state.timer = mp.add_timeout(2.0, function()
            state.is_skipping = false
            clear_osd()
        end)
    end

    local rebuild
    rebuild = function()
        entries = {}
        for rank, name in ipairs(source_order) do
            for _, interval in ipairs(sources[name].intervals) do
                entries[#entries + 1] = { interval = interval, src = sources[name], rank = rank }
            end
        end
    end

    -- Is `b` just a second description of what `a` already covers? Same label
    -- starting within 5s, or the two overlap by at least half of the shorter one.
    local function redundant(a, b)
        local overlap = math.min(a.end_time, b.end_time) - math.max(a.start_time, b.start_time)
        if overlap <= 0 then return false end
        if (a.label or ""):lower() == (b.label or ""):lower()
           and math.abs(a.start_time - b.start_time) < 5 then
            return true
        end
        local shorter = math.min(a.end_time - a.start_time, b.end_time - b.start_time)
        return overlap >= 0.5 * shorter
    end

    -- Providers are ranked by registration order (PROVIDERS list). When a
    -- higher-ranked provider already has the same segment, the lower one is ignored,
    -- so e.g. AniSkip's timings win over a matching chapter title, with no double skip.
    local function covered_by_higher(entry)
        for _, other in ipairs(entries) do
            if other.rank < entry.rank
               and (other.src.opts.auto_skip or other.src.opts.show_skip_button)
               and redundant(other.interval, entry.interval) then
                return true
            end
        end
        return false
    end

    local function any_enabled()
        for _, src in pairs(sources) do
            if src.opts.auto_skip or src.opts.show_skip_button then return true end
        end
        return false
    end

    local function on_tick()
        if not any_enabled() then
            if state.active_interval or state.key_bound or state.mouse_bound then
                state.active_interval = nil
                state.active_src = nil
                state.progress = 1
                state.expanded = true
                clear_osd()
                unbind_keys()
            end
            return
        end

        if state.is_skipping then return end

        local time = mp.get_property_number("time-pos")
        local now = mp.get_time()
        local dt = state.last_wall and math.min(now - state.last_wall, 0.5) or 0
        state.last_wall = now

        if not time or time < 0.5 then return end

        local active, active_src = nil, nil
        for _, entry in ipairs(entries) do
            local interval, o = entry.interval, entry.src.opts
            if (o.auto_skip or o.show_skip_button)
               and time >= interval.start_time and time < interval.end_time then
                if not (o.skip_once and state.skipped_intervals[interval])
                   and not covered_by_higher(entry) then
                    active, active_src = interval, entry.src; break
                end
            end
        end

        if active then
            local o = active_src.opts
            if state.active_interval ~= active then
                state.active_interval = active
                state.active_src = active_src
                state.shown_since = time
                state.expanded = true
                state.progress = 1
            end

            if o.auto_skip then skip_action(); return end

            if o.show_skip_button then
                local hovering = is_hovering_near()
                if hovering then
                    state.expanded = true
                elseif (time - state.shown_since) > o.timeout then
                    state.expanded = false
                end

                local target = state.expanded and 1 or 0
                local step = dt / SLIDE_DURATION
                if state.progress < target then
                    state.progress = math.min(target, state.progress + step)
                elseif state.progress > target then
                    state.progress = math.max(target, state.progress - step)
                end

                local slide = -(1 - ease(state.progress)) * PANEL_W
                state.last_visual_x = BTN_X + slide

                draw_button(active.label, math.ceil(active.end_time - time), hovering, state.progress, accent_of(o))
                bind_mouse_if_needed(state.progress >= 0.999 and is_over_button())

                if not state.key_bound then
                    mp.add_forced_key_binding(o.skip_key, "skip-action",
                        function() skip_action() end)
                    state.key_bound = true
                end
            end
        else
            if state.active_interval then
                state.active_interval = nil
                state.active_src = nil
                clear_osd()
                unbind_keys()
            end
        end
    end

    function skip.register(name, opts)
        if not sources[name] then source_order[#source_order + 1] = name end
        sources[name] = { name = name, opts = opts, intervals = {} }
    end

    function skip.set(name, intervals)
        sources[name].intervals = intervals or {}
        rebuild()
    end

    function skip.clear(name)
        if sources[name] then skip.set(name, {}) end
    end

    function skip.reset()
        kill_skip_timer()
        unbind_keys()
        clear_osd()
        for _, src in pairs(sources) do src.intervals = {} end
        entries = {}
        state.active_interval = nil
        state.active_src = nil
        state.is_skipping = false
        state.skipped_intervals = {}
        state.last_visual_x = BTN_X
        state.last_wall = nil
        state.progress = 1
        state.expanded = true
    end

    mp.add_periodic_timer(0.05, on_tick)
end

------------------------------------------------------------------
-- Shared: remote provider plumbing
-- Online providers (aniskip, theintrodb) only differ in how they identify a
-- file, fetch, and parse. Everything else lives here: cache, stale-callback
-- guard, publishing intervals to the skip engine, chapters, toggle key.
--
--   local R = remote.new{ name, prefix, label, opts, close, toggle_message }
--   R.log.debug/info/warn    R.curl(method, url, headers, body, cb)
--   R.cache_dir()            R.id_map_dir()
--   return R.install{
--       applicable = function() ... end,        -- optional; false = silently skip this file
--       fetch      = function(done, alive) ... end,
--           done(body)  |  done(nil, "reason shown on screen")  |  done(nil, false) = silent
--           alive() is false once the file changed or the toggle was switched off
--       parse      = function(body) ... end,    -- -> list of { start_time, end_time, label[, ending] }
--   }
--
-- The fetched body is cached verbatim, per filename, for opts.cache_ttl_days.
-- `close` ({ Intro = "Episode" }) adds a chapter where such a segment ends,
-- unless the next segment starts within END_MERGE_WINDOW seconds.
------------------------------------------------------------------
local remote = {}
do
    local END_MERGE_WINDOW = 5      -- no "end" chapter if the next segment starts this close
    local CHAPTER_DEDUPE_WINDOW = 2 -- online chapters this close to an existing one are dropped

    -- Drop additions within the window of an existing chapter (or an earlier addition).
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

    function remote.new(spec)
        local name, opts, prefix = spec.name, spec.opts, spec.prefix
        local R = {}
        local state = { intervals = {}, token = 0 }
        local categories = util.category_set(opts.skip_categories)

        R.log = util.logger(prefix, function() return opts.debug end)

        function R.curl(method, url, headers, body, callback)
            util.curl(method, url, headers, body, callback, { debug = R.log.debug, warn = R.log.warn })
        end

        function R.cache_dir()
            local dir = util.expand_path("~~/cache/scripts/" .. name .. "/")
            util.mkdir_p(dir)
            return dir
        end

        function R.id_map_dir()
            local dir = R.cache_dir() .. "idmap/"
            util.mkdir_p(dir)
            return dir
        end

        -- Hand the skippable intervals to the shared skip engine.
        local function publish()
            local skippable = {}
            for _, interval in ipairs(state.intervals) do
                if categories[util.trim_lower(interval.label)] then
                    skippable[#skippable + 1] = interval
                end
            end
            skip.set(name, skippable)
        end

        local function build_chapters()
            local list = {}
            for _, interval in ipairs(state.intervals) do list[#list + 1] = interval end
            table.sort(list, function(a, b) return a.start_time < b.start_time end)

            local out = {}
            for i, interval in ipairs(list) do
                out[#out + 1] = { title = interval.label, time = interval.start_time }

                local closing = spec.close and spec.close[interval.label]
                if closing then
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

        local function apply_chapters()
            local additions = build_chapters()
            if #additions == 0 then return end

            if opts.override_chapters then
                chapters.set(name, additions, { replace = true })
            else
                chapters.set(name, dedupe_against(chapters.original(), additions))
            end
        end

        function R.install(impl)
            local function initialize()
                state.token = state.token + 1
                local token = state.token
                local function alive() return token == state.token and not not opts.online_fetch end

                state.intervals = {}
                skip.clear(name)
                chapters.clear(name)
                chapters.refresh()

                if not opts.online_fetch then return end
                if impl.applicable and not impl.applicable() then return end

                local fname = (mp.get_property("filename", ""):gsub("[/\\:*?\"<>|]", "_"))
                local cache_file = R.cache_dir() .. fname .. ".json"

                local function intervals_of(body)
                    local ok, list = pcall(impl.parse, body)
                    return (ok and type(list) == "table") and list or {}
                end

                local function accept(intervals, note)
                    state.intervals = intervals
                    R.log.info(string.format("Loaded %d %s markers%s.",
                        #intervals, spec.label or name, note or ""))
                    publish()
                    apply_chapters()
                end

                local function failed(msg)
                    if msg ~= false and opts.show_failed_osd then
                        mp.osd_message(prefix .. (msg or "No online markers found"), 2.5)
                    end
                end

                if util.file_exists(cache_file) and util.cache_is_fresh(cache_file, opts.cache_ttl_days) then
                    local content = util.read_file(cache_file)
                    local intervals = content and intervals_of(content) or {}
                    if #intervals > 0 then
                        accept(intervals, " (cached)")
                        return
                    end
                end

                impl.fetch(function(body, reason)
                    if not alive() then return end
                    if not body then failed(reason); return end

                    local intervals = intervals_of(body)
                    if #intervals == 0 then failed(); return end

                    util.write_file(cache_file, body)
                    accept(intervals)
                end, alive)
            end

            local function set_online_fetch(value)
                value = not not value
                if opts.online_fetch == value then return end
                opts.online_fetch = value

                initialize() -- also invalidates any pending HTTP callbacks

                mp.osd_message(prefix .. "Online fetch "
                    .. (value and "enabled" or "disabled"), 1.5)
            end

            return {
                setup = function()
                    skip.register(name, opts)

                    mp.register_script_message(spec.toggle_message or (name .. "-toggle-state"), function(val)
                        set_online_fetch(val == "true")
                    end)

                    mp.add_key_binding(opts.toggle_key, name .. "-toggle", function()
                        set_online_fetch(not opts.online_fetch)
                    end)
                end,
                on_file_loaded = initialize,
            }
        end

        return R
    end
end

package.loaded["autoskip"] = { util = util, chapters = chapters, skip = skip, remote = remote }

------------------------------------------------------------------
-- Providers + lifecycle
------------------------------------------------------------------
-- Order matters for skipping: earlier providers win when two describe the same segment.
local PROVIDERS = { "aniskip", "theintrodb", "localchapters", "sponsorblock" }

local loaded = {}
for _, name in ipairs(PROVIDERS) do
    local ok, mod = pcall(require, name)
    if not ok then
        mp.msg.error(("provider '%s' failed to load: %s"):format(name, tostring(mod)))
    else
        if mod.setup then
            local ok_setup, err = pcall(mod.setup)
            if not ok_setup then
                mp.msg.error(("provider '%s' setup failed: %s"):format(name, tostring(err)))
            end
        end
        loaded[#loaded + 1] = { name = name, mod = mod }
    end
end

mp.register_event("file-loaded", function()
    -- Hide any OSD message left over from the previous file ("sponsor skipped", etc.)
    mp.osd_message("")

    -- Snapshot the new file's own chapters before any provider adds layers,
    -- and clear the skip button / intervals left over from the previous file.
    chapters.reset()
    skip.reset()

    for _, p in ipairs(loaded) do
        if p.mod.on_file_loaded then
            local ok, err = pcall(p.mod.on_file_loaded)
            if not ok then
                mp.msg.error(("provider '%s' failed: %s"):format(p.name, tostring(err)))
            end
        end
    end
end)
