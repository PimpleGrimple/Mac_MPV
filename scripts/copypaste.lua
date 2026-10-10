local mp = require("mp")
local utils = require("mp.utils")

local options = {
    copy_keybind = [[ ["meta+c"] ]],
    paste_keybind = [[ ["meta+v"] ]],
    copy_timestamp_keybind = [[ ["meta+alt+c", "meta+shift+t"] ]],
    copy_timestamped_url = true,
    -- YouTube links: also copy the chosen ytdl-format (as #MBSTREAM, mpv-only).
    -- Set to no for a plain browser-friendly timestamped URL.
    copy_youtube_format = true,
}

(require "mp.options").read_options(options)
options.copy_youtube_format = (options.copy_youtube_format == true or options.copy_youtube_format == "yes" or options.copy_youtube_format == "true")
options.copy_keybind = utils.parse_json(options.copy_keybind)
options.paste_keybind = utils.parse_json(options.paste_keybind)
options.copy_timestamp_keybind = utils.parse_json(options.copy_timestamp_keybind)

local function bind_keys(keys, name, func)
    if not keys then return end
    for i = 1, #keys do
        mp.add_key_binding(keys[i], name .. (i == 1 and "" or i), func)
    end
end

local function is_url(s)
    return s and string.match(s, "^https?://%S+$") ~= nil
end

local function extract_timestamp(str)
    if not str then return nil end
    local h, m, s = string.match(str, "^%s*(%d+):(%d%d):(%d%d%.?%d*)%s*$")
    if h and m and s then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
    local m2, s2 = string.match(str, "^%s*(%d+):(%d%d%.?%d*)%s*$")
    if m2 and s2 then return tonumber(m2) * 60 + tonumber(s2) end
    return nil
end

local function extract_url_timestamp(url)
    if not url then return nil end
    local param = url:match("[?&#]t=([%w%.]+)") or url:match("[?&#]start=(%d+)") or url:match("[?&#]time=([%w%.]+)")
    if not param then return nil end

    -- Ignore huge Unix timestamps used for CDN authentication
    local max_reasonable_time = 1000000 

    local pure_sec = param:match("^(%d+%.?%d*)s?$")
    if pure_sec then 
        local sec = tonumber(pure_sec)
        if sec and sec <= max_reasonable_time then return sec end
    end

    local h = param:match("(%d+)h") or 0
    local m = param:match("(%d+)m") or 0
    local s = param:match("(%d+)s") or 0
    local total = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    if total > 0 and total <= max_reasonable_time then return total end
    return nil
end

local function normalize_path(path)
    if not path then return nil end
    if path:match("^file://") then
        path = path:gsub("^file://", "")
        path = path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    if path:sub(1, 1) == "~" then
        path = (os.getenv("HOME") or "") .. path:sub(2)
    end
    return path
end

local function file_exists(name)
    local target = normalize_path(name)
    if not target or target == "" then return false end
    local f = io.open(target, "r")
    if f ~= nil then io.close(f); return true else return false end
end

local function format_timestamp(sec)
    if not sec or sec < 0 then sec = 0 end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%02d:%02d:%02d", h, m, math.floor(s))
    else
        return string.format("%02d:%02d", m, math.floor(s))
    end
end

local function set_clipboard(text)
    mp.command_native_async({ name = "subprocess", playback_only = false, args = { "/usr/bin/pbcopy" }, stdin_data = text })
end

local function get_clipboard()
    local res = mp.command_native({name = "subprocess", playback_only = false, args = {"/usr/bin/pbpaste"}, capture_stdout = true})
    local txt = res.status == 0 and res.stdout or nil

    if txt then
        local trimmed = txt:match("^%s*(.-)%s*$")
        if is_url(trimmed) or extract_timestamp(trimmed) or trimmed:sub(1, 9) == "#MBSTREAM" then
            return txt
        end
    end

    local as_cmd = "try\nset clipItem to (the clipboard as «class furl»)\nreturn POSIX path of clipItem\nend try"
    local as_res = mp.command_native({name = "subprocess", playback_only = false, args = {"osascript", "-e", as_cmd}, capture_stdout = true})
    local path_res = as_res.status == 0 and as_res.stdout or nil

    if path_res and path_res:match("%S") then
        return path_res:match("^%s*(.-)%s*$")
    end
    return txt
end

local function parse_mbstream(raw)
    if not raw then return nil end
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 9) ~= "#MBSTREAM" then return nil end
    local json_part = trimmed:sub(10):match("^%s*(.-)%s*$")
    local ok, data = pcall(utils.parse_json, json_part)
    if ok and data and data.url and data.url ~= "" then return data end
    return nil
end

