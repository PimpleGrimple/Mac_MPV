local mp = require("mp")
local utils = require("mp.utils")

------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------
local opts = {
    -- Core behavior
    online_fetch        = false,
    auto_skip           = true,
    skip_once           = true,
    advance_on_ending   = true,

    -- Skip UI
    -- Set auto_skip=false to use the optional on-screen skip button.
    show_skip_button    = false,
    show_skip_feedback  = true,
    skip_key            = "ENTER",
    timeout             = 5,
    toggle_key          = "alt+s",
    accent_color        = "A78BFA",
    show_failed_osd     = true,

    -- Chapter categories to skip. Case-insensitive, comma-separated.
    skip_categories     = "Opening,Ending,Preview,Intro,Misc",

    -- Local chapter-title matching.
    -- Words are exact, case-insensitive matches.
    -- Patterns use Lua pattern syntax, not regular expressions.
    -- Add any personal one-off titles to Misc.
    opening_words       = {
        "opening", "op", "ncop", "theme song", "main theme",
        "オープニング", "主題歌",
    },
    opening_patterns    = {
        "^%s*op%s*%d+%s*$",
        "^%s*opening%s*%d+%s*$",
    },

    ending_words        = {
        "ending", "ed", "nced", "credits", "outro", "end roll",
        "エンディング", "結び",
    },
    ending_patterns     = {
        "^%s*ed%s*%d+%s*$",
        "^%s*ending%s*%d+%s*$",
    },

    preview_words       = {
        "preview", "pv", "trailer", "next episode",
        "予告", "次回予告", "jikai", "yokoku",
    },
    preview_patterns    = {
        "^%s*pv%s*%d+%s*$",
    },

    intro_words         = {
        "intro", "introduction", "prologue", "cold open",
        "アバン", "アバンタイトル", "序章",
    },
    intro_patterns      = {},

    misc_words          = {},
    misc_patterns       = {},

    -- Chapter display and cache
    override_chapters   = false,
    cache_ttl_days      = 30,

    debug               = false,
}

------------------------------------------------------------------
-- Logging
------------------------------------------------------------------
local LOG_PREFIX = "[aniskip] "

local function log_debug(msg)
    if opts.debug then mp.msg.info(LOG_PREFIX .. msg) end
end
local function log_info(msg)  mp.msg.info(LOG_PREFIX .. msg) end
local function log_warn(msg)  mp.msg.warn(LOG_PREFIX .. msg) end

------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------
local function nonempty(s)
    return (type(s) == "string" and s:match("%S+")) and s or nil
end

local function file_exists(path)
    return utils.file_info(path) ~= nil
end

local function file_mtime(path)
    local info = utils.file_info(path)
    return info and info.mtime
end

local function mkdir_p(path)
    if not path or path == "" then return false end
    local info = utils.file_info(path)
    if info and info.is_dir then return true end
    local res = utils.subprocess({ args = { "mkdir", "-p", path }, playback_only = false })
    return res and res.status == 0
end

local function cache_dir()
    local base = mp.command_native({ "expand-path", "~~/cache/scripts/aniskip/" })
    mkdir_p(base)
    return base
end

local function id_map_dir()
    local d = cache_dir() .. "idmap/"
    mkdir_p(d)
    return d
end

