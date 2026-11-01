local mp = require("mp")
local utils = require("mp.utils")

local function trim(s) return s and s:match("^%s*(.-)%s*$") or "" end

local function unquote(s)
    s = trim(s)
    while true do
        local q = s:sub(1, 1)
        if (q == '"' or q == "'" or q == "`") and s:sub(-1) == q and #s >= 2 then
            s = trim(s:sub(2, -2))
        else
            break
        end
    end
    return s
end

local function is_url(s)
    return s and (s:match("^https?://%S+$") or s:match("^ytdl://%S+$") or s:match("^magnet:%?%S+$")) ~= nil
end

local function extract_timestamp(str)
    if not str then return nil end
    local h, m, s = str:match("^%s*(%d+):(%d%d):(%d%d%.?%d*)%s*$")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
    local m2, s2 = str:match("^%s*(%d+):(%d%d%.?%d*)%s*$")
    return m2 and (tonumber(m2) * 60 + tonumber(s2)) or nil
end

local function extract_url_timestamp(url)
    if not url then return nil end
    local p = url:match("[?&#]t=([%w%.]+)") or url:match("[?&#]start=(%d+)")
    if not p then return nil end
    local sec = tonumber(p:match("^(%d+%.?%d*)s?$"))
    if sec and sec <= 1e6 then return sec end
    local h, m, s = p:match("(%d+)h") or 0, p:match("(%d+)m") or 0, p:match("(%d+)s") or 0
    local total = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    return (total > 0 and total <= 1e6) and total or nil
end

local function normalize_path(path)
    path = unquote(path)
    if path:match("^file://") then
        path = path:gsub("^file://localhost", ""):gsub("^file://", "")
        path = path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    if path:sub(1, 1) == "~" then
        path = (os.getenv("HOME") or "") .. path:sub(2)
    end
    return path
end

local function resolve_file_path(path)
    if not path or path == "" then return nil end
    local norm = normalize_path(path)
    local info = utils.file_info(norm)
    if info and (info.is_file or info.is_dir) then return norm end
    local unescaped = norm:gsub("\\(.)", "%1")
    if unescaped ~= norm then
        info = utils.file_info(unescaped)
        if info and (info.is_file or info.is_dir) then return unescaped end
    end
    return nil
end