local function add_item(type, val, start_time, ytdl_format)
    local opts = {}
    if start_time then opts[#opts + 1] = "start=" .. start_time end
    if ytdl_format and ytdl_format ~= "" then
        -- %len%value syntax so [ ] / + > = in the selector survive option parsing
        opts[#opts + 1] = string.format("ytdl-format=%%%d%%%s", #ytdl_format, ytdl_format)
        -- ytdl:// forces the ytdl hook even for .m3u8 (which it excludes by default)
        if not val:match("^ytdl://") then val = "ytdl://" .. val end
    end
    local opt = #opts > 0 and table.concat(opts, ",") or nil
    if mp.get_property_number("playlist-count", 0) == 0 then
        mp.osd_message(string.format("Opening %s%s...", type, start_time and (" at " .. format_timestamp(start_time)) or ""))
        if opt then
            mp.commandv("loadfile", val, "replace", "-1", opt)
        else
            mp.commandv("loadfile", val, "replace")
        end
    else
        mp.osd_message(string.format("Added %s to playlist%s", type, start_time and (" (starts at " .. format_timestamp(start_time) .. ")") or ""))
        if opt then
            mp.commandv("loadfile", val, "append-play", "-1", opt)
        else
            mp.commandv("loadfile", val, "append-play")
        end
    end
end

local function paste()
    mp.osd_message("Checking clipboard...", 1)
    local clip = get_clipboard()
    if not clip then
        mp.osd_message("Could not read clipboard", 2)
        return
    end

    local mb = parse_mbstream(clip)
    if mb then
        if mb.ref and mb.ref ~= "" then mp.set_property("referrer", mb.ref) end
        if mb.ua and mb.ua ~= "" then mp.set_property("user-agent", mb.ua) end
        local url_time = extract_url_timestamp(mb.url)
        add_item("URL", mb.url, url_time, mb.format)
        return
    end

    clip = clip:gsub("\r", ""):gsub("\n", ""):match("^%s*(.-)%s*$"):gsub('^"', ""):gsub('"$', "")
    if clip == "" then
        mp.osd_message("Clipboard is empty", 2)
        return
    end

    local clean_path = normalize_path(clip)
    local seconds = extract_timestamp(clip)

    if seconds then
        mp.osd_message("Seeking to: " .. clip, 2)
        mp.commandv("seek", seconds, "absolute", "exact")
    elseif is_url(clip) then
        local url_time = extract_url_timestamp(clip)
        add_item("URL", clip, url_time)
    elseif file_exists(clean_path) then
        add_item("file", clean_path)
    else
        mp.osd_message("Invalid clipboard content: " .. (#clip > 80 and (clip:sub(1, 80) .. "...") or clip), 3)
    end
end

local function copy()
    local sub = mp.get_property("sub-text")
    if sub and sub:match("%S") then
        set_clipboard(sub:gsub("\n", " "))
        mp.osd_message("Copied subtitle")
        return
    end

    local path = mp.get_property("path")
    if not path then 
        mp.osd_message("Nothing to copy")
        return 
    end
    path = path:match("^%s*(.-)%s*$")

    -- Files opened with a format selector are loaded as ytdl://URL; copy the
    -- plain URL and carry the selector along so pasting reproduces the choice.
    local via_ytdl = false
    if path:match("^ytdl://") then
        path = (path:gsub("^ytdl://", ""))
        via_ytdl = true
    end

    local is_yt = path:match("youtube%.com") or path:match("youtu%.be")
    local is_u = is_url(path)

    local yt_fmt = nil
    if is_yt and is_u and options.copy_youtube_format then
        local f = mp.get_property("ytdl-format")
        if f and f ~= "" then yt_fmt = f end
    end

    if is_u and (not is_yt or yt_fmt) then
        local payload
        if is_yt then
            -- keep the timestamp behaviour of plain YouTube copies
            local u = path:gsub("([&?])t=[%d%.]+", function(c) return c == "?" and "?" or "" end):gsub("[?&]$", "")
            local t = mp.get_property_number("time-pos", 0)
            if t > 0 then u = u .. (u:find("?") and "&" or "?") .. "t=" .. math.floor(t) end
            payload = { url = u }
        else
            payload = { url = path, ua = mp.get_property("user-agent", "Mozilla/5.0"), ref = mp.get_property("referrer", "") }
        end
        -- Include the active ytdl-format whenever one is set (covers files opened
        -- via the extension's play button too, not only ytdl:// paste).
        local f = mp.get_property("ytdl-format")
        if f and f ~= "" then payload.format = f end
        local json_str, err = utils.format_json(payload)
        
        if json_str then
            path = "#MBSTREAM\n" .. json_str
            mp.osd_message("Copied URL")
        else
            mp.osd_message("Failed to format stream")
            return
        end
    elseif is_u and options.copy_timestamped_url then
        path = path:gsub("([&?])t=[%d%.]+", function(s) return s == "?" and "?" or "" end):gsub("[?&]$", "")
        local t = mp.get_property_number("time-pos", 0)
        if t > 0 then path = path .. (path:find("?") and "&" or "?") .. "t=" .. math.floor(t) end
        mp.osd_message("Copied URL")
    else
        mp.osd_message("Copied path")
    end

    set_clipboard(path)
end

local function copy_timestamp()
    local t = mp.get_property_number("time-pos")
    if not t then
        mp.osd_message("No video playing", 2)
        return
    end
    local ts = format_timestamp(t)
    set_clipboard(ts)
    mp.osd_message("Copied timestamp: " .. ts, 2)
end

bind_keys(options.copy_keybind, "copy", copy)
bind_keys(options.paste_keybind, "paste", paste)
bind_keys(options.copy_timestamp_keybind, "copy_timestamp", copy_timestamp)

mp.register_script_message("copy-timestamp", copy_timestamp)