local mp = require 'mp'
local options = require 'mp.options'

local config = {
    -- Full subtitle matching (when audio language differs from subtitle language).
    -- Earlier keywords have higher priority.
    priority_keywords = "dialogue,full,complete",
    reject_keywords   = "signs,songs,commentary",

    -- Signs / forced subtitle matching (when audio matches subtitle language).
    -- Earlier keywords have higher priority; the track.forced flag takes precedence.
    forced_keywords   = "signs,songs,forced,s&s",
    forced_reject_keywords = "commentary",

    -- Adapt subtitle selection to the active audio language.
    audio_aware = true,

    -- 'no' = turn subs off; 'full' = fall back to full dialogue; 'keep' = leave sid unchanged.
    fallback_on_matching_audio = "no",

    -- Re-select subtitles when the active audio track changes.
    observe_audio_switches = true,

    -- Stop automatic changes after the user manually selects a subtitle.
    -- The protection resets for each newly loaded file. Selecting sid=auto resumes it.
    respect_manual_selection = true,

    -- Infer a language for external subtitle tracks when mpv provides no lang metadata.
    infer_external_lang = true,
}
options.read_options(config, "smart_subs")

if config.fallback_on_matching_audio ~= "no"
    and config.fallback_on_matching_audio ~= "full"
    and config.fallback_on_matching_audio ~= "keep" then
    mp.msg.warn("invalid fallback_on_matching_audio; using 'no'")
    config.fallback_on_matching_audio = "no"
end

