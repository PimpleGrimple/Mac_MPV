--[[
    sponsorblock.lua
    Based on sponsorblock.lua by zydezu (ModernX build) / po5/mpv_sponsorblock.

    Skips sponsored segments of YouTube videos using data from
    https://github.com/ajayyy/SponsorBlock. Network calls go through the
    sponsorblock.py helper next to this file, always asynchronously so they
    can't stall the other providers.

    Deliberately NOT on the shared skip engine (core.skip). Its skipping is built
    around things the engine does not model: silent seeks with their own OSD text,
    unskip / vote on the last skip, audio fade, fast-forward, and submitting new
    segments. A consequence: the provider order in main.lua does not affect it.

    Options: script-opts/sponsorblock.conf  (identifier "sponsorblock")
]]
local mp = require("mp")
local core = require("autoskip")
local util, chapter_store = core.util, core.chapters

local M = {}

local options = {
    server_address = "https://sponsor.ajay.app",
    python_path = "python3",

    -- Categories to fetch (also get chapters)
    categories = "sponsor,intro,outro,interaction,selfpromo,preview,music_offtopic,filler",

    -- Categories to skip automatically
    skip_categories = "sponsor,music_offtopic",

    -- If true, sponsored segments will only be skipped once
    skip_once = true,

    -- Show a message when a segment is skipped
    show_skip_message = true,

    -- Fast forward through sponsors instead of skipping
    fast_forward = false,
    -- Playback speed modifier when fast forwarding, applied once every second until cap is reached
    fast_forward_increase = .2,
    -- Playback speed cap
    fast_forward_cap = 2,

    -- Fade audio for smoother transitions
    audio_fade = false,
    -- Audio fade step, applied once every 100ms until cap is reached
    audio_fade_step = 10,
    -- Audio fade cap
    audio_fade_cap = 0,

    -- If true, UUIDs (the brackets) will be removed from chapter titles
    removeuuid = true,

    -- User ID used to submit sponsored segments, leave blank for random
    user_id = "",

    -- Name to display on the stats page https://sponsor.ajay.app/stats/ leave blank to keep current name
    display_name = "",

    -- Tell the server when a skip happens
    report_views = false,

    -- Auto upvote skipped sponsors
    auto_upvote = false,

    -- Minimum duration for sponsors (in seconds), segments under that threshold will be ignored
    min_duration = 1,

    -- Length of the sha256 prefix (3-32) when querying server, 0 to disable
    sha256_length = 4,

    -- Pattern for video id in local files, ignored if blank
    -- Recommended value for base youtube-dl is "-([%w-_]+)%.[mw][kpe][v4b]m?$"
    local_pattern = "",

    -- Keybinds: mpv does not bind alt+b / alt+u by default, but other scripts may;
    -- change them here (or in input.conf) if they clash.
    -- Keybind to toggle sponsorblock on/off (can also be mapped via script-binding <script>/toggle)
    toggle_key = "alt+b",

    -- Keybind to unskip the last skipped segment (can also be mapped via script-binding <script>/unskip)
    unskip_key = "alt+u",
}

require("mp.options").read_options(options, "sponsorblock")

------------------------------------------------------------------
-- Paths
------------------------------------------------------------------
local script_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local helper = script_dir .. "sponsorblock.py"
local uid_path = util.expand_path("~~/cache/scripts/sponsorblock.txt")
local cache_dir = util.expand_path("~~/cache/scripts/sponsorblock/")

------------------------------------------------------------------
-- State
------------------------------------------------------------------
local all_categories = {"sponsor", "intro", "outro", "interaction", "selfpromo", "preview", "music_offtopic", "filler"}
local skip_set = {}
for category in string.gmatch(options.skip_categories, "([^,]+)") do
    skip_set[category] = true
end

local enabled = true
local init = false            -- true once a YouTube file has been seen (display name is sent once)
local youtube_id = nil
local generation = 0          -- bumped per file; stale async callbacks check it
local ranges = {}             -- uuid -> {start_time, end_time, category, skipped}
-- pending: first boundary set, waiting for the second.  menu: category menu is open.
-- first: no boundary has been set yet (no preview chapter until there are two).
local function new_segment()
    return {a = 0, b = 0, pending = false, menu = false, first = true}
