local mp = require("mp")
local utils = require("mp.utils")
local display_protocol = os.getenv("XDG_SESSION_TYPE")

local options = {
    copy_keybind = [[ ["ctrl+c", "meta+c"] ]],
    paste_keybind = [[ ["ctrl+v", "meta+v"] ]],
    copy_sub_keybind = [[ ["ctrl+C", "meta+C"] ]],
    open_keybind = "o",

    linux_copy_command = { "xclip", "-silent", "-selection", "clipboard", "-in" },
    linux_paste_command = "xclip -selection clipboard -o",
    copy_youtube_timestamp = true,
}

if display_protocol == "wayland" then
    options.linux_copy_command = { "wl-copy" }
    options.linux_paste_command = "wl-paste"
end

(require "mp.options").read_options(options)
options.copy_keybind = utils.parse_json(options.copy_keybind)
options.paste_keybind = utils.parse_json(options.paste_keybind)
options.copy_sub_keybind = utils.parse_json(options.copy_sub_keybind)

local device = "linux"
if os.getenv("windir") ~= nil then
    device = "windows"
elseif os.execute('[ -d "/Applications" ]') == 0 and os.execute('[ -d "/Library" ]') == 0 then
    device = "mac"
end

local function bind_keys(keys, name, func)
    if not keys then mp.add_forced_key_binding(keys, name, func); return end
    for i = 1, #keys do
        mp.add_forced_key_binding(keys[i], name .. (i == 1 and "" or i), func)
    end
end

local function is_url(s)
    return string.match(s, "^https?://%S+$") ~= nil
end

local function extract_timestamp(str)
    if not str then return nil end
    local h, m, s = string.match(str, "^%s*(%d+):(%d%d):(%d%d)%s*$")
    if h and m and s then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    local m2, s2 = string.match(str, "^%s*(%d+):(%d%d)%s*$")
    if m2 and s2 then
        return tonumber(m2) * 60 + tonumber(s2)
    end
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

local function set_clipboard(text)
    local args
    if device == "mac" then
        args = { "/usr/bin/pbcopy" }
    elseif device == "linux" then
        args = options.linux_copy_command
    elseif device == "windows" then
        args = { "powershell", "-NoProfile", "-Command", "Add-Type -AssemblyName PresentationCore; [System.Windows.Clipboard]::SetText('" .. text:gsub("'", "''") .. "')" }
    end
    if args then mp.command_native_async({ name = "subprocess", args = args, stdin_data = text }) end
end

local function get_clipboard()
    if device == "mac" then
        -- Check text/URL clipboard first via pbpaste
        local handle = io.popen("/usr/bin/pbpaste 2>/dev/null")
        local txt = handle and handle:read("*a")
        if handle then handle:close() end

        -- If pbpaste has a URL or timestamp, use it immediately
        if txt and (is_url(txt:match("^%s*(.-)%s*$")) or extract_timestamp(txt)) then
            return txt
        end

        -- Check Finder file clipboard via AppleScript
        local as_cmd = "osascript -e 'try' -e 'set clipItem to (the clipboard as «class furl»)' -e 'return POSIX path of clipItem' -e 'end try' 2>/dev/null"
        handle = io.popen(as_cmd)
        local path_res = handle and handle:read("*a")
        if handle then handle:close() end

        if path_res and path_res:match("%S") then
            return path_res:match("^%s*(.-)%s*$")
        end

        return txt
    elseif device == "windows" then
        local handle = io.popen("powershell -NoProfile -Command \"$c = (Get-Clipboard -Format FileDropList)[0]; if (-not $c) { $c = Get-Clipboard -Raw -Format Text }; [Console]::Write($c)\"")
        local txt = handle and handle:read("*a")
        if handle then handle:close() end
        return txt
    else
        local handle = io.popen(options.linux_paste_command)
        local txt = handle and handle:read("*a")
        if handle then handle:close() end
        return txt
    end
