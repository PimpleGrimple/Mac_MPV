--[[
  remux — export mpv's current state as a new, losslessly muxed file
  (main.lua = all the logic; style.lua = how it looks)

  Install as a folder:
      ~/.config/mpv/scripts/remux/main.lua
      ~/.config/mpv/scripts/remux/style.lua

  mpv already knows your tracks (embedded + audio-add/sub-add/video-add), your
  audio/sub delays and your chapters. This script adds the missing part, a small
  track manager (exclude, reorder, rename, language, default/forced, add, unload),
  then does one `ffmpeg -c copy` pass with all of it baked in. No cutting.

  What gets exported from mpv's state:
    - every video/audio/sub track in track-list (local files), minus excluded ones,
      in the order you set here
    - audio-delay -> the selected audio track, sub-delay / secondary-sub-delay ->
      the selected subtitle track(s)   (mpv has no per-track delay, so only the
      active tracks are shifted)
    - chapter-list (so chapters made by scripts like auto-skip survive)
    - MKV: attachments (ASS fonts) of the main file

  Menu:    UP/DOWN move, ENTER = the item's main action, RIGHT = its options/list,
           LEFT (or right-click) = back, ESC closes. Mouse: click, hover, wheel.
  Key:     Ctrl+R opens/closes the menu, Ctrl+Alt+r exports straight away
           (registered by this script; also reachable as `script-binding
           remux/toggle` and `script-binding remux/export`)
  Options: script-opts/remux.conf
           output_dir (empty = next to the source file), ffmpeg,
           ffprobe, container, convert_text_subs, apply_timing
           (look: width, anchor, plus your shared menu-* opts, see style.lua)
  Needs:   mpv >= 0.39 (mp.input), ffmpeg + ffprobe
]]

local mp      = require "mp"
local utils   = require "mp.utils"
local options = require "mp.options"
local msg     = require "mp.msg"
local has_input, input = pcall(require, "mp.input")

-- All remux options are read here, in one place. style.lua receives
-- its card look from this table (style.configure below) and reads no confs.
-- The keys are registered by this script (see the key bindings at the bottom).
local o = {
    output_dir = "",   -- where exports go; empty = next to the source file
    ffmpeg = "",
    ffprobe = "",
    container = "mkv",
    convert_text_subs = false,
    apply_timing = true,
    -- card look (consumed by style.lua)
    width = 680,
    anchor = "",       -- empty = use the shared menu anchor
    bg_alpha = "14",   -- hex 00-FF: 00 solid, FF invisible
}
options.read_options(o, "remux")

-- Shared menu look (script-opts/menu.conf + menu-* script-opts). Read here for
-- style.lua, which stays a pure renderer. Only the keys the card uses are
-- touched; the rest of menu.conf belongs to menu_style.lua.
local menu_look = {
    accent_color = "9b5de5", bg_color = "111111",
    border_color = "d4baff", border_alpha = "78",
    text_color = "f2f2f2", desc_color = "9a9a9a",
    text_border_color = "111111",
    font = "", blur = 12, anchor = "top-right", margin = 30,
}
do
    local function set(key, value)
        local default = menu_look[key]
        if default == nil then return end
        if type(default) == "number" then
            menu_look[key] = tonumber(value) or default
        else
            menu_look[key] = value
        end
    end

    local path = mp.command_native({ "expand-path", "~~/script-opts/menu.conf" })
    local f = path and io.open(path, "r")
    if f then
        for line in f:lines() do
            line = line:gsub("\r$", "")
            if line:sub(1, 1) ~= "#" then
                local key, value = line:match("^([%w_%-]+)%s*=(.*)$")
                if key then set(key, value) end
            end
        end
        f:close()
    end

    -- style profiles add these at runtime; they override menu.conf.
    for key, value in pairs(mp.get_property_native("options/script-opts") or {}) do
        local name = key:match("^menu%-(.+)$")
        if name then set(name, tostring(value)) end
    end
end

---------------------------------------------------------------------------
-- Static tables
---------------------------------------------------------------------------

local TYPES = { "video", "audio", "subtitle" }
local TAG   = { video = "V", audio = "A", subtitle = "S" }

local function set(...) local t = {} for _, v in ipairs({ ... }) do t[v] = true end return t end

local CONTAINERS = {
    { id = "mkv",  ext = "mkv",  fmt = "matroska", name = "Matroska (.mkv)" },
    { id = "mp4",  ext = "mp4",  fmt = "mp4",      name = "MPEG-4 (.mp4)",    sub = "mov_text" },
    { id = "mov",  ext = "mov",  fmt = "mov",      name = "QuickTime (.mov)", sub = "mov_text" },
    { id = "webm", ext = "webm", fmt = "webm",     name = "WebM (.webm)",     sub = "webvtt" },
}
local CONT = {}
for _, c in ipairs(CONTAINERS) do CONT[c.id] = c end

-- Stream-copy compatibility of the non-MKV containers.
local ALLOW = {
    mp4 = {
        video = set("h264", "hevc", "av1", "vp9", "mpeg4", "mpeg2video", "mjpeg", "png"),
        audio = set("aac", "mp3", "mp2", "ac3", "eac3", "alac", "opus", "flac"),
        subtitle = set("mov_text"),
    },
    mov = {
        video = set("h264", "hevc", "prores", "mpeg4", "mpeg2video", "mjpeg", "png", "dnxhd", "qtrle", "rawvideo"),
        audio = set("aac", "alac", "mp3", "mp2", "ac3", "eac3"),
        subtitle = set("mov_text"),
    },
    webm = {
        video = set("vp8", "vp9", "av1"),
        audio = set("vorbis", "opus"),
        subtitle = set("webvtt"),
    },
}

local TEXT_SUB = set("subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text")

local SHORT = {
    hdmv_pgs_subtitle = "PGS", dvd_subtitle = "VobSub", dvb_subtitle = "DVB-sub",
    subrip = "SRT", mpeg2video = "MPEG-2", truehd = "TrueHD", eac3 = "E-AC-3",
    ac3 = "AC-3", webvtt = "WebVTT", hevc = "HEVC", h264 = "H.264",
}

local LANG2 = {
    en = "eng", ja = "jpn", fr = "fre", de = "ger", es = "spa", it = "ita", pt = "por",
    ru = "rus", zh = "chi", ko = "kor", ar = "ara", hi = "hin", nl = "dut", sv = "swe",
    pl = "pol", tr = "tur", uk = "ukr", he = "heb", th = "tha", vi = "vie", id = "ind",
}

local LANGS = {
    { "eng", "English" }, { "jpn", "Japanese" }, { "fre", "French" }, { "ger", "German" },
    { "spa", "Spanish" }, { "ita", "Italian" }, { "por", "Portuguese" }, { "rus", "Russian" },
    { "chi", "Chinese" }, { "kor", "Korean" }, { "ara", "Arabic" }, { "hin", "Hindi" },
    { "und", "Undetermined" },
}
local LANGNAME = { fra = "French", deu = "German", zho = "Chinese", nld = "Dutch", dut = "Dutch" }
for _, l in ipairs(LANGS) do LANGNAME[l[1]] = l[2] end

-- mpv track-list flag -> ffmpeg disposition (default/forced are handled separately)
local EXTRA_DISP = {
    ["hearing-impaired"] = "hearing_impaired",
    ["visual-impaired"] = "visual_impaired",
    ["albumart"] = "attached_pic",
    ["dependent"] = "dependent",
    ["original"] = "original",
    ["commentary"] = "comment",
}

