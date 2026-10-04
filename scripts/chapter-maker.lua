local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local opt = require 'mp.options'

-- Make sure optional modules (user-input-module) can be found.
for _, dir in ipairs({ "~~/script-modules", "~~/scripts" }) do
    package.path = mp.command_native({ "expand-path", dir }) .. "/?.lua;" .. package.path
end
local user_input_loaded, user_input = pcall(require, "user-input-module")

local EPS = 0.01 -- 10ms tolerance when matching chapter boundaries
local MAX_TITLE_LEN = 100
local URL_PATTERN = "^%a[%w+.-]*://"

-- chapter_maker.conf options. Keybinds are NOT options: override them in input.conf, e.g.
--   Alt+r script-binding chapter-maker/rename_chapter      (use "ignore" to disable a default key)
local options = {
    ask_for_title = true,
    pause_on_prompt = true,
    mkvpropedit_path = "mkvpropedit",
}
opt.read_options(options, "chapter_maker")
if options.mkvpropedit_path == "mkvpropedit" and utils.file_info("/opt/homebrew/bin/mkvpropedit") then
    options.mkvpropedit_path = "/opt/homebrew/bin/mkvpropedit" -- GUI-launched mpv often lacks Homebrew in PATH
end

local chapters_dir = mp.command_native({ "expand-path", "~~/cache/scripts/chapters" })
local active_prompt = nil
local undo_snapshot = nil -- editable chapters before the last edit (undo toggles with redo)
local embed_armed = nil   -- timer while an embed confirmation is pending
local MKV_EXT = { mkv = true, mka = true, mk3d = true, webm = true }

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

-- Cut to at most `max` bytes without splitting a UTF-8 character.
local function utf8_truncate(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1) -- first byte that would be dropped
        if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
    end
    return s:sub(1, cut)
end