end

local function paste()
    mp.osd_message("Checking clipboard...", 1)
    local clip = get_clipboard()
    if not clip then
        mp.osd_message("Could not read clipboard", 2)
        return
    end

    clip = clip:gsub("\r", ""):gsub("\n", ""):match("^%s*(.-)%s*$"):gsub('^"', ""):gsub('"$', "")
    if clip == "" then
        mp.osd_message("Clipboard is empty", 2)
        return
    end

    local clean_path = normalize_path(clip)
    local seconds = extract_timestamp(clip)

    local function add_item(type, val)
        if mp.get_property_number("playlist-count", 0) == 0 then
            mp.osd_message("Opening " .. type .. "...")
            mp.commandv("loadfile", val, "replace")
        else
            mp.osd_message("Added " .. type .. " to playlist")
            mp.commandv("loadfile", val, "append-play")
        end
    end

    if seconds then
        mp.osd_message("Seeking to: " .. clip, 2)
        mp.commandv("seek", seconds, "absolute", "exact")
    elseif is_url(clip) then
        add_item("URL", clip)
    elseif file_exists(clean_path) then
        add_item("file", clean_path)
    else
        mp.osd_message("Invalid clipboard content: " .. clip, 3)
    end
end

local function copy()
    local path = mp.get_property("path")
    if not path then return end
    path = path:match("^%s*(.-)%s*$")

    local is_yt = path:match("youtube%.com") or path:match("youtu%.be")
    local is_u = is_url(path)

    if is_u and not is_yt then
        local ua = mp.get_property("user-agent", "Mozilla/5.0")
        local ref = mp.get_property("referrer", "")
        local ua_str = string.format('--user-agent "%s"', ua)
        local ref_str = ref ~= "" and string.format('--referer "%s"', ref) or ""
        path = string.format('yt-dlp -q --impersonate chrome --cookies-from-browser "chrome:~/Library/Application Support/Google/Chrome Beta" %s %s -o - "%s" | mpv --force-seekable=yes --cache=yes --demuxer-max-bytes=60M --demuxer-max-back-bytes=50M -', ua_str, ref_str, path)
        path = path:gsub("%s+", " ")
        mp.osd_message("Copied yt-dlp command")
    elseif is_u and options.copy_youtube_timestamp then
        path = path:gsub("([&?])t=%d+", function(s) return s == "?" and "?" or "" end):gsub("[?&]$", "")
        local t = mp.get_property_number("time-pos", 0)
        if t > 0 then path = path .. (path:find("?") and "&" or "?") .. "t=" .. math.floor(t) end
        mp.osd_message("Copied YouTube URL")
    else
        mp.osd_message("Copied path")
    end

    set_clipboard(path)
end

local function open_current()
    local path = mp.get_property("path")
    if not path then return end
    local args
    if is_url(path) then
        if device == "windows" then args = { "powershell", "start", path }
        elseif device == "mac" then args = { "/usr/bin/open", path }
        else args = { "xdg-open", path } end
    else
        if device == "windows" then args = { "explorer", "/select,", path }
        elseif device == "mac" then args = { "/usr/bin/open", "-a", "Finder", "-R", path }
        else args = { "dbus-send", "--print-reply", "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems", "array:string:file://" .. path, "string:" } end
    end
    mp.command_native_async({ name = "subprocess", args = args })
end

local function copy_sub()
    local sub = mp.get_property("sub-text")
    if sub and sub ~= "" then
        set_clipboard(sub:gsub("\n", " "))
        mp.osd_message("Copied subtitle")
    else
        mp.osd_message("No subtitle to copy")
    end
end

bind_keys(options.copy_keybind, "copy", copy)
bind_keys(options.paste_keybind, "paste", paste)
bind_keys(options.copy_sub_keybind, "copy_sub", copy_sub)
mp.add_forced_key_binding(options.open_keybind, "open_current", open_current)