local function format_timestamp(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h, m, s = math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60
    return h > 0 and string.format("%02d:%02d:%02d", h, m, s) or string.format("%02d:%02d", m, s)
end

-- Native clipboard (mpv property clipboard/text)
local function set_clipboard(text)
    if text then mp.set_property("clipboard/text", text) end
end

local function get_clipboard()
    mp.commandv("update-clipboard", "text")
    local txt = mp.get_property("clipboard/text")
    return (txt and txt ~= "") and txt or nil
end

local function parse_mbstream(raw)
    local t = trim(raw)
    if t:sub(1, 9) ~= "#MBSTREAM" then return nil end
    local data = utils.parse_json(trim(t:sub(10)))
    return (data and data.url and data.url ~= "") and data or nil
end

local function add_item(kind, val, start_time, extra)
    extra = extra or {}
    local opts = {}
    if start_time then opts["start"] = tostring(start_time) end
    if extra.ua and extra.ua ~= "" then opts["user-agent"] = extra.ua end
    if extra.ref and extra.ref ~= "" then opts["referrer"] = extra.ref end
    if extra.format and extra.format ~= "" then
        opts["ytdl-format"] = extra.format
        if not val:match("^ytdl://") then val = "ytdl://" .. val end
    end

    local has_pl = mp.get_property_number("playlist-count", 0) > 0
    local at = start_time and (" (starts at " .. format_timestamp(start_time) .. ")") or ""
    mp.osd_message(has_pl and string.format("Added %s to playlist%s", kind, at)
                          or string.format("Opening %s%s...", kind, at))

    local cmd = { name = "loadfile", url = val, flags = has_pl and "append-play" or "replace" }
    if next(opts) then cmd.options = opts end
    mp.command_native(cmd)
end

local function paste()
    mp.osd_message("Checking clipboard...", 1)
    local clip = get_clipboard()
    if not clip then return mp.osd_message("Clipboard is empty", 2) end

    local mb = parse_mbstream(clip)
    if mb then
        return add_item("URL", mb.url, extract_url_timestamp(mb.url), { format = mb.format, ua = mb.ua, ref = mb.ref })
    end

    clip = unquote(clip:gsub("[\r\n]", " "))
    if clip == "" then return mp.osd_message("Clipboard is empty", 2) end

    local seconds = extract_timestamp(clip)
    local file_path = resolve_file_path(clip)

    if seconds then
        mp.osd_message("Seeking to: " .. clip, 2)
        mp.commandv("seek", seconds, "absolute", "exact")
    elseif is_url(clip) then
        add_item("URL", clip, extract_url_timestamp(clip))
    elseif file_path then
        add_item("file", file_path)
    else
        mp.osd_message("Invalid clipboard content: " .. (#clip > 80 and (clip:sub(1, 80) .. "...") or clip), 3)
    end
end

local function strip_time(url)
    local out = url:gsub("[?&]t=[%w%.]+&?", function(m) return m:sub(1, 1) == "?" and "?" or "" end)
    return (out:gsub("[?&]$", ""))
end

local function with_time(url, t)
    return t > 0 and (url .. (url:find("?", 1, true) and "&" or "?") .. "t=" .. math.floor(t)) or url
end

local function get_current_target()
    local path = mp.get_property("path")
    if not path or path == "" then return nil end
    path = trim(path):gsub("^ytdl://", "")
    if not is_url(path) and not path:match("^/") then
        local wd = mp.get_property("working-directory", "")
        if wd ~= "" then path = utils.join_path(wd, path) end
    end
    return path
end

local function copy_sub(quiet)
    local sub = mp.get_property("sub-text")
    if sub and sub:match("%S") then
        set_clipboard((sub:gsub("\n", " ")))
        mp.osd_message("Copied subtitle")
        return true
    end
    if not quiet then mp.osd_message("No subtitle to copy", 2) end
    return false
end

local function copy()
    if copy_sub(true) then return end

    local path = get_current_target()
    if not path then return mp.osd_message("Nothing to copy") end

    local is_yt = path:match("youtube%.com") or path:match("youtu%.be")
    local is_u = is_url(path)
    local ytdl_format = mp.get_property("ytdl-format")
    if ytdl_format == "" then ytdl_format = nil end

    if is_u and (not is_yt or ytdl_format) then
        local payload = is_yt and { url = strip_time(path) } or {
            url = path,
            ua = mp.get_property("user-agent", "Mozilla/5.0"),
            ref = mp.get_property("referrer", ""),
        }
        if ytdl_format then payload.format = ytdl_format end
        local json_str = utils.format_json(payload)
        if json_str then
            set_clipboard("#MBSTREAM\n" .. json_str)
            return mp.osd_message("Copied URL")
        end
    end

    set_clipboard(path)
    mp.osd_message("Copied path")
end

local function copy_timestamp()
    local t = mp.get_property_number("time-pos")
    if not t then return mp.osd_message("No video playing", 2) end

    local path = get_current_target()
    if path and is_url(path) then
        set_clipboard(with_time(strip_time(path), t))
        return mp.osd_message("Copied timestamped URL", 2)
    end

    local ts = format_timestamp(t)
    set_clipboard(ts)
    mp.osd_message("Copied timestamp: " .. ts, 2)
end

local function open_current()
    local path = get_current_target()
    if not path then return end
    local is_u = is_url(path)
    local target = is_u and path or normalize_path(path)
    local args = is_u and { "/usr/bin/open", target } or { "/usr/bin/open", "-a", "Finder", "-R", target }
    mp.command_native_async({ name = "subprocess", playback_only = false, args = args })
end

local bindings = {
    { keys = { "meta+c" }, name = "copy", fn = copy },
    { keys = { "meta+v" }, name = "paste", fn = paste },
    { keys = { "meta+alt+c" }, name = "copy_timestamp", fn = copy_timestamp },
    { keys = { "meta+C" }, name = "copy_sub", fn = function() copy_sub(false) end },
    { keys = { "Alt+o" }, name = "open_current", fn = open_current },
}

for _, b in ipairs(bindings) do
    if b.keys then
        for i, k in ipairs(b.keys) do
            mp.add_key_binding(k, b.name .. (i == 1 and "" or tostring(i)), b.fn)
        end
    else
        mp.add_key_binding(nil, b.name, b.fn)
    end
    mp.register_script_message(b.name, b.fn)
    if b.name:find("_") then
        mp.register_script_message(b.name:gsub("_", "-"), b.fn)
    end
end
