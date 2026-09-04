local mp = require("mp")
local utils = require("mp.utils")
local read_options = require("mp.options").read_options

local opts = {
    enabled = false,
    auto_skip = false,       -- Set to true to automatically skip without pressing ENTER
    show_skip_button = false, -- Set to false to hide the OSD button prompt (just show on seekbar)
    skip_key = "ENTER",
    timeout = 5,              -- Seconds the full button stays expanded before sliding away (leaving the accent), re-expands on hover
    ignored_patterns = "Music,MV,Soundtrack,OST,Openings,Endings",
    show_failed_osd = true,   -- Set to false to hide the "No online markers found" OSD message
    toggle_key = "alt+s",     -- Keybind to toggle the skipper on/off (e.g. if you don't want it running on every file)
    accent_color = "A78BFA",  -- Accent color as a plain RGB hex string (no #)
    skip_categories = "Opening,Ending" -- Comma-separated chapter types the skip button/auto-skip applies to.
                                        -- Others (PV, Intro, Recap) still show as chapters/seekbar markers, just without the skip prompt.
                                        -- Available: Opening, Ending, PV, Intro, Recap
}
read_options(opts, "skip_intro")

local categories = {
    { label = "Opening", keywords = { "opening", " op ", "♪ OP", "♪OP", "^op$", "op%d", "theme song", "main theme", "オープニング", "主題歌", "ncop", "creditless op" } },
    { label = "Ending",  keywords = { "ending", " ed ", "♪ ED", "♪ED", "^ed$", "ed%d", "credits", "outro", "end roll", "エンディング", "結び", "nced", "creditless ed" } },
    { label = "PV",      keywords = { "preview", " pv ", "^pv$", "pv%d", "trailer", "next episode", "予告", "次回予告", "jikai", "yokoku" } },
    { label = "Intro",   keywords = { "intro", "introduction", "prologue", "cold open", "アバン", "アバンタイトル", "序章" } }
}

-- Converts a plain "RRGGBB" hex string to ASS's "BBGGRR" order. Falls back to
-- the default violet if the option is missing/malformed.
local function hex_to_ass_bgr(hex)
    hex = (hex or ""):gsub("^[#!]", "")
    if not hex:match("^%x%x%x%x%x%x$") then return "FA8BA7" end
    return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end

local ACCENT_COLOR = hex_to_ass_bgr(opts.accent_color)

local function update_options()
    read_options(opts, "skip_intro")
    ACCENT_COLOR = hex_to_ass_bgr(opts.accent_color)
end

-- Watch script-opts for runtime updates when styles change
mp.observe_property("user-data/script-opts", "native", update_options)
mp.observe_property("script-opts", "string", update_options)

-- Button geometry: minimal pill, flush against the top-left screen edge
local SCREEN_W, SCREEN_H = 1920, 1080
local EDGE_MARGIN_Y = 66          -- distance down from the top
local BTN_H, BTN_R, BTN_FS = 36, 10, 18
local EDGE_BAR_W = 6              -- width of the accent strip (the end-cap that's left behind)
local PANEL_W = 194               -- width of the dark label area (excludes the accent strip)
local BTN_W = PANEL_W + EDGE_BAR_W
local BTN_X, BTN_Y = 0, EDGE_MARGIN_Y   -- flush left when expanded
local HOVER_PAD_X, HOVER_PAD_Y = 70, 40  -- extra margin around the button that counts as "hovering near it"
local SLIDE_DURATION = 0.4        -- seconds for the panel to slide away, leaving the accent behind

local state = {
    key_bound = false, mouse_bound = false, active_interval = nil,
    is_skipping = false, timer = nil, intervals = {},
    expanded = true, shown_since = nil, progress = 1, last_wall = nil,
    initialized = false
}
local current_file_enabled = true
local ignored_list = {}
local skip_categories_set = {}

local function parse_ignored_patterns()
    ignored_list = {}
    for pattern in string.gmatch(opts.ignored_patterns, "[^,]+") do
        table.insert(ignored_list, (pattern:gsub("^%s*(.-)%s*$", "%1")))
    end
end
parse_ignored_patterns()

local function parse_skip_categories()
    skip_categories_set = {}
    for name in string.gmatch(opts.skip_categories, "[^,]+") do
        skip_categories_set[(name:gsub("^%s*(.-)%s*$", "%1"))] = true
    end
end
parse_skip_categories()

local function clear_osd() mp.set_osd_ass(SCREEN_W, SCREEN_H, "") end

-- Unified async curl helper (replaces separate http_get/http_post)
local function curl(method, url, headers, body, callback)
    local args = { "curl", "-s", "-X", method, url }
    if headers then
        for k, v in pairs(headers) do
            table.insert(args, "-H"); table.insert(args, k .. ": " .. v)
        end
    end
    if body then table.insert(args, "-d"); table.insert(args, body) end
    mp.command_native_async({
        name = "subprocess", playback_only = false,
        capture_stdout = true, capture_stderr = true, args = args
    }, function(_, result)
        callback(result and result.status == 0 and result.stdout or nil)
    end)
end

-- Parse Anime Title and Episode Number from filename
local function parse_filename(filename)
    if not filename then return nil, nil end
    local clean = filename:gsub("%b[]", " "):gsub("%b()", " "):gsub("%.%w+$", ""):gsub("[%._]", " ")

    local title, ep = clean:match("^(.-)%s+[Ee][Pp][%.%s]*(%d+)")
    if not title or not ep then
        title, ep = clean:match("^(.-)%s+[Ee][Pp][Ii][Ss][Oo][Dd][Ee]%s*(%d+)")
    end
    if not title or not ep then
        clean = clean:gsub("%s+", " ")
        local padded = " " .. clean .. " "
        for word in padded:gmatch("%s(%d+)%s") do
            local num = tonumber(word)
            if num and num < 2000 then
                local start_idx = padded:find(" " .. word .. " ", 1, true)
                if start_idx then
                    title, ep = padded:sub(2, start_idx - 1), num
                    break
                end
            end
        end
    end
    if title and ep then
        return title:gsub("%s*-%s*$", ""):gsub("^%s*(.-)%s*$", "%1"), ep
    end
    return nil, nil
end

local function fetch_anilist_id(title, callback)
    local query = [[
    query ($search: String) {
      Media (search: $search, type: ANIME) { id idMal }
    }
    ]]
    local body = utils.format_json({ query = query, variables = { search = title } })
    curl("POST", "https://graphql.anilist.co", { ["Content-Type"] = "application/json" }, body, function(response)
        local data = response and utils.parse_json(response)
        local media = data and data.data and data.data.Media
        callback(media and (media.idMal or media.id) or nil)
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

-- Rounded-rect variant with only the right corners rounded (left edge stays flat)
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

-- Rounded-rect variant with only the left corners rounded (right edge stays flat,
-- so the panel butts seamlessly against the accent strip beside it)
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

-- Dark label panel: rounded on the left (screen-edge side), flat on the right
-- where it butts against the accent strip
local function draw_panel(x, bg_alpha, scale)
    return string.format(
        "{\\an7}{\\pos(%d,%d)}{\\p1}{\\bord0}{\\shad0}{\\fscx%d}{\\fscy%d}{\\1c&H1A1A1A&}{\\1a&H%s&}%s{\\p0}",
        x, BTN_Y, scale, scale, bg_alpha, rounded_rect_left(PANEL_W, BTN_H, BTN_R))
end

-- Accent strip: the end-cap of the pill, flat on the left (against the
-- panel), rounded on the right. Slides as one rigid piece with the panel, so
-- when the panel exits off-screen the accent is what's left sitting flush
-- against the edge.
local function draw_accent(x, scale)
    return string.format(
        "{\\an7}{\\pos(%d,%d)}{\\p1}{\\bord0}{\\shad0}{\\fscx%d}{\\fscy%d}{\\1c&H%s&}{\\1a&H00&}%s{\\p0}",
        x, BTN_Y, scale, scale, ACCENT_COLOR, rounded_rect_right(EDGE_BAR_W, BTN_H, 3))
end

-- Smoothstep easing so the slide accelerates then decelerates instead of
-- moving at a constant linear speed
local function ease(t)
    return t * t * (3 - 2 * t)
end

-- Draws the pill sliding along the x-axis: progress=1 -> fully expanded, sitting
-- flush left with the accent strip visible at its right end; progress=0 ->
-- slid fully left so only the accent strip (now flush against the edge) remains
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

local function get_chapter_label(title)
    if not title then return nil end
    local title_lower = title:lower()
    for _, cat in ipairs(categories) do
        for _, kw in ipairs(cat.keywords) do
            if title_lower:find(kw) or title:find(kw) then return cat.label end
        end
    end
    return nil
end

local function unbind_keys()
    if state.key_bound then mp.remove_key_binding("skip-intro-action"); state.key_bound = false end
    if state.mouse_bound then mp.remove_key_binding("mouse-skip-action"); state.mouse_bound = false end
end

local function skip_action()
    if not state.active_interval or state.is_skipping then return end
    state.is_skipping = true
    mp.set_property_number("time-pos", state.active_interval.end_time)
    draw_feedback(state.active_interval.label)
    unbind_keys()
    if state.timer then state.timer:kill() end
    state.timer = mp.add_timeout(2.0, function()
        state.is_skipping = false
        clear_osd()
    end)
end

local function is_hovering_near()
    local mx, my = mp.get_mouse_pos()
    local osd_w, osd_h = mp.get_osd_size()
    if not osd_w or osd_w == 0 then return false end
    local tx, ty = mx * (SCREEN_W / osd_w), my * (SCREEN_H / osd_h)
    return tx < BTN_X + BTN_W + HOVER_PAD_X and ty < BTN_Y + BTN_H + HOVER_PAD_Y
end

local function is_over_button()
    local mx, my = mp.get_mouse_pos()
    local osd_w, osd_h = mp.get_osd_size()
    if not osd_w or osd_w == 0 then return false end
    local tx, ty = mx * (SCREEN_W / osd_w), my * (SCREEN_H / osd_h)
    return tx >= BTN_X and tx <= BTN_X + BTN_W and ty >= BTN_Y and ty <= BTN_Y + BTN_H
end

local function set_mouse_bound(active)
    if active and not state.mouse_bound then
        mp.add_forced_key_binding("MBTN_LEFT", "mouse-skip-action", skip_action)
        state.mouse_bound = true
    elseif not active and state.mouse_bound then
        mp.remove_key_binding("mouse-skip-action")
        state.mouse_bound = false
    end
end

local function on_tick()
    if not opts.enabled or not current_file_enabled or state.is_skipping then return end
    local time = mp.get_property_number("time-pos")

    local now = mp.get_time()
    local dt = state.last_wall and math.min(now - state.last_wall, 0.5) or 0
    state.last_wall = now

    if not time or time < 0.5 then return end

    local active = nil
    for _, interval in ipairs(state.intervals) do
        if time >= interval.start_time and time < interval.end_time and skip_categories_set[interval.label] then
            active = interval
            break
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

            draw_button(active.label, math.ceil(active.end_time - time), hovering, state.progress)
            set_mouse_bound(state.progress >= 0.999 and is_over_button())

            if not state.key_bound then
                mp.add_forced_key_binding(opts.skip_key, "skip-intro-action", skip_action)
                state.key_bound = true
            end
        end
    else
        state.active_interval = nil
        clear_osd()
        unbind_keys()
    end
end

local function apply_chapters_to_mpv()
    if #state.intervals == 0 then return end
    table.sort(state.intervals, function(a, b) return a.start_time < b.start_time end)

    local chapters = {}
    for i, interval in ipairs(state.intervals) do
        table.insert(chapters, { title = interval.label, time = interval.start_time })
        if interval.label == "Opening" or interval.label == "Ending" or interval.label == "Recap" then
            local next_ch = state.intervals[i + 1]
            local has_close_next = next_ch and math.abs(next_ch.start_time - interval.end_time) < 5
            if not has_close_next then
                local end_label = interval.label == "Ending" and "Outro" or "Episode"
                table.insert(chapters, { title = end_label, time = interval.end_time })
            end
        end
    end
    table.sort(chapters, function(a, b) return a.time < b.time end)
    mp.set_property_native("chapter-list", chapters)
end

local function parse_local_chapters()
    local chapters = mp.get_property_native("chapter-list") or {}
    for i, ch in ipairs(chapters) do
        local label = get_chapter_label(ch.title)
        local start_time = ch.time
        local end_time = chapters[i + 1] and chapters[i + 1].time or (mp.get_property_number("duration") or start_time + 90)

        if label and (label == "Opening" or label == "Ending") and (end_time - start_time > 180) then
            end_time = start_time + 90
        end
        table.insert(state.intervals, { start_time = start_time, end_time = end_time, label = label or ch.title })
    end
end

local function initialize_skipper()
    update_options()
    state.initialized = false
    if not opts.enabled then return end
    state.initialized = true

    parse_ignored_patterns()
    parse_skip_categories()

    state.intervals, state.active_interval, state.is_skipping = {}, nil, false
    current_file_enabled = true
    clear_osd()

    local path_lower = mp.get_property("path", ""):lower()
    for _, pattern in ipairs(ignored_list) do
        if path_lower:find(pattern:lower(), 1, true) then
            print(string.format("[skip-intro] Ignored path pattern matched: '%s'. Skipper disabled for this file.", pattern))
            current_file_enabled = false
            return
        end
    end

    parse_local_chapters()
    apply_chapters_to_mpv()

    local title, ep = parse_filename(mp.get_property("filename"))
    if not (title and ep) then return end

    local cache_dir = mp.command_native({"expand-path", "~~/cache/scripts/aniskip/"})
    mp.command_native({name = "subprocess", args = {"mkdir", "-p", cache_dir}})
    local fname = mp.get_property("filename", ""):gsub("[/\\:*?\"<>|]", "_")
    local cache_file = cache_dir .. fname .. ".json"

    local function process_results(results)
        local added_count = 0
        for _, res in ipairs(results) do
            if res.interval and res.interval.startTime and res.interval.endTime then
                local label = "Opening"
                if res.skipType == "ed" then label = "Ending"
                elseif res.skipType == "recap" then label = "Recap" end

                local exists = false
                for _, existing in ipairs(state.intervals) do
                    if existing.label == label and math.abs(existing.start_time - res.interval.startTime) < 5 then
                        exists = true; break
                    end
                end
                if not exists then
                    table.insert(state.intervals, {
                        start_time = res.interval.startTime, end_time = res.interval.endTime, label = label
                    })
                    print(string.format("[skip-intro] Loaded online marker: %s from %.2fs to %.2fs",
                        label, res.interval.startTime, res.interval.endTime))
                    added_count = added_count + 1
                end
            end
        end
        if added_count > 0 then
            print(string.format("[skip-intro] Loaded %d online AniSkip markers.", added_count))
            apply_chapters_to_mpv()
        elseif opts.show_failed_osd then
            mp.osd_message("[skip-intro] No online markers found", 2.0)
        end
    end

    local cf = io.open(cache_file, "r")
    if cf then
        local content = cf:read("*a")
        cf:close()
        local data = utils.parse_json(content)
        if data then
            print("[skip-intro] Loaded markers from cache")
            process_results(data)
            return
        end
    end

    print(string.format("[skip-intro] Querying AniSkip for '%s' Ep %d...", title, ep))
    fetch_anilist_id(title, function(anilist_id)
        if not anilist_id then
            if opts.show_failed_osd then mp.osd_message("[skip-intro] No online markers found", 2.0) end
            return
        end
        fetch_skip_times(anilist_id, ep, function(results)
            if not results then
                if opts.show_failed_osd then mp.osd_message("[skip-intro] No online markers found", 2.0) end
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

local function set_enabled(value)
    opts.enabled = value
    if not opts.enabled then
        clear_osd()
        state.is_skipping, state.active_interval = false, nil
        unbind_keys()
    else
        if not state.initialized then
            initialize_skipper()
        end
    end
    mp.osd_message("[skip-intro] " .. (opts.enabled and "enabled" or "disabled"), 1.5)
end

mp.register_script_message("toggle-state", function(val)
    set_enabled(val == "true")
end)

mp.add_key_binding(opts.toggle_key, "skip-intro-toggle", function()
    set_enabled(not opts.enabled)
end)

mp.add_periodic_timer(0.02, on_tick)
mp.register_event("file-loaded", initialize_skipper)