end
local segment = new_segment()
local last_skip = {uuid = "", dir = nil}
local segments_with_chapters = {}
local sb_chapters = {}        -- chapters for fetched segments
local submitted_chapters = {} -- chapters for segments the user submitted
local retry_delays = {2, 5}
local retry_count = 0

local ff_uuid = nil           -- segment currently being fast-forwarded through
local speed_timer = nil
local fade_timer = nil
local fade_dir = nil
local volume_before = mp.get_property_number("volume")

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------
local function category_title(category)
    return (category:gsub("^%l", string.upper):gsub("_", " "))
end

local function usable(s)
    return s and s:match("^%s*(.*%S)") and not s:find("error", 1, true)
end

-- Run the python helper asynchronously; callback(stdout) is optional.
local function run(args, callback)
    local cmd = {options.python_path, helper}
    for _, a in ipairs(args) do cmd[#cmd + 1] = tostring(a) end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, args = cmd,
    }, function(_, res)
        if callback then callback((res and res.stdout) or "") end
    end)
end

local function stats_call(uuid, view, vote_type)
    run({"stats", options.server_address, uuid, uid_path, options.user_id, view and "1" or "", vote_type or ""})
end

local function make_chapter(title, time)
    local duration = mp.get_property_native("duration")
    return {
        title = "[SponsorBlock] " .. title,
        time = (duration == nil or duration > time) and time or duration - .001,
    }
end

local function notify_done()
    -- ModernX listens for this to refresh its chapter markers
    mp.commandv("script-message", "sponsorblock-done")
end

------------------------------------------------------------------
-- Effects (fast forward / audio fade)
------------------------------------------------------------------
local function stop_effects()
    ff_uuid = nil
    if speed_timer ~= nil then
        speed_timer:kill()
        speed_timer = nil
        mp.set_property("speed", 1)
    end
    if fade_timer ~= nil then
        fade_timer:kill()
        fade_timer = nil
        if volume_before then mp.set_property("volume", volume_before) end
    end
    fade_dir = nil
end

local function ramp_speed()
    local last_speed = mp.get_property_number("speed")
    local new_speed = math.min(last_speed + options.fast_forward_increase, options.fast_forward_cap)
    if new_speed <= last_speed then return end
    mp.set_property("speed", new_speed)
end

local function fade_audio(step)
    local last_volume = mp.get_property_number("volume")
    local new_volume = math.max(options.audio_fade_cap, math.min(last_volume + step, volume_before))
    if new_volume == last_volume then
        if step >= 0 then fade_dir = nil end
        if fade_timer ~= nil then fade_timer:kill() end
        fade_timer = nil
        return
    end
    mp.set_property("volume", new_volume)
end

------------------------------------------------------------------
-- Fetching segments
------------------------------------------------------------------
-- Turns one "start,end,uuid,category" entry into a skip range and its chapters.
local function process(uuid, t)
    local start_time = tonumber(string.match(t, "[^,]+"))
    local end_time = tonumber(string.sub(string.match(t, ",[^,]+"), 2))
    local category = string.match(t, "[^,]+$")
    if skip_set[category] and end_time - start_time >= options.min_duration then
        ranges[uuid] = {
            start_time = start_time,
            end_time = end_time,
            category = category,
            skipped = false,
        }
    end
    if not segments_with_chapters[uuid] then
        segments_with_chapters[uuid] = true
        local title = category_title(category)
        local suffix = options.removeuuid and "" or (" (" .. string.sub(uuid, 1, 6) .. ")")
        table.insert(sb_chapters, make_chapter(title .. " start" .. suffix, start_time))
        table.insert(sb_chapters, make_chapter(title .. " end" .. suffix, end_time))
    end
end

