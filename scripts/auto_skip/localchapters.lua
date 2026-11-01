--[[
    localchapters.lua
    Source "local": skips chapters of the file itself by title: openings, endings,
    previews, intros, and your own one-off titles under Misc. Fully offline, first in
    the default priority chain. Which categories are skipped lives in auto_skip.conf
    (local_categories).

    A chapter runs until the next chapter starts (or the end of the file).

    The title lists below are Lua, so they stay here. Words are exact,
    case-insensitive matches; patterns use Lua pattern syntax, not regular
    expressions. Add personal one-off titles to the Misc lists.
]]
local mp = require("mp")
local core = require("autoskip")
local util, chapter_store = core.util, core.chapters

local lists = {
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
}

------------------------------------------------------------------
-- Category matching
------------------------------------------------------------------
local categories = {
    { label = "Opening", words = lists.opening_words, patterns = lists.opening_patterns },
    { label = "Ending",  words = lists.ending_words,  patterns = lists.ending_patterns  },
    { label = "Preview", words = lists.preview_words, patterns = lists.preview_patterns },
    { label = "Intro",   words = lists.intro_words,   patterns = lists.intro_patterns   },
    { label = "Misc",    words = lists.misc_words,    patterns = lists.misc_patterns    },
}

local trim_lower = util.trim_lower

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

------------------------------------------------------------------
-- Intervals from the file's own chapters
------------------------------------------------------------------
-- Returns every labelled chapter; main.lua keeps the ones in local_categories.
local function scan()
    local intervals = {}
    local original = chapter_store.original()
    for i, chapter in ipairs(original) do
        local label = get_chapter_label(chapter.title)
        if label then
            local start_time = tonumber(chapter.time) or 0
            local next_time = original[i + 1] and tonumber(original[i + 1].time)
            local end_time = next_time or mp.get_property_number("duration", start_time + 90)

            if end_time > start_time then
                intervals[#intervals + 1] = {
                    start_time = start_time,
                    end_time   = end_time,
                    label      = label,
                }
            end
        end
    end
    return intervals
end

return { online = false, scan = scan }
