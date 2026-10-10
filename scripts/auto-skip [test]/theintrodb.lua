--[[
    theintrodb.lua
    Intro / recap / credits / preview timestamps for TV episodes and movies,
    from TheIntroDB (https://theintrodb.org). Online only.

    The API is keyed by TMDB ID (IMDb / TVDB also work), so a file has to be
    identified first. In order:
      1. an ID tag anywhere in the path:  [tmdbid-1396]  {tmdb-1396}  {imdb-tt0903747}
         (Jellyfin / Plex naming; tag the show folder, not every file)
      2. otherwise a TMDB title search, if tmdb_api_key is set. Only done when
         the filename clearly looks like an episode (S01E02, 1x02) or a movie
         with a year, so random videos never get looked up.
    Network streams are never looked up.

    Options: edit below, or script-opts/theintrodb.conf (identifier "theintrodb").
    Keep api keys in the .conf file.
]]
local mp = require("mp")
local utils = require("mp.utils")
local core = require("autoskip")
local util = core.util

local API  = "https://api.theintrodb.org/v3"
local TMDB = "https://api.themoviedb.org/3"

------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------
local opts = {
    -- Core behavior
    online_fetch        = false,
    auto_skip           = true,
    skip_once           = true,
    advance_on_ending   = true,   -- Credits that run to the end of the file start the next episode

    -- Skip UI
    -- Set auto_skip=false to use the optional on-screen skip button.
    show_skip_button    = false,
    show_skip_feedback  = true,
    skip_key            = "ENTER",
    timeout             = 5,
    toggle_key          = "alt+i",
    accent_color        = "A78BFA",
    show_failed_osd     = true,

    -- Segment types to skip: Intro, Recap, Credits, Preview.
    -- Case-insensitive, comma-separated.
    skip_categories     = "Intro,Credits,Preview",

    -- Chapter display and cache
    override_chapters   = false,
    cache_ttl_days      = 30,    -- days before a cached result is fetched again; 0 = never

    -- Identification
    api_key             = "",    -- optional TheIntroDB key (also shows your own pending submissions)
    tmdb_api_key        = "",    -- optional; only used to find a TMDB ID from the filename
    default_season      = 1,     -- season to use when a file has an episode number but no season
    send_duration       = true,  -- send the file length so the API can pick the matching release

    debug               = false,
}
require("mp.options").read_options(opts, "theintrodb")

local R = core.remote.new({
    name = "theintrodb",
    prefix = "[theintrodb] ",
    label = "TheIntroDB",
    opts = opts,
    close = { Intro = "Episode", Recap = "Episode" },
})
local log_debug, log_info, curl = R.log.debug, R.log.info, R.curl

------------------------------------------------------------------
-- Identifying the file
------------------------------------------------------------------
local function ids_from_path(path)
    local p = path:lower()
    return {
        tmdb = p:match("tmdbid[%-=](%d+)") or p:match("tmdb[%-=](%d+)"),
        imdb = p:match("imdbid[%-=](tt%d+)") or p:match("imdb[%-=](tt%d+)"),
        tvdb = p:match("tvdbid[%-=](%d+)") or p:match("tvdb[%-=](%d+)"),
    }
end

-- The text was already cut before the year / episode marker, so no quality tags
-- are left in it. (Stripping them anyway would eat title words: "Charlotte's Web".)
local function clean_title(raw)
    local t = (raw or ""):gsub("%b[]", " "):gsub("%b()", " ")
    t = t:gsub("%s+", " "):gsub("[%-%s]+$", ""):gsub("^%s+", "")
    return t:lower()
end

-- Returns { title, year, season, episode, strong } or nil.
--   strong = true for S01E02 / 1x02 style names (safe to search by title)
local function parse_name(name)
    if not name or name == "" then return nil end

    local base = name
    local ext = name:match("%.(%w+)$")
    if ext and #ext <= 4 and not ext:match("^%d+$") then
        base = name:sub(1, #name - #ext - 1)
    end
    local clean = base:gsub("[%._]", " "):gsub("%s+", " ")
    local padded = " " .. clean .. " "
    local info = {}

    local a, _, s, e = clean:find("[Ss](%d+)%s*[Ee](%d+)")
    if a then
        info.season, info.episode, info.strong = tonumber(s), tonumber(e), true
        info.raw_title = clean:sub(1, a - 1)
    else
        local pa, _, ps, pe = padded:find("[^%d](%d%d?)x(%d%d%d?)[^%d]")
        if pa then
            info.season, info.episode, info.strong = tonumber(ps), tonumber(pe), true
            info.raw_title = padded:sub(1, pa - 1)
        else
            local t, ep = padded:match("^%s*(.-)%s+%-%s+(%d+)%s")
            if t and ep then
                info.episode = tonumber(ep)   -- anime style "Title - 05": needs an ID tag
                info.raw_title = t
            end
        end
    end

    if info.episode then
        info.year = tonumber((info.raw_title or ""):match("[%(%[]([12]%d%d%d)[%)%]]"))
    else
        local ya, _, y = padded:find("[%s%(%[]([12]%d%d%d)[%s%)%]]")
        y = tonumber(y)
        if ya and y and y >= 1900 and y <= 2100 then
            info.year = y
            info.raw_title = padded:sub(1, ya - 1)
        else
            info.raw_title = clean
        end
    end

    info.title = clean_title(info.raw_title)
    if info.title == "" then return nil end
    return info
end

local function best_info()
    local info = parse_name(util.nonempty(mp.get_property("filename")))
    if info and (info.episode or info.year) then return info end
    return parse_name(util.nonempty(mp.get_property("media-title"))) or info
end

local function tmdb_search(kind, title, year, callback)
    local cache = R.id_map_dir() .. util.cache_key(kind .. "|" .. title .. "|" .. tostring(year or "")) .. ".txt"
    if util.file_exists(cache) and util.cache_is_fresh(cache, opts.cache_ttl_days) then
        local id = tonumber(util.read_file(cache))
        if id then
            log_debug("TMDB ID from cache: " .. tostring(id))
            callback(id)
            return
        end
    end

    local url = TMDB .. "/search/" .. kind .. "?query=" .. util.url_encode(title)
    if year then
        url = url .. (kind == "tv" and "&first_air_date_year=" or "&year=") .. year
    end
    local headers = { Accept = "application/json" }
    local key = opts.tmdb_api_key
    if key:match("^eyJ") then   -- v4 read-access token
        headers.Authorization = "Bearer " .. key
    else
        url = url .. "&api_key=" .. util.url_encode(key)
    end

    curl("GET", url, headers, nil, function(body)
        local data = body and utils.parse_json(body)
        local first = data and data.results and data.results[1]
        local id = first and first.id
        if id then util.write_file(cache, string.format("%d", id)) end
        callback(id)
    end)
end

-- callback(query, nil) on success; callback(nil, reason) otherwise.
local function resolve(callback)
    local path = mp.get_property("path", "")
    if path:match("^%a[%w+.%-]*://") then return callback(nil, "stream") end

    local ids = ids_from_path(path)
    local info = best_info()

    local season, episode
    if info and info.episode then
        season = info.season
            or tonumber(path:match("[Ss]eason[%s%._]*(%d+)"))
            or opts.default_season
        episode = info.episode
    end

    local function make(field, id)
        local q = { [field] = id }
        if episode then q.season, q.episode = season, episode end
        return q
    end

    if ids.tmdb then return callback(make("tmdb_id", ids.tmdb)) end
    if ids.imdb then return callback(make("imdb_id", ids.imdb)) end
    if ids.tvdb then return callback(make("tvdb_id", ids.tvdb)) end

    if not info then return callback(nil, "unparsed") end

    local kind
    if info.episode and info.strong then
        kind = "tv"
    elseif not info.episode and info.year then
        kind = "movie"
    end
    if not kind then return callback(nil, "unparsed") end

    if opts.tmdb_api_key == "" then return callback(nil, "no_id") end

    tmdb_search(kind, info.title, info.year, function(id)
        if not id then return callback(nil, "not_found") end
        callback(make("tmdb_id", id))
    end)
end

------------------------------------------------------------------
-- TheIntroDB
------------------------------------------------------------------
local function build_query(q)
    local parts = {}
    for _, k in ipairs({ "tmdb_id", "imdb_id", "tvdb_id" }) do
        if q[k] then parts[#parts + 1] = k .. "=" .. util.url_encode(q[k]) end
    end
    if q.season and q.episode then
        parts[#parts + 1] = "season=" .. q.season
        parts[#parts + 1] = "episode=" .. q.episode
    end
    if opts.send_duration then
        local duration = mp.get_property_number("duration", 0)
        if duration > 0 then
            parts[#parts + 1] = "duration_ms=" .. string.format("%d", math.floor(duration * 1000 + 0.5))
        end
    end
    return table.concat(parts, "&")
end

local function fetch_media(q, callback)
    local headers = { Accept = "application/json" }
    if opts.api_key ~= "" then headers.Authorization = "Bearer " .. opts.api_key end
    curl("GET", API .. "/media?" .. build_query(q), headers, nil, callback)
end

local SEGMENT_TYPES = {
    { key = "intro",   label = "Intro" },
    { key = "recap",   label = "Recap" },
    { key = "credits", label = "Credits", ending = true },
    { key = "preview", label = "Preview" },
}

local function num(v)
    return type(v) == "number" and v or nil
end

-- start_ms may be null (= from the start); end_ms null means "to the end of the file".
local function build_intervals(data)
    local duration = mp.get_property_number("duration", 0)
    local out = {}
    for _, t in ipairs(SEGMENT_TYPES) do
        local list = data[t.key]
        if type(list) == "table" then
            for _, seg in ipairs(list) do
                if type(seg) == "table" then
                    local start_time = (num(seg.start_ms) or 0) / 1000
                    local end_ms = num(seg.end_ms)
                    local end_time = end_ms and end_ms / 1000 or (duration > 0 and duration or nil)
                    if end_time and duration > 0 and end_time > duration then end_time = duration end
                    if end_time and end_time > start_time then
                        out[#out + 1] = {
                            start_time = start_time,
                            end_time   = end_time,
                            label      = t.label,
                            ending     = t.ending,
                        }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.start_time < b.start_time end)
    return out
end

------------------------------------------------------------------
-- Provider
------------------------------------------------------------------
local NO_ID_MESSAGE = "No TMDB ID\ntag the folder [tmdbid-N] or set tmdb_api_key"

local function fetch(done, alive)
    resolve(function(q, reason)
        if not alive() then return end

        if not q then
            if reason == "no_id" then
                done(nil, NO_ID_MESSAGE)
            elseif reason == "not_found" then
                done(nil, "Not found on TMDB")
            else
                log_debug("Not an identifiable episode or movie (" .. tostring(reason) .. ")")
                done(nil, false)
            end
            return
        end

        log_info("Querying TheIntroDB: " .. build_query(q))
        fetch_media(q, function(body, code)
            if not alive() then return end
            if body then done(body); return end

            if code == 404 then
                done(nil, "TheIntroDB has no markers for this title")
            elseif code == 429 then
                done(nil, "TheIntroDB rate limit hit, try again later")
            else
                done(nil, "TheIntroDB request failed")
            end
        end)
    end)
end

local function parse(body)
    local data = utils.parse_json(body)
    return type(data) == "table" and build_intervals(data) or {}
end

return R.install({ fetch = fetch, parse = parse })