-- Installs are unconditional and happen at most once per file: `ranges` is reset
-- in on_file_loaded, and a retry only follows a failed request, so there is never
-- an earlier install to merge with or to carry skipped flags over from.
local function install_ranges(stdout)
    for t in string.gmatch(stdout, "[^:%s]+") do
        process(string.match(t, "([^,]+),[^,]+$"), t)
    end
    if #sb_chapters > 0 then
        chapter_store.set("sponsorblock", sb_chapters)
    end
end

local function fetch_ranges()
    local video_id, gen = youtube_id, generation
    local cache_file = cache_dir .. video_id .. ".txt"

    local cached = util.read_file(cache_file)
    if usable(cached) then
        mp.msg.debug("Cached: " .. (cached:gsub("[\n\r]", "")))
        install_ranges(cached)
        notify_done()
        return
    end

    local first_attempt = retry_count == 0
    run({"ranges", options.server_address, video_id, options.categories, options.sha256_length}, function(stdout)
        if gen ~= generation or video_id ~= youtube_id then return end
        mp.msg.debug("Got: " .. (stdout:gsub("[\n\r]", "")))

        if not stdout:match("^%s*(.*%S)") then      -- no segments for this video
            if first_attempt then notify_done() end
            return
        end
        if stdout:find("error", 1, true) then
            if first_attempt then notify_done() end
            if retry_count >= #retry_delays then
                mp.msg.warn("SponsorBlock request failed; giving up until the next file")
                return
            end
            local delay = retry_delays[retry_count + 1]
            retry_count = retry_count + 1
            mp.msg.warn(string.format("SponsorBlock request failed; retrying in %d seconds", delay))
            mp.add_timeout(delay, function()
                if gen == generation and video_id == youtube_id then fetch_ranges() end
            end)
            return
        end

        util.write_file(cache_file, stdout)
        install_ranges(stdout)
        notify_done()
    end)
end

------------------------------------------------------------------
-- Skipping
------------------------------------------------------------------
local function skip_ads(_, pos)
    if not enabled or pos == nil then return end
    local sponsor_ahead = false
    for uuid, t in pairs(ranges) do
        if (ff_uuid == uuid or not options.skip_once or not t.skipped)
           and t.start_time <= pos and t.end_time > pos then
            if ff_uuid == uuid then return end
            if not options.fast_forward then
                if options.show_skip_message then mp.osd_message(t.category .. " skipped") end
                mp.commandv("seek", tostring(t.end_time), "absolute+exact")
            else
                mp.osd_message("skipping " .. t.category)
            end
            t.skipped = true
            last_skip = {uuid = uuid, dir = nil}
            if options.report_views or options.auto_upvote then
                stats_call(uuid, options.report_views, options.auto_upvote and "1" or nil)
            end
            if options.fast_forward then
                ff_uuid = uuid
                if speed_timer ~= nil then speed_timer:kill() end
                speed_timer = mp.add_periodic_timer(1, ramp_speed)
            end
            return
        elseif (not options.skip_once or not t.skipped)
               and t.start_time <= pos + 1 and t.end_time > pos + 1 then
            sponsor_ahead = true
        end
    end
    if options.audio_fade then
        if sponsor_ahead then
            if fade_dir ~= false then
                if fade_dir == nil then volume_before = mp.get_property_number("volume") end
                if fade_timer ~= nil then fade_timer:kill() end
                fade_dir = false
                fade_timer = mp.add_periodic_timer(.1, function() fade_audio(-options.audio_fade_step) end)
            end
        elseif fade_dir == false then
            fade_dir = true
            if fade_timer ~= nil then fade_timer:kill() end
            fade_timer = mp.add_periodic_timer(.1, function() fade_audio(options.audio_fade_step) end)
        end
    end
    if ff_uuid ~= nil then   -- left the fast-forwarded segment
        ff_uuid = nil
        if speed_timer ~= nil then speed_timer:kill(); speed_timer = nil end
        mp.set_property("speed", 1)
    end
end

------------------------------------------------------------------
-- Keybind actions
------------------------------------------------------------------
local function toggle_sponsorblock()
    enabled = not enabled
    if not enabled then stop_effects() end
    mp.osd_message((enabled and "enabled" or "disabled"), 2)
end