local function cache_key(s)
    -- Small deterministic key that also works for non-ASCII titles.
    local hash = 5381
    s = s or ""
    for i = 1, #s do
        hash = (hash * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

------------------------------------------------------------------
-- Color helpers
------------------------------------------------------------------
local function hex_to_ass_bgr(hex)
    hex = (hex or ""):gsub("^[#!]", "")
    if not hex:match("^%x%x%x%x%x%x$") then return "FA8BA7" end
    return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end

local ACCENT_COLOR = hex_to_ass_bgr(opts.accent_color)

------------------------------------------------------------------
-- Category matching
------------------------------------------------------------------
local categories = {
    { label = "Opening", words = opts.opening_words, patterns = opts.opening_patterns },
    { label = "Ending",  words = opts.ending_words,  patterns = opts.ending_patterns  },
    { label = "Preview", words = opts.preview_words, patterns = opts.preview_patterns },
    { label = "Intro",   words = opts.intro_words,   patterns = opts.intro_patterns   },
    { label = "Misc",    words = opts.misc_words,    patterns = opts.misc_patterns    },
}

local function trim_lower(text)
    return (text or ""):lower():gsub("^%s*(.-)%s*$", "%1")
end

local function get_chapter_label(title)
    if not title then return nil end
    local t = trim_lower(title)

    for _, cat in ipairs(categories) do
        for _, word in ipairs(cat.words) do
            if t == trim_lower(word) then return cat.label end
        end
        for _, pattern in ipairs(cat.patterns) do
            if t:find(pattern) then return cat.label end
        end
    end
    return nil
end

local skip_categories_set = {}
for name in opts.skip_categories:gmatch("[^,]+") do
    skip_categories_set[trim_lower(name)] = true
end

------------------------------------------------------------------
-- OSD geometry (reference space: 1920x1080)
------------------------------------------------------------------
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

------------------------------------------------------------------
-- HTTP
------------------------------------------------------------------
local function curl(method, url, headers, body, callback)
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

    log_debug(string.format("HTTP %s %s", method, url))
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true, args = args
    }, function(_, result)
        if not result then callback(nil, nil); return end
        if result.stderr and result.stderr ~= "" then log_debug("curl stderr: " .. result.stderr) end

        local stdout = result.stdout or ""
        local body_str, http_code = stdout:match("(.*)\n(%d+)$")
        local code = tonumber(http_code)

        if result.status ~= 0 or not code or code < 200 or code >= 300 then
            log_warn(string.format("HTTP %s failed (code=%s, status=%s)",
                url, tostring(code), tostring(result.status)))
            callback(nil, code)
            return
        end
        callback(body_str, code)
    end)
end

------------------------------------------------------------------
-- Filename parsing
------------------------------------------------------------------
local QUALITY_TAGS = {
    "1080p","720p","2160p","480p","4k","uhd","web%-dl","webrip","web","bluray","bdrip","bd","hdtv",
    "hevc","h%.?264","x264","x265","avc","aac","ac3","flac","eac3","ddp?5%.1","hdr","dv","10bit","8bit",
    "multi","dual","subs?","dub","batch","repack","proper","extended","uncensored",
}

local function strip_quality_tags(s)
    local lower = s:lower()
    for _, tag in ipairs(QUALITY_TAGS) do
        lower = lower:gsub("[%s%._%-%[%]%(%)]" .. tag .. "[%s%._%-%[%]%(%)]", " ")
    end
    lower = lower:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return lower
end

local function parse_filename(filename)
    if not filename then return nil, nil end
    local clean = filename:gsub("%.%w+$", ""):gsub("%b[]", " "):gsub("%b()", " ")
    clean = clean:gsub("[%._]", " "):gsub("%s+", " ")
    clean = strip_quality_tags(clean)

    local title, ep = clean:match("^(.-)%s+[Ss]%d+[Ee](%d+)")
    if title and ep then
        return title:gsub("^%s*(.-)%s*$", "%1"), tonumber(ep)
    end
    title, ep = clean:match("^(.-)%s+[Ee][Pp][%.%s]*(%d+)")
    if not title or not ep then
        title, ep = clean:match("^(.-)%s+[Ee][Pp][Ii][Ss][Oo][Dd][Ee]%s*(%d+)")
    end
    if not title or not ep then
        title, ep = clean:match("^(.-)%s+%-%s+(%d+)")
    end
    if not title or not ep then
        local padded = " " .. clean .. " "
        for word in padded:gmatch("%s(%d+)%s") do
            local num = tonumber(word)
            if num and num < 2000 then
                local idx = padded:find(" " .. word .. " ", 1, true)
                if idx then title, ep = padded:sub(2, idx - 1), num end
            end
        end
    end

    if title and ep then
        title = title:gsub("[%-%s]+$", ""):gsub("^%s*(.-)%s*$", "%1")
        return title, tonumber(ep)
    end
    return nil, nil
