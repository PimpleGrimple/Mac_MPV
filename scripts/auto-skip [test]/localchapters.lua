--[[
    localchapters.lua
    Skips chapters of the file itself by title: openings, endings, previews,
    intros, and your own one-off titles under Misc. Fully offline.

    A chapter runs until the next chapter starts. Chapters longer than
    max_length are treated as overlong_length instead (a mislabeled chapter
    shouldn't swallow half the video).
]]
local mp = require("mp")
local core = require("autoskip")
local util, chapter_store, skip = core.util, core.chapters, core.skip

local M = {}

------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------
local opts = {
    enabled             = true,

    -- Core behavior
    auto_skip           = true,
    skip_once           = true,
    advance_on_ending   = true,

    -- Skip UI
    -- Set auto_skip=false to use the optional on-screen skip button.
    show_skip_button    = false,
    show_skip_feedback  = true,
    skip_key            = "ENTER",
    timeout             = 5,
    toggle_key          = "alt+l",
    accent_color        = "A78BFA",

    -- Chapter categories to skip. Case-insensitive, comma-separated.
    skip_categories     = "Opening,Ending,Preview,Intro,Misc",

    -- Chapter length handling (seconds)
    max_length          = 180,
    overlong_length     = 90,

    -- Title matching.
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
}

local LOG_PREFIX = "[chapters] "

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

local skip_categories_set = util.category_set(opts.skip_categories)

------------------------------------------------------------------
-- Intervals from the file's own chapters
------------------------------------------------------------------
local function build_intervals()
    local intervals = {}
    local original = chapter_store.original()
    for i, chapter in ipairs(original) do
        local label = get_chapter_label(chapter.title)
        if label and skip_categories_set[trim_lower(label)] then
            local start_time = tonumber(chapter.time) or 0
            local next_time = original[i + 1] and tonumber(original[i + 1].time)
            local end_time = next_time or mp.get_property_number("duration", start_time + 90)

            if end_time - start_time > opts.max_length then
                end_time = start_time + opts.overlong_length
            end

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

local function publish()
    if opts.enabled then
        skip.set("localchapters", build_intervals())
    else
        skip.clear("localchapters")
    end
end

local function set_enabled(value)
    value = not not value
    if opts.enabled == value then return end
    opts.enabled = value
    publish()
    mp.osd_message(LOG_PREFIX .. "Local chapter skipping "
        .. (value and "enabled" or "disabled"), 1.5)
end

------------------------------------------------------------------
-- Provider interface
------------------------------------------------------------------
function M.setup()
    skip.register("localchapters", opts)

    mp.register_script_message("localchapters-toggle-state", function(val)
        set_enabled(val == "true")
    end)

    mp.add_key_binding(opts.toggle_key, "localchapters-toggle", function()
        set_enabled(not opts.enabled)
    end)
end

M.on_file_loaded = publish

return M
