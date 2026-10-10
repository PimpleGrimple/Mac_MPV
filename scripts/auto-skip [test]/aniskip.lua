--[[
    aniskip.lua
    Skips anime openings, endings and recaps using the AniSkip API (via AniList).
    Online only: skipping chapters by their title lives in localchapters.lua.

    Unlike theintrodb.lua this also tries to look files up when they are streams
    (a stream's media-title often carries a usable "Show - 05"), on purpose.
]]
local mp = require("mp")
local utils = require("mp.utils")
local core = require("autoskip")
local util = core.util

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

    -- AniSkip categories to skip: Opening, Ending, Recap.
    -- Case-insensitive, comma-separated.
    skip_categories     = "Opening,Ending",

    -- Chapter display and cache
    override_chapters   = false,
    cache_ttl_days      = 30,   -- days before a cached result is fetched again; 0 = never

    debug               = false,
}

local R = core.remote.new({
    name = "aniskip",
    prefix = "[aniskip] ",
    label = "AniSkip",
    opts = opts,
    toggle_message = "toggle-state",
    close = { Opening = "Episode", Ending = "Outro", Recap = "Episode" },
})
local log_debug, log_info, curl = R.log.debug, R.log.info, R.curl

------------------------------------------------------------------
-- Filename parsing
------------------------------------------------------------------
local strip_quality_tags = util.strip_quality_tags

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
        -- Last resort: a bare number after the title. The last one wins (episode
        -- numbers trail the title) and 1900+ is skipped as almost certainly a year.
        -- Like every pattern above, the title is everything before the episode
        -- number, so sequel numbers stay: "Overlord 4 07" -> "overlord 4", ep 7.
        -- (Cutting at the first number would search "Overlord" = season 1.)
        local padded = " " .. clean .. " "
        local pos = 1
        while true do
            local s, e, word = padded:find("%s(%d+)%s", pos)
            if not s then break end
            local num = tonumber(word)
            if num and num < 1900 then title, ep = padded:sub(2, s - 1), num end
            pos = e -- the trailing space may be the next number's leading space
        end
    end

    if title and ep then
        title = title:gsub("[%-%s]+$", ""):gsub("^%s*(.-)%s*$", "%1")
        return title, tonumber(ep)
    end
    return nil, nil
end

local function best_title_and_episode()
    local media = util.nonempty(mp.get_property("media-title"))
    local file  = util.nonempty(mp.get_property("filename"))
    local t1, e1 = parse_filename(media)
    if t1 and e1 then return t1, e1 end
    return parse_filename(file)
end

------------------------------------------------------------------
-- AniList + AniSkip
-- AniSkip is keyed by MAL id. An AniList entry without a MAL mapping is a miss:
-- using AniList's own id here would fetch some other show's timings.
------------------------------------------------------------------
local function anilist_query_mal_id(title, callback)
    local query = [[
      query ($search: String) {
        Media (search: $search, type: ANIME) { id idMal }
      }
    ]]
    local body = utils.format_json({ query = query, variables = { search = title } })
    curl("POST", "https://graphql.anilist.co",
         { ["Content-Type"] = "application/json" }, body, function(response, code)
        local data = response and utils.parse_json(response)
        local media = data and data.data and data.data.Media
        if not media then
            -- AniList answers an unknown title with HTTP 404
            callback(nil, (response or code == 404) and "No AniList match for this title"
                                                     or "AniList request failed")
        elseif not media.idMal then
            log_debug("AniList found '" .. title .. "' but it has no MAL id")
            callback(nil, "AniList has no MAL ID for this title")
        else
            callback(media.idMal)
        end
    end)
end

-- Bump when the shape of an ID-map entry changes; entries with any other
-- version (or none, e.g. the old AniList-id fallback format) are ignored and refetched.
local ID_MAP_VERSION = 2

local function fetch_mal_id(title, callback)
    local cache = R.id_map_dir() .. util.cache_key(title) .. ".json"
    if util.file_exists(cache) and util.cache_is_fresh(cache, opts.cache_ttl_days) then
        local data = utils.parse_json(util.read_file(cache) or "")
        if data and data.v == ID_MAP_VERSION and data.mal then
            log_debug("MAL ID from cache: " .. tostring(data.mal))
            callback(data.mal)
            return
        end
    end

    anilist_query_mal_id(title, function(id, reason)
        if id then util.write_file(cache, utils.format_json({ v = ID_MAP_VERSION, mal = id })) end
        callback(id, reason)
    end)
end

local function fetch_skip_times(mal_id, episode, callback)
    local url = string.format(
        "https://api.aniskip.com/v2/skip-times/%d/%d?types[]=op&types[]=ed&types[]=recap&types[]=mixed-op&episodeLength=0",
        mal_id, episode)
    curl("GET", url, nil, nil, function(response, code)
        local data = response and utils.parse_json(response)
        if data and data.found and data.results then
            callback(data.results)
        else
            -- AniSkip answers "no skip times" with HTTP 404
            callback(nil, (response or code == 404) and "AniSkip has no skip times for this episode"
                                                     or "AniSkip request failed")
        end
    end)
end

------------------------------------------------------------------
-- Provider
------------------------------------------------------------------
local current = {}   -- title / episode parsed by applicable(), used by fetch()

local function applicable()
    local title, ep = best_title_and_episode()
    if not (title and ep) then
        log_debug("Could not parse title/episode from metadata")
        return false
    end
    current.title, current.ep = title, ep
    return true
end

local function fetch(done, alive)
    local title, ep = current.title, current.ep
    log_info(string.format("Querying AniSkip: '%s' ep %d", title, ep))
    fetch_mal_id(title, function(mal_id, reason)
        if not alive() then return end
        if not mal_id then done(nil, reason); return end

        fetch_skip_times(mal_id, ep, function(results, why)
            if not alive() then return end
            if not results then done(nil, why); return end
            done(utils.format_json(results))
        end)
    end)
end

local function parse(body)
    local intervals = {}
    for _, res in ipairs(utils.parse_json(body) or {}) do
        if res.interval and res.interval.startTime and res.interval.endTime then
            local label = "Opening"
            if res.skipType == "ed" then
                label = "Ending"
            elseif res.skipType == "recap" then
                label = "Recap"
            end

            local duplicate = false
            for _, existing in ipairs(intervals) do
                if existing.label == label
                   and math.abs(existing.start_time - res.interval.startTime) < 5 then
                    duplicate = true
                    break
                end
            end

            if not duplicate and res.interval.endTime > res.interval.startTime then
                intervals[#intervals + 1] = {
                    start_time = res.interval.startTime,
                    end_time   = res.interval.endTime,
                    label      = label,
                }
            end
        end
    end
    return intervals
end

return R.install({ applicable = applicable, fetch = fetch, parse = parse })