end

local function best_title_and_episode()
    local media = nonempty(mp.get_property("media-title"))
    local file  = nonempty(mp.get_property("filename"))
    local t1, e1 = parse_filename(media)
    if t1 and e1 then return t1, e1 end
    return parse_filename(file)
end

------------------------------------------------------------------
-- AniList + AniSkip
------------------------------------------------------------------
local function anilist_query_id(title, callback)
    local query = [[
      query ($search: String) {
        Media (search: $search, type: ANIME) { id idMal }
      }
    ]]
    local body = utils.format_json({ query = query, variables = { search = title } })
    curl("POST", "https://graphql.anilist.co",
         { ["Content-Type"] = "application/json" }, body, function(response)
        local data = response and utils.parse_json(response)
        local media = data and data.data and data.data.Media
        callback(media and (media.idMal or media.id) or nil)
    end)
end

local function fetch_anilist_id(title, callback)
    local cache = id_map_dir() .. cache_key(title) .. ".json"
    if file_exists(cache) then
        local f = io.open(cache, "r")
        if f then
            local content = f:read("*a"); f:close()
            local data = utils.parse_json(content)
            if data and data.id then
                log_debug("AniList ID from cache: " .. tostring(data.id))
                callback(data.id)
                return
            end
        end
    end

    anilist_query_id(title, function(id)
        if id then
            local f = io.open(cache, "w")
            if f then
                f:write(utils.format_json({ id = id, ts = os.time() }))
                f:close()
            end
        end
        callback(id)
    end)
end

local function fetch_skip_times(anilist_id, episode, callback)
    local url = string.format(
        "https://api.aniskip.com/v2/skip-times/%d/%d?types[]=op&types[]=ed&types[]=recap&types[]=mixed-op&episodeLength=0",
        anilist_id, episode)
    curl("GET", url, nil, nil, function(response)
        local data = response and utils.parse_json(response)
        callback(data and data.found and data.results or nil)
    end)
end

------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------
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

local function draw_accent(x, scale)
    return string.format(
        "{\\an7}{\\pos(%d,%d)}{\\p1}{\\bord0}{\\shad0}{\\fscx%d}{\\fscy%d}{\\1c&H%s&}{\\1a&H00&}%s{\\p0}",
        x, BTN_Y, scale, scale, ACCENT_COLOR, rounded_rect_right(EDGE_BAR_W, BTN_H, 3))
end

local function ease(t) return t * t * (3 - 2 * t) end

local function draw_button(label, remaining, is_hovering, progress)
    local slide = -(1 - ease(progress)) * PANEL_W
    local base_x = BTN_X + slide
    local scale = (progress >= 0.999 and is_hovering) and 104 or 100
    local bg_alpha = is_hovering and "20" or "48"

    local parts = {}
    if progress > 0.02 then
        table.insert(parts, draw_panel(base_x, bg_alpha, scale))
    end
    table.insert(parts, draw_accent(base_x + PANEL_W, scale))
    if progress > 0.15 then
        local text = string.format(
            "{\\an4}{\\pos(%d,%d)}{\\fnsans-serif}{\\fs%d}{\\bord0}{\\shad0}{\\1c&HFFFFFF&}Skip %s  {\\1c&H%s&}•  {\\1c&HFFFFFF&}%ds",
            base_x + 16, BTN_Y + BTN_H / 2, BTN_FS, label, ACCENT_COLOR, remaining)
        table.insert(parts, text)
    end
    mp.set_osd_ass(SCREEN_W, SCREEN_H, table.concat(parts, "\n"))
end