-- 32-bit FNV-1a path hash
local function hash_path(str)
    local hash = 2166136261
    for i = 1, #str do
        hash = ((hash ~ str:byte(i)) * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function sanitize_title(title)
    title = tostring(title or ""):gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    return utf8_truncate(title, MAX_TITLE_LEN)
end

local function format_timestamp(seconds)
    local ms = math.floor(math.max(0, tonumber(seconds) or 0) * 1000 + 0.5)
    return string.format("%02d:%02d:%02d.%03d", math.floor(ms / 3600000), math.floor(ms / 60000) % 60, math.floor(ms / 1000) % 60, ms % 1000)
end

-- HH:MM:SS.mmm, MM:SS.mmm or plain seconds; comma or dot decimals.
local function parse_time_str(str)
    local parts = {}
    for p in tostring(str):gsub(",", "."):gmatch("[^:]+") do
        local v = tonumber(p)
        if not v then return nil end
        parts[#parts + 1] = v
    end
    if #parts == 0 or #parts > 3 then return nil end
    local total = 0
    for i, v in ipairs(parts) do
        if i > 1 and v >= 60 then return nil end
        total = total * 60 + v
    end
    return total
end

-- Absolute path for files (so relative invocations don't share a cache key), raw string for URLs.
local function media_path()
    local path = mp.get_property("path")
    if not path or path == "" then return nil end
    if not path:find(URL_PATTERN) then
        path = utils.join_path(mp.get_property("working-directory", ""), path)
    end
    return path
end

---------------------------------------------------------------------------
-- Chapter list helpers
---------------------------------------------------------------------------

local function is_protected(ch)
    return tostring(ch and ch.title or ""):lower():find("^%s*%[sponsorblock%]") ~= nil
end

local function select_chapters(chapters, want_protected)
    local out = {}
    for _, ch in ipairs(chapters or {}) do
        if is_protected(ch) == want_protected then out[#out + 1] = ch end
    end
    return out
end

local function normalize_chapters(chapters)
    local clean = {}
    for idx, ch in ipairs(chapters or {}) do
        local time = tonumber(ch.time)
        if time then
            clean[#clean + 1] = { title = sanitize_title(ch.title), time = math.max(0, time), idx = idx }
        end
    end
    table.sort(clean, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.idx < b.idx
    end)
    for _, ch in ipairs(clean) do ch.idx = nil end
    return clean
end

local function get_current_chapters()
    return normalize_chapters(mp.get_property_native("chapter-list") or {})
end

local function get_editable_chapters()
    return select_chapters(get_current_chapters(), false)
end

local function ensure_zero_chapter(chapters)
    if chapters[1] and chapters[1].time <= EPS then
        chapters[1].time = 0
    else
        table.insert(chapters, 1, { title = "Chapter 01", time = 0 })
    end
end

-- Nearest editable chapter within epsilon (SponsorBlock chapters are never matched).
local function find_chapter_at(chapters, time_pos, epsilon)
    local best_idx, best_delta = nil, epsilon or EPS
    for i, ch in ipairs(chapters) do
        if not is_protected(ch) then
            local delta = math.abs(ch.time - time_pos)
            if delta <= best_delta then best_idx, best_delta = i, delta end
        end
    end
    return best_idx
end

local function ensure_boundary_at(chapters, time_pos, default_title)
    local idx = find_chapter_at(chapters, time_pos)
    if idx then
        chapters[idx].time = time_pos
        if chapters[idx].title == "" then chapters[idx].title = default_title end
    else
        chapters[#chapters + 1] = { title = default_title, time = time_pos }
    end
end

local function remove_boundaries_between(chapters, start_time, end_time)
    local result = {}
    for _, ch in ipairs(chapters) do
        if ch.time <= start_time + EPS or ch.time >= end_time - EPS then
            result[#result + 1] = ch
        end
    end
    return result
end

---------------------------------------------------------------------------
-- Persistence (JSON cache + sidecar files)
---------------------------------------------------------------------------

local function get_cache_path()
    local path = media_path()
    if not path then return nil end
    local name = (mp.get_property("filename/no-ext") or "media"):gsub("[/\\:*?\"<>|]", "_")
    return utils.join_path(chapters_dir, utf8_truncate(name, 60) .. "_" .. hash_path(path) .. ".json")
end

-- First entry is the export target.
local function sidecar_paths()
    local path = media_path()
    if not path or path:find(URL_PATTERN) then return {} end
    local dir = utils.split_path(path)
    local base = mp.get_property("filename/no-ext") or "media"
    return {
        utils.join_path(dir, base .. ".chapters.txt"),
        utils.join_path(dir, base .. ".chp"),
    }
end

local function atomic_write(filepath, content)
    local tmp = string.format("%s.%d.tmp", filepath, utils.getpid())
    local f, err = io.open(tmp, "wb")
    if not f then
        msg.error("Cannot open " .. tmp .. ": " .. tostring(err))
        return false
    end
    local ok, werr = f:write(content)
    f:close()
    if ok and os.rename(tmp, filepath) then return true end
    os.remove(tmp)
    msg.error("Failed to write " .. filepath .. ": " .. tostring(werr))
    return false
end

local function ensure_cache_dir()
    if not utils.file_info(chapters_dir) then
        mp.command_native({ name = "subprocess", args = { "mkdir", "-p", chapters_dir }, playback_only = false })
    end
end

local function save_chapters(chapters)
    local filepath = get_cache_path()
    if not filepath then return end
    ensure_cache_dir()
    local json = utils.format_json({
        version = 2,
        media_path = media_path(),
        media_title = mp.get_property("media-title") or "",
        saved_at = os.date("%Y-%m-%d %H:%M:%S"),
        chapters = chapters,
    })
    if atomic_write(filepath, json) then msg.info("Chapters saved to cache: " .. filepath) end
end

-- Replace the editable chapters in mpv; SponsorBlock chapters already in mpv are kept untouched.
local function apply_chapters(user_chapters)
    local combined = select_chapters(user_chapters, false)
    for _, ch in ipairs(select_chapters(get_current_chapters(), true)) do
        combined[#combined + 1] = ch
    end
    mp.set_property_native("chapter-list", normalize_chapters(combined))
end

-- Single entry point for every edit: apply to mpv + persist. Accepts a full list; protected entries are dropped.
-- keep_undo: don't replace the undo snapshot (used so "split + title" undoes as one step).
local function commit_chapters(chapters, keep_undo)
    if not keep_undo then undo_snapshot = get_editable_chapters() end
    chapters = normalize_chapters(select_chapters(chapters, false))
    apply_chapters(chapters)
    save_chapters(chapters)
end

-- Reads OGM (CHAPTER01=... / CHAPTER01NAME=...) and simple "HH:MM:SS Title" lines.
local function load_sidecar(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local tagged, simple, max_idx = {}, {}, 0
    for raw in f:lines() do
        local line = raw:gsub("^\239\187\191", ""):gsub("\r", ""):match("^%s*(.-)%s*$") -- strip BOM / CR / padding
        local lower = line:lower()
        local time_id = lower:match("^chapter(%d+)=")
        local name_id = lower:match("^chapter(%d+)name=")
        local value = line:match("=(.*)$")

        if time_id then
            local sec, i = parse_time_str(value), tonumber(time_id)
            if sec then
                tagged[i] = tagged[i] or {}
                tagged[i].time = sec
                max_idx = math.max(max_idx, i)
            end
        elseif name_id then
            local i = tonumber(name_id)
            tagged[i] = tagged[i] or {}
            tagged[i].title = sanitize_title(value)
            max_idx = math.max(max_idx, i)
        else
            local ts, title = line:match("^(%d+:%d%d[%d:%.]*)%s*(.*)$")
            local sec = ts and parse_time_str(ts)
            if sec then
                simple[#simple + 1] = { time = sec, title = sanitize_title((title:gsub("^[%-:%s]+", ""))) }
            end
        end
    end
    f:close()

    local chapters = {}
    for i = 1, max_idx do
        local ch = tagged[i]
        if ch and ch.time then
            chapters[#chapters + 1] = {
                title = ch.title and ch.title ~= "" and ch.title or string.format("Chapter %02d", i),
                time = ch.time,
            }
        end
    end
    for _, ch in ipairs(simple) do chapters[#chapters + 1] = ch end
    return #chapters > 0 and normalize_chapters(chapters) or nil
end

local function load_cache(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()

    local data = content ~= "" and utils.parse_json(content)
    if type(data) ~= "table" or type(data.chapters) ~= "table" then return nil end
    local version = tonumber(data.version) or 1
    if version > 2 then
        msg.warn("Unsupported chapter cache version: " .. version)
        return nil
    end
    return normalize_chapters(data.chapters)
end

-- Newest source wins (cache beats sidecars on a tie); an unreadable source falls through to the next.
local function load_chapters()
    local sources = {}
    local function add(path, loader)
        local info = path and utils.file_info(path)
        if info then
            sources[#sources + 1] = { path = path, load = loader, mtime = info.mtime, order = #sources }
        end
    end
    add(get_cache_path(), load_cache)
    for _, p in ipairs(sidecar_paths()) do add(p, load_sidecar) end

    table.sort(sources, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.order < b.order
    end)

    for _, s in ipairs(sources) do
        local chapters = s.load(s.path)
        if chapters then
            apply_chapters(chapters)
            msg.info(string.format("Loaded %d chapters from %s", #chapters, s.path))
            if s.load == load_sidecar then
                mp.osd_message(string.format("Loaded %d sidecar chapters", #chapters), 2)
            end
            return
        end
    end
end

---------------------------------------------------------------------------
-- Title prompt
---------------------------------------------------------------------------

local function cancel_active_prompt()
    local p = active_prompt
    if not p then return end
    active_prompt = nil
    if p.req and p.req.cancel then pcall(p.req.cancel, p.req) end
    if p.was_paused ~= nil and mp.get_property("path") == p.path then
        mp.set_property_bool("pause", p.was_paused)
    end
end

local function change_chapter_title(title, time_pos, keep_undo)
    title = sanitize_title(title)
    if title == "" then return end

    local chapters = get_editable_chapters()
    local idx = find_chapter_at(chapters, time_pos, EPS * 5)
    if not idx then
        mp.osd_message("Cannot rename: chapter not found or protected", 2)
        return
    end
    chapters[idx].title = title
    commit_chapters(chapters, keep_undo)
    mp.osd_message("Chapter title set to: " .. title, 2)
end

local function prompt_for_title(time_pos, default_title, label, keep_undo)
    cancel_active_prompt()

    if not user_input_loaded then
        mp.osd_message("user-input-module not found. Can't prompt.", 2)
        return
    end

    local prompt = { path = mp.get_property("path") }
    active_prompt = prompt
    if options.pause_on_prompt then
        prompt.was_paused = mp.get_property_native("pause")
        mp.set_property_bool("pause", true)
    end

    prompt.req = user_input.get_user_input(function(text)
        if active_prompt ~= prompt then return end -- cancelled or superseded
        active_prompt = nil
        if mp.get_property("path") ~= prompt.path then return end

        if prompt.was_paused ~= nil then mp.set_property_bool("pause", prompt.was_paused) end
        if text and text ~= "" then change_chapter_title(text, time_pos, keep_undo) end
    end, {
        request_text = label .. " (" .. format_timestamp(time_pos) .. "):",
        default_input = default_title,
    })
end

-- Shared tail of split / A-B: save, optionally jump to the new chapter, then ask for a title (or just report).
local function finish_edit(chapters, time_pos, default_title, done_msg, seek)
    commit_chapters(chapters)

    if seek then
        local idx = find_chapter_at(get_current_chapters(), time_pos)
        if idx then
            mp.add_timeout(0, function() mp.set_property_number("chapter", idx - 1) end)
        end
    end

    if options.ask_for_title then
        prompt_for_title(time_pos, default_title, "Chapter title", true)
    else
        mp.osd_message(done_msg, 2)
    end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function split_chapter()
    local time_pos = mp.get_property_number("time-pos")
    if not time_pos then return end

    local chapters = get_editable_chapters()
    local zero_added = not chapters[1] or chapters[1].time > EPS
    ensure_zero_chapter(chapters)

    local title, time = "Chapter 01", 0
    local existing = find_chapter_at(chapters, time_pos)

    if existing then
        -- Only OK when we are sitting at ~0 and Chapter 01 was just created by ensure_zero_chapter.
        if not zero_added then
            mp.osd_message("Chapter boundary already exists here", 2)
            return
        end
    else
        local insert_idx = 1
        for i, ch in ipairs(chapters) do
            if time_pos > ch.time then insert_idx = i + 1 else break end
        end
        title, time = string.format("Chapter %02d", insert_idx), time_pos
        table.insert(chapters, insert_idx, { title = title, time = time })
    end

    finish_edit(chapters, time, title, "Split chapter at " .. format_timestamp(time), false)
end

-- Turns mpv's own A-B loop (default key: l, l) into a chapter segment and clears the loop.
local function mark_ab_chapter()
    local a, b = mp.get_property_number("ab-loop-a"), mp.get_property_number("ab-loop-b")
    if not (a and b) then
        mp.osd_message("Set an A-B loop first (press l twice), then run this again", 3)
        return
    end
    mp.set_property("ab-loop-a", "no")
    mp.set_property("ab-loop-b", "no")

    local t_start, t_end = math.min(a, b), math.max(a, b)
    if t_end - t_start < 0.5 then
        mp.osd_message("Points A and B are too close (< 0.5s). Cancelled.", 3)
        return
    end

    local chapters = get_editable_chapters()
    ensure_zero_chapter(chapters)

    -- The chapter that B cuts into keeps its title after B.
    local end_title
    for _, ch in ipairs(chapters) do
        if ch.time <= t_end + EPS and ch.title ~= "" then end_title = ch.title end
    end

    chapters = remove_boundaries_between(chapters, t_start, t_end)
    ensure_boundary_at(chapters, t_start, "Chapter at " .. format_timestamp(t_start))
    ensure_boundary_at(chapters, t_end, end_title or ("Chapter at " .. format_timestamp(t_end)))

    local default_title = chapters[find_chapter_at(chapters, t_start)].title
    finish_edit(chapters, t_start, default_title,
        string.format("Created chapter segment [%s -> %s]", format_timestamp(t_start), format_timestamp(t_end)), true)
end

local function undo_last_edit()
    if not undo_snapshot then
        mp.osd_message("Nothing to undo", 2)
        return
    end
    cancel_active_prompt()
    commit_chapters(undo_snapshot) -- snapshots the current state, so pressing again redoes
    mp.osd_message("Chapters restored (press again to redo)", 2)
end

-- The chapter mpv says is playing, if it is user-editable. Returns (all_chapters, index) or (nil, nil, error).
local function get_current_editable()
    local all = get_current_chapters()
    local idx = mp.get_property_number("chapter", -1) + 1
    if not all[idx] then return nil, nil, "No chapter at current position" end
    if is_protected(all[idx]) then return nil, nil, "SponsorBlock chapter is protected" end
    return all, idx
end

local function rename_current_chapter()
    local all, idx, err = get_current_editable()
    if not all then return mp.osd_message(err, 2) end

    local ch = all[idx]
    prompt_for_title(ch.time, ch.title ~= "" and ch.title or string.format("Chapter %02d", idx), "Rename chapter")
end

local function remove_chapter()
    local all, idx, err = get_current_editable()
    if not all then return mp.osd_message(err, 2) end

    local ch = table.remove(all, idx)
    commit_chapters(all)
    mp.osd_message("Removed " .. (ch.title ~= "" and ch.title or "Chapter at " .. format_timestamp(ch.time)), 2)
end

local function ogm_text(chapters)
    local lines = {}
    for i, ch in ipairs(chapters) do
        lines[#lines + 1] = string.format("CHAPTER%02d=%s", i, format_timestamp(ch.time))
        lines[#lines + 1] = string.format("CHAPTER%02dNAME=%s", i, ch.title ~= "" and ch.title or string.format("Chapter %02d", i))
    end
    return table.concat(lines, "\n") .. "\n"
end

local function export_chapters()
    local chapters = get_editable_chapters()
    if #chapters == 0 then
        mp.osd_message("No chapters to export", 2)
        return
    end

    local target = sidecar_paths()[1]
    if not target then
        mp.osd_message("Cannot export chapters for this media type", 3)
        return
    end

    if atomic_write(target, ogm_text(chapters)) then
        msg.info("Exported OGM chapters next to media: " .. target)
        mp.osd_message(string.format("Exported %d chapters (.chapters.txt)", #chapters), 3)
    else
        mp.osd_message("Failed to export chapters", 3)
    end
end

-- Writes the editable chapters into the Matroska file itself with mkvpropedit (in place, no remux).
-- Needs a second press within 5s to confirm.
local function embed_chapters()
    local path = media_path()
    local ext = path and not path:find(URL_PATTERN) and path:match("%.(%w+)$")
    if not (ext and MKV_EXT[ext:lower()]) then
        mp.osd_message("Embedding only works for local Matroska files (.mkv/.mka/.webm)", 3)
        return
    end

    local chapters = get_editable_chapters()
    if #chapters == 0 then
        mp.osd_message("No chapters to embed", 2)
        return
    end

    if not embed_armed then
        embed_armed = mp.add_timeout(5, function() embed_armed = nil end)
        mp.osd_message(string.format("Press again within 5s to write %d chapters into the file (modifies it in place)",
            #chapters), 5)
        return
    end
    embed_armed:kill()
    embed_armed = nil

    ensure_cache_dir()
    local tmp = utils.join_path(chapters_dir, string.format("embed_%d.txt", utils.getpid()))
    if not atomic_write(tmp, ogm_text(chapters)) then
        mp.osd_message("Failed to embed chapters", 3)
        return
    end

    mp.osd_message("Embedding chapters...", 2)
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { options.mkvpropedit_path, path, "--chapters", tmp },
    }, function(_, res)
        os.remove(tmp)
        -- mkvpropedit exit codes: 0 = ok, 1 = ok with warnings, 2 = error. Failing to start gives status < 0.
        if res and (res.status == 0 or res.status == 1) then
            mp.osd_message(string.format("Embedded %d chapters into the file", #chapters), 3)
        else
            local detail = res and ((res.stderr ~= "" and res.stderr) or (res.stdout ~= "" and res.stdout) or res.error_string)
            msg.error("mkvpropedit failed: " .. tostring(detail))
            mp.osd_message("Embedding failed (see log; is mkvpropedit installed? set mkvpropedit_path)", 4)
        end
    end)
end

---------------------------------------------------------------------------
-- Bindings, script messages, events
---------------------------------------------------------------------------

-- { binding name, function, default keys }. Script message names use '-' instead of '_'.
-- Daily use is a bare key; everything else is Alt+<mnemonic>. Destructive/slow actions are not next to the common ones.
local actions = {
    { "split_chapter",   split_chapter,          { "c" } },      -- [c]reate a chapter here
    { "rename_chapter",  rename_current_chapter, { "Alt+r" } },  -- [r]ename current chapter
    { "mark_ab_chapter", mark_ab_chapter,        { "Alt+l" } },  -- [l]oop (mpv's A-B loop) -> chapter
    { "remove_chapter",  remove_chapter,         { "Alt+d" } },  -- [d]elete current chapter
    { "undo_chapters",   undo_last_edit,         { "Alt+z" } },  -- undo / redo
    { "export_chapters", export_chapters,        { "Alt+e" } },  -- [e]xport sidecar .chapters.txt
    { "embed_chapters",  embed_chapters,         { "Alt+w" } },  -- [w]rite into the .mkv (asks to confirm)
}

for _, a in ipairs(actions) do
    local name, fn, keys = a[1], a[2], a[3]
    for i, key in ipairs(keys) do
        mp.add_key_binding(key, name .. (i == 1 and "" or i), fn)
    end
    local message_name = name:gsub("_", "-")
    mp.register_script_message(message_name, fn)
end
mp.register_script_message("create-chapter", split_chapter) -- legacy alias

mp.register_event("file-loaded", load_chapters)
mp.register_event("end-file", function()
    cancel_active_prompt()
    undo_snapshot = nil
    if embed_armed then embed_armed:kill(); embed_armed = nil end
end)