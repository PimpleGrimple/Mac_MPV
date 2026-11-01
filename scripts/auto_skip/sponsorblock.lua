--[[
    sponsorblock.lua
    Source "sponsorblock": sponsored segments of YouTube videos, from
    https://github.com/ajayyy/SponsorBlock. Read-only: nothing is sent back to the
    server (no submission, no voting, no telemetry).

    Skipping, caching, chapters and options all come from main.lua like any other
    source; this file only knows how to recognise a YouTube video and ask the server.
    Options: sponsorblock_categories, and any sponsorblock_<option> override.

    Uses the raw-videoID API endpoint. The SHA-256 prefix endpoint would hide the ID
    in the server's request log, but the response contains video-specific segment
    timings, so the server can identify the video either way. Not worth the extra
    dependency.

    main.lua asks detect() for every file. A video recognised with certainty (a
    YouTube URL or a [id] in the filename) uses only this source; a weak guess
    (id-shaped metadata) tries it first and falls through to the priority chain
    when the server has nothing.
]]
local mp = require("mp")
local utils = require("mp.utils")
local core = require("autoskip")
local util, conf = core.util, core.conf

local log = core.logger("[sponsorblock] ")

local SERVER = "https://sponsor.ajay.app"
local MIN_DURATION = 1

local function category_title(category)
    return (category:gsub("^%l", string.upper):gsub("_", " "))
end

-- sponsorblock_categories: fetched, skipped and shown as chapters.
local category_list, labels = {}, {}
local close = {}
for c in conf.sponsorblock_categories:gmatch("[^,]+") do
    c = c:gsub("%s", "")
    if c ~= "" and not labels[c] then
        category_list[#category_list + 1] = c
        labels[c] = category_title(c)
        close[labels[c]] = "Video"   -- chapter title where the segment ends
    end
end
-- the category list is part of the cache key: changing it must not reuse old data
local categories_key = util.cache_key(table.concat(category_list, ","))

local youtube_id = nil

------------------------------------------------------------------
-- Video id detection
-- Returns id, strong. Strong = a YouTube URL or a [id] in the filename; anything
-- id-shaped (11 characters) in a title or filename tail is only a weak guess.
------------------------------------------------------------------
local url_patterns = {
    "ytdl://([%w%-_]+).*",
    "https?://youtu%.be/([%w%-_]+).*",
    "https?://w?w?w?%.?youtube%.com/v/([%w%-_]+).*",
    "/watch.*[?&]v=([%w%-_]+).*",
    "/embed/([%w%-_]+).*",
}

local metadata_keys = {
    "metadata/by-key/comment", "metadata/by-key/COMMENT",
    "metadata/by-key/purl", "metadata/by-key/PURL",
    "metadata/by-key/title", "metadata/by-key/TITLE",
    "metadata/by-key/description", "metadata/by-key/DESCRIPTION",
}

local function find_id()
    local video_path = mp.get_property("path", "")
    local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""

    for _, pattern in ipairs(url_patterns) do
        local id = string.match(video_path, pattern) or string.match(video_referer, pattern)
        if id and #id == 11 then return id, true end
    end

    local bracket = string.match(video_path, "%[([%w%-_]+)%]%..+$")
    if bracket and #bracket == 11 then return bracket, true end

    local weak = string.match(video_path, "%(([%w%-_]+)%)%..+$")
                 or string.match(video_path, "%-([%w%-_]+)%..+$")
    if weak and #weak == 11 then return weak, false end

    for _, key in ipairs(metadata_keys) do
        local val = mp.get_property(key, "")
        if val ~= "" then
            for _, pattern in ipairs(url_patterns) do
                local id = string.match(val, pattern)
                if id and #id == 11 then return id, true end
            end
            if string.match(val, "^([%w%-_]+)$") and #val == 11 then return val, false end
        end
    end

    return nil
end

------------------------------------------------------------------
-- Source interface
------------------------------------------------------------------
local M = { online = true, close = close }

-- id, strong  (nil when this is not a YouTube video)
function M.detect()
    youtube_id = nil
    if #category_list == 0 then return nil end
    local id, strong = find_id()
    youtube_id = id
    return id, strong
end

function M.applicable()
    return youtube_id ~= nil
end

function M.cache_key()
    return youtube_id .. "-" .. categories_key
end

local function encode_categories()
    local parts = {}
    for _, cat in ipairs(category_list) do parts[#parts + 1] = '"' .. cat .. '"' end
    return util.url_encode("[" .. table.concat(parts, ",") .. "]")
end

-- done(body) | done(nil, reason, final)
function M.fetch(done, alive)
    local url = SERVER .. "/api/skipSegments?videoID=" .. youtube_id
             .. "&categories=" .. encode_categories()
    log.curl("GET", url, nil, nil, function(body, code)
        if not alive() then return end
        if body then
            done(body)
        elseif code == 404 then
            done(nil, "no segments for this video", true)
        else
            done(nil, "request failed")
        end
    end)
end

function M.parse(body)
    local data = utils.parse_json(body)
    local intervals = {}
    if type(data) ~= "table" then return intervals end
    for _, entry in ipairs(data) do
        local seg = entry.segment
        local label = entry.category and labels[entry.category]
        if label and seg and seg[1] and seg[2] then
            local start_time, end_time = tonumber(seg[1]), tonumber(seg[2])
            if start_time and end_time and end_time - start_time >= MIN_DURATION then
                intervals[#intervals + 1] = {
                    start_time = start_time, end_time = end_time, label = label,
                }
            end
        end
    end
    return intervals
end

return M