local function draw_feedback(label)
    local panel = draw_panel(BTN_X, "48", 100)
    local accent = draw_accent(BTN_X + PANEL_W, 100)
    local text = string.format(
        "{\\an4}{\\pos(%d,%d)}{\\fnsans-serif}{\\fs%d}{\\bord0}{\\shad0}{\\1c&HFFFFFF&}Skipped %s",
        BTN_X + 16, BTN_Y + BTN_H / 2, BTN_FS, label)
    mp.set_osd_ass(SCREEN_W, SCREEN_H, panel .. "\n" .. accent .. "\n" .. text)
end

------------------------------------------------------------------
-- State
------------------------------------------------------------------
local function copy_chapters(chapters)
    local copy = {}
    for i, chapter in ipairs(chapters or {}) do
        local item = {}
        for k, v in pairs(chapter) do item[k] = v end
        copy[i] = item
    end
    return copy
end

local state = {
    key_bound = false,
    mouse_bound = false,
    active_interval = nil,
    is_skipping = false,
    timer = nil,
    intervals = {},
    skipped_intervals = {},
    expanded = true,
    shown_since = nil,
    progress = 1,
    last_wall = nil,
    last_visual_x = BTN_X,
    original_chapters = {},
    last_applied_chapters = nil,
    load_token = 0,
}

local skip_action  -- forward declaration

local function unbind_keys()
    if state.key_bound then
        mp.remove_key_binding("aniskip-action"); state.key_bound = false
    end
    if state.mouse_bound then
        mp.remove_key_binding("aniskip-mouse-action"); state.mouse_bound = false
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
        mp.add_forced_key_binding("MBTN_LEFT", "aniskip-mouse-action",
            function() if skip_action then skip_action() end end)
        state.mouse_bound = true
    elseif not active and state.mouse_bound then
        mp.remove_key_binding("aniskip-mouse-action")
        state.mouse_bound = false
    end
end

skip_action = function()
    if not state.active_interval or state.is_skipping then return end
    state.is_skipping = true
    state.skipped_intervals[state.active_interval] = true

    local duration = mp.get_property_number("duration", 0)
    local pl_count = mp.get_property_number("playlist-count", 1)
    local pl_pos   = mp.get_property_number("playlist-pos", 0)

    local is_ending = state.active_interval.label == "Ending"
    local is_near_end = duration > 0 and (duration - state.active_interval.end_time) <= 3.0
    local has_next    = (pl_pos + 1) < pl_count

    if opts.advance_on_ending and is_ending and is_near_end and has_next then
        mp.osd_message("Skipping to next episode...", 2)
        unbind_keys()
        state.is_skipping = false
        clear_osd()
        mp.commandv("playlist-next")
        return
    end

    mp.set_property_number("time-pos", state.active_interval.end_time)
    if opts.show_skip_feedback then draw_feedback(state.active_interval.label) end
    unbind_keys()
    kill_skip_timer()
    state.timer = mp.add_timeout(2.0, function()
        state.is_skipping = false
        clear_osd()
    end)
end