-- the other ffmpeg dispositions you can set per track (default/forced have their own toggles)
local OTHER_FLAGS = { "original", "dub", "comment", "lyrics", "karaoke", "hearing_impaired", "visual_impaired",
                      "clean_effects", "captions", "descriptions", "dependent", "metadata" }

---------------------------------------------------------------------------
-- State (reset whenever the playing file changes)
---------------------------------------------------------------------------

local S = {
    path = nil, tracks = {}, known = {}, skipped = 0,
    container = CONT[o.container] and o.container or "mkv",
    convert = o.convert_text_subs,
    timing = o.apply_timing,
    chapters = nil,        -- "mpv" | "source" | "none"; nil = automatic
    out_override = nil,
    job = nil, job_out = nil, pfile = nil, meta = nil, timer = nil,
    total = 0, t0 = 0, last_out = nil, card = nil,
}

local main_menu -- forward

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function bin(name, override)
    if override ~= "" then return override end
    for _, d in ipairs({ "/opt/homebrew/bin/", "/usr/local/bin/" }) do
        if utils.file_info(d .. name) then return d .. name end
    end
    return name
end
local FFMPEG, FFPROBE = bin("ffmpeg", o.ffmpeg), bin("ffprobe", o.ffprobe)

local function is_url(p) return p:find("^%a[%w+.-]*://") ~= nil end

local function abspath(p)
    if p:find("^/") or p:find("^%a:[\\/]") then return p end
    return utils.join_path(mp.get_property("working-directory") or ".", p)
end

local function basename(p) return (p:match("[^/\\]+$")) or p end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function human(n)
    local u, i = { "B", "KB", "MB", "GB", "TB" }, 1
    while n >= 1024 and i < #u do n = n / 1024; i = i + 1 end
    return string.format(i == 1 and "%d %s" or "%.1f %s", n, u[i])
end