local function unskip_segment()
    if last_skip.uuid ~= "" and ranges[last_skip.uuid] then
        local t = ranges[last_skip.uuid]
        mp.commandv("seek", tostring(t.start_time), "absolute+exact")
        mp.osd_message("unskipped " .. t.category, 2)
    else
        mp.osd_message("no recently skipped segment", 2)
    end
end

local function vote(dir)
    if last_skip.uuid == "" then return mp.osd_message("no sponsors skipped, can't submit vote") end
    local updown = dir == "1" and "up" or "down"
    if last_skip.dir == dir then return mp.osd_message(updown .. "vote already submitted") end
    last_skip.dir = dir
    stats_call(last_skip.uuid, false, dir)
    mp.osd_message(updown .. "vote submitted")
end

local select_category

local function submit_segment(category)
    if not youtube_id then return end
    local start_time = math.min(segment.a, segment.b)
    local end_time = math.max(segment.a, segment.b)
    if end_time - start_time == 0 or end_time == 0 then
        mp.osd_message("empty segment, not submitting")
    elseif not segment.menu then
        segment.menu = true
        local category_list = ""
        for category_id, name in ipairs(all_categories) do
            category_list = category_list .. category_id .. ": " .. category_title(name) .. "\n"
            mp.add_forced_key_binding(tostring(category_id), "select_category_" .. name, function() select_category(name) end)
            mp.add_forced_key_binding("KP" .. tostring(category_id), "kp_select_category_" .. name, function() select_category(name) end)
        end
        mp.osd_message(string.format("press a number to select category for segment: %.2d:%.2d:%.2d to %.2d:%.2d:%.2d\n\n" .. category_list .. "\nyou can press Shift+G again for default (Sponsor) or hide this message with g", math.floor(start_time/(60*60)), math.floor(start_time/60%60), math.floor(start_time%60), math.floor(end_time/(60*60)), math.floor(end_time/60%60), math.floor(end_time%60)), 30)
    else
        mp.osd_message("submitting segment...", 30)
        local gen = generation
        run({"submit", options.server_address, youtube_id, start_time, end_time,
             type(category) == "string" and category or "sponsor", uid_path, options.user_id},
            function(stdout)
                if gen ~= generation then return end
                if stdout:match("success") then
                    segment = new_segment()
                    mp.osd_message("segment submitted")
                    chapter_store.clear("sponsorblock-preview")
                    table.insert(submitted_chapters, make_chapter("Submitted segment start", start_time))
                    table.insert(submitted_chapters, make_chapter("Submitted segment end", end_time))
                    chapter_store.set("sponsorblock-submitted", submitted_chapters)
                elseif stdout:match("error") then
                    mp.osd_message("segment submission failed, server may be down. try again", 5)
                elseif stdout:match("502") then
                    mp.osd_message("segment submission failed, server is down. try again", 5)
                elseif stdout:match("400") then
                    mp.osd_message("segment submission failed, impossible inputs", 5)
                    segment = new_segment()
                elseif stdout:match("429") then
                    mp.osd_message("segment submission failed, rate limited. try again", 5)
                elseif stdout:match("409") then
                    mp.osd_message("segment already submitted", 3)
                    segment = new_segment()
                else
                    mp.osd_message("segment submission failed", 5)
                end
            end)
    end
end

function select_category(selected)
    for _, name in ipairs(all_categories) do
        mp.remove_key_binding("select_category_" .. name)
        mp.remove_key_binding("kp_select_category_" .. name)
    end
    submit_segment(selected)
end

local function set_segment()
    if not youtube_id then return end
    local pos = mp.get_property_number("time-pos")
    if pos == nil then return end
    segment.menu = false
    if segment.pending then
        segment.pending = false
        segment.b = pos
        mp.osd_message("segment boundary B set, press again for boundary A", 3)
    else
        segment.pending = true
        segment.a = pos
        mp.osd_message("segment boundary A set, press again for boundary B", 3)
    end
    if not segment.first then
        local start_time = math.min(segment.a, segment.b)
        local end_time = math.max(segment.a, segment.b)
        if end_time - start_time ~= 0 and end_time ~= 0 then
            chapter_store.set("sponsorblock-preview", {
                make_chapter("Preview segment start", start_time),
                make_chapter("Preview segment end", end_time),
            })
        end
    end
    segment.first = false