------------------------------------------------------------------
-- Chapter management
------------------------------------------------------------------
local function merge_chapters(existing, additions)
    local merged = copy_chapters(existing)
    for _, chapter in ipairs(additions) do
        local duplicate = false
        for _, current in ipairs(merged) do
            if math.abs((current.time or 0) - (chapter.time or 0)) < 2 then
                duplicate = true
                break
            end
        end
        if not duplicate then merged[#merged + 1] = chapter end
    end
    table.sort(merged, function(a, b) return (a.time or 0) < (b.time or 0) end)
    return merged
end

local function build_online_chapters()
    local online = {}
    for _, interval in ipairs(state.intervals) do
        if interval.source == "online" then online[#online + 1] = interval end
    end
    if #online == 0 then return {} end

    table.sort(online, function(a, b) return a.start_time < b.start_time end)
    local chapters = {}
    for i, interval in ipairs(online) do
        chapters[#chapters + 1] = {
            title = interval.label,
            time = interval.start_time,
        }

        if interval.label == "Opening" or interval.label == "Ending" or interval.label == "Recap" then
            local next_interval = online[i + 1]
            local has_close_next = next_interval
                and math.abs(next_interval.start_time - interval.end_time) < 5
            if not has_close_next then
                chapters[#chapters + 1] = {
                    title = interval.label == "Ending" and "Outro" or "Episode",
                    time = interval.end_time,
                }
            end
        end
    end

    table.sort(chapters, function(a, b) return a.time < b.time end)
    return chapters
end

local function chapters_match(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if (a[i].time or 0) ~= (b[i].time or 0)
           or (a[i].title or "") ~= (b[i].title or "") then
            return false
        end
    end
    return true
end

local function restore_original_chapters()
    if not state.last_applied_chapters then return end
    local current = mp.get_property_native("chapter-list", {}) or {}
    if chapters_match(current, state.last_applied_chapters) then
        mp.set_property_native("chapter-list", copy_chapters(state.original_chapters))
    end
    state.last_applied_chapters = nil
end

local function apply_online_chapters()
    local additions = build_online_chapters()
    if #additions == 0 then return end

    local chapters
    if opts.override_chapters then
        chapters = additions
    else
        chapters = merge_chapters(state.original_chapters, additions)
    end

    mp.set_property_native("chapter-list", chapters)
    state.last_applied_chapters = copy_chapters(chapters)
end

local function parse_local_chapters()
    local chapters = state.original_chapters
    for i, chapter in ipairs(chapters) do
        local label = get_chapter_label(chapter.title)
        if label then
            local start_time = tonumber(chapter.time) or 0
            local next_time = chapters[i + 1] and tonumber(chapters[i + 1].time)
            local end_time = next_time or mp.get_property_number("duration", start_time + 90)

            if end_time - start_time > 180 then
                end_time = start_time + 90
            end

            if end_time > start_time then
                table.insert(state.intervals, {
                    start_time = start_time,
                    end_time   = end_time,
                    label      = label,
                    source     = "local",
                })
            end
        end
    end
end

------------------------------------------------------------------
-- Cache freshness
------------------------------------------------------------------
local function cache_is_fresh(path)
    if opts.cache_ttl_days == 0 then return true end
    local mt = file_mtime(path)
    if not mt then return false end
    return (os.time() - mt) < (opts.cache_ttl_days * 86400)
end

------------------------------------------------------------------
-- Init
------------------------------------------------------------------
local initialize_skipper

initialize_skipper = function()
    state.load_token = state.load_token + 1
    local load_token = state.load_token

    kill_skip_timer()
    unbind_keys()
    clear_osd()

    state.intervals = {}
    state.active_interval = nil
    state.is_skipping = false
    state.skipped_intervals = {}
    state.last_visual_x = BTN_X
    state.last_wall = nil
    state.progress = 1
    state.expanded = true

    state.original_chapters = copy_chapters(
        mp.get_property_native("chapter-list", {}) or {}
    )
    state.last_applied_chapters = nil
    parse_local_chapters()

    if not opts.online_fetch then return end

    local title, ep = best_title_and_episode()
    if not (title and ep) then
        log_debug("Could not parse title/episode from metadata")
        return
    end

    local fname = mp.get_property("filename", ""):gsub("[/\\:*?\"<>|]", "_")
    local cache_file = cache_dir() .. fname .. ".json"

    local function process_results(results)
        if load_token ~= state.load_token or not opts.online_fetch then return end

        local added = 0
        for _, res in ipairs(results or {}) do
            if res.interval and res.interval.startTime and res.interval.endTime then
                local label = "Opening"
                if res.skipType == "ed" then
                    label = "Ending"
                elseif res.skipType == "recap" then
                    label = "Recap"
                end

                local duplicate = false
                for _, existing in ipairs(state.intervals) do
                    if existing.label == label
                       and math.abs(existing.start_time - res.interval.startTime) < 5 then
                        -- Prefer AniSkip timings when a local chapter marks the same section.
                        if existing.source == "local" then
                            existing.start_time = res.interval.startTime
                            existing.end_time = res.interval.endTime
                            existing.source = "online"
                            added = added + 1
                        end
                        duplicate = true
                        break
                    end
                end

                if not duplicate and res.interval.endTime > res.interval.startTime then
                    state.intervals[#state.intervals + 1] = {
                        start_time = res.interval.startTime,
                        end_time   = res.interval.endTime,
                        label      = label,
                        source     = "online",
                    }
                    added = added + 1
                end
            end
        end

        if added > 0 then
            log_info(string.format("Loaded %d AniSkip markers.", added))
            apply_online_chapters()
        elseif opts.show_failed_osd then
            mp.osd_message(LOG_PREFIX .. "No online markers found", 2.0)
        end
    end

    if file_exists(cache_file) and cache_is_fresh(cache_file) then
        local f = io.open(cache_file, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local data = utils.parse_json(content)
            if data then
                log_debug("Loaded markers from cache")
                process_results(data)
                return
            end
        end
    end

    log_info(string.format("Querying AniSkip: '%s' ep %d", title, ep))
    fetch_anilist_id(title, function(anilist_id)
        if load_token ~= state.load_token or not opts.online_fetch then return end
        if not anilist_id then
            if opts.show_failed_osd then
                mp.osd_message(LOG_PREFIX .. "No online markers found", 2.0)
            end
            return
        end

        fetch_skip_times(anilist_id, ep, function(results)
            if load_token ~= state.load_token or not opts.online_fetch then return end
            if not results then
                if opts.show_failed_osd then
                    mp.osd_message(LOG_PREFIX .. "No online markers found", 2.0)
                end
                return
            end

            local cw = io.open(cache_file, "w")
            if cw then
                cw:write(utils.format_json(results))
                cw:close()
            end
            process_results(results)
        end)
    end)
end

------------------------------------------------------------------
-- Tick
------------------------------------------------------------------
local function on_tick()
    if not (opts.auto_skip or opts.show_skip_button) then
        if state.active_interval or state.key_bound or state.mouse_bound then
            state.active_interval = nil
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

    local active = nil
    for _, interval in ipairs(state.intervals) do
        local lbl = (interval.label or ""):lower()
        if time >= interval.start_time and time < interval.end_time
           and skip_categories_set[lbl] then
            if not (opts.skip_once and state.skipped_intervals[interval]) then
                active = interval; break
            end
        end
    end

    if active then
        if state.active_interval ~= active then
            state.active_interval = active
            state.shown_since = time
            state.expanded = true
            state.progress = 1
        end

        if opts.auto_skip then skip_action(); return end

        if opts.show_skip_button then
            local hovering = is_hovering_near()
            if hovering then
                state.expanded = true
            elseif (time - state.shown_since) > opts.timeout then
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

            draw_button(active.label, math.ceil(active.end_time - time), hovering, state.progress)
            bind_mouse_if_needed(state.progress >= 0.999 and is_over_button())

            if not state.key_bound then
                mp.add_forced_key_binding(opts.skip_key, "aniskip-action",
                    function() skip_action() end)
                state.key_bound = true
            end
        end
    else
        if state.active_interval then
            state.active_interval = nil
            clear_osd()
            unbind_keys()
        end
    end
end

------------------------------------------------------------------
-- Bindings / lifecycle
------------------------------------------------------------------
local function set_online_fetch(value)
    value = not not value
    if opts.online_fetch == value then return end
    opts.online_fetch = value

    if not value then restore_original_chapters() end
    initialize_skipper() -- also invalidates any pending HTTP callbacks

    mp.osd_message(LOG_PREFIX .. "Online fetch "
        .. (value and "enabled" or "disabled"), 1.5)
end

mp.register_script_message("toggle-state", function(val)
    set_online_fetch(val == "true")
end)

mp.add_key_binding(opts.toggle_key, "aniskip-toggle", function()
    set_online_fetch(not opts.online_fetch)
end)

mp.add_periodic_timer(0.05, on_tick)
mp.register_event("file-loaded", initialize_skipper)
