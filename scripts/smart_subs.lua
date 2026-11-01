local mp = require 'mp'
local options = require 'mp.options'

local config = {
    priority_keywords = "dialogue,full,complete",
    reject_keywords   = "signs,songs,commentary",
}
options.read_options(config, "smart_subs")

local function parse_list(str)
    local list = {}
    for item in (str or ""):gmatch("([^,]+)") do
        list[#list + 1] = item:match("^%s*(.-)%s*$"):lower()
    end
    return list
end

local function has_keyword(title, keywords)
    for _, kw in ipairs(keywords) do
        if title:find(kw, 1, true) then return true end
    end
    return false
end

local function select_best_subtitle()
    local opt_sid = mp.get_property("options/sid")
    if opt_sid ~= "auto" then
        mp.msg.info("skipped (sid=" .. tostring(opt_sid) .. ")")
        return
    end

    local slang = mp.get_property("options/slang")
    if not slang or slang == "no" then
        mp.msg.info("skipped (no slang)")
        return
    end

    local preferred = parse_list(slang)
    local priority  = parse_list(config.priority_keywords)
    local reject    = parse_list(config.reject_keywords)

    local first_priority, first_normal
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
        if track.type == "sub" and not track.forced and track.lang then
            local tl = track.lang:lower()
            local lang_ok = false
            for _, p in ipairs(preferred) do
                if tl:find(p, 1, true) then lang_ok = true; break end
            end
            if lang_ok then
                local title = (track.title or ""):lower()
                if not has_keyword(title, reject) then
                    if has_keyword(title, priority) then
                        first_priority = first_priority or track
                    else
                        first_normal = first_normal or track
                    end
                end
            end
        end
    end

    local best, reason = first_priority, "priority"
    if not best then best, reason = first_normal, "normal" end
    if not best then
        mp.msg.info("no matching track")
        return
    end

    mp.set_property("sid", best.id)
    mp.msg.info(string.format("#%d \"%s\" (%s)",
        best.id, best.title or "untitled", reason))
end

mp.register_event("file-loaded", select_best_subtitle)