local function parse_list(str)
    local list = {}
    for item in (str or ""):gmatch("([^,]+)") do
        item = item:match("^%s*(.-)%s*$"):lower()
        if item ~= "" then
            list[#list + 1] = item
        end
    end
    return list
end

local function keyword_rank(title, keywords)
    if not title or title == "" then return nil end
    title = title:lower()
    for rank, keyword in ipairs(keywords) do
        if title:find(keyword, 1, true) then
            return rank
        end
    end
    return nil
end

local function has_keyword(title, keywords)
    return keyword_rank(title, keywords) ~= nil
end

local language_groups = {
    en = { "en", "eng", "english" },
    ja = { "ja", "jpn", "jap", "japanese" },
    zh = { "zh", "zho", "chi", "chinese" },
    ko = { "ko", "kor", "korean" },
    fr = { "fr", "fra", "fre", "french" },
    de = { "de", "deu", "ger", "german" },
    es = { "es", "spa", "spanish" },
    it = { "it", "ita", "italian" },
    ru = { "ru", "rus", "russian" },
    pt = { "pt", "por", "pob", "portuguese" },
}

local language_aliases = {}
for canonical, aliases in pairs(language_groups) do
    for _, alias in ipairs(aliases) do
        language_aliases[alias] = canonical
    end
end

local function normalize_lang(lang)
    if not lang or lang == "" then return nil end
    local clean = lang:lower():match("^([a-z]+)")
    if not clean then return nil end
    return language_aliases[clean] or clean
end

local function langs_match(lang_a, lang_b)
    local norm_a = normalize_lang(lang_a)
    local norm_b = normalize_lang(lang_b)
    return norm_a ~= nil and norm_b ~= nil and norm_a == norm_b
end

local function infer_external_lang(track)
    local candidates = {
        track.title,
        track["external-filename"],
    }

    for _, candidate in ipairs(candidates) do
        if candidate and candidate ~= "" then
            -- Token matching supports names such as Movie.en.srt, Movie.jpn.ass,
            -- Movie (English).srt and locale-style names such as Movie.en-US.srt.
            for token in candidate:lower():gmatch("[a-z]+") do
                local canonical = language_aliases[token]
                if canonical then return canonical end
            end
        end
    end
    return nil
end

local function get_track_lang(track)
    local lang = normalize_lang(track.lang)
    if lang and lang ~= "und" and lang ~= "unknown" and lang ~= "zxx" then
        return lang
    end
    if config.infer_external_lang and track.external then
        return infer_external_lang(track)
    end
    return nil
end

local function matches_preferred_language(track, preferred)
    local track_lang = get_track_lang(track)
    if not track_lang then return false end

    for _, preferred_lang in ipairs(preferred) do
        if langs_match(track_lang, preferred_lang) then
            return true
        end
    end
    return false
end

local function get_active_audio_track()
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
        if track.type == "audio" and track.selected then
            return track
        end
    end
    return nil
end

local manual_override = false
local last_sid = tostring(mp.get_property("sid", "auto"))

local function set_sid(value)
    value = tostring(value)
    -- Update before setting the property so our own sid observer callback is ignored.
    last_sid = value
    mp.set_property("sid", value)
end

local function on_sid_changed(_, sid)
    local value = tostring(sid or "auto")
    if value == last_sid then return end
    last_sid = value

    if not config.respect_manual_selection then return end

    if value == "auto" then
        if manual_override then
            mp.msg.info("manual subtitle override cleared; automatic selection resumed")
        end
        manual_override = false
    else
        manual_override = true
        mp.msg.info("manual subtitle selection detected; automatic selection paused for this file")
    end
end
mp.observe_property("sid", "native", on_sid_changed)

local function select_best_subtitle()
    if mp.get_property("options/sid") ~= "auto" then
        mp.msg.info("skipped (options/sid is not auto)")
        return
    end

    if config.respect_manual_selection and manual_override then
        mp.msg.info("skipped (manual subtitle selection is being respected)")
        return
    end

    local slang = mp.get_property("options/slang")
    if not slang or slang == "no" then
        mp.msg.info("skipped (no slang)")
        return
    end

    local preferred = parse_list(slang)
    if #preferred == 0 then
        mp.msg.info("skipped (no usable slang entries)")
        return
    end

    local active_audio = get_active_audio_track()
    local audio_lang = active_audio and active_audio.lang
    local audio_matches_sub = false

    if config.audio_aware and audio_lang then
        for _, preferred_lang in ipairs(preferred) do
            if langs_match(audio_lang, preferred_lang) then
                audio_matches_sub = true
                break
            end
        end
    end

    local tracks = mp.get_property_native("track-list") or {}

    if audio_matches_sub then
        local forced_kw = parse_list(config.forced_keywords)
        local forced_rej = parse_list(config.forced_reject_keywords)
        local best_forced, best_signs
        local best_signs_rank

        for _, track in ipairs(tracks) do
            if track.type == "sub" and matches_preferred_language(track, preferred) then
                local title = (track.title or ""):lower()
                if not has_keyword(title, forced_rej) then
                    if track.forced then
                        best_forced = best_forced or track
                    else
                        local rank = keyword_rank(title, forced_kw)
                        if rank and (not best_signs_rank or rank < best_signs_rank) then
                            best_signs = track
                            best_signs_rank = rank
                        end
                    end
                end
            end
        end

        local chosen = best_forced or best_signs
        if chosen then
            set_sid(chosen.id)
            mp.msg.info(string.format("Selected signs/forced sub #%s \"%s\" (audio match: %s)",
                tostring(chosen.id), chosen.title or "untitled", audio_lang or "unknown"))
            return
        end

        if config.fallback_on_matching_audio == "no" then
            set_sid("no")
            mp.msg.info(string.format("Audio is %s; no signs/forced sub found, turning subs off", audio_lang))
            return
        elseif config.fallback_on_matching_audio == "keep" then
            mp.msg.info(string.format("Audio is %s; keeping current sub state", audio_lang))
            return
        end
        -- 'full' continues to normal full-dialogue selection below.
    end

    local priority = parse_list(config.priority_keywords)
    local reject = parse_list(config.reject_keywords)
    local best_priority, best_normal
    local best_priority_rank

    for _, track in ipairs(tracks) do
        if track.type == "sub" and not track.forced
            and matches_preferred_language(track, preferred) then
            local title = (track.title or ""):lower()
            if not has_keyword(title, reject) then
                local rank = keyword_rank(title, priority)
                if rank then
                    if not best_priority_rank or rank < best_priority_rank then
                        best_priority = track
                        best_priority_rank = rank
                    end
                else
                    best_normal = best_normal or track
                end
            end
        end
    end

    local best = best_priority or best_normal
    if not best then
        mp.msg.info("no matching track")
        return
    end

    set_sid(best.id)
    mp.msg.info(string.format("Selected sub #%s \"%s\" (%s, audio: %s)",
        tostring(best.id), best.title or "untitled",
        best_priority and "priority" or "normal", audio_lang or "unknown"))
end

local audio_switch_timer
local current_aid = mp.get_property_native("aid")

local function cancel_audio_switch_timer()
    if audio_switch_timer then
        audio_switch_timer:kill()
        audio_switch_timer = nil
    end
end

local function schedule_selection()
    cancel_audio_switch_timer()
    audio_switch_timer = mp.add_timeout(0.05, function()
        audio_switch_timer = nil
        select_best_subtitle()
    end)
end

mp.register_event("file-loaded", function()
    cancel_audio_switch_timer()
    manual_override = false
    last_sid = tostring(mp.get_property("sid", "auto"))
    current_aid = mp.get_property_native("aid")
    select_best_subtitle()
end)

if config.observe_audio_switches then
    mp.observe_property("aid", "native", function(_, aid)
        if aid == current_aid then return end
        current_aid = aid
        schedule_selection()
    end)
end