end

------------------------------------------------------------------
-- Video id detection
------------------------------------------------------------------
local url_patterns = {
    "ytdl://([%w-_]+).*",
    "https?://youtu%.be/([%w-_]+).*",
    "https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
    "/watch.*[?&]v=([%w-_]+).*",
    "/embed/([%w-_]+).*",
}

local metadata_keys = {
    "metadata/by-key/comment", "metadata/by-key/COMMENT",
    "metadata/by-key/purl", "metadata/by-key/PURL",
    "metadata/by-key/title", "metadata/by-key/TITLE",
    "metadata/by-key/description", "metadata/by-key/DESCRIPTION",
}

local function detect_youtube_id()
    local video_path = mp.get_property("path", "")
    mp.msg.debug("Path: " .. video_path)
    local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""
    mp.msg.debug("Referer: " .. video_referer)

    local id
    for _, pattern in ipairs(url_patterns) do
        id = string.match(video_path, pattern) or string.match(video_referer, pattern)
        if id then break end
    end

    -- Local filename fallbacks: [id].ext, (id).ext, -id.ext
    if not id then
        local fn_match = string.match(video_path, "%[([%w%-_]+)%]%..+$")
                      or string.match(video_path, "%(([%w%-_]+)%)%..+$")
                      or string.match(video_path, "%-([%w%-_]+)%..+$")
        if fn_match and string.len(fn_match) == 11 then id = fn_match end
    end

    -- Embedded tag fallbacks (downloaded files carrying the source URL / id)
    if not id then
        for _, key in ipairs(metadata_keys) do
            local val = mp.get_property(key, "")
            if val ~= "" then
                for _, pattern in ipairs(url_patterns) do
                    id = string.match(val, pattern)
                    if id then break end
                end
                if not id and string.match(val, "^([%w%-_]+)$") and string.len(val) == 11 then
                    id = val
                end
                if id then break end
            end
        end
    end

    if not id and options.local_pattern ~= "" then
        id = string.match(video_path, options.local_pattern)
    end

    if not id or string.len(id) ~= 11 then return nil end
    return id
end

------------------------------------------------------------------
-- Provider interface
------------------------------------------------------------------
function M.on_file_loaded()
    generation = generation + 1
    retry_count = 0
    stop_effects()
    ranges = {}
    segment = new_segment()
    last_skip = {uuid = "", dir = nil}
    segments_with_chapters = {}
    sb_chapters = {}
    submitted_chapters = {}

    youtube_id = detect_youtube_id()
    if not youtube_id then return end
    mp.msg.debug("Found YouTube ID: " .. youtube_id)

    fetch_ranges()

    if not init then
        init = true
        if options.display_name ~= "" then
            run({"username", options.server_address, options.display_name, uid_path, options.user_id})
        end
    end
end

function M.setup()
    util.mkdir_p(cache_dir)

    mp.observe_property("time-pos", "native", skip_ads)

    -- Don't leave the speed / volume of a fast-forward or fade behind (they can
    -- end up in watch-later files otherwise). end-file also fires on quit
    -- (reason "quit"), while properties can still be set.
    mp.register_event("end-file", stop_effects)

    mp.add_key_binding("g", "set_segment", set_segment)
    mp.add_key_binding("G", "submit_segment", submit_segment)
    mp.add_key_binding("h", "upvote_segment", function() return vote("1") end)
    mp.add_key_binding("H", "downvote_segment", function() return vote("0") end)
    if options.toggle_key and options.toggle_key ~= "" then
        mp.add_key_binding(options.toggle_key, "toggle", toggle_sponsorblock)
    end
    if options.unskip_key and options.unskip_key ~= "" then
        mp.add_key_binding(options.unskip_key, "unskip", unskip_segment)
    end
    mp.register_script_message("sponsorblock-toggle", toggle_sponsorblock)
    mp.register_script_message("sponsorblock-unskip", unskip_segment)
end

return M