local function mmss(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function shell_quote(a)
    if a:match("^[%w%-%._/:=+,]+$") then return a end
    return "'" .. a:gsub("'", "'\\''") .. "'"
end

local function parse_paths(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local p = line:match("^%s*(.-)%s*$")
        p = p:gsub("^(['\"])(.*)%1$", "%2")
        p = p:gsub("^file://", "")
        p = p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        p = p:gsub("\\(.)", "%1")
        p = p:gsub("^~", os.getenv("HOME") or "~")
        if p ~= "" then out[#out + 1] = p end
    end
    return out
end

local function say(text, secs) mp.osd_message(text, secs or 4) end


---------------------------------------------------------------------------
-- Tracks: mirror mpv's track-list, keep our own edits on top
---------------------------------------------------------------------------

local function label(t) return TAG[t.type] .. t.n end

local function short(t)
    if t.codec == "dts" and t.profile and t.profile ~= "" then return t.profile end
    return SHORT[t.codec] or t.codec
end

local function ordered()
    local out, cnt = {}, {}
    for _, ty in ipairs(TYPES) do
        for _, t in ipairs(S.tracks) do
            if t.type == ty then
                cnt[ty] = (cnt[ty] or 0) + 1
                t.n = cnt[ty]
                out[#out + 1] = t
            end
        end
    end
    return out
end

local function enabled()
    local out = {}
    for _, t in ipairs(ordered()) do if t.on then out[#out + 1] = t end end
    return out
end

local function reset(path)
    S.path, S.tracks, S.known, S.skipped = path, {}, {}, 0
    S.chapters, S.last_out, S.out_override = nil, nil, nil
end

-- returns false (and says why) when there's nothing exportable
local function sync()
    local p = mp.get_property("path")
    if not p or p == "" then say("remux: nothing is playing"); return false end
    if is_url(p) then say("remux: needs a local file (this is a stream)"); return false end
    p = abspath(p)
    if S.path ~= p then reset(p) end

    local seen, skipped = {}, 0
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        local ty = tr.type == "sub" and "subtitle" or tr.type
        if TAG[ty] then
            local file = p
            if tr.external then file = tr["external-filename"] and abspath(tr["external-filename"]) or nil end
            if not file or is_url(file) then
                skipped = skipped + 1
            else
                local key = file .. "#" .. (tr["ff-index"] or tr.id)
                local t = S.known[key]
                if not t then
                    t = {
                        key = key, type = ty, file = file, external = tr.external or false,
                        index = tr["ff-index"] or 0, on = true,
                        lang = tr.lang or "", name = tr.title or "",
                        default = tr.default or false, forced = tr.forced or false, flags = {},
                    }
                    for flag, name in pairs(EXTRA_DISP) do
                        if tr[flag] then t.flags[name] = true end
                    end
                    S.known[key] = t
                    S.tracks[#S.tracks + 1] = t
                end
                t.mpv_id, t.codec, t.profile = tr.id, tr.codec or "unknown", tr["codec-profile"]
                if ty == "video" then
                    t.info = (tr["demux-w"] and tr["demux-h"]) and (tr["demux-w"] .. "x" .. tr["demux-h"]) or ""
                elseif ty == "audio" then
                    t.info = tr["demux-channels"] or (tr["demux-channel-count"] and (tr["demux-channel-count"] .. "ch")) or ""
                else
                    t.info = TEXT_SUB[t.codec] and "text" or "bitmap"
                end
                seen[key] = true
            end
        end
    end
    S.skipped = skipped
    -- drop tracks that were unloaded from mpv
    for i = #S.tracks, 1, -1 do
        local t = S.tracks[i]
        if not seen[t.key] then S.known[t.key] = nil; table.remove(S.tracks, i) end
    end
    return true
end

-- mpv has no per-track delay; the active tracks carry the delay you dialed in.
local function delay_ms(t)
    if not S.timing or t.type == "video" or not t.mpv_id then return 0 end
    local d
    if t.type == "audio" then
        if t.mpv_id == mp.get_property_number("aid") then
            d = -(mp.get_property_number("audio-delay") or 0) -- mpv: + delays video, - delays audio
        end
    elseif t.mpv_id == mp.get_property_number("sid") then
        d = mp.get_property_number("sub-delay")
    elseif t.mpv_id == mp.get_property_number("secondary-sid") then
        d = mp.get_property_number("secondary-sub-delay")
    end
    return d and math.floor(d * 1000 + 0.5) or 0
end

---------------------------------------------------------------------------
-- Container compatibility
---------------------------------------------------------------------------

local function needs_convert(t, cid)
    if t.type ~= "subtitle" or cid == "mkv" then return false end
    return (not ALLOW[cid].subtitle[t.codec]) and TEXT_SUB[t.codec] or false
end

-- returns level ("block" | "warn") and text, or nil when fine
local function check(t, cid)
    local nm = string.format("%s %s", label(t), short(t))
    if cid == "mkv" then
        if t.codec == "mov_text" or t.codec == "eia_608" then
            return "warn", nm .. " may not stream-copy into MKV; if ffmpeg refuses, exclude it or use MP4/MOV"
        end
        return nil
    end
    local cname = CONT[cid].ext:upper()
    local allow = ALLOW[cid][t.type]
    if allow[t.codec] or (cid == "mov" and t.type == "audio" and t.codec:find("^pcm_")) then return nil end
    if t.type == "subtitle" and TEXT_SUB[t.codec] then
        if S.convert then return nil end
        return "block", string.format("%s can't be copied into %s. Enable text-sub conversion (to %s, styling lost) or switch to MKV",
            nm, cname, CONT[cid].sub)
    end
    if t.type == "subtitle" then
        return "block", nm .. " is a bitmap sub, invalid in " .. cname .. ". Use MKV, OCR it to SRT, or exclude it"
    end
    if t.type == "audio" then
        return "block", string.format("%s isn't valid in %s. Use MKV, or exclude it / pick an AC-3 or AAC track", nm, cname)
    end
    return "block", string.format("%s isn't valid in %s. Use MKV or exclude it", nm, cname)
end

local function compute_issues()
    local list, conv = {}, 0
    for _, t in ipairs(ordered()) do
        t.issue = nil
        if t.on then
            local lvl, text = check(t, S.container)
            if lvl then
                t.issue = lvl
                list[#list + 1] = { level = lvl, text = text }
            elseif S.convert and needs_convert(t, S.container) then
                conv = conv + 1
            end
        end
    end
    if conv > 0 then
        list[#list + 1] = { level = "info",
            text = string.format("%d text sub(s) will be converted to %s (text kept, styling lost)", conv, CONT[S.container].sub) }
    end
    return list
end

---------------------------------------------------------------------------
-- Output path, chapters, ffmpeg command
---------------------------------------------------------------------------

-- returns path, note, blocked. note explains where the path came from;
-- blocked is true when a chosen output file already exists.
local function out_path()
    local dir, fname = utils.split_path(S.path)
    local note
    local want = S.out_override or (o.output_dir or "")
    want = want:match("^%s*(.-)%s*$")
    if want ~= "" then
        want = (want:gsub("^~", os.getenv("HOME") or "~"))
        local fi = utils.file_info(want)
        if fi and fi.is_dir then
            dir = want
        elseif S.out_override then
            return want, fi and "this file already exists" or nil, fi ~= nil
        else
            note = "output_dir missing, using the source folder"
        end
    end
    local stem = (fname:gsub("%.[^.]+$", ""))
    local ext = CONT[S.container].ext
    local p = utils.join_path(dir, stem .. " (remux)." .. ext)
    local n = 2
    while utils.file_info(p) do
        p = utils.join_path(dir, string.format("%s (remux %d).%s", stem, n, ext))
        n = n + 1
    end
    return p, note, false
end

-- Raw dump formats for "Extract": codec -> { extension, ffmpeg muxer, extra output args }
local EXTRACT = {
    -- subtitles
    subrip = { "srt", "srt" }, srt = { "srt", "srt" }, ass = { "ass", "ass" }, ssa = { "ssa", "ass" },
    webvtt = { "vtt", "webvtt" }, mov_text = { "srt", "srt", { "-c:s", "srt" } }, -- no raw mov_text file exists
    hdmv_pgs_subtitle = { "sup", "sup" },
    dvd_subtitle = { "mks", "matroska" }, dvb_subtitle = { "mks", "matroska" },
    -- audio
    aac = { "aac", "adts" }, ac3 = { "ac3", "ac3" }, eac3 = { "eac3", "eac3" }, dts = { "dts", "dts" },
    truehd = { "thd", "truehd" }, mlp = { "mlp", "mlp" }, flac = { "flac", "flac" }, mp3 = { "mp3", "mp3" },
    mp2 = { "mp2", "mp2" }, opus = { "opus", "opus" }, vorbis = { "ogg", "ogg" }, alac = { "m4a", "ipod" },
}

local function extract_format(t)
    if EXTRACT[t.codec] then return EXTRACT[t.codec] end
    if t.type == "audio" and t.codec:find("^pcm_") then return { "wav", "wav" } end
    return { t.type == "audio" and "mka" or "mks", "matroska" } -- anything else keeps its codec inside a minimal container
end

-- folder for extracted files: same rule as the export (chosen folder, output_dir, or next to the source)
local function target_dir()
    local dir = (utils.split_path(S.path))
    local want = (S.out_override or o.output_dir or ""):match("^%s*(.-)%s*$")
    if want ~= "" then
        want = (want:gsub("^~", os.getenv("HOME") or "~"))
        local fi = utils.file_info(want)
        if fi and fi.is_dir then return want end
        if S.out_override then return (utils.split_path(want)) end
    end
    return dir
end

local function extract_path(t)
    local _, fname = utils.split_path(S.path)
    local stem = (fname:gsub("%.[^.]+$", ""))
    local ext = extract_format(t)[1]
    local dir = target_dir()
    local tag = (t.lang ~= "" and t.lang or label(t))
    local p = utils.join_path(dir, string.format("%s.%s.%s", stem, tag, ext))
    local n = 2
    while utils.file_info(p) do
        p = utils.join_path(dir, string.format("%s.%s %d.%s", stem, tag, n, ext))
        n = n + 1
    end
    return p
end

local function chapter_count()
    return #(mp.get_property_native("chapter-list") or {})
end

local function chapter_mode()
    return S.chapters or (chapter_count() > 0 and "mpv" or "source")
end

-- chapters from mpv's chapter-list as an ffmetadata file (keeps script-made chapters)
local function write_meta()
    local ch = mp.get_property_native("chapter-list") or {}
    if #ch == 0 then return nil end
    local function mesc(s) return (tostring(s):gsub("[=;#\\\n]", "\\%0")) end
    local dur = math.floor((mp.get_property_number("duration") or 0) * 1000 + 0.5)
    local lines = { ";FFMETADATA1" }
    for i, c in ipairs(ch) do
        local s = math.floor(c.time * 1000 + 0.5)
        local e = ch[i + 1] and math.floor(ch[i + 1].time * 1000 + 0.5) or math.max(dur, s + 1)
        if e <= s then e = s + 1 end
        lines[#lines + 1] = "[CHAPTER]"
        lines[#lines + 1] = "TIMEBASE=1/1000"
        lines[#lines + 1] = "START=" .. s
        lines[#lines + 1] = "END=" .. e
        lines[#lines + 1] = "title=" .. mesc(c.title or "")
    end
    S.meta = S.meta or os.tmpname()
    local f = io.open(S.meta, "wb")
    if not f then return nil end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    return S.meta
end

local function disp_str(t)
    local names = {}
    if t.default then names[#names + 1] = "default" end
    if t.forced then names[#names + 1] = "forced" end
    for name, on in pairs(t.flags or {}) do
        if on then names[#names + 1] = name end
    end
    table.sort(names)
    return #names == 0 and "0" or table.concat(names, "+")
end

local function build(bare)
    local en = enabled()
    local c = CONT[S.container]
    local inputs, imap, idx_of = {}, {}, {}
    local function input_for(t)
        local d = delay_ms(t)
        local key = t.file .. "\n" .. d
        if not imap[key] then
            inputs[#inputs + 1] = { path = t.file, delay = d }
            imap[key] = #inputs - 1
        end
        idx_of[t] = imap[key]
    end
    -- main file first, so input 0 is the source of chapters/attachments
    for _, t in ipairs(en) do if t.file == S.path then input_for(t) end end
    for _, t in ipairs(en) do if t.file ~= S.path then input_for(t) end end
    local main_idx = 0
    local has_main = false
    for _, t in ipairs(en) do if t.file == S.path then has_main = true end end

    local a = { FFMPEG, "-hide_banner", "-nostdin", "-n" }
    if not bare then
        for _, v in ipairs({ "-loglevel", "error", "-nostats", "-stats_period", "0.25", "-progress", S.pfile }) do
            a[#a + 1] = v
        end
    end
    for _, inp in ipairs(inputs) do
        if inp.delay ~= 0 then
            a[#a + 1] = "-itsoffset"; a[#a + 1] = string.format("%.3f", inp.delay / 1000)
        end
        a[#a + 1] = "-i"; a[#a + 1] = inp.path
    end

    local cm, meta_idx = chapter_mode(), nil
    if cm == "mpv" then
        local m = write_meta()
        if m then a[#a + 1] = "-i"; a[#a + 1] = m; meta_idx = #inputs end
    end

    for _, t in ipairs(en) do
        a[#a + 1] = "-map"; a[#a + 1] = idx_of[t] .. ":" .. t.index
    end
    if S.container == "mkv" and has_main then
        a[#a + 1] = "-map"; a[#a + 1] = main_idx .. ":t?" -- fonts etc. for ASS
    end
    a[#a + 1] = "-c"; a[#a + 1] = "copy"

    local mp4ish = (S.container == "mp4" or S.container == "mov")
    for i, t in ipairs(en) do
        local s = i - 1
        a[#a + 1] = "-metadata:s:" .. s; a[#a + 1] = "language=" .. t.lang
        a[#a + 1] = "-metadata:s:" .. s; a[#a + 1] = "title=" .. t.name
        if mp4ish then
            a[#a + 1] = "-metadata:s:" .. s; a[#a + 1] = "handler_name=" .. t.name
        end
        a[#a + 1] = "-disposition:" .. s; a[#a + 1] = disp_str(t)
        if S.convert and needs_convert(t, S.container) then
            a[#a + 1] = "-c:" .. s; a[#a + 1] = c.sub
        end
    end

    if cm == "none" then
        a[#a + 1] = "-map_chapters"; a[#a + 1] = "-1"
    elseif meta_idx then
        a[#a + 1] = "-map_chapters"; a[#a + 1] = tostring(meta_idx)
    elseif has_main then
        a[#a + 1] = "-map_chapters"; a[#a + 1] = tostring(main_idx)
    end
    a[#a + 1] = "-f"; a[#a + 1] = c.fmt
    a[#a + 1] = (out_path())
    return a
end

---------------------------------------------------------------------------
-- Style (the look lives in style.lua next to this file)
---------------------------------------------------------------------------

local style, style_err
do
    local dir = mp.get_script_directory()
    if not dir then
        style_err = "install as a folder: scripts/remux/main.lua + style.lua"
    else
        local fn, err = loadfile(utils.join_path(dir, "style.lua"))
        if not fn then
            style_err = "style.lua: " .. tostring(err)
        else
            local ok, mod = pcall(fn)
            if ok and type(mod) == "table" then
                style = mod
                if style.configure then style.configure(menu_look, o) end
            else
                style_err = "style.lua: " .. tostring(mod)
            end
        end
    end
    if style_err then msg.error(style_err) end
end

local ovc = mp.create_osd_overlay("ass-events") -- progress card
local ovm = mp.create_osd_overlay("ass-events") -- menu
local card_timer

-- c = { title, sub, pct, stats, hint, tone }
local function card_show(c, ttl)
    S.card = c
    if style then
        local r = style.card(c)
        ovc.res_x, ovc.res_y = r.res_x, r.res_y
        ovc.data = r.ass
        ovc:update()
    else
        mp.osd_message(c.title .. "  " .. (c.stats or c.sub or ""), ttl or 2)
    end
    if ttl then
        if card_timer then card_timer:kill() end
        card_timer = mp.add_timeout(ttl, function() S.card = nil; ovc:remove() end)
    end
end

local function card_hide()
    if card_timer then card_timer:kill(); card_timer = nil end
    S.card = nil
    ovc:remove()
end

---------------------------------------------------------------------------
-- Menu engine (no drawing here: items are plain data for style.menu)
--   spec = { title, subtitle, badge, items, issues }
--   item = { id, kind, ...style fields..., enter = fn, right = fn }
--   ENTER = main action, RIGHT = the item's options, LEFT / right-click = back.
---------------------------------------------------------------------------

local function move_track(t, dir)
    local i
    for k, u in ipairs(S.tracks) do if u == t then i = k end end
    local j = i + dir
    while S.tracks[j] and S.tracks[j].type ~= t.type do j = j + dir end
    if S.tracks[j] then S.tracks[i], S.tracks[j] = S.tracks[j], S.tracks[i] end
end

local UI = { open = false, bound = false, stack = {}, toast = nil, toast_tone = nil, toast_timer = nil, hit = nil, grab = nil }
local ui_refresh, ui_close, ui_bind, ui_unbind, ui_push, ui_pop, ui_home, ui_render

local PLAIN = { section = true, info = true, gap = true }

local function selectable(it)
    return it and (it.enter or it.right or it.left) and not PLAIN[it.kind]
end

local function top() return UI.stack[#UI.stack] end

-- tone: nil | "dim" | "ok" | "warn" | "bad"
local function notify(msg_text, tone, ttl)
    if not UI.open then return mp.osd_message(msg_text, ttl or 4) end
    UI.toast, UI.toast_tone = msg_text, tone
    if UI.toast_timer then UI.toast_timer:kill() end
    UI.toast_timer = mp.add_timeout(ttl or 4, function() UI.toast = nil; if UI.open then ui_render() end end)
    ui_render()
end

ui_render = function()
    if not UI.open then ovm:remove(); return end
    local m = top()
    local sp = m and m.spec
    if not sp or not style then return end
    local sel = m.sel
    if not selectable(sp.items[sel]) then
        for i, it in ipairs(sp.items) do if selectable(it) then sel = i; break end end
        m.sel = sel
    end
    local r = style.menu({
        title = sp.title, subtitle = sp.subtitle, badge = sp.badge, items = sp.items, issues = sp.issues,
        toast = UI.toast, toast_tone = UI.toast_tone,
    }, sel, m.scroll + 1)
    m.scroll = r.first - 1
    ovm.res_x, ovm.res_y = r.res_x, r.res_y
    ovm.data = r.ass
    ovm:update()
    UI.hit = { box = r.box, hits = r.hits, cw = r.res_x, ch = r.res_y }
end

local function find_sel(m, items)
    if m.sel_id then
        for i, it in ipairs(items) do if it.id == m.sel_id and selectable(it) then return i end end
    end
    return clamp(m.sel or 1, 1, math.max(1, #items))
end

ui_refresh = function()
    if not UI.open then return end
    local m = top()
    if not m then return end
    m.spec = m.build()
    m.sel = find_sel(m, m.spec.items)
    local it = m.spec.items[m.sel]
    m.sel_id = it and it.id or nil
    ui_render()
end

ui_push = function(build)
    UI.stack[#UI.stack + 1] = { build = build, sel = 1, scroll = 0 }
    ui_refresh()
end

ui_pop = function()
    if #UI.stack > 1 then table.remove(UI.stack) end
    ui_refresh()
end

ui_home = function()
    for i = #UI.stack, 2, -1 do table.remove(UI.stack, i) end
    ui_refresh()
end

local function ui_back()
    if #UI.stack > 1 then ui_pop() else ui_close() end
end

local function ui_move(d, absolute)
    local m = top()
    local items = m.spec.items
    local n = #items
    if n == 0 then return end
    local i = m.sel
    if absolute then
        i = d > 0 and n + 1 or 0
        d = d > 0 and -1 or 1
    end
    for _ = 1, n do
        i = ((i - 1 + d) % n) + 1
        if selectable(items[i]) then break end
    end
    m.sel, m.sel_id = i, items[i].id
    ui_render()
end

local function ui_activate(kind)
    local m = top()
    local it = m and m.spec.items[m.sel]
    local fn = it and it[kind]
    if not fn then return end
    local ok, err = pcall(fn)
    if not ok then
        msg.error(tostring(err))
        notify("remux error: " .. tostring(err), "bad", 8)
    end
end

local function mouse_row()
    local h = UI.hit
    if not h then return nil end
    local pos = mp.get_property_native("mouse-pos")
    local ow, oh = mp.get_osd_size()
    if not pos or not ow or ow <= 0 or oh <= 0 then return nil end
    local mx, my = pos.x * h.cw / ow, pos.y * h.ch / oh
    local b = h.box
    if mx < b.x or mx > b.x + b.w or my < b.y or my > b.y + b.h then return nil, true end
    for _, r in ipairs(h.hits) do
        if my >= r.y1 and my < r.y2 then return r.idx end
    end
    return nil, false
end

-- LEFT on a track picks it up; UP/DOWN then move it; ENTER/LEFT drops it, ESC/BACKSPACE puts it back
local function grab_start(t)
    local snap = {}
    for i, u in ipairs(S.tracks) do snap[i] = u end
    UI.grab = { t = t, snapshot = snap }
    ui_refresh()
end

local function grab_drop() UI.grab = nil; ui_refresh() end

local function grab_cancel()
    if not UI.grab then return end
    S.tracks = UI.grab.snapshot
    UI.grab = nil
    ui_refresh()
end

local function ui_step(d)
    if UI.grab then move_track(UI.grab.t, d); ui_refresh() else ui_move(d) end
end

local function back_or_cancel() if UI.grab then grab_cancel() else ui_back() end end
local function close_or_cancel() if UI.grab then grab_cancel() else ui_close() end end

local UI_KEYS = {
    { "UP", "up", function() ui_step(-1) end, true },
    { "k", "up", function() ui_step(-1) end, true },
    { "WHEEL_UP", "up", function() ui_step(-1) end, true },
    { "DOWN", "down", function() ui_step(1) end, true },
    { "j", "down", function() ui_step(1) end, true },
    { "WHEEL_DOWN", "down", function() ui_step(1) end, true },
    { "HOME", "first", function() if not UI.grab then ui_move(1, true) end end },
    { "END", "last", function() if not UI.grab then ui_move(-1, true) end end },
    { "ENTER", "enter", function() if UI.grab then grab_drop() else ui_activate("enter") end end },
    { "KP_ENTER", "enter", function() if UI.grab then grab_drop() else ui_activate("enter") end end },
    { "RIGHT", "right", function() if not UI.grab then ui_activate("right") end end },
    { "LEFT", "left", function() if UI.grab then grab_drop() else ui_activate("left") end end },
    { "BS", "back", back_or_cancel },
    { "MBTN_RIGHT", "back", back_or_cancel },
    { "ESC", "close", close_or_cancel },
    { "q", "close", close_or_cancel },
    { "MBTN_LEFT_DBL", "dbl", function() end }, -- a double-click must not toggle fullscreen
    { "MBTN_LEFT", "click", function()
        if UI.grab then return end
        local idx, outside = mouse_row()
        local m = top()
        if idx and selectable(m.spec.items[idx]) then
            m.sel, m.sel_id = idx, m.spec.items[idx].id
            ui_activate("enter")
        elseif outside then
            ui_close()
        end
    end },
    { "MOUSE_MOVE", "hover", function()
        if UI.grab then return end
        local idx = mouse_row()
        local m = top()
        if idx and idx ~= m.sel and selectable(m.spec.items[idx]) then
            m.sel, m.sel_id = idx, m.spec.items[idx].id
            ui_render()
        end
    end },
}

ui_bind = function()
    if UI.bound or not UI.open then return end
    UI.bound = true
    for i, b in ipairs(UI_KEYS) do
        mp.add_forced_key_binding(b[1], "rs-" .. b[2] .. "-" .. i, b[3], b[4] and { repeatable = true } or nil)
    end
end

ui_unbind = function()
    if not UI.bound then return end
    UI.bound = false
    for i, b in ipairs(UI_KEYS) do mp.remove_key_binding("rs-" .. b[2] .. "-" .. i) end
end

ui_close = function()
    ui_unbind()
    UI.open, UI.stack, UI.toast, UI.grab = false, {}, nil, nil
    ovm:remove()
end

-- text prompt via mp.input; the menu keys are released while the console is open
local function ask(prompt, default, cb)
    ui_unbind()
    ovm:remove()
    input.get({
        prompt = prompt,
        default_text = default or "",
        submit = function(value)
            input.terminate()
            ui_bind()
            cb(value or "")
            ui_refresh()
        end,
        closed = function() ui_bind(); ui_refresh() end,
    })
end

---------------------------------------------------------------------------
-- Execution
---------------------------------------------------------------------------

local function cleanup_tmp()
    if S.pfile then os.remove(S.pfile); S.pfile = nil end
    if S.meta then os.remove(S.meta); S.meta = nil end
end

local function stop_job_ui()
    if S.timer then S.timer:kill(); S.timer = nil end
    mp.remove_key_binding("rs-cancel")
end

local function poll()
    if not S.pfile then return end
    local f = io.open(S.pfile, "rb")
    if not f then return end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 700))
    local tail = f:read("*a") or ""
    f:close()
    local us, speed, bytes
    for v in tail:gmatch("out_time_us=(%-?%d+)") do us = tonumber(v) end
    for v in tail:gmatch("speed=%s*([%d%.]+)x") do speed = tonumber(v) end
    for v in tail:gmatch("total_size=(%d+)") do bytes = tonumber(v) end
    if us and us >= 0 then
        local pct = S.total > 0 and clamp(us / 1e6 / S.total, 0, 1) or 0
        local parts = { string.format("%d%%", math.floor(pct * 100)) }
        if speed then parts[#parts + 1] = string.format("%.1fx", speed) end
        if pct > 0.01 then parts[#parts + 1] = "eta " .. mmss((mp.get_time() - S.t0) * (1 - pct) / pct) end
        if bytes then parts[#parts + 1] = human(bytes) end
        card_show({ title = "REMUXING", sub = basename(S.job_out), pct = pct,
                    stats = table.concat(parts, "  ·  "), hint = "ESC cancels", tone = "accent" })
    end
end

local function on_done(_, res)
    stop_job_ui()
    local out = S.job_out
    S.job = nil
    cleanup_tmp()
    if res and res.status == 0 then
        local fi = utils.file_info(out)
        S.last_out = out
        card_show({ title = "DONE", sub = basename(out), pct = 1, stats = human(fi and fi.size or 0), tone = "ok" }, 8)
    else
        os.remove(out)
        if res and res.killed_by_us then
            card_show({ title = "CANCELLED", sub = basename(out), stats = "partial file removed", tone = "warn" }, 3)
        else
            local err = ((res and res.stderr) or ""):gsub("%s+$", "")
            local last = err:match("([^\r\n]+)$") or (res and res.error_string) or "unknown error"
            card_show({ title = "FAILED", sub = "ffmpeg reported an error", stats = last, tone = "bad" }, 14)
            msg.error("ffmpeg failed: " .. err)
        end
    end
end

local function first_problems()
    local list = {}
    for _, is in ipairs(compute_issues()) do
        if is.level == "block" then list[#list + 1] = is.text end
    end
    return list
end

local function start_export()
    if S.job then return end
    if #enabled() == 0 then return notify("Nothing selected to export", "warn") end
    local problems = first_problems()
    if #problems > 0 then
        return notify(problems[1] .. (#problems > 1 and string.format("  (+%d more)", #problems - 1) or ""), "bad", 8)
    end
    local out, _, exists = out_path()
    if exists then return notify("That output file already exists. Change it in the export options.", "bad", 6) end

    ui_close()
    card_hide()
    S.pfile = os.tmpname()
    S.job_out = out
    S.total = mp.get_property_number("duration") or 0
    S.t0 = mp.get_time()
    local args = build(false)
    S.timer = mp.add_periodic_timer(0.25, poll)
    mp.add_forced_key_binding("ESC", "rs-cancel", function()
        if S.job then mp.abort_async_command(S.job) end
    end)
    S.job = mp.command_native_async(
        { name = "subprocess", args = args, capture_stderr = true, playback_only = false }, on_done)
    card_show({ title = "REMUXING", sub = basename(out), pct = 0, stats = "starting…", hint = "ESC cancels", tone = "accent" })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function playing_kind(t)
    if not t.mpv_id then return nil end
    if t.type == "video" then return t.mpv_id == mp.get_property_number("vid") and "1" or nil end
    if t.type == "audio" then return t.mpv_id == mp.get_property_number("aid") and "1" or nil end
    if t.mpv_id == mp.get_property_number("sid") then return "1" end
    if t.mpv_id == mp.get_property_number("secondary-sid") then return "2" end
end

local function auto_name(t)
    local parts = {}
    if t.type == "video" then
        parts[1] = short(t)
        if t.info and t.info ~= "" then parts[2] = t.info end
    else
        if t.lang ~= "" and t.lang ~= "und" then parts[#parts + 1] = LANGNAME[t.lang] or t.lang end
        if t.type == "audio" then
            parts[#parts + 1] = short(t)
            if t.info and t.info ~= "" then parts[#parts + 1] = t.info end
        elseif t.forced then
            parts[#parts + 1] = "(Forced)"
        end
    end
    return table.concat(parts, " ")
end


local function platform()
    local p = mp.get_property("platform")
    if p and p ~= "" then return p end
    if utils.file_info("/usr/bin/osascript") then return "darwin" end
    if utils.file_info("/usr/bin/zenity") or utils.file_info("/usr/local/bin/zenity") then return "linux" end
    return "other"
end

local function add_media(paths)
    local n = 0
    for _, p in ipairs(paths) do
        p = abspath(p)
        local res = mp.command_native({
            name = "subprocess", playback_only = false, capture_stdout = true,
            args = { FFPROBE, "-v", "error", "-print_format", "json", "-show_streams", "-i", p },
        })
        local j = res and res.status == 0 and utils.parse_json(res.stdout or "")
        if not j or not j.streams then
            notify("ffprobe couldn't read " .. basename(p), "bad")
        else
            local types = {}
            for _, s in ipairs(j.streams) do types[s.codec_type] = true end
            if types.video then mp.commandv("video-add", p, "auto") end
            if types.audio then mp.commandv("audio-add", p, "auto") end
            if types.subtitle then mp.commandv("sub-add", p, "auto") end
            n = n + 1
        end
    end
    mp.add_timeout(0.1, function()
        sync()
        if n > 0 then notify(string.format("Added %d file(s)", n), "ok", 3) end
        if UI.open then ui_home() end
    end)
end

local function type_path()
    ask("Path to add:", "", function(value)
        local list = parse_paths(value)
        if #list > 0 then add_media(list) end
    end)
end

local function pick_files()
    local plat = platform()
    local args
    if plat == "darwin" then
        args = { "/usr/bin/osascript",
            "-e", "tell current application to activate",
            "-e", 'set fs to choose file with prompt "Add tracks to remux" with multiple selections allowed',
            "-e", "set out to {}",
            "-e", "repeat with f in fs",
            "-e", "set end of out to POSIX path of f",
            "-e", "end repeat",
            "-e", "set AppleScript's text item delimiters to linefeed",
            "-e", "return out as text" }
    elseif plat == "linux" then
        args = { "zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Add tracks to remux" }
    else
        return type_path()
    end
    notify("Opening the file dialog… (it can hide behind a fullscreen player)", "dim", 6)
    mp.command_native_async(
        { name = "subprocess", args = args, capture_stdout = true, capture_stderr = true, playback_only = false },
        function(_, res)
            local out = (res and res.stdout) or ""
            local err = (res and res.stderr) or ""
            if res and res.status == 0 then
                if out:match("%S") then add_media(parse_paths(out)) else notify("", "dim", 0.1) end
            elseif err:find("%-128") or (plat == "linux" and res and res.status == 1 and not err:match("%S")) then
                notify("", "dim", 0.1) -- the user just closed the dialog
            else
                local why = err:match("([^\r\n]+)") or (res and res.error_string) or "unknown error"
                notify("File dialog failed: " .. why, "bad", 10)
                msg.error("file dialog failed: " .. err)
            end
        end)
end

local function paste_paths()
    local ok, clip = pcall(mp.get_property, "clipboard/text")
    local paths = ok and parse_paths(clip) or {}
    if #paths == 0 then return notify("Clipboard has no file paths", "warn") end
    add_media(paths)
end

local function copy_command()
    local parts = {}
    for _, a in ipairs(build(true)) do parts[#parts + 1] = shell_quote(a) end
    local ok = pcall(mp.set_property, "clipboard/text", table.concat(parts, " "))
    notify(ok and "ffmpeg command copied to the clipboard" or "Couldn't write the clipboard", ok and "ok" or "bad")
end

local function set_container(id)
    S.container = id
    if S.out_override then
        local fi = utils.file_info(S.out_override)
        if not (fi and fi.is_dir) then S.out_override = (S.out_override:gsub("%.%w+$", "." .. CONT[id].ext)) end
    end
end

local function step_index(list, cur, dir)
    local idx = 0
    for i, v in ipairs(list) do if v == cur then idx = i end end
    if idx == 0 then return dir > 0 and list[1] or list[#list] end
    return list[((idx - 1 + dir) % #list) + 1]
end

local function edit_output()
    ask("Output: a folder or a full path (empty = automatic)", (out_path()), function(value)
        local p = parse_paths(value)[1]
        if not p then S.out_override = nil; return end
        p = abspath(p)
        local fi = utils.file_info(p)
        if not (fi and fi.is_dir) then
            local ext = p:match("%.(%w+)$")
            if ext and CONT[ext:lower()] then S.container = ext:lower()
            elseif not ext then p = p .. "." .. CONT[S.container].ext end
        end
        S.out_override = p
    end)
end

local function do_reset()
    S.tracks, S.known, S.chapters, S.out_override = {}, {}, nil, nil
    sync()
    notify("Reset: back to mpv's current tracks", "ok", 3)
end

local function selected_ids()
    return { audio = mp.get_property_number("aid"), subtitle = mp.get_property_number("sid"),
             sub2 = mp.get_property_number("secondary-sid") }
end

local function tilde(p)
    local home = os.getenv("HOME")
    if home and p:sub(1, #home + 1) == home .. "/" then return "~" .. p:sub(#home + 1) end
    return p
end

---------------------------------------------------------------------------
-- Menu builders (data only; style.lua decides how it looks)
---------------------------------------------------------------------------

-- generic "pick one value" list: choices = { {value, label, detail?}, ... }
local function build_choice(title, choices, current, set)
    local items = {}
    for _, c in ipairs(choices) do
        items[#items + 1] = {
            id = tostring(c[1]), kind = "choice", text = c[2], detail = c[3], checked = (c[1] == current),
            enter = function() set(c[1]); ui_pop() end,
        }
    end
    return { title = title, items = items }
end

local function chapter_label(mode)
    return mode == "mpv" and string.format("From mpv (%d)", chapter_count())
        or mode == "source" and "From the source file" or "None"
end

local CHAPTER_MODES = { "mpv", "source", "none" }

-- ← / → step through a list of values; ENTER on the same item opens the full list
local function stepper(it, values, get, set)
    it.cycle = true
    it.left = function() set(step_index(values, get(), -1)); ui_refresh() end
    it.right = function() set(step_index(values, get(), 1)); ui_refresh() end
    return it
end

-- ← / → both flip a yes/no item
local function toggler(it, flip)
    it.left, it.right = flip, flip
    return it
end

local LANG_CODES = {}
for _, l in ipairs(LANGS) do LANG_CODES[#LANG_CODES + 1] = l[1] end
local CONTAINER_IDS = {}
for _, c in ipairs(CONTAINERS) do CONTAINER_IDS[#CONTAINER_IDS + 1] = c.id end

local function extract_track(t)
    if S.xjob then return notify("An extraction is already running", "warn") end
    if S.job then return notify("Wait for the export to finish first", "warn") end
    local fmt = extract_format(t)
    local out = extract_path(t)
    local args = { FFMPEG, "-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-i", t.file,
                   "-map", "0:" .. t.index, "-c", "copy" }
    for _, a in ipairs(fmt[3] or {}) do args[#args + 1] = a end
    args[#args + 1] = "-f"; args[#args + 1] = fmt[2]
    args[#args + 1] = out
    notify("Extracting " .. label(t) .. "…", "dim", 60)
    S.xjob = mp.command_native_async(
        { name = "subprocess", args = args, capture_stderr = true, playback_only = false },
        function(_, res)
            S.xjob = nil
            if res and res.status == 0 then
                local fi = utils.file_info(out)
                notify(string.format("Extracted %s (%s)", basename(out), human(fi and fi.size or 0)), "ok", 8)
            else
                os.remove(out)
                local err = ((res and res.stderr) or ""):gsub("%s+$", "")
                notify("Extract failed: " .. (err:match("([^\r\n]+)$") or (res and res.error_string) or "unknown error"), "bad", 10)
                msg.error("extract failed: " .. err)
            end
        end)
end

local function flags_summary(t)
    local names = {}
    for _, n in ipairs(OTHER_FLAGS) do if t.flags[n] then names[#names + 1] = n end end
    if t.flags.attached_pic then names[#names + 1] = "attached_pic" end
    return #names > 0 and table.concat(names, ", ") or "none"
end

local function build_flags(t)
    local list = {}
    for _, n in ipairs(OTHER_FLAGS) do list[#list + 1] = n end
    if t.type == "video" then list[#list + 1] = "attached_pic" end
    local items = {}
    for _, n in ipairs(list) do
        items[#items + 1] = { id = n, kind = "choice", text = n, checked = t.flags[n] or false,
                              enter = function() t.flags[n] = (not t.flags[n]) or nil; ui_refresh() end }
    end
    return { title = "Flags", subtitle = label(t), items = items }
end

local function build_lang(t)
    local items = {}
    for _, l in ipairs(LANGS) do
        items[#items + 1] = { id = l[1], kind = "choice", text = l[2], detail = l[1], checked = (t.lang == l[1]),
                              enter = function() t.lang = l[1]; ui_pop() end }
    end
    items[#items + 1] = { id = "other", kind = "choice", text = "Other code…", enter = function()
        ask("Language code (ISO 639-2, e.g. nor):", t.lang, function(value)
            value = value:lower():match("^%s*(.-)%s*$")
            t.lang = LANG2[value] or value
            ui_pop()
        end)
    end }
    items[#items + 1] = { id = "clear", kind = "choice", text = "Clear", enter = function() t.lang = ""; ui_pop() end }
    return { title = "Language", subtitle = label(t), items = items }
end

local function build_track(t)
    local items = {}
    local function add(it) items[#items + 1] = it end
    add(toggler({ id = "inc", kind = "choice", text = "Include in export", detail = t.on and "on" or "off", checked = t.on,
                  enter = function() t.on = not t.on; ui_refresh() end },
                function() t.on = not t.on; ui_refresh() end))
    add({ id = "rename", kind = "value", text = "Rename", value = t.name ~= "" and ('"' .. t.name .. '"') or "none",
          enter = function() ask("Track name (empty clears):", t.name, function(value) t.name = value end) end })
    add({ id = "auto", kind = "value", text = "Auto-name", value = '"' .. auto_name(t) .. '"',
          enter = function() t.name = auto_name(t); ui_refresh() end })
    add(stepper({ id = "lang", kind = "value", text = "Language",
                  value = t.lang ~= "" and (LANGNAME[t.lang] or t.lang) or "none",
                  enter = function() ui_push(function() return build_lang(t) end) end },
                LANG_CODES, function() return t.lang end, function(v) t.lang = v end))
    local function flip_default()
        if t.default then t.default = false
        else
            for _, u in ipairs(S.tracks) do if u.type == t.type then u.default = false end end
            t.default = true
        end
        ui_refresh()
    end
    add(toggler({ id = "default", kind = "choice", text = "Default", detail = t.default and "on" or "off", checked = t.default, enter = flip_default }, flip_default))
    local function flip_forced() t.forced = not t.forced; ui_refresh() end
    add(toggler({ id = "forced", kind = "choice", text = "Forced", detail = t.forced and "on" or "off", checked = t.forced, enter = flip_forced }, flip_forced))
    add({ id = "flags", kind = "value", text = "Other flags", value = flags_summary(t), chevron = true,
          enter = function() ui_push(function() return build_flags(t) end) end })
    if t.type ~= "video" then
        add({ id = "extract", kind = "action", text = "Extract", detail = "save as ." .. extract_format(t)[1],
              enter = function() extract_track(t) end })
    end
    if t.external and t.mpv_id then
        add({ id = "unload", kind = "action", text = "Unload from mpv", detail = "removes this external track", enter = function()
            local cmd = ({ video = "video-remove", audio = "audio-remove", subtitle = "sub-remove" })[t.type]
            mp.commandv(cmd, tostring(t.mpv_id))
            mp.add_timeout(0.1, function() sync(); ui_pop() end)
        end })
    end
    local sub = short(t) .. ((t.info and t.info ~= "") and (" " .. t.info) or "") .. (playing_kind(t) and "  ·  playing now" or "")
    return { title = label(t), subtitle = sub, items = items }
end

local function build_add()
    return { title = "Add tracks", items = {
        { id = "pick", kind = "action", text = "File picker…", enter = pick_files },
        { id = "paste", kind = "action", text = "Paste path(s) from the clipboard", enter = paste_paths },
        { id = "type", kind = "action", text = "Type a path…", enter = type_path },
    } }
end

local function container_choices()
    local list = {}
    for _, c in ipairs(CONTAINERS) do list[#list + 1] = { c.id, c.name } end
    return list
end

local function build_export_options()
    local items = {}
    local function add(it) items[#items + 1] = it end
    local out, note = out_path()
    add({ id = "output", kind = "value", text = "Output", value = tilde(out) .. (note and ("  (" .. note .. ")") or ""),
          enter = edit_output })
    if S.out_override then
        add({ id = "auto-out", kind = "action", text = "Use the automatic location",
              enter = function() S.out_override = nil; ui_refresh() end })
    end
    local cm = chapter_mode()
    add(stepper({ id = "chapters", kind = "value", text = "Chapters", value = chapter_label(cm),
                  enter = function()
                      local choices = {}
                      for _, v in ipairs(CHAPTER_MODES) do choices[#choices + 1] = { v, chapter_label(v) } end
                      ui_push(function() return build_choice("Chapters", choices, chapter_mode(), function(v) S.chapters = v end) end)
                  end },
                CHAPTER_MODES, chapter_mode, function(v) S.chapters = v end))
    local adm = math.floor(-(mp.get_property_number("audio-delay") or 0) * 1000 + 0.5)
    local sdm = math.floor((mp.get_property_number("sub-delay") or 0) * 1000 + 0.5)
    local onoff = { { true, "On" }, { false, "Off" } }
    local BOOLS = { true, false }
    add(stepper({ id = "timing", kind = "value", text = "Timing from mpv",
                  value = string.format("%s  (audio %+dms, subs %+dms)", S.timing and "on" or "off", adm, sdm),
                  enter = function()
                      ui_push(function() return build_choice("Timing from mpv", onoff, S.timing, function(v) S.timing = v end) end)
                  end },
                BOOLS, function() return S.timing end, function(v) S.timing = v end))
    add(stepper({ id = "convert", kind = "value", text = "Convert text subs if needed", value = S.convert and "on" or "off",
                  enter = function()
                      ui_push(function() return build_choice("Convert text subs", onoff, S.convert, function(v) S.convert = v end) end)
                  end },
                BOOLS, function() return S.convert end, function(v) S.convert = v end))
    add({ id = "keep", kind = "action", text = "Keep only what's playing", detail = "exclude the other audio/sub tracks", enter = function()
        local ids = selected_ids()
        local kept = 0
        for _, t in ipairs(S.tracks) do
            if t.type == "audio" and ids.audio then t.on = (t.mpv_id == ids.audio) end
            if t.type == "subtitle" and (ids.subtitle or ids.sub2) then
                t.on = (t.mpv_id == ids.subtitle) or (t.mpv_id == ids.sub2)
            end
            if t.on then kept = kept + 1 end
        end
        notify(string.format("%d track(s) kept", kept), "ok", 3)
        ui_pop()
    end })
    add({ id = "mkdef", kind = "action", text = "Mark what's playing as default", enter = function()
        local ids = selected_ids()
        for _, t in ipairs(S.tracks) do
            if t.type == "audio" and ids.audio then t.default = (t.mpv_id == ids.audio) end
            if t.type == "subtitle" and ids.subtitle then t.default = (t.mpv_id == ids.subtitle) end
        end
        notify("Defaults updated", "ok", 3)
    end })
    add({ id = "copy", kind = "action", text = "Copy ffmpeg command", enter = copy_command })
    return { title = "Export options", subtitle = basename(S.path), items = items }
end

local function build_main()
    local items = {}
    local function add(it) items[#items + 1] = it end
    if not S.path or not sync() then return { title = "Remux", items = {} } end
    local issues = compute_issues()
    local problems = first_problems()
    local out = out_path()
    local nen = #enabled()

    -- the Export row and the track rows keep their own keys:
    --   Export: ENTER exports, RIGHT = export options (LEFT does nothing, it never closes the menu)
    --   Track:  ENTER include/exclude, RIGHT = track menu, LEFT = pick it up and reorder with UP/DOWN
    if #problems > 0 then
        add({ id = "export", kind = "button", text = "Can't export", detail = problems[1], tone = "bad", chevron = true,
              enter = start_export, right = function() ui_push(build_export_options) end })
    else
        add({ id = "export", kind = "button", text = string.format("Export %d track%s", nen, nen == 1 and "" or "s"),
              detail = basename(out), chevron = true,
              enter = start_export, right = function() ui_push(build_export_options) end })
    end

    local ord = ordered()
    local counts = {}
    for _, t in ipairs(ord) do counts[t.type] = (counts[t.type] or 0) + 1 end
    local GROUP = { video = "Video", audio = "Audio", subtitle = "Subtitles" }
    local last
    for _, t in ipairs(ord) do
        if t.type ~= last then
            add({ id = "hdr-" .. t.type, kind = "section", text = GROUP[t.type], count = counts[t.type] })
            last = t.type
        end
        local d = delay_ms(t)
        add({
            id = t.key, kind = "track", label = label(t), codec = short(t), info = t.info or "", lang = t.lang,
            default = t.default, forced = t.forced, delay = d ~= 0 and string.format("%+dms", d) or nil,
            name = t.name, src = t.file ~= S.path and basename(t.file) or nil, on = t.on, playing = playing_kind(t),
            tone = t.on and (t.issue == "block" and "bad" or t.issue == "warn" and "warn" or nil) or nil,
            chevron = true, grabbed = (UI.grab and UI.grab.t == t) or nil,
            enter = function() t.on = not t.on; ui_refresh() end,
            left = function() grab_start(t) end,
            right = function() ui_push(function() return build_track(t) end) end,
        })
    end

    add({ id = "gap", kind = "gap" })
    add({ id = "add", kind = "action", icon = "plus", text = "Add tracks from file…", chevron = true,
          enter = function() ui_push(build_add) end })
    add(stepper({ id = "container", kind = "value", text = "Container", value = CONT[S.container].name,
                  enter = function()
                      ui_push(function() return build_choice("Output container", container_choices(), S.container,
                          function(v) set_container(v) end) end)
                  end },
                CONTAINER_IDS, function() return S.container end, function(v) set_container(v) end))
    add({ id = "reset", kind = "action", text = "Reset", enter = do_reset })
    if S.last_out and utils.file_info(S.last_out) then
        add({ id = "play", kind = "action", text = "Play last export", detail = basename(S.last_out), enter = function()
            local f = S.last_out
            ui_close()
            mp.commandv("loadfile", f, "replace")
        end })
    end
    if S.skipped > 0 then
        add({ id = "skipped", kind = "info", text = string.format("%d stream track(s) skipped: not local files", S.skipped) })
    end
    return { title = "Remux", subtitle = basename(S.path), badge = CONT[S.container].ext:upper(), items = items, issues = issues }
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local function guarded(fn)
    return function()
        if not has_input then
            return mp.osd_message("remux: needs mpv >= 0.39 (mp.input missing)", 6)
        end
        if not style then
            return mp.osd_message("remux: " .. tostring(style_err), 8)
        end
        local ok, err = pcall(fn)
        if not ok then
            msg.error(tostring(err))
            mp.osd_message("remux error: " .. tostring(err), 10)
        end
    end
end

local function open_menu()
    if S.job then return mp.osd_message("Export is running (ESC cancels)", 3) end
    if not sync() then return end
    card_hide()
    UI.open = true
    UI.stack = { { build = build_main, sel = 1, scroll = 0 } }
    ui_bind()
    ui_refresh()
end

mp.add_key_binding("Ctrl+R", "toggle", guarded(function()
    if UI.open then ui_close() else open_menu() end
end))
mp.add_key_binding("Ctrl+Alt+r", "export", guarded(function()
    if sync() then start_export() end
end))

mp.observe_property("path", "string", function()
    S.path = nil
    if UI.open then ui_close() end
end)
mp.observe_property("osd-dimensions", "native", function()
    if UI.open then ui_render() end
    if S.card then card_show(S.card) end
end)

mp.register_event("shutdown", function()
    if S.job then mp.abort_async_command(S.job) end
    if S.xjob then mp.abort_async_command(S.xjob) end
    cleanup_tmp()
end)

msg.info(string.format("loaded as '%s' (ffmpeg: %s, style: %s)",
    mp.get_script_name(), FFMPEG, style and "ok" or ("MISSING: " .. tostring(style_err